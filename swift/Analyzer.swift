import Foundation

/// Avanzamento complessivo (0...1) come media delle fasi, che girano in parallelo.
final class Progress {
    private let lock = NSLock(); private var parts: [String: Double] = [:]; private var names: [String: String] = [:]
    let total: Int; let cb: (Double, String) -> Void
    init(total: Int, cb: @escaping (Double, String) -> Void) { self.total = total; self.cb = cb }
    func set(_ stage: String, _ frac: Double, _ label: String? = nil) {
        lock.lock(); parts[stage] = min(1, frac); if let l = label { names[stage] = l }
        let p = parts.values.reduce(0, +) / Double(total); let active = parts.filter { $0.value < 1 }.keys.sorted().compactMap { names[$0] }.first ?? "Fine"; lock.unlock()
        cb(p, active)
    }
}

/// Analizza un film: lancia le fasi in parallelo e restituisce il rapporto.
func analyze(_ url: URL, progress: @escaping (Double, String) -> Void = { _, _ in }) -> Report {
    let t0 = Date(); let path = url.path; let col = Collector()
    var rep = Report(file: url)
    guard tool("ffprobe") != nil, tool("ffmpeg") != nil else {
        col.add(.error, "File", "ffmpeg non trovato", "Servono ffmpeg e ffprobe (brew install ffmpeg).")
        rep.findings = col.findings; return rep
    }
    guard let pr = Probe(path), pr.duration > 0 || !pr.streams.isEmpty else {
        col.add(.error, "File", "File non leggibile", "ffprobe non riesce ad aprirlo: file danneggiato, incompleto o non è un video.")
        rep.findings = col.findings; rep.seconds = Date().timeIntervalSince(t0); return rep
    }
    rep.duration = pr.duration
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("booth-" + UUID().uuidString); try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let nAudio = min(pr.audio.count, 3)
    var foundMeta: MovieMeta?; let metaLock = NSLock()
    let nDial = pr.audio.prefix(2).filter { (dbl($0["channels"]) ?? 0) == 6 }.count
    let model = CommandLine.arguments.contains("--no-speech") ? nil : whisperModelPath()
    let doSpeech = model != nil && tool("whisper-cli") != nil && pr.duration > 600
    let doDub = pr.audio.count >= 2 && pr.duration > 300 && pr.audio.contains { lang($0) == "ita" }
    let prog = Progress(total: 6 + nAudio + nDial + (doSpeech ? 1 : 0) + (onlineLookups ? 1 : 0) + (doDub ? 1 : 0)) { progress($0, $1) }
    prog.set("0probe", 1, "Lettura dei dati")
    func info(_ s: [String: Any], _ i: Int) -> TrackInfo { let tg = tags(s); return TrackInfo(ord: i, lang: lang(s), title: tg["title"] ?? "", codec: (s["codec_name"] as? String) ?? "?", channels: Int(dbl(s["channels"]) ?? 0), isDefault: disp(s, "default") == 1, forced: disp(s, "forced") == 1, image: imageSubs.contains((s["codec_name"] as? String) ?? ""), bitrate: dbl(s["bit_rate"]) ?? dbl(tg["bps"]) ?? 0) }
    rep.audioTracks = pr.audio.enumerated().map { info($1, $0) }; rep.subTracks = pr.subs.enumerated().map { info($1, $0) }
    checkContainer(pr, url, col); checkVideo(pr, col); checkAudioStreams(pr, col); checkSubStreams(pr, col)

    let g = DispatchGroup(); let q = DispatchQueue.global(qos: .userInitiated)
    func go(_ stage: String, _ label: String, _ work: @escaping () -> Void) {
        prog.set(stage, 0, label); g.enter(); q.async { work(); prog.set(stage, 1); g.leave() }
    }
    go("1pacchetti", "Controllo dei flussi") { scanPackets(pr, path, col) }
    go("2video", "Analisi dell'immagine") { scanVideoWindows(pr, path, col) { prog.set("2video", $0) } }
    go("3titoli", "Ricerca dei crediti nelle immagini") { scanCredits(pr, path, tmp, col) { prog.set("3titoli", $0) } }
    go("4sub", "Lettura dei sottotitoli") { scanSubtitles(pr, path, tmp, col) }
    go("4mediainfo", "Dettagli MediaInfo") { scanMediaInfo(pr, path, col) }
    if onlineLookups { go("8meta", "Dati del film online") { if let m = fetchMovieMeta(for: url) { metaLock.lock(); foundMeta = m; metaLock.unlock(); metaFindings(pr, url, m, col) } } }
    if doSpeech, let model = model { go("7parlato", "Ascolto del parlato (lingua e sincronia)") { scanSpeech(pr, path, tmp, col, model: model) { prog.set("7parlato", $0) } } }
    else if whisperModelPath() == nil && tool("whisper-cli") != nil && pr.duration > 600 { col.add(.info, "Audio", "Controlli sul parlato non eseguiti", "Per verificare la lingua realmente parlata e la sincronia dei sottotitoli serve il modello vocale (148 MB, una sola volta, open source). Si scarica da File → Controlli sul parlato….") }
    for k in 0..<nAudio { go("5audio\(k)", "Misura dell'audio (traccia \(k + 1))") { scanAudio(pr, path, k, col) { prog.set("5audio\(k)", $0) } } }
    for k in 0..<min(2, pr.audio.count) where (dbl(pr.audio[k]["channels"]) ?? 0) == 6 { go("6dialoghi\(k)", "Misura dei dialoghi (traccia \(k + 1))") { scanDialogue(pr, path, k, col) } }
    if doDub { go("6doppiaggio", "Sincronia del doppiaggio con l'originale") { scanDubSync(pr, path, col) { prog.set("6doppiaggio", $0) } } }
    g.wait()

    rep.meta = foundMeta; rep.findings = col.findings; rep.tech = col.sections; rep.seconds = Date().timeIntervalSince(t0)
    let facts = col.facts; rep.facts = facts; refineFindings(&rep.findings, facts, rep); rep.tips = projectionTips(rep, facts)
    if rep.findings.allSatisfy({ $0.sev <= .info }) { rep.findings.append(Finding(sev: .ok, area: "File", title: "Nessun problema rilevato", detail: "", time: nil, thumb: nil)) }
    return rep
}
