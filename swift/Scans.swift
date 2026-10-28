import Foundation
import Vision
import NaturalLanguage

// MARK: pacchetti: buchi, file troncato, keyframe, sincronia tra flussi
func packetTimes(_ fp: String, _ path: String, _ sel: String) -> (pts: [Double], keys: [Double]) {
    let o = run(fp, ["-v", "error", "-select_streams", sel, "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", path])
    var pts: [Double] = [], keys: [Double] = []
    for l in o.text.split(separator: "\n") {
        let p = l.split(separator: ","); guard p.count >= 1, let t = Double(p[0]) else { continue }
        pts.append(t); if p.count > 1 && p[1].hasPrefix("K") { keys.append(t) }
    }
    return (pts.sorted(), keys.sorted())
}
func scanPackets(_ pr: Probe, _ path: String, _ c: Collector) {
    guard let fp = tool("ffprobe") else { return }
    let d = pr.duration; var lastV: Double?, lastA: Double?
    if pr.video != nil {
        let (p, k) = packetTimes(fp, path, "v:0")
        if p.count > 10 {
            lastV = p.last
            var gaps: [(Double, Double)] = []; for i in 1..<p.count where p[i] - p[i - 1] > 1.0 { gaps.append((p[i - 1], p[i] - p[i - 1])) }
            for g in gaps.prefix(4) { c.add(.warn, "Video", "Buco nel flusso video", String(format: "Per %.1f s non ci sono fotogrammi: l'immagine si blocca.", g.1), time: g.0) }
            if gaps.count > 4 { c.add(.warn, "Video", "Altri \(gaps.count - 4) buchi nel flusso video", "") }
            var maxKey = 0.0, at = 0.0; for i in 1..<max(k.count, 1) where k[i] - k[i - 1] > maxKey { maxKey = k[i] - k[i - 1]; at = k[i - 1] }
            if k.count < 2 && d > 120 { c.add(.warn, "Video", "Quasi nessun keyframe", "Cercare un punto del film sarà lentissimo o impreciso.") }
            else if maxKey > 20 { c.add(.warn, "Video", String(format: "Keyframe troppo distanti (fino a %.0f s)", maxKey), "Gli avanzamenti rapidi e le ricerche in sala saranno lenti o imprecisi.", time: at) }
            if d > 0 && p.last! < d - 8 { c.add(.error, "File", "Il video finisce prima del previsto", "L'ultimo fotogramma è a \(hms(p.last!)) ma il file dichiara \(hms(d)): file incompleto o troncato.", time: p.last) }
        }
    }
    for (i, _) in pr.audio.prefix(2).enumerated() {
        let (p, _) = packetTimes(fp, path, "a:\(i)"); guard p.count > 10 else { continue }
        if i == 0 { lastA = p.last }
        let gaps = (1..<p.count).filter { p[$0] - p[$0 - 1] > 0.3 }
        for g in gaps.prefix(4) { c.add(.warn, "Audio", "Buco nell'audio (traccia \(i + 1))", String(format: "Mancano %.1f s di suono: possibile perdita di sincronia da quel punto.", p[g] - p[g - 1]), time: p[g - 1]) }
        if gaps.count > 4 { c.add(.warn, "Audio", "Altri \(gaps.count - 4) buchi nell'audio (traccia \(i + 1))", "") }
        if d > 0 && p.last! < d - 8 && i == 0 { c.add(.warn, "Audio", "L'audio finisce prima del film", "L'ultimo suono è a \(hms(p.last!)) su \(hms(d)).", time: p.last) }
    }
    if let v = lastV, let a = lastA, abs(v - a) > 3 { c.add(.warn, "File", "Audio e video finiscono a istanti diversi", String(format: "Scarto di %.1f s (video %@, audio %@): sincronia da verificare.", abs(v - a), hms(v), hms(a))) }
}

// MARK: finestre video: interlacciamento, bande nere, neri, fermi immagine, errori di decodifica
struct WinResult { var brng = 0.0, tout = 0.0, block = 0.0, blur = 0.0, qn = 0; var interl = 0, prog = 0; var crops: [String: Int] = [:]; var blacks: [(Double, Double)] = []; var freezes: [(Double, Double)] = []; var errs: [String] = [] }
private func videoWindow(_ path: String, _ start: Double, _ len: Double) -> WinResult {
    var r = WinResult(), fs: Double?; guard let ff = tool("ffmpeg") else { return r }
    let vf = "idet,cropdetect=limit=0.1:round=2:reset=1,blackdetect=d=0.4:pic_th=0.97:pix_th=0.10,freezedetect=n=-60dB:d=3,signalstats=stat=tout+brng,blockdetect,blurdetect,metadata=mode=print:file=-"
    let o = run(ff, ["-nostats", "-hide_banner", "-ss", String(start), "-t", String(len), "-i", path, "-map", "0:v:0", "-an", "-sn", "-vf", vf, "-f", "null", "-"]) { l in
        if let m = l.match(#"Multi frame detection: TFF:\s*(\d+) BFF:\s*(\d+) Progressive:\s*(\d+)"#) { r.interl += (Int(m[1]) ?? 0) + (Int(m[2]) ?? 0); r.prog += Int(m[3]) ?? 0 }
        else if let m = l.match(#"crop=(\d+:\d+:\d+:\d+)"#) { r.crops[m[1], default: 0] += 1 }
        else if let m = l.match(#"black_start:([\d.]+) black_end:([\d.]+)"#) { r.blacks.append((start + (Double(m[1]) ?? 0), (Double(m[2]) ?? 0) - (Double(m[1]) ?? 0))) }
        else if let m = l.match(#"freeze_start: ([\d.]+)"#) { fs = Double(m[1]) }
        else if let m = l.match(#"freeze_duration: ([\d.]+)"#) { r.freezes.append((start + (fs ?? 0), Double(m[1]) ?? 0)); fs = nil }
        else if l.has(#"error while decoding|corrupt|invalid (nal|data|frame)|missing reference|concealing|co located POCs|reference picture missing|Invalid data found"#) { r.errs.append(l) }
    }
    // segnale (signalstats), blocchi e sfocatura: medie sui fotogrammi del tratto
    var n = 0, b1 = 0.0, t1 = 0.0, bk = 0.0, bl = 0.0, bkn = 0, bln = 0
    for l in o.text.split(separator: "\n") {
        if l.hasPrefix("frame:") { n += 1 }
        else if l.hasPrefix("lavfi.signalstats.BRNG=") { b1 += Double(l.dropFirst(23)) ?? 0 }
        else if l.hasPrefix("lavfi.signalstats.TOUT=") { t1 += Double(l.dropFirst(23)) ?? 0 }
        else if l.hasPrefix("lavfi.block="), let v = Double(l.dropFirst(12)), v.isFinite { bk += v; bkn += 1 }
        else if l.hasPrefix("lavfi.blur="), let v = Double(l.dropFirst(11)), v.isFinite { bl += v; bln += 1 }
    }
    if n > 0 { r.qn = n; r.brng = b1 / Double(n); r.tout = t1 / Double(n); r.block = bkn > 0 ? bk / Double(bkn) : 0; r.blur = bln > 0 ? bl / Double(bln) : 0 }
    return r
}
func scanVideoWindows(_ pr: Probe, _ path: String, _ c: Collector, progress: @escaping (Double) -> Void) {
    guard let v = pr.video else { return }; let d = pr.duration; let w = Int(dbl(v["width"]) ?? 0), h = Int(dbl(v["height"]) ?? 0)
    guard d > 30 else { return }
    let wins: [(String, Double, Double)] = [("all'inizio", 0, min(60, d)), ("a metà", d * 0.45, 60), ("alla fine", max(0, d - 120), min(120, d))]
    var res = [WinResult](repeating: WinResult(), count: 3); let lock = NSLock(); var done = 0; let g = DispatchGroup()
    for (i, wn) in wins.enumerated() { g.enter(); DispatchQueue.global(qos: .userInitiated).async { let r = videoWindow(path, wn.1, wn.2); lock.lock(); res[i] = r; done += 1; lock.unlock(); progress(Double(done) / 3); g.leave() } }
    g.wait()
    let interl = res.reduce(0) { $0 + $1.interl }, prog = res.reduce(0) { $0 + $1.prog }
    if interl + prog > 100 {
        let pc = Double(interl) / Double(interl + prog)
        if pc > 0.2 { c.add(.warn, "Video", "Immagine interlacciata", String(format: "Il %.0f%% dei fotogrammi campionati mostra righe a pettine (il file dichiara scansione %@).", pc * 100, (v["field_order"] as? String) ?? "non dichiarata"), fix: [.deinterlace]) }
    }
    // bande nere incorporate
    var crops: [String: Int] = [:]; for r in res { for (k, n) in r.crops { crops[k, default: 0] += n } }
    let valid = crops.filter { let p = $0.key.split(separator: ":").compactMap { Int($0) }; return p.count == 4 && p[0] * p[1] > w * h / 4 }
    if let top = valid.max(by: { $0.value < $1.value }), w > 0 {
        let p = top.key.split(separator: ":").compactMap { Int($0) }
        if p[1] < h - 24 || p[0] < w - 24 { c.add(.info, "Video", "Bande nere incorporate nell'immagine", "L'immagine utile è \(p[0])×\(p[1]) (\(String(format: "%.2f", Double(p[0]) / Double(p[1])))∶1) dentro un quadro \(w)×\(h). Su uno schermo con proporzioni diverse restano bande nere intorno.") }
        c.rows("Video", order: 1, [("Immagine utile", "\(p[0])×\(p[1])")]); c.fact("v.cropW", Double(p[0])); c.fact("v.cropH", Double(p[1]))
    }
    // neri e fermi immagine
    for b in res[0].blacks where b.0 < 1 && b.1 > 8 { c.add(.warn, "Video", String(format: "Nero iniziale lungo (%.0f s)", b.1), "Lo schermo resta nero prima che parta il film.", time: 0) }
    if let b = res[0].blacks.first, b.1 >= 59 { c.add(.error, "Video", "Immagine nera nei primi 60 secondi", "Il video sembra vuoto all'inizio.", time: 0) }
    if let b = res[2].blacks.last, b.0 + b.1 >= d - 2, b.1 > 20 { c.add(.warn, "Video", String(format: "Nero finale lungo (%.0f s)", b.1), "Dopo la fine il film resta nero a lungo.", time: b.0) }
    if let b = res[1].blacks.first(where: { $0.1 > 5 }) { c.add(.warn, "Video", String(format: "Schermo nero di %.0f s a metà film", b.1), "Se non è voluto può indicare un pezzo mancante o un errore di codifica.", time: b.0) }
    // da dove far partire il film: nero e fermi immagine che si susseguono dall'inizio
    var startAt = 0.0, grew = true
    while grew { grew = false; for x in res[0].blacks + res[0].freezes where x.0 <= startAt + 0.5 && x.0 + x.1 > startAt + 0.01 { startAt = x.0 + x.1; grew = true } }
    if startAt >= 3 { c.fact("v.startAt", startAt) }
    for (i, r) in res.enumerated() { if let f = r.freezes.first(where: { $0.1 > 8 }) { c.add(.info, "Video", String(format: "Immagine ferma per %.0f s (%@)", f.1, wins[i].0), "Fermo immagine o scheda fissa.", time: f.0) } }
    let q = res.filter { $0.qn > 100 }
    if !q.isEmpty {
        let brng = q.map(\.brng).reduce(0, +) / Double(q.count), tout = q.map(\.tout).reduce(0, +) / Double(q.count), block = q.map(\.block).reduce(0, +) / Double(q.count), blur = q.map(\.blur).reduce(0, +) / Double(q.count)
        c.fact("v.block", block); c.fact("v.blur", blur)
        c.rows("Video", order: 1, [("Livelli fuori standard", String(format: "%.2f%% dei pixel (nei tratti campionati)", brng * 100)), ("Blocchettatura / sfocatura", String(format: "%.2f / %.1f", block, blur))])
        if brng > 0.05 { c.add(.warn, "Video", "Livelli luminosi fuori standard", String(format: "Il %.1f%% dei pixel è fuori dalla gamma di luminosità legale (16-235; nei film normali resta sotto l'1,5%%): bianchi o neri bruciati nel passaggio al proiettore.", brng * 100)) }
        if tout > 0.005 { c.add(.warn, "Video", "Disturbi puntuali nell'immagine (dropout)", String(format: "Lo %.2f%% dei pixel risulta anomalo rispetto ai fotogrammi vicini: tipico di una sorgente rovinata.", tout * 100)) }
        if block > 4 { c.add(.info, "Video", "Immagine con blocchettatura (compressione troppo forte)", String(format: "Indice di blocchettatura %.1f (nei tuoi film normali 1-2,5): si vedono quadretti nelle zone piatte e nelle scene scure.", block)) }
        if blur > 14 { c.add(.info, "Video", "Immagine molto sfocata", String(format: "Indice di sfocatura %.1f (nei tuoi film normali 5-7): poca nitidezza, possibile sorgente a bassa risoluzione ingrandita.", blur)) }
    }
    for (i, r) in res.enumerated() where !r.errs.isEmpty { c.add(.warn, "Video", "Errori di decodifica (\(wins[i].0))", "\(r.errs.count) segnalazioni, es.: \(String(r.errs[0].prefix(110))). Possibili blocchi o quadretti nell'immagine.", time: wins[i].1) }
}

// MARK: crediti del torrent nelle immagini (OCR sui primi e ultimi secondi)
func scanCredits(_ pr: Probe, _ path: String, _ tmp: URL, _ c: Collector, progress: @escaping (Double) -> Void) {
    guard pr.video != nil, let ff = tool("ffmpeg") else { return }; let d = pr.duration; guard d > 20 else { return }
    let wins: [(String, Double, Double, Double)] = [("s", 0, min(45, d), 1.5), ("e", max(45, d - 150), min(150, d - 45), 3)]   // prefisso, inizio, durata, passo (s)
    var frames: [(URL, Double)] = []
    for w in wins {
        run(ff, ["-nostats", "-v", "error", "-ss", String(w.1), "-t", String(w.2), "-i", path, "-map", "0:v:0", "-an", "-sn", "-vf", "fps=1/\(w.3),scale=1280:-2", "-q:v", "3", tmp.appendingPathComponent("\(w.0)_%03d.jpg").path])
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).filter { $0.hasPrefix(w.0 + "_") }.sorted()
        for (i, f) in files.enumerated() { frames.append((tmp.appendingPathComponent(f), w.1 + Double(i) * w.3)) }
    }
    progress(0.4)
    var hits: [(t: Double, text: String, url: URL, boxes: [(String, CGRect)])] = []; let lock = NSLock(); var done = 0
    DispatchQueue.concurrentPerform(iterations: frames.count) { i in
        let (u, t) = frames[i]
        if let h = creditHits(in: u, t: t) { lock.lock(); hits.append((t, h.text, u, h.boxes)); lock.unlock() }
        lock.lock(); done += 1; let f = Double(done) / Double(max(frames.count, 1)); lock.unlock(); progress(0.4 + 0.6 * f)
    }
    // una segnalazione per ogni gruppo di fotogrammi vicini; la miniatura va copiata prima che la cartella temporanea sparisca
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("booth-thumbs"); try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var groups: [[(t: Double, text: String, url: URL, boxes: [(String, CGRect)])]] = []
    for h in hits.sorted(by: { $0.t < $1.t }) { if let l = groups.last?.last, h.t - l.t < 6 { groups[groups.count - 1].append(h) } else { groups.append([h]) } }
    for grp in groups {
        let h = grp[0]
        let dest = outDir.appendingPathComponent(UUID().uuidString + ".jpg"); try? FileManager.default.copyItem(at: h.url, to: dest)
        let where_ = h.t < 60 ? "nei primi secondi" : "verso la fine"
        var fixes: [FixHint] = []
        let boxes = grp.flatMap(\.boxes)
        if h.t < 60, !boxes.isEmpty {   // nei primi secondi la scritta si può cancellare dall'immagine (rettangolo che contiene tutte le sue posizioni)
            let u = boxes.map(\.1).reduce(boxes[0].1) { $0.union($1) }
            fixes = [.eraseText(EraseRegion(x: Double(u.minX), y: Double(1 - u.maxY), w: Double(u.width), h: Double(u.height), from: max(0, h.t - 1.6), to: grp.last!.t + 1.6, label: boxes[0].0.trimmingCharacters(in: CharacterSet(charactersIn: " !.|"))))]
        }
        c.add(.error, "Video", "Scritta pubblicitaria o crediti del torrent nell'immagine (\(where_))", "Testo rilevato: «\(String(h.text.prefix(140)))» — ha fatto scattare: «\(boxes.first?.0 ?? h.text.found(adPattern) ?? "")»", time: h.t, thumb: dest, fix: fixes)
    }
}

/// Riconosce con l'OCR le scritte da rimuovere in un fotogramma: pubblicità/nomi di gruppi (adPattern) e, nei primi 60 s, la firma «By Nome» isolata in basso.
/// Restituisce tutto il testo letto e i rettangoli (normalizzati, origine in basso a sinistra) delle scritte da togliere; nil se non c'è nulla.
func creditHits(in u: URL, t: Double) -> (text: String, boxes: [(String, CGRect)])? {
    let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate; req.usesLanguageCorrection = false
    try? VNImageRequestHandler(url: u).perform([req])
    let obs = (req.results ?? []).compactMap { o in o.topCandidates(1).first.map { ($0.string, o.boundingBox) } }
    let text = obs.map(\.0).joined(separator: " | ")
    var boxes = obs.filter { $0.0.has(adPattern) }.map { ($0.0, $0.1) }
    if t < 60 { boxes += obs.filter { $0.1.minY < 0.25 && $0.0.has(#"^\s*by\s+[^\s|]{3,24}\s*$"#) && !$0.0.has(adPattern) }.map { ($0.0, $0.1) } }
    if boxes.isEmpty && text.has(adPattern) { return (text, []) }   // testo spezzato fra più righe: segnalato ma senza rettangolo
    return boxes.isEmpty ? nil : (text, boxes)
}

// MARK: caratteri rovinati (doppia codifica UTF-8 → Windows-1252 → UTF-8)
/// Sequenze tipiche: «Ã» + carattere (Ã¨ = è, Ã  = à), «Â» + spazio/simbolo, «â€» + segno (virgolette e trattini). Maiuscole e minuscole contano: «ã» è un carattere normale in portoghese.
let mojibakePattern = "Ã[\\x{80}-\\x{BF}€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ]|Â[\\x{A0}-\\x{BF}]|â€[\\x{80}-\\x{BF}€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ]|\\x{FFFD}"
/// Ripara un testo con doppia codifica: lo riscrive come byte Windows-1252 e rilegge quei byte come UTF-8. Se non è riparabile lo lascia com'è.
func repairMojibake(_ s: String) -> String {
    guard s.hasExact(mojibakePattern), let d = s.data(using: .windowsCP1252, allowLossyConversion: false), let r = String(data: d, encoding: .utf8) else {
        // caratteri non rappresentabili in CP1252 (rari): ripara solo le sequenze riconosciute una per una
        guard s.hasExact(mojibakePattern) else { return s }
        var out = ""; var it = Array(s); var i = 0
        while i < it.count {
            if i + 1 < it.count, it[i] == "Ã" || it[i] == "Â", let d = String(it[i...i + 1]).data(using: .windowsCP1252), let r = String(data: d, encoding: .utf8) { out += r; i += 2 } else { out.append(it[i]); i += 1 }
        }
        it = []; return out
    }
    return r
}

// MARK: sottotitoli: lingua, pubblicità, sincronia, qualità
struct Cue { var s: Double, e: Double, t: String }
func parseSRT(_ text: String) -> [Cue] {
    var out: [Cue] = []
    for block in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
        let ls = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let i = ls.firstIndex(where: { $0.contains("-->") }), let m = ls[i].match(#"(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)"#) else { continue }
        func sec(_ a: Int) -> Double { (Double(m[a]) ?? 0) * 3600 + (Double(m[a + 1]) ?? 0) * 60 + (Double(m[a + 2]) ?? 0) + (Double(m[a + 3]) ?? 0) / 1000 }
        let t = ls[(i + 1)...].joined(separator: "\n").replacingOccurrences(of: #"<[^>]+>|\{\\[^}]*\}"#, with: "", options: .regularExpression)
        out.append(Cue(s: sec(1), e: sec(5), t: t))
    }
    return out
}
func scanSubtitles(_ pr: Probe, _ path: String, _ tmp: URL, _ c: Collector) {
    guard let ff = tool("ffmpeg") else { return }; let d = pr.duration
    let text = pr.subs.enumerated().filter { !imageSubs.contains(($0.element["codec_name"] as? String) ?? "") }
    if text.isEmpty { return }
    var args = ["-nostats", "-v", "error", "-i", path]
    for (k, t) in text.enumerated() { args += ["-map", "0:s:\(t.offset)", "-f", "srt", tmp.appendingPathComponent("sub\(k).srt").path] }
    run(ff, args)
    for (k, item) in text.enumerated() {
        let s = item.element; let n = "sottotitoli \(item.offset + 1)" + (lang(s).isEmpty ? "" : " (\(langLabel(lang(s)))" + (disp(s, "forced") == 1 ? ", forzati)" : ")")); let area = "Sottotitoli"
        guard let raw = try? String(contentsOf: tmp.appendingPathComponent("sub\(k).srt"), encoding: .utf8) else { c.add(.warn, area, "Impossibile leggere i \(n)", "ffmpeg non è riuscito a estrarre il testo."); continue }
        let cues = parseSRT(raw).filter { !$0.t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.s < $1.s }
        let forced = disp(s, "forced") == 1
        if cues.isEmpty { c.add(forced ? .info : .error, area, "Sottotitoli vuoti — \(n)", "La traccia non contiene alcuna battuta.", fix: [.dropSub(item.offset)]); continue }
        c.fact("s\(item.offset).last", cues.last!.e); c.fact("s\(item.offset).n", Double(cues.count))
        c.rows("Sottotitoli \(item.offset + 1)", order: 30 + item.offset, [("Battute lette", "\(cues.count)"), ("Prima battuta", hms(cues[0].s)), ("Ultima battuta", hms(cues.last!.e))])
        // pubblicità e crediti
        var ads = 0
        for q in cues where q.t.has(adPattern) { ads += 1; if ads <= 4 { c.add(.error, area, "Crediti o pubblicità nei sottotitoli — \(n)", "«\(String(q.t.replacingOccurrences(of: "\n", with: " ").prefix(120)))» — ha fatto scattare: «\(q.t.found(adPattern) ?? "")»", time: q.s, fix: [.cleanSub(item.offset)]) } }
        if ads > 4 { c.add(.error, area, "Altre \(ads - 4) battute con crediti o pubblicità — \(n)", "", fix: [.cleanSub(item.offset)]) }
        // lingua
        if let code = langNames[lang(s)]?.nl, !forced, cues.count >= 20 {
            let rec = NLLanguageRecognizer(); var checked = 0, other = 0; var samples: [Cue] = []
            for q in cues { let t = q.t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: "-– ")); guard t.count >= 25 else { continue }
                rec.reset(); rec.processString(t); let h = rec.languageHypotheses(withMaximum: 8); let want = h[NLLanguage(rawValue: code)] ?? 0; let best = h.max { $0.value < $1.value }
                checked += 1
                if let b = best, b.key.rawValue != code, b.value > 0.8, want < 0.08 { other += 1; if samples.count < 3 { samples.append(q) } } }
            if checked >= 15 {
                let pc = Double(other) / Double(checked) * 100
                if pc > 60 { c.add(.error, area, "Lingua dei sottotitoli diversa da quella dichiarata — \(n)", String(format: "Dichiarati in %@ ma il %.0f%% delle battute è in un'altra lingua.", langLabel(lang(s)), pc), time: samples.first?.s, fix: [.dropSub(item.offset)]) }
                else if pc > 3 { c.add(.warn, area, String(format: "Parte dei sottotitoli non è in %@ — %@", langLabel(lang(s)), n), String(format: "Circa il %.0f%% delle battute (%d su %d) sembra in un'altra lingua, es.: «%@»", pc, other, checked, String((samples.first?.t ?? "").replacingOccurrences(of: "\n", with: " ").prefix(80))), time: samples.first?.s) }
            }
        }
        // sincronia di massima e qualità
        if d > 0 && !forced && cues.count > 50 {
            if cues.last!.e > d + 5 { c.add(.warn, area, "Sottotitoli più lunghi del film — \(n)", "L'ultima battuta è a \(hms(cues.last!.e)) ma il film dura \(hms(d)): probabile versione per un altro montaggio, fuori sincrono.", time: cues.last!.s) }
            else if cues.last!.e < d * 0.7 { c.add(.warn, area, "I sottotitoli finiscono molto prima del film — \(n)", "L'ultima battuta è a \(hms(cues.last!.e)) su \(hms(d)): mancano gli ultimi minuti o sono per un'altra versione.", time: cues.last!.e) }
            if cues[0].s > d * 0.25 { c.add(.warn, area, "I sottotitoli iniziano molto tardi — \(n)", "La prima battuta è a \(hms(cues[0].s)).", time: cues[0].s) }
        }
        let overl = (1..<max(cues.count, 1)).filter { cues[$0].s < cues[$0 - 1].e - 0.2 }.count
        if overl > 8 { c.add(.warn, area, "Battute sovrapposte — \(n)", "\(overl) battute iniziano prima che finisca la precedente: appaiono una sopra l'altra.") }
        let fast = cues.filter { let dur = max($0.e - $0.s, 0.1); return Double($0.t.count) / dur > 30 && $0.t.count > 20 }.count
        if fast > max(10, cues.count / 25) { c.add(.warn, area, "Sottotitoli troppo veloci da leggere — \(n)", "\(fast) battute superano i 30 caratteri al secondo.") }
        let moj = cues.filter { $0.t.hasExact(mojibakePattern) }.count
        if moj > 3 {
            let bad = cues.first(where: { $0.t.hasExact(mojibakePattern) })
            let sample = String((bad?.t ?? "").replacingOccurrences(of: "\n", with: " ").prefix(60))
            c.add(.error, area, "Caratteri rovinati — \(n)", "\(moj) battute con lettere accentate illeggibili (testo scritto in UTF-8 ma riletto come Windows-1252 e salvato di nuovo), per esempio «\(sample)». Si ripara senza toccare le battute.", time: bad?.s, fix: [.repairEncoding(item.offset)])
        }
        if forced && cues.count > 150 { c.add(.warn, area, "Troppe battute per essere «forzati» — \(n)", "\(cues.count) battute: sembra una traccia completa marcata come forzata.", fix: [.setForced(item.offset, false)]) }
    }
}
