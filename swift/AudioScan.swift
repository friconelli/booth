import Foundation

/// Misura il volume di una traccia audio: livello medio, escursione, picchi, salti bruschi, silenzi.
func scanAudio(_ pr: Probe, _ path: String, _ k: Int, _ c: Collector, progress: @escaping (Double) -> Void) {
    guard let ff = tool("ffmpeg") else { return }; let d = pr.duration; let s = pr.audio[k]
    let n = "traccia audio \(k + 1)" + (lang(s).isEmpty ? "" : " (\(langLabel(lang(s))))")
    var mom: [Int: Double] = [:], short: [Int: Double] = [:]   // 1 valore al secondo
    var integrated: Double?, lra: Double?, peak: Double?, lastT = 0.0, silences: [(Double, Double)] = [], silStart: Double?, errs: [String] = []
    let start = Date()
    run(ff, ["-nostats", "-hide_banner", "-i", path, "-map", "0:a:\(k)", "-vn", "-sn", "-af", "ebur128=peak=true:framelog=info,silencedetect=noise=-50dB:d=4", "-f", "null", "-"]) { l in
        if let m = l.match(#"t:\s*([\d.]+)\s+TARGET.*?M:\s*(-?[\d.]+|-inf)\s+S:\s*(-?[\d.]+|-inf)"#) {
            let t = Double(m[1]) ?? 0; lastT = t; let sec = Int(t); mom[sec] = Double(m[2]) ?? -120; short[sec] = Double(m[3]) ?? -120
            if sec % 20 == 0 && d > 0 { progress(min(0.99, t / d)) }
        } else if let m = l.match(#"^\s+I:\s+(-?[\d.]+) LUFS"#) { if integrated == nil { integrated = Double(m[1]) } }   // ffmpeg stampa un secondo riepilogo (vuoto) a fine analisi: vale il primo
        else if let m = l.match(#"^\s+LRA:\s+([\d.]+) LU"#) { if lra == nil { lra = Double(m[1]) } }
        else if let m = l.match(#"^\s+Peak:\s+(-?[\d.]+) dBFS"#) { if peak == nil { peak = Double(m[1]) } }
        else if let m = l.match(#"silence_start: ([\d.]+)"#) { silStart = Double(m[1]) }
        else if let m = l.match(#"silence_end: ([\d.]+) \| silence_duration: ([\d.]+)"#) { silences.append(((Double(m[1]) ?? 0) - (Double(m[2]) ?? 0), Double(m[2]) ?? 0)); silStart = nil }
        else if l.has(#"error|corrupt|invalid data|Error while decoding"#) && !l.has("Parsed_") { errs.append(l) }
    }
    if let st = silStart { silences.append((st, max(0, lastT - st))) }   // silenzio fino alla fine
    guard let I = integrated else { c.add(.warn, "Audio", "Misura del volume non riuscita — \(n)", "ffmpeg non ha restituito i livelli."); return }
    var rows: [(String, String)] = [("Volume medio (integrato)", String(format: "%.1f LUFS", I))]
    if let r = lra { rows.append(("Escursione dinamica (LRA)", String(format: "%.1f LU", r))) }
    if let p = peak { rows.append(("Picco massimo", String(format: "%.1f dBFS", p))) }
    // distribuzione del volume a breve termine (solo i secondi con suono)
    let vals = short.sorted { $0.key < $1.key }.map(\.value).filter { $0 > -60 }.sorted()
    func pct(_ p: Double) -> Double { vals.isEmpty ? -70 : vals[min(vals.count - 1, Int(Double(vals.count) * p))] }
    let p10 = pct(0.10), p50 = pct(0.50), p95 = pct(0.95)
    if vals.count > 60 { rows.append(("Scene sommesse / tipiche / forti", String(format: "%.0f / %.0f / %.0f LUFS", p10, p50, p95))) }
    c.rows("Audio \(k + 1)", order: 10 + k, rows)
    c.fact("a\(k).I", I); if let r = lra { c.fact("a\(k).lra", r) }; if let p = peak { c.fact("a\(k).peak", p) }; c.fact("a\(k).p50", p50); c.fact("a\(k).p95", p95); c.fact("a\(k).end", lastT)
    // un tratto di 20 s al livello tipico e stabile (di solito dialogo), dopo i titoli di testa: è il punto giusto per regolare il volume della sala
    var bestT: Int?, bestS = 1e9
    for t in stride(from: Int(min(240, d * 0.1)), to: Int(d * 0.7), by: 5) {
        let w = (t..<t + 20).compactMap { short[$0] }.filter { $0 > -60 }; guard w.count >= 18 else { continue }
        let med = w.sorted()[w.count / 2], mean = w.reduce(0, +) / Double(w.count), sd = sqrt(w.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(w.count))
        if abs(med - p50) < 2, abs(med - p50) + sd < bestS { bestS = abs(med - p50) + sd; bestT = t }
    }
    if let t = bestT { c.fact("a\(k).talkT", Double(t)) }
    // il punto più forte del film (esclusi gli ultimi 5 minuti, di solito titoli di coda)
    if let loud = short.filter({ Double($0.key) < max(d - 300, d * 0.8) }).max(by: { $0.value < $1.value }) { c.fact("a\(k).loudT", Double(max(0, loud.key - 2))); c.fact("a\(k).loudL", loud.value) }
    let ar = "Audio"
    let dynHint: [FixHint] = (dbl(s["channels"]) ?? 0) == 6 ? [.boostCenter(k)] : []   // niente compressori: per i 5.1 si alza solo il centro; negli altri casi nessuna correzione automatica
    if I < -70 || vals.count < 10 { c.add(.error, ar, "Audio quasi muto — \(n)", "Livello medio \(String(format: "%.0f", I)) LUFS: la traccia sembra vuota."); return }
    if I < -32 { c.add(.warn, ar, "Audio molto basso — \(n)", String(format: "Volume medio %.1f LUFS: in sala servirà alzare molto il volume e il rumore di fondo salirà.", I), fix: [.levelGain(k)]) }
    else if I > -16 { c.add(.warn, ar, "Audio molto alto e compresso — \(n)", String(format: "Volume medio %.1f LUFS: tipico di un master per la TV, poca dinamica e rischio di distorsione.", I), fix: [.levelGain(k)]) }
    if let p = peak, p > -0.1 { c.add(.warn, ar, "Picchi a 0 dB — \(n)", String(format: "Il picco arriva a %.1f dBFS: possibile distorsione (clipping) nei passaggi forti.", p), fix: [.levelGain(k)]) }
    if let r = lra, r > 26 { c.add(.warn, ar, "Dinamica molto ampia — \(n)", String(format: "Escursione di %.0f LU: il divario tra parti sommesse e forti è grande, in sala i dialoghi possono sembrare bassi rispetto alla musica.", r), fix: dynHint) }
    // salti bruschi: media dei 8 s dopo contro i 8 s prima, sui secondi con suono
    let maxT = Int(lastT); var jumps: [(Int, Double)] = []
    if maxT > 40 {
        let m = (0...maxT).map { max(mom[$0] ?? -120, -90) }
        func avg(_ a: Int, _ b: Int) -> Double? { let v = (max(a, 0)..<min(b, maxT)).map { m[$0] }.filter { $0 > -42 }; return v.count >= 5 ? v.reduce(0, +) / Double(v.count) : nil }
        var i = 8; while i < maxT - 8 {
            if let b = avg(i - 8, i), let a = avg(i, i + 8), abs(a - b) >= 12 { var best = i, bd = abs(a - b); for j in i..<min(i + 12, maxT - 8) { if let b2 = avg(j - 8, j), let a2 = avg(j, j + 8), abs(a2 - b2) > bd { bd = abs(a2 - b2); best = j } }
                jumps.append((best, (avg(best, best + 8) ?? 0) - (avg(best - 8, best) ?? 0))); i = best + 45 } else { i += 1 }
        }
    }
    if jumps.count >= 10 {
        let top = jumps.sorted { abs($0.1) > abs($1.1) }.prefix(5).sorted { $0.0 < $1.0 }
        c.add(jumps.count >= 25 ? .warn : .info, ar, "\(jumps.count) salti bruschi di volume — \(n)", "Cambi di livello di oltre 12 LU tra parti con suono: " + top.map { String(format: "%@ (%+.0f)", hms(Double($0.0)), $0.1) }.joined(separator: ", ") + ". Verifica che non sia musica troppo forte rispetto ai dialoghi.", time: Double(top.first!.0), fix: dynHint)
    }
    if vals.count > 120 {
        if p95 - p50 > 15 { c.add(.warn, ar, "Musica o effetti molto più forti del parlato tipico — \(n)", String(format: "I passaggi forti sono %.0f LU sopra il livello medio (%.0f contro %.0f LUFS): alzando il volume per i dialoghi, la musica sarà fortissima.", p95 - p50, p95, p50), fix: dynHint) }
        if p50 - p10 > 19 { c.add(.warn, ar, "Passaggi molto sommessi — \(n)", String(format: "Le parti piano sono %.0f LU sotto il livello medio: in sala potrebbero risultare inudibili.", p50 - p10), fix: dynHint) }
    }
    // silenzi
    for sl in silences {
        if sl.0 < 1 && sl.1 > 60 { c.add(.info, ar, String(format: "Silenzio iniziale di %.0f s — %@", sl.1, n), "", time: 0) }
        else if sl.0 + sl.1 >= lastT - 2 && sl.1 > 60 && lastT > 300 { c.add(.info, ar, String(format: "Silenzio finale di %.0f s — %@", sl.1, n), "", time: sl.0) }
        else if sl.1 >= 12 && sl.0 > 5 && sl.0 + sl.1 < lastT - 60 { c.add(sl.0 < 180 ? .info : .warn, ar, String(format: "Silenzio di %.0f s — %@", sl.1, n), "Può essere voluto (titoli, pausa) o un pezzo di audio mancante.", time: sl.0) }
    }
    if !errs.isEmpty { c.add(.warn, ar, "Errori di decodifica dell'audio — \(n)", "\(errs.count) segnalazioni, es.: \(String(errs[0].prefix(100))).") }
    if d > 0 && abs(lastT - d) > 8 && lastT > 0 { c.add(.info, ar, "Durata dell'audio diversa dal film — \(n)", "L'audio dura \(hms(lastT)), il film \(hms(d)).") }
    _ = start
}
