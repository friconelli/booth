import SwiftUI
import AVKit
import AppKit

/// I tratti di un doppiaggio rimesso a tempo in cui la misura non decide: si guardano le labbra e si sceglie lo spostamento.
struct DoubtRequest: Identifiable { let id = UUID(); var url: URL; var track: Int; var doubts: [DubDoubt] }

final class DoubtModel: ObservableObject {
    let req: DoubtRequest
    @Published var choice: [Double: Double] = [:]          // inizio del tratto → spostamento scelto (secondi, positivo = audio prima)
    @Published var current: Double?; @Published var player: AVPlayer?; @Published var previewBusy = false; @Published var previewError: String?
    @Published var applying = false; @Published var progress = 0.0; @Published var stage = ""; @Published var result: FixResult?
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("booth-doubt-" + UUID().uuidString)
    private var n = 0
    init(_ r: DoubtRequest) { req = r; try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: tmp) }

    func shift(_ d: DubDoubt) -> Double { choice[d.start] ?? 0 }
    var changed: [AudioShift] { req.doubts.compactMap { d in let s = shift(d); return abs(s) > 0.0005 ? AudioShift(start: d.start, end: d.end, shift: s) : nil } }

    func set(_ d: DubDoubt, _ s: Double) { choice[d.start] = s; preview(d) }
    /// 12 secondi dall'inizio del tratto, con l'audio spostato come scelto (immagine ridotta: serve solo a guardare le labbra).
    func preview(_ d: DubDoubt) {
        guard let ff = tool("ffmpeg") else { return }
        current = d.start; previewBusy = true; previewError = nil; player?.pause(); n += 1
        let out = tmp.appendingPathComponent("p\(n).mp4"), s = shift(d), at = d.start, url = req.url, k = req.track
        DispatchQueue.global().async {
            let r = run(ff, ["-nostdin", "-y", "-v", "error", "-ss", String(format: "%.3f", at), "-t", "12", "-i", url.path, "-ss", String(format: "%.3f", max(0, at + s)), "-t", "12", "-i", url.path,
                             "-map", "0:v:0", "-map", "1:a:\(k)", "-vf", "scale=960:-2", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "24", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-b:a", "192k", out.path])
            DispatchQueue.main.async {
                self.previewBusy = false
                if r.status == 0 { let p = AVPlayer(url: out); self.player = p; p.play() } else { self.previewError = "Anteprima non riuscita: \(r.err.suffix(160))" }
            }
        }
    }
    func apply(done: @escaping (FixResult) -> Void) {
        let shifts = changed; guard !shifts.isEmpty else { return }
        applying = true; player?.pause()
        var p = FixPlan(); p.shiftAudio[req.track] = shifts
        let url = req.url
        DispatchQueue.global().async {
            let r = applyFix(url, p, output: url) { v, s in DispatchQueue.main.async { self.progress = v; self.stage = s } }
            DispatchQueue.main.async { self.applying = false; self.result = r; done(r) }
        }
    }
}

struct DoubtView: View {
    @StateObject var m: DoubtModel; var done: (FixResult?) -> Void; @Environment(\.dismiss) private var dismiss
    init(req: DoubtRequest, done: @escaping (FixResult?) -> Void) { _m = StateObject(wrappedValue: DoubtModel(req)); self.done = done }
    func label(_ s: Double) -> String { abs(s) < 0.0005 ? "Com'è" : String(format: "%.0f ms %@", abs(s) * 1000, s > 0 ? "prima" : "dopo") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tratti da guardare a occhio").font(.title2.weight(.semibold))
            Text("In questi tratti la musica e gli effetti vanno d'accordo con più di uno scarto, e la misura non può decidere. Guarda le labbra nell'anteprima e scegli: «Com'è» lascia il tratto così, le altre voci lo spostano. «Applica» aggiorna «\(m.req.url.lastPathComponent)»; il file di partenza non viene toccato.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(m.req.doubts) { d in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(hms(d.start)) – \(hms(d.end))").font(.body.monospacedDigit().weight(.medium))
                                    if abs(d.options[0]) >= 0.015 { Text("la misura preferisce \(label(d.options[0]).lowercased())").font(.caption).foregroundStyle(.orange) }
                                    Spacer(); Button("Guarda") { m.preview(d) }.disabled(m.previewBusy || m.applying)
                                }
                                HStack(spacing: 6) {
                                    ForEach(d.options.sorted(), id: \.self) { s in
                                        Button(label(s)) { m.set(d, s) }.buttonStyle(.bordered).tint(abs(m.shift(d) - s) < 0.0005 ? .accentColor : .secondary)
                                    }
                                    Divider().frame(height: 16)
                                    Button("−1 fot.") { m.set(d, m.shift(d) - 0.040) }.help("Audio dopo di un fotogramma")
                                    Button("+1 fot.") { m.set(d, m.shift(d) + 0.040) }.help("Audio prima di un fotogramma")
                                    if !d.options.contains(where: { abs($0 - m.shift(d)) < 0.0005 }) { Text(label(m.shift(d))).font(.caption.monospacedDigit()).foregroundStyle(.orange) }
                                }.disabled(m.applying)
                            }.padding(8).background(RoundedRectangle(cornerRadius: 6).fill(m.current == d.start ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)))
                        }
                    }
                }.frame(width: 430)
                VStack {
                    ZStack {
                        Rectangle().fill(Color.black)
                        if let p = m.player { PlayerView(player: p) }
                        if m.previewBusy { ProgressView().controlSize(.large) }
                        else if m.player == nil { Text("Premi «Guarda» su un tratto").foregroundStyle(.white.opacity(0.7)) }
                    }.frame(width: 480, height: 270)
                    if let e = m.previewError { Text(e).font(.caption).foregroundStyle(.red) }
                    if let c = m.current, let d = m.req.doubts.first(where: { $0.start == c }) { Text("Anteprima: \(hms(d.start)), audio \(label(m.shift(d)).lowercased())").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(height: 360)
            if m.applying { ProgressView(value: m.progress) { Text(m.stage).font(.caption) } }
            if let r = m.result { Text(r.message).font(.callout).foregroundStyle(r.ok ? .green : .red) }
            HStack {
                Text(m.changed.isEmpty ? "Nessun tratto cambiato" : "\(m.changed.count) tratt\(m.changed.count == 1 ? "o" : "i") da spostare").foregroundStyle(.secondary)
                Spacer()
                Button(m.result?.ok == true ? "Chiudi" : "Lascia così") { m.player?.pause(); done(m.result); dismiss() }.disabled(m.applying)
                Button("Applica") { m.apply { r in if r.ok { m.choice = [:] } } }.buttonStyle(.borderedProminent).disabled(m.changed.isEmpty || m.applying)
            }
        }.padding(22).frame(width: 960)
    }
}
