import Foundation

// MARK: modello vocale (whisper.cpp, MIT)
let modelDir = NSHomeDirectory() + "/Library/Application Support/Booth/models"
let modelURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"   // 148 MB, multilingue
let modelBytes = 147_951_465
func whisperModelPath() -> String? {
    if let e = ProcessInfo.processInfo.environment["BOOTH_MODEL"], FileManager.default.fileExists(atPath: e) { return e }
    let p = modelDir + "/ggml-base.bin"
    return ((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0) == modelBytes ? p : nil
}
/// Scarica il modello (solo se l'utente ha acconsentito) con curl, verificando la dimensione.
@discardableResult func downloadWhisperModel(progress: @escaping (Double) -> Void) -> Bool {
    try? FileManager.default.createDirectory(atPath: modelDir, withIntermediateDirectories: true)
    let part = modelDir + "/ggml-base.bin.part"; try? FileManager.default.removeItem(atPath: part)
    run("/usr/bin/curl", ["-L", "--fail", "--silent", "--show-error", "--progress-bar", "-o", part, modelURL]) { l in if let m = l.match(#"([\d.]+)%"#), let v = Double(m[1]) { progress(v / 100) } }
    guard ((try? FileManager.default.attributesOfItem(atPath: part)[.size] as? Int) ?? 0) == modelBytes else { try? FileManager.default.removeItem(atPath: part); return false }
    try? FileManager.default.removeItem(atPath: modelDir + "/ggml-base.bin"); return (try? FileManager.default.moveItem(atPath: part, toPath: modelDir + "/ggml-base.bin")) != nil
}

// MARK: trascrizione di un tratto
struct SpeechWindow { var start: Double; var lang: String; var segments: [(Double, Double)]; var speechSecs: Double; var nseg = 0 }   // segments: tratti di parlato con tempi fini; nseg e speechSecs: quelli grezzi di whisper
func transcribe(_ pr: Probe, _ path: String, audio k: Int, start: Double, len: Double, model: String, tmp: URL) -> SpeechWindow? {
    guard let ff = tool("ffmpeg"), let wc = tool("whisper-cli") else { return nil }
    let wav = tmp.appendingPathComponent("w\(k)_\(Int(start)).wav"), out = tmp.appendingPathComponent("w\(k)_\(Int(start))")
    let ch = Int(dbl(pr.audio[k]["channels"]) ?? 2); let pan = ch == 6 ? "pan=mono|c0=FC" : "pan=mono|c0=0.5*c0+0.5*c1"   // nei 5.1 il parlato sta nel canale centrale
    run(ff, ["-nostdin", "-y", "-v", "error", "-ss", String(start), "-t", String(len), "-i", path, "-map", "0:a:\(k)", "-vn", "-af", ch == 1 ? "anull" : pan, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path])
    run(wc, ["-m", model, "-f", wav.path, "-l", "auto", "-oj", "-of", out.path, "-np", "-t", "4"])
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: out.path + ".json")), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    let lang = ((j["result"] as? [String: Any])?["language"] as? String) ?? ""
    var segs: [(Double, Double)] = []
    for s in j["transcription"] as? [[String: Any]] ?? [] {
        guard let o = s["offsets"] as? [String: Any], let f = dbl(o["from"]), let t = dbl(o["to"]), t > f else { continue }
        let text = ((s["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        if text.count < 3 || text.hasPrefix("[") || text.hasPrefix("(") || text.hasPrefix("♪") { continue }   // musica, rumori, tag
        segs.append((start + f / 1000, start + t / 1000))
    }
    let raw = segs.reduce(0) { $0 + $1.1 - $1.0 }
    return SpeechWindow(start: start, lang: lang, segments: refine(segs, wav: wav.path, start: start, ff: ff), speechSecs: raw, nseg: segs.count)
}

/// Tempi fini del parlato: whisper indica le zone con voce (segmenti lunghi che includono le pause); dentro queste zone si tiene solo ciò che è davvero sopra il rumore di fondo nella banda della voce.
func refine(_ segs: [(Double, Double)], wav: String, start: Double, ff: String) -> [(Double, Double)] {
    var rms: [Double] = []
    let o = run(ff, ["-nostdin", "-nostats", "-v", "error", "-i", wav, "-af", "highpass=f=300,lowpass=f=3400,asetnsamples=n=4000:p=0,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=-", "-f", "null", "-"])
    for l in o.text.split(separator: "\n") where l.hasPrefix("lavfi.astats.Overall.RMS_level=") { let v = Double(l.dropFirst(31)) ?? -120; rms.append(v.isFinite ? v : -120) }
    guard rms.count > 40 else { return segs }
    let sorted = rms.sorted(); let floor = sorted[sorted.count / 10], thr = max(-50, floor + 12)
    var out: [(Double, Double)] = []; var runStart: Double?
    for (i, v) in rms.enumerated() {
        let t = start + Double(i) * 0.25, on = v > thr && segs.contains { $0.0 - 0.3 <= t && t <= $0.1 + 0.3 }
        if on { if runStart == nil { runStart = t } } else if let s = runStart { out.append((s, t)); runStart = nil }
    }
    if let s = runStart { out.append((s, start + Double(rms.count) * 0.25)) }
    return out.filter { $0.1 - $0.0 >= 0.5 }
}

let iso2: [String: String] = Dictionary(langNames.map { ($0.value.nl, $0.key) }, uniquingKeysWith: { a, b in ["ita", "eng", "fre", "spa", "ger", "por", "rus", "jpn", "chi", "dut"].contains(a) ? a : b })

// MARK: allineamento sottotitoli / parlato
/// Spostamento da dare ai sottotitoli per farli coincidere col parlato in un tratto, con la correlazione di Pearson tra i due segnali (1 = parlato presente, 0 = assente).
/// Restituisce lo spostamento migliore, la correlazione senza spostamento e quella con lo spostamento migliore. nil se il tratto non è utilizzabile.
func alignCues(speech: [(Double, Double)], cues: [Cue], window: (Double, Double), maxShift: Double = 300) -> (delta: Double, base: Double, best: Double)? {
    let dt = 0.25, lo = window.0, n = Int((window.1 - window.0) / dt)
    guard n > 60, speech.count >= 4 else { return nil }
    var sp = [Double](repeating: 0, count: n)
    for s in speech { for i in max(0, Int((s.0 - lo) / dt))..<max(0, min(n, Int((s.1 - lo) / dt) + 1)) { sp[i] = 1 } }
    let near = cues.filter { $0.e > lo - maxShift && $0.s < window.1 + maxShift }; guard near.count >= 6 else { return nil }
    let mSp = sp.reduce(0, +) / Double(n); let vSp = sp.reduce(0) { $0 + ($1 - mSp) * ($1 - mSp) }; guard vSp > 0 else { return nil }
    func corr(_ d: Double) -> Double {
        var ca = [Double](repeating: 0, count: n)
        for q in near { let a = q.s + d, b = q.e + d; if b < lo || a > window.1 { continue }
            for i in max(0, Int((a - lo) / dt))..<max(0, min(n, Int((b - lo) / dt) + 1)) { ca[i] = 1 } }
        let mC = ca.reduce(0, +) / Double(n); var cov = 0.0, vC = 0.0
        for i in 0..<n { cov += (sp[i] - mSp) * (ca[i] - mC); vC += (ca[i] - mC) * (ca[i] - mC) }
        return vC > 0 ? cov / (vSp * vC).squareRoot() : 0
    }
    var best = (0.0, -2.0), d = -maxShift
    while d <= maxShift { let v = corr(d); if v > best.1 { best = (d, v) }; d += 0.25 }
    var fine = best; d = best.0 - 0.5
    while d <= best.0 + 0.5 { let v = corr(d); if v > fine.1 { fine = (d, v) }; d += 0.05 }
    return (fine.0, corr(0), fine.1)
}

// MARK: fase completa
func scanSpeech(_ pr: Probe, _ path: String, _ tmp: URL, _ c: Collector, model: String, progress: @escaping (Double) -> Void) {
    let d = pr.duration; guard d > 600 else { return }
    let wins = [0.25, 0.5, 0.75].map { max(60, min($0 * d, d - 120)) }; let L = 70.0
    var done = 0; let total = Double(min(2, pr.audio.count) * 3)
    var bySpeech: [Int: [SpeechWindow]] = [:]
    for k in 0..<min(2, pr.audio.count) {
        for s in wins { if let w = transcribe(pr, path, audio: k, start: s, len: L, model: model, tmp: tmp) { bySpeech[k, default: []].append(w) }; done += 1; progress(Double(done) / total * 0.8) }
    }
    // lingua parlata di ciascuna traccia
    for k in 0..<min(2, pr.audio.count) {
        let ws = (bySpeech[k] ?? []).filter { $0.nseg >= 3 && $0.speechSecs >= 10 && !$0.lang.isEmpty }
        guard !ws.isEmpty else { continue }
        var tally: [String: Double] = [:]; ws.forEach { tally[$0.lang, default: 0] += $0.speechSecs }
        let (top, secs) = tally.max { $0.value < $1.value }!; let share = secs / tally.values.reduce(0, +)
        let n = "traccia audio \(k + 1)"; let declared = lang(pr.audio[k]); let dn = langNames[declared]?.nl.replacingOccurrences(of: "nb", with: "no")
        let code3 = iso2[top] ?? top; let label = langLabel(code3)
        c.rows("Audio \(k + 1)", order: 10 + k, [("Lingua parlata (rilevata)", "\(label) (\(ws.filter { $0.lang == top }.count) tratti su \(ws.count))")])
        if declared.isEmpty { c.add(.info, "Audio", "Lingua parlata rilevata: \(label) — \(n)", "La traccia non ha un'etichetta di lingua; dal parlato risulta \(label).", fix: [.setLangTo("a", k, code3)]) }
        else if dn != nil, dn != top, share >= 0.7, ws.count >= 2 || ws[0].speechSecs > 30 {
            c.add(.warn, "Audio", "La lingua parlata non corrisponde all'etichetta — \(n)", "L'etichetta dice \(langLabel(declared)), ma nel parlato si riconosce \(label) (\(Int(share * 100))% di \(ws.count) tratti analizzati).", fix: [.setLangTo("a", k, code3)])
        }
    }
    // sincronia dei sottotitoli di testo rispetto al parlato della traccia principale
    let main = pr.audio.firstIndex { disp($0, "default") == 1 } ?? 0
    if ProcessInfo.processInfo.environment["BOOTH_DEBUG"] != nil { for w in bySpeech[main] ?? [] { FileHandle.standardError.write(Data("finestra \(w.start) lang=\(w.lang) segmenti=\(w.segments.count) parlato=\(w.speechSecs) primi=\(w.segments.prefix(3))\n".utf8)) } }
    guard let mainWins = bySpeech[main]?.filter({ $0.segments.count >= 4 }), mainWins.count >= 2, let ff = tool("ffmpeg") else { return }
    for (i, s) in pr.subs.enumerated() where !imageSubs.contains((s["codec_name"] as? String) ?? "") && disp(s, "forced") != 1 {
        let f = tmp.appendingPathComponent("sync\(i).srt"); run(ff, ["-nostdin", "-y", "-v", "error", "-i", path, "-map", "0:s:\(i)", "-f", "srt", f.path])
        guard let txt = try? String(contentsOf: f, encoding: .utf8) else { continue }
        let cues = parseSRT(txt).filter { !$0.t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; guard cues.count >= 50 else { continue }
        let res = mainWins.compactMap { w -> (Double, Double, Double, Double)? in alignCues(speech: w.segments, cues: cues, window: (w.start, w.start + L)).map { ($0.delta, $0.base, $0.best, w.start) } }
        guard res.count >= 2 else { continue }
        if ProcessInfo.processInfo.environment["BOOTH_DEBUG"] != nil { FileHandle.standardError.write(Data("sync sottotitoli \(i + 1): \(res.map { String(format: "t=%.0f δ=%+.2f base=%.2f best=%.2f", $0.3, $0.0, $0.1, $0.2) })\n".utf8)) }
        let n = "sottotitoli \(i + 1)" + (lang(s).isEmpty ? "" : " (\(langLabel(lang(s))))")
        // per ogni tratto: allineato (la correlazione senza spostamento è già alta), sfasato (uno spostamento la alza nettamente) o inutilizzabile
        enum K { case aligned, shifted(Double), unknown }
        let kinds: [K] = res.map { r in r.1 >= 0.25 && r.2 - r.1 < 0.1 ? .aligned : (r.2 >= 0.25 && r.2 >= r.1 + 0.15 ? .shifted(r.0) : .unknown) }
        let usable = kinds.filter { if case .unknown = $0 { return false }; return true }; guard usable.count >= 2 else { continue }
        let shifts: [Double] = kinds.compactMap { if case .shifted(let d) = $0 { return d }; return nil }
        if shifts.isEmpty { c.rows("Sottotitoli \(i + 1)", order: 30 + i, [("Sincronia con il parlato", "verificata in \(usable.count) tratti")]); continue }
        guard shifts.count == usable.count else { continue }   // tratti discordi: nessuna conclusione
        if (shifts.max()! - shifts.min()!) <= 0.8 {
            let dl = shifts.reduce(0, +) / Double(shifts.count)
            c.rows("Sottotitoli \(i + 1)", order: 30 + i, [("Sfasamento rispetto al parlato", String(format: "%+.1f s", dl))])
            if abs(dl) >= 1.0 { c.add(.warn, "Sottotitoli", String(format: "Sottotitoli sfasati di %.1f s — %@", abs(dl), n), String(format: "Rispetto al parlato risultano %@ di circa %.1f s (misurato in %d tratti del film).", dl < 0 ? "in ritardo" : "in anticipo", abs(dl), shifts.count), time: res[0].3, fix: [.syncSubs(i, 1, dl)]) }
        } else {
            // lo spostamento cresce con il tempo: retta delta = b + (a-1)·t, tipica di un frame rate diverso
            let ts = res.map(\.3); let t0 = ts.first!, t1 = ts.last!, d0 = shifts.first!, d1 = shifts.last!; let slope = (d1 - d0) / (t1 - t0); let a = 1 + slope, b = d0 - slope * t0
            let known: [(Double, String)] = [(25 / 23.976, "25 → 23,976 fps"), (23.976 / 25, "23,976 → 25 fps"), (24 / 23.976, "24 → 23,976 fps"), (23.976 / 24, "23,976 → 24 fps"), (25 / 24, "25 → 24 fps"), (24 / 25, "24 → 25 fps"), (30 / 29.97, "30 → 29,97 fps"), (29.97 / 30, "29,97 → 30 fps")]
            let kn = known.min { abs($0.0 - a) < abs($1.0 - a) }!
            let match = abs(kn.0 - a) < 0.0008
            c.add(.warn, "Sottotitoli", "Sottotitoli che si sfasano col passare del tempo — \(n)", String(format: "Lo sfasamento passa da %+.1f s a %+.1f s tra i tratti misurati: tipico di un frame rate diverso%@.", d0, d1, match ? " (\(kn.1))" : ""), time: res[0].3, fix: match ? [.syncSubs(i, kn.0, b)] : [])
        }
    }
    progress(1)
}
