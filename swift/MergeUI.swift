import SwiftUI
import AVKit
import AppKit

/// I due film da unire (dal menu, dalla barra o da riga di comando per le prove a vista).
struct MergeRequest: Identifiable { let id = UUID(); var urls: [URL] }

final class MergeModel: ObservableObject {
    let urls: [URL]
    @Published var srcs: [MergeSource] = []; @Published var loadError: String?
    @Published var video = 0; @Published var audio: [String] = []; @Published var subs: Set<String> = []; @Published var defaultAudio: String?
    @Published var alignment: Alignment?; @Published var alignFail: String?; @Published var aligning = false; private var alignKey = ""
    @Published var progress = 0.0; @Published var stage = ""; @Published var creating = false; @Published var result: FixResult?
    @Published var previewTime = 0.0; @Published var previewBusy = false; @Published var previewError: String?; @Published var player: AVPlayer?
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("booth-merge-" + UUID().uuidString)
    private var previewN = 0
    init(urls: [URL]) { self.urls = urls; try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: tmp) }

    var allTracks: [MergeTrack] { srcs.flatMap(\.tracks) }
    var bestVideo: Int { (srcs.count == 2 && (srcs[1].video?.score ?? -1e9) > (srcs[0].video?.score ?? -1e9)) ? 1 : 0 }
    var plan: MergePlan {
        let order = audio.sorted { a, b in a == defaultAudio ? true : b == defaultAudio ? false : (allTracks.firstIndex { $0.id == a } ?? 0) < (allTracks.firstIndex { $0.id == b } ?? 0) }   // la predefinita per prima
        return MergePlan(video: video, audio: order, subs: allTracks.filter { $0.kind == "s" && subs.contains($0.id) }.map(\.id), defaultAudio: defaultAudio, output: nil)
    }
    var needsAlign: Bool { srcs.count == 2 && needsAlignment(plan) }
    /// La traccia dell'altra copia su cui si misura l'allineamento: la prima scelta, altrimenti la prima audio di quel file.
    var alignTrack: MergeTrack? {
        guard srcs.count == 2 else { return nil }
        return allTracks.first { $0.kind == "a" && $0.src != video && audio.contains($0.id) } ?? srcs[1 - video].tracks.first { $0.kind == "a" }
    }
    var ready: Bool { !audio.isEmpty && (!needsAlign || alignment != nil) && !aligning && !creating }
    var output: URL? { srcs.count == 2 ? mergeOutputURL(srcs[video].url) : nil }

    func load() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let a = loadMergeSource(self.urls[0], src: 0), b = loadMergeSource(self.urls[1], src: 1)
            DispatchQueue.main.async {
                guard let a = a, let b = b else { self.loadError = "Non riesco a leggere uno dei due file."; return }
                self.srcs = [a, b]; let s = autoSelect(self.srcs)
                self.video = s.video; self.audio = s.audio; self.subs = Set(s.subs); self.defaultAudio = s.def
                self.previewTime = (a.video?.duration ?? 600) * 0.3
                self.selectionChanged()
            }
        }
    }
    func toggleAudio(_ id: String) {
        if let i = audio.firstIndex(of: id) { audio.remove(at: i); if defaultAudio == id { defaultAudio = audio.first } } else { audio.append(id); if defaultAudio == nil { defaultAudio = id } }
        selectionChanged()
    }
    func toggleSub(_ id: String) { if subs.contains(id) { subs.remove(id) } else { subs.insert(id) }; selectionChanged() }
    func setVideo(_ v: Int) { video = v; selectionChanged() }
    /// Dopo ogni cambio di scelta: se serve un allineamento diverso da quello già fatto, lo rifà.
    func selectionChanged() {
        result = nil
        guard needsAlign, let ot = alignTrack else { alignment = nil; alignFail = nil; alignKey = ""; return }
        let key = "\(video)|\(ot.id)"; guard key != alignKey else { return }
        alignKey = key; alignment = nil; alignFail = nil; aligning = true; progress = 0; stage = "Allineamento…"
        let v = srcs[video], o = srcs[1 - video]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = alignAudio(v: v, o: o, oTrack: ot) { p, s in DispatchQueue.main.async { self?.progress = p; self?.stage = s } }
            DispatchQueue.main.async {
                guard let self = self, self.alignKey == key else { return }
                self.aligning = false
                switch r { case .ok(let a): self.alignment = a; self.preview(); case .fail(let why, _): self.alignFail = why }
            }
        }
    }
    /// Sposta l'audio dell'altra copia di un fotogramma (circa 40 ms) e rifà l'anteprima.
    func nudge(_ delta: Double) { guard alignment != nil else { return }; alignment!.nudge += delta; result = nil; preview() }
    var cutPoints: [(String, Double)] {
        guard let a = alignment else { return [] }
        return a.segments.enumerated().compactMap { i, s in i == 0 ? nil : (s.d == nil ? "Silenzio" : "Taglio", s.start) }
    }
    func preview(at t: Double? = nil) {
        if let t = t { previewTime = t }
        guard srcs.count == 2, !audio.isEmpty, !needsAlign || alignment != nil else { return }
        previewBusy = true; previewError = nil; previewN += 1
        let n = previewN, out = tmp.appendingPathComponent("anteprima\(n).mp4"), s = srcs, p = plan, a = alignment, at = max(0, previewTime - 5)   // 5 s prima del punto scelto: si vede l'arrivo
        player?.pause()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = renderPreview(s, p, alignment: a, at: at, len: 15, out: out)
            DispatchQueue.main.async {
                guard let self = self, n == self.previewN else { return }
                self.previewBusy = false; self.previewError = err
                if err == nil { let pl = AVPlayer(url: out); self.player = pl; pl.play() }
            }
        }
    }
    func create(done: @escaping (URL) -> Void) {
        guard ready else { return }
        player?.pause(); creating = true; result = nil; progress = 0; stage = "Preparazione…"
        let s = srcs, p = plan, a = needsAlign ? alignment : nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = runMerge(s, p, alignment: a) { v, st in DispatchQueue.main.async { self?.progress = v; self?.stage = st } }
            DispatchQueue.main.async { self?.creating = false; self?.result = r; if r.ok, let u = r.newURL { done(u) } }
        }
    }
}

struct MergeView: View {
    @StateObject var m: MergeModel; @ObservedObject var store: Store; @Environment(\.dismiss) private var dismiss
    init(urls: [URL], store: Store) { _m = StateObject(wrappedValue: MergeModel(urls: urls)); self.store = store }
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 2) { Text("Unisci due copie").font(.title3.weight(.semibold))
                Text("L'immagine migliore da una copia, l'audio italiano dall'altra: l'app li allinea e ti fa controllare prima di creare il file.").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("Chiudi") { m.player?.pause(); dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            Divider()
            if let e = m.loadError { Text(e).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if m.srcs.count < 2 { ProgressView("Leggo i due film…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView { VStack(alignment: .leading, spacing: 22) { videoSection; audioSection; if m.allTracks.contains(where: { $0.kind == "s" }) { subsSection }; alignSection }.padding(18) }
                Divider(); footer.padding(14)
            }
        }.frame(width: 920, height: 820).onAppear { m.load() }
    }
    // MARK: immagine
    var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Immagine").font(.headline)
            HStack(alignment: .top, spacing: 12) { ForEach(0..<2, id: \.self) { i in videoCard(i) } }
        }
    }
    func videoCard(_ i: Int) -> some View {
        let s = m.srcs[i], sel = m.video == i
        return Button { m.setVideo(i) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack { Image(systemName: sel ? "largecircle.fill.circle" : "circle").foregroundStyle(sel ? Color.accentColor : .secondary); Text(i == 0 ? "A" : "B").font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Text(s.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading); Spacer(minLength: 0)
                    if i == m.bestVideo { Text("Migliore").font(.caption.weight(.semibold)).foregroundStyle(.green).padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.13))) } }
                Text(s.video?.summary ?? "nessuna immagine").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("\(hms(s.probe.duration)) · \(fmtBytes(s.probe.size))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ForEach(s.video?.notes ?? [], id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.orange) }
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9).fill(sel ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(sel ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: sel ? 2 : 1))
        }.buttonStyle(.plain)
    }
    // MARK: audio e sottotitoli
    func trackLine(_ t: MergeTrack) -> some View {
        HStack(spacing: 8) {
            Text(t.src == 0 ? "A" : "B").font(.caption.weight(.bold)).frame(width: 18).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.15)))
            Text(langLabel(t.effLang)).fontWeight(t.isItalian ? .semibold : .regular).frame(width: 96, alignment: .leading)
            Text([t.codecLabel, t.channelLabel, t.kind == "a" && t.bitrate > 0 ? fmtRate(t.bitrate) : "", t.forced ? "forzati" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
            if t.src != m.video { Text("verrà allineata").font(.caption).foregroundStyle(.orange).fixedSize() }
            Text(t.title).font(.caption).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
        }
    }
    var audioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio").font(.headline)
            ForEach(m.allTracks.filter { $0.kind == "a" }) { t in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { m.audio.contains(t.id) }, set: { _ in m.toggleAudio(t.id) })).toggleStyle(.checkbox).labelsHidden()
                    trackLine(t); Spacer(minLength: 0)
                    if m.audio.contains(t.id) { Button { m.defaultAudio = t.id; m.selectionChanged(); m.preview() } label: { Label("Predefinita", systemImage: m.defaultAudio == t.id ? "star.fill" : "star") }.buttonStyle(.borderless).foregroundStyle(m.defaultAudio == t.id ? Color.accentColor : .secondary) }
                }
            }
            Text("Già scelta la traccia italiana migliore. La stella indica quella che parte da sola (ed è quella che senti nell'anteprima).").font(.caption).foregroundStyle(.secondary)
        }
    }
    var subsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sottotitoli").font(.headline)
            ForEach(m.allTracks.filter { $0.kind == "s" }) { t in
                HStack(spacing: 10) { Toggle("", isOn: Binding(get: { m.subs.contains(t.id) }, set: { _ in m.toggleSub(t.id) })).toggleStyle(.checkbox).labelsHidden(); trackLine(t); Spacer(minLength: 0) }
            }
            Text("I sottotitoli scelti restano spenti: partono da soli solo i «forzati».").font(.caption).foregroundStyle(.secondary)
        }
    }
    // MARK: allineamento e anteprima
    var alignSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allineamento e controllo a vista").font(.headline)
            if !m.needsAlign {
                Text("Tutte le tracce scelte sono già nella copia con l'immagine: nessun allineamento da fare.").foregroundStyle(.secondary)
            } else if m.aligning {
                VStack(alignment: .leading, spacing: 4) { ProgressView(value: m.progress).frame(maxWidth: 420); Text(m.stage).font(.caption).foregroundStyle(.secondary)
                    Text("Confronto musica ed effetti delle due copie in tutto il film: con un film intero ci vuole meno di un minuto.").font(.caption).foregroundStyle(.tertiary) }
            } else if let f = m.alignFail {
                Label(f, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let a = m.alignment {
                Label(a.isConstant ? "Audio allineato. Controlla l'anteprima: le labbra devono andare a tempo con le voci." : "Audio allineato in \(a.effSegments.filter { $0.d != nil }.count) parti. Controlla l'anteprima soprattutto nei punti rossi, dove le due copie hanno un montaggio diverso.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Dettagli") { VStack(alignment: .leading, spacing: 3) { ForEach(Array(a.lines.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4) }.font(.caption)
                PartsBar(alignment: a, duration: m.srcs[m.video].probe.duration, current: m.previewTime) { m.preview(at: $0) }
            }
            if !m.needsAlign || m.alignment != nil { previewBox }
        }
    }
    var previewBox: some View {
        let dur = m.srcs[m.video].probe.duration
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(Color.black)
                if let p = m.player { PlayerView(player: p) }
                if m.previewBusy { ProgressView("Preparo l'anteprima…").padding(10).background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial)) }
                if let e = m.previewError { Text(e).foregroundStyle(.red).padding() }
            }.frame(width: 640, height: 360).cornerRadius(6)
            HStack {
                Text(hms(m.previewTime)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .leading)
                Slider(value: $m.previewTime, in: 0...max(1, dur - 10), onEditingChanged: { if !$0 { m.preview() } }).frame(width: 330)
                Menu("Vai a…") {
                    ForEach(Array(m.cutPoints.enumerated()), id: \.offset) { p in Button("\(p.element.0) a \(hms(p.element.1))") { m.preview(at: p.element.1) } }
                    if !m.cutPoints.isEmpty { Divider() }
                    ForEach([0.1, 0.3, 0.5, 0.7, 0.9], id: \.self) { f in Button("\(Int(f * 100))% del film (\(hms(f * dur)))") { m.preview(at: f * dur) } }
                }.fixedSize()
                Button { m.preview() } label: { Label("Riguarda", systemImage: "arrow.counterclockwise") }
            }
            if m.alignment != nil && m.needsAlign {
                HStack(spacing: 10) {
                    Text("Labiale fuori sincrono?").font(.callout)
                    Button("Audio prima (−1 fotogramma)") { m.nudge(0.040) }
                    Button("Audio dopo (+1 fotogramma)") { m.nudge(-0.040) }
                    if let a = m.alignment, abs(a.nudge) > 0.0005 { Text(String(format: "correzione %@%.0f ms", a.nudge > 0 ? "−" : "+", abs(a.nudge) * 1000)).font(.callout.monospacedDigit()).foregroundStyle(.orange); Button("Azzera") { m.nudge(-a.nudge) } }
                }
                Text("L'anteprima parte 5 secondi prima del punto scelto e dura 15 secondi, con l'audio predefinito già allineato come nel film finale. Guarda un primo piano con dialoghi e, se ci sono, i punti di taglio.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    // MARK: creazione
    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = m.result {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(r.ok ? Color.green : Color.red).font(.system(size: 17))
                    VStack(alignment: .leading, spacing: 3) { Text(r.message).font(.callout.weight(.semibold)).textSelection(.enabled)
                        ForEach(Array(r.lines.filter { $0.hasPrefix("Sincronia") || $0.hasPrefix("Audio") }.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.secondary) }
                        if r.ok, let u = r.newURL { HStack { Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.controlSize(.small)
                            Button("Controlla con Booth") { m.player?.pause(); store.add([u]); dismiss() }.controlSize(.small).buttonStyle(.borderedProminent) } } }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill((r.ok ? Color.green : Color.red).opacity(0.09)))
            }
            HStack {
                if m.creating { ProgressView(value: m.progress).frame(width: 220); Text(m.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                else if let o = m.output { Text("Verrà creato «\(o.lastPathComponent)» accanto al film con l'immagine. I due file di partenza non vengono toccati.").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Crea il film unito") { m.create { _ in } }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!m.ready)
            }
        }
    }
}

/// Lettore di AppKit (il VideoPlayer di SwiftUI richiede una libreria che swiftc non collega e fa chiudere l'app).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let v = AVPlayerView(); v.controlsStyle = .inline; v.player = player; return v }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}
/// La durata del film con le parti dell'allineamento: blu = audio dell'altra copia, grigio = silenzio; le linee rosse sono i punti di taglio. Clic = anteprima da lì.
struct PartsBar: View {
    let alignment: Alignment; let duration: Double; let current: Double; var go: (Double) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                let w = g.size.width, x = { (t: Double) in CGFloat(t / max(1, duration)) * w }
                ZStack(alignment: .leading) {
                    ForEach(Array(alignment.segments.enumerated()), id: \.offset) { _, s in
                        Rectangle().fill(s.d == nil ? Color.secondary.opacity(0.35) : Color.accentColor.opacity(0.55)).frame(width: max(1, x(s.end) - x(s.start))).offset(x: x(s.start))
                    }
                    ForEach(Array(alignment.segments.enumerated().dropFirst()), id: \.offset) { _, s in Rectangle().fill(Color.red).frame(width: 2).offset(x: x(s.start) - 1) }
                    Rectangle().fill(Color.primary).frame(width: 2, height: 22).offset(x: x(current) - 1)
                }.frame(width: w, height: 14, alignment: .leading).cornerRadius(3).contentShape(Rectangle())   // larghezza esplicita: con gli offset lo ZStack prenderebbe solo quella della prima parte
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in go(max(0, min(duration, Double(v.location.x / w) * duration))) })
            }.frame(height: 22)
            HStack { Text("0:00"); Spacer(); Text(alignment.segments.count > 1 ? "\(alignment.segments.count - 1) punti di taglio (in rosso): clicca per guardarli" : "Un'unica parte: stesso montaggio"); Spacer(); Text(hms(duration)) }.font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: 640)
    }
}
