import SwiftUI
import AVFoundation
import AppKit

// MARK: differenze tra i due rapporti
struct ReportDiff {
    var resolved: [Finding] = [], remaining: [Finding] = [], added: [Finding] = []
    var changed: [(label: String, before: String, after: String)] = []
}
func diffReports(_ a: Report, _ b: Report) -> ReportDiff {
    func key(_ f: Finding) -> String { f.area + "|" + f.title }
    let ka = Set(a.findings.filter { $0.sev > .ok }.map(key)), kb = Set(b.findings.filter { $0.sev > .ok }.map(key))
    var d = ReportDiff()
    d.resolved = a.findings.filter { $0.sev > .ok && !kb.contains(key($0)) }.sorted { $0.sev > $1.sev }
    d.remaining = b.findings.filter { $0.sev > .ok && ka.contains(key($0)) }.sorted { $0.sev > $1.sev }
    d.added = b.findings.filter { $0.sev > .ok && !ka.contains(key($0)) }.sorted { $0.sev > $1.sev }
    func rows(_ r: Report) -> [(String, String, Int)] { r.tech.sorted { $0.order < $1.order }.flatMap { s in s.rows.map { ("\(s.title): \($0.k)", $0.v, s.order) } } }
    let ra = Dictionary(rows(a).map { ($0.0, $0.1) }, uniquingKeysWith: { x, _ in x }), rb = Dictionary(rows(b).map { ($0.0, $0.1) }, uniquingKeysWith: { x, _ in x })
    for (k, _, _) in rows(b) + rows(a).filter({ rb[$0.0] == nil }) {
        let x = ra[k], y = rb[k]; if x != y, !d.changed.contains(where: { $0.label == k }) { d.changed.append((k, x ?? "—", y ?? "—")) }
    }
    return d
}

// MARK: estrazione di fotogrammi, audio e sottotitoli da un punto del film
enum CompareMedia {
    static func still(_ url: URL, at t: Double, tmp: URL, name: String) -> NSImage? {
        guard let ff = tool("ffmpeg") else { return nil }; let out = tmp.appendingPathComponent(name + ".jpg"); try? FileManager.default.removeItem(at: out)
        run(ff, ["-nostdin", "-y", "-v", "error", "-ss", String(max(0, t)), "-i", url.path, "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=720:-2", "-q:v", "3", out.path])
        return NSImage(contentsOf: out)
    }
    static func audio(_ url: URL, at t: Double, len: Double, track: Int, tmp: URL, name: String) -> URL? {
        guard let ff = tool("ffmpeg") else { return nil }; let out = tmp.appendingPathComponent(name + ".wav"); try? FileManager.default.removeItem(at: out)
        run(ff, ["-nostdin", "-y", "-v", "error", "-ss", String(max(0, t)), "-t", String(len), "-i", url.path, "-map", "0:a:\(track)", "-vn", "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le", out.path])
        return FileManager.default.fileExists(atPath: out.path) ? out : nil
    }
    static func subtitles(_ url: URL, at t: Double, track: Int) -> String {
        guard let ff = tool("ffmpeg") else { return "" }; let start = max(0, t - 20)
        let o = run(ff, ["-nostdin", "-y", "-v", "error", "-ss", String(start), "-t", "40", "-i", url.path, "-map", "0:s:\(track)", "-f", "srt", "-"])
        let rel = t - start; let near = parseSRT(o.text).filter { $0.e >= rel - 4 && $0.s <= rel + 4 }.prefix(3)
        return near.map { "[\(hms($0.s + start))] " + $0.t.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }
}

/// Una coppia di film da confrontare (prima / dopo) con i loro rapporti.
struct ComparePair: Identifiable { let id = UUID(); var before: URL; var beforeReport: Report; var after: URL; var afterReport: Report; var lines: [String] = []
    var swapped: ComparePair { ComparePair(before: after, beforeReport: afterReport, after: before, afterReport: beforeReport, lines: []) } }

final class CompareModel: ObservableObject {
    let before: URL, after: URL; let beforeReport: Report, afterReport: Report
    @Published var time: Double; @Published var stillA: NSImage?; @Published var stillB: NSImage?; @Published var cueA = ""; @Published var cueB = ""; @Published var busy = false
    @Published var audioTrackAfter = 0; @Published var subTrackAfter = 0; @Published var playing: String?
    private var wavA: URL?, wavB: URL?; private var pA: AVAudioPlayer?, pB: AVAudioPlayer?
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("booth-compare-" + UUID().uuidString)
    init(pair: ComparePair) {
        before = pair.before; after = pair.after; beforeReport = pair.beforeReport; afterReport = pair.afterReport
        let first = beforeReport.findings.filter { $0.sev >= .warn }.compactMap(\.time).first ?? afterReport.duration * 0.35
        time = min(max(0, first), max(0, afterReport.duration - 30))
        audioTrackAfter = afterReport.audioTracks.firstIndex { $0.isDefault } ?? 0; subTrackAfter = afterReport.subTracks.firstIndex { !$0.forced && !$0.image } ?? 0
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: tmp) }
    /// La traccia «prima» che corrisponde a quella scelta «dopo»: stessa lingua (e codec se possibile), altrimenti stessa posizione.
    func match(_ tracks: [TrackInfo], like t: TrackInfo?) -> Int {
        guard let t = t else { return 0 }
        return tracks.firstIndex { $0.lang == t.lang && $0.title == t.title && $0.forced == t.forced } ?? tracks.firstIndex { $0.lang == t.lang && $0.forced == t.forced } ?? min(t.ord, max(0, tracks.count - 1))
    }
    var problemTimes: [(String, Double)] { beforeReport.findings.compactMap { f in f.time.map { (f.title, $0) } }.prefix(12).map { ($0.0, $0.1) } }
    func load() {
        stop(); busy = true; let t = time, a = after, b = before
        let at = afterReport.audioTracks.indices.contains(audioTrackAfter) ? audioTrackAfter : 0
        let bt = match(beforeReport.audioTracks, like: afterReport.audioTracks.indices.contains(at) ? afterReport.audioTracks[at] : nil)
        let st = afterReport.subTracks.indices.contains(subTrackAfter) ? subTrackAfter : 0
        let sb = match(beforeReport.subTracks, like: afterReport.subTracks.indices.contains(st) ? afterReport.subTracks[st] : nil)
        let hasA = !afterReport.audioTracks.isEmpty, hasS = !afterReport.subTracks.isEmpty && !(afterReport.subTracks.indices.contains(st) && afterReport.subTracks[st].image)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ia = CompareMedia.still(a, at: t, tmp: self.tmp, name: "a"), ib = CompareMedia.still(b, at: t, tmp: self.tmp, name: "b")
            let ca = hasS ? CompareMedia.subtitles(a, at: t, track: st) : "", cb = hasS ? CompareMedia.subtitles(b, at: t, track: sb) : ""
            let wa = hasA ? CompareMedia.audio(a, at: t, len: 20, track: at, tmp: self.tmp, name: "after") : nil, wb = hasA ? CompareMedia.audio(b, at: t, len: 20, track: bt, tmp: self.tmp, name: "before") : nil
            DispatchQueue.main.async { self.stillA = ia; self.stillB = ib; self.cueA = ca; self.cueB = cb; self.wavA = wa; self.wavB = wb
                self.pA = wa.flatMap { try? AVAudioPlayer(contentsOf: $0) }; self.pB = wb.flatMap { try? AVAudioPlayer(contentsOf: $0) }; self.pA?.prepareToPlay(); self.pB?.prepareToPlay(); self.busy = false }
        }
    }
    func stop() { pA?.stop(); pB?.stop(); pA?.currentTime = 0; pB?.currentTime = 0; playing = nil }
    /// Riproduce «prima» o «dopo»; se si cambia mentre suona, continua dallo stesso istante (confronto A/B).
    func play(_ which: String) {
        let (p, o) = which == "prima" ? (pB, pA) : (pA, pB)
        guard let p = p else { return }
        let pos = o?.isPlaying == true ? (o?.currentTime ?? 0) : 0
        o?.stop(); p.currentTime = pos; p.play(); playing = which
    }
}

struct CompareView: View {
    @StateObject var m: CompareModel; @Environment(\.dismiss) private var dismiss; let fixLines: [String]; var swap: (() -> Void)?
    init(pair: ComparePair, swap: (() -> Void)? = nil) { _m = StateObject(wrappedValue: CompareModel(pair: pair)); fixLines = pair.lines; self.swap = swap }
    var body: some View {
        let d = diffReports(m.beforeReport, m.afterReport)
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 2) { Text("Prima e dopo").font(.title3.weight(.semibold))
                Text("Prima: \(m.before.lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1); Text("Dopo: \(m.after.lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); if let s = swap { Button { m.stop(); s() } label: { Label("Inverti prima e dopo", systemImage: "arrow.left.arrow.right") } }
                Button("Chiudi") { m.stop(); dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            Divider()
            ScrollViewReader { proxy in ScrollView { VStack(alignment: .leading, spacing: 20) {
                verdicts
                summary(d)
                media.id("media")
            }.padding(18) }
            .onAppear { if ProcessInfo.processInfo.environment["BOOTH_SCROLLMEDIA"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { proxy.scrollTo("media", anchor: .top) } } } }   // solo per le prove a vista
        }.frame(width: 860, height: 760).onAppear { m.load() }
    }
    var verdicts: some View {
        HStack(spacing: 14) { pill("Prima", m.beforeReport); Image(systemName: "arrow.right").foregroundStyle(.secondary); pill("Dopo", m.afterReport) }
    }
    func pill(_ t: String, _ r: Report) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(t).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) { Image(systemName: r.worst.symbol); Text(r.verdict).fontWeight(.medium) }.foregroundStyle(r.worst.color).padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(r.worst.color.opacity(0.12)))
            Text("\(r.essential.count) indispensabili · \(r.extras.count) migliorie").font(.caption).foregroundStyle(.secondary) }
    }
    func summary(_ d: ReportDiff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cosa è cambiato").font(.headline)
            if !fixLines.isEmpty { VStack(alignment: .leading, spacing: 3) { ForEach(Array(fixLines.enumerated()), id: \.offset) { Text("• " + $0.element).font(.callout.monospacedDigit()).foregroundStyle(.secondary) } } }
            list("Risolti", d.resolved, "checkmark.circle.fill", .green)
            list("Ancora presenti", d.remaining, "exclamationmark.circle", .secondary)
            list("Nuovi dopo la correzione", d.added, "xmark.octagon.fill", .red)
            if !d.changed.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("Dati tecnici diversi").font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(Array(d.changed.enumerated()), id: \.offset) { r in HStack(alignment: .top) { Text(r.element.label).frame(width: 260, alignment: .leading).foregroundStyle(.secondary)
                    Text(r.element.before).frame(width: 180, alignment: .leading); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(r.element.after).fontWeight(.medium) }.font(.caption) } } }
        }
    }
    @ViewBuilder func list(_ title: String, _ fs: [Finding], _ icon: String, _ color: Color) -> some View {
        if !fs.isEmpty { VStack(alignment: .leading, spacing: 3) { Text("\(title) (\(fs.count))").font(.subheadline.weight(.semibold)).padding(.top, 2)
            ForEach(fs) { f in HStack(alignment: .top, spacing: 6) { Image(systemName: icon).foregroundStyle(color).frame(width: 16); Text(f.title).font(.callout) } } } }
    }
    var media: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Guarda e ascolta").font(.headline)
            HStack { Text(hms(m.time)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .leading)
                Slider(value: $m.time, in: 0...max(1, m.afterReport.duration - 25), onEditingChanged: { if !$0 { m.load() } })
                Menu("Punti dei problemi") { ForEach(Array(m.problemTimes.enumerated()), id: \.offset) { p in Button("\(hms(p.element.1)) — \(p.element.0)") { m.time = min(p.element.1, max(0, m.afterReport.duration - 25)); m.load() } }
                    if m.problemTimes.isEmpty { Text("Nessun punto indicato") } }.fixedSize() }
            if m.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Estraggo fotogrammi e audio…").font(.caption).foregroundStyle(.secondary) } }
            HStack(alignment: .top, spacing: 12) { frame("Prima", m.stillB, m.cueB); frame("Dopo", m.stillA, m.cueA) }
            HStack(spacing: 10) {
                if !m.afterReport.audioTracks.isEmpty {
                    Picker("Traccia audio", selection: Binding(get: { m.audioTrackAfter }, set: { m.audioTrackAfter = $0; m.load() })) { ForEach(m.afterReport.audioTracks) { Text("\($0.ord + 1) · \(langLabel($0.lang)) · \($0.codec.uppercased())").tag($0.ord) } }.frame(width: 300)
                    Button { m.play("prima") } label: { Label("Ascolta prima", systemImage: "play.fill") }.tint(m.playing == "prima" ? .accentColor : nil)
                    Button { m.play("dopo") } label: { Label("Ascolta dopo", systemImage: "play.fill") }.tint(m.playing == "dopo" ? .accentColor : nil)
                    Button { m.stop() } label: { Label("Ferma", systemImage: "stop.fill") }
                } else { Text("Nessuna traccia audio").foregroundStyle(.secondary) }
            }
            Text("Si ascoltano 20 secondi dal punto scelto, in stereo. Premendo l'altro pulsante mentre suona, il confronto continua dallo stesso istante.").font(.caption).foregroundStyle(.secondary)
            if m.afterReport.subTracks.count > 1 { Picker("Sottotitoli", selection: Binding(get: { m.subTrackAfter }, set: { m.subTrackAfter = $0; m.load() })) { ForEach(m.afterReport.subTracks) { Text("\($0.ord + 1) · \(langLabel($0.lang))\($0.forced ? " (forzati)" : "")").tag($0.ord) } }.frame(width: 340) }
        }
    }
    func frame(_ t: String, _ img: NSImage?, _ cue: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(t).font(.subheadline.weight(.semibold))
            ZStack { Rectangle().fill(Color.secondary.opacity(0.12)); if let i = img { Image(nsImage: i).resizable().scaledToFit() } else { Image(systemName: "photo").foregroundStyle(.secondary) } }.aspectRatio(16 / 9, contentMode: .fit).cornerRadius(6)
            Text(cue.isEmpty ? "(nessun sottotitolo in questo punto)" : cue).font(.caption).foregroundStyle(cue.isEmpty ? .tertiary : .primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).textSelection(.enabled) }
    }
}
