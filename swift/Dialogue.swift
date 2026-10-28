import Foundation

/// Livello al secondo (momentaneo, LUFS) di una combinazione di canali di una traccia audio.
func loudnessSeries(_ path: String, _ ord: Int, pan: String) -> [Int: Double] {
    guard let ff = tool("ffmpeg") else { return [:] }
    var m: [Int: Double] = [:]
    run(ff, ["-nostats", "-hide_banner", "-i", path, "-map", "0:a:\(ord)", "-vn", "-sn", "-af", "\(pan),ebur128=framelog=info", "-f", "null", "-"]) { l in
        if let x = l.match(#"t:\s*([\d.]+)\s+TARGET.*?M:\s*(-?[\d.]+|-inf)"#) { m[Int(Double(x[1]) ?? 0)] = Double(x[2]) ?? -120 }
    }
    return m
}
struct DialogueStats { var centerMedian: Double; var frontMedian: Double; var coveredPct: Double; var covered10Pct: Double; var seconds: Int; var worst: [(Int, Double)] }

/// Misura per il rapporto: dialoghi (centro) contro musica/effetti (fronte), solo per le tracce 5.1.
func scanDialogue(_ pr: Probe, _ path: String, _ k: Int, _ c: Collector) {
    let n = "traccia audio \(k + 1)" + (lang(pr.audio[k]).isEmpty ? "" : " (\(langLabel(lang(pr.audio[k]))))")
    guard let d = dialogueStats(path, k) else { return }
    c.fact("a\(k).cover", d.coveredPct)
    c.rows("Audio \(k + 1)", order: 10 + k, [("Dialoghi (canale centrale)", String(format: "%.0f LUFS", d.centerMedian)), ("Musica/effetti (fronte)", String(format: "%.0f LUFS", d.frontMedian)), ("Musica sopra i dialoghi", String(format: "%.0f%% dei momenti con parlato (>6 LU) · %.0f%% (>10 LU)", d.coveredPct, d.covered10Pct))])
    if d.coveredPct >= 12 {
        let where_ = d.worst.prefix(5).map { hms(Double($0.0)) }.joined(separator: ", ")
        c.add(d.coveredPct >= 20 ? .warn : .info, "Audio", "Musica ed effetti coprono i dialoghi — \(n)", String(format: "Nel %.0f%% dei momenti con parlato il fronte sinistro/destro supera il canale centrale di oltre 6 LU (nel %.0f%% di oltre 10). Punti peggiori: %@. Su un film normale è sotto il 10%%.", d.coveredPct, d.covered10Pct, where_.isEmpty ? "—" : where_), time: d.worst.first.map { Double($0.0) }, fix: [.boostCenter(k)])
    }
}
/// Confronta il canale centrale (dove stanno i dialoghi nei mix 5.1) con il fronte sinistro/destro (musica ed effetti).
/// Conta i secondi, tra quelli con parlato nel centro, in cui destra+sinistra sovrastano il centro.
func dialogueStats(_ path: String, _ ord: Int) -> DialogueStats? {
    var c: [Int: Double] = [:], lr: [Int: Double] = [:]; let g = DispatchGroup()
    g.enter(); DispatchQueue.global().async { c = loudnessSeries(path, ord, pan: "pan=mono|c0=FC"); g.leave() }
    g.enter(); DispatchQueue.global().async { lr = loudnessSeries(path, ord, pan: "pan=mono|c0=0.5*FL+0.5*FR"); g.leave() }
    g.wait()
    let ts = c.keys.filter { lr[$0] != nil }.sorted(); guard ts.count > 120 else { return nil }
    let act = ts.filter { c[$0]! > -42 && lr[$0]! > -80 }   // secondi con parlato nel canale centrale
    guard act.count > 60 else { return nil }
    let d = act.map { (lr[$0]! - c[$0]!, $0) }
    func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
    let over6 = d.filter { $0.0 > 6 }.count, over10 = d.filter { $0.0 > 10 }.count
    // i punti peggiori: finestre di 10 s con il divario medio più alto
    var worst: [(Int, Double)] = []; var i = 0
    let byT = Dictionary(uniqueKeysWithValues: d.map { ($0.1, $0.0) })
    while i < ts.last! - 10 { let w = (i..<i + 10).compactMap { byT[$0] }; if w.count >= 6 { let a = w.reduce(0, +) / Double(w.count); if a > 8 { worst.append((i, a)); i += 60; continue } }; i += 1 }
    return DialogueStats(centerMedian: med(act.map { c[$0]! }), frontMedian: med(act.map { lr[$0]! }), coveredPct: Double(over6) / Double(d.count) * 100, covered10Pct: Double(over10) / Double(d.count) * 100, seconds: act.count, worst: worst)
}
