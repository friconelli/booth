import Foundation

/// Che cosa fare ai sottotitoli predefiniti.
enum SubDefault: Equatable { case keep, none, track(Int) }

/// Un insieme di correzioni da applicare in un colpo solo. Le posizioni sono ordinali dentro il proprio tipo (audio 0, 1…; sottotitoli 0, 1…).
struct FixPlan {
    var audioDefault: Int?; var subDefault: SubDefault = .keep
    var lang: [String: String] = [:]                 // "a0" / "s1" → codice lingua a 3 lettere
    var cleanSubs: Set<Int> = [], dropSubs: Set<Int> = [], dropAudio: Set<Int> = [], normalize: Set<Int> = [], boostCenter: Set<Int> = [], levelGain: Set<Int> = [], toDolby: Set<Int> = []
    var syncSubs: [Int: (a: Double, b: Double)] = [:]   // sottotitoli da risincronizzare: tempo nuovo = a·tempo + b
    var retimeDub: [Int: Int] = [:]                     // doppiaggio → traccia originale dello stesso file su cui rimetterlo a tempo, tratto per tratto
    var shiftAudio: [Int: [AudioShift]] = [:]           // tratti di una traccia da spostare a mano (scelti guardando le labbra)
    var rename: String?                                  // nuovo nome del file (senza estensione)
    var repairSubs: Set<Int> = []                       // sottotitoli con accenti rovinati (doppia codifica) da riparare
    var forcedFlags: [Int: Bool] = [:]                  // etichetta «forzati» da impostare o togliere
    var tonemap = false                                 // HDR → SDR (zscale + tonemap), ricodifica del video
    var setTitle: String?                               // titolo del contenitore da impostare (di solito uguale al nome del file)
    var clearTitle = false                              // toglie il titolo dai metadati del contenitore
    var deinterlace = false                            // deinterlacciamento dell'immagine (ricodifica del video)
    var centerDB = 4.0                                 // quanto alzare il canale centrale
    var audioTouched: Set<Int> { normalize.union(boostCenter).union(levelGain).union(toDolby).union(retimeDub.keys).union(shiftAudio.keys) }
    var addSubs: [AddedSub] = []
    var outputExt: String?                             // formato della copia, se diverso dall'originale (mp4 → mkv per i sottotitoli posizionati)                      // sottotitoli esterni (es. scaricati) da aggiungere come nuova traccia
    var eraseText: [EraseRegion] = []                  // scritte da cancellare dall'immagine (ricodifica solo il tratto in cui compaiono)
    var changesContent: Bool { !cleanSubs.isEmpty || !dropSubs.isEmpty || !dropAudio.isEmpty || !normalize.isEmpty || !boostCenter.isEmpty || !levelGain.isEmpty || !toDolby.isEmpty || !retimeDub.isEmpty || !shiftAudio.isEmpty || !syncSubs.isEmpty || !repairSubs.isEmpty || deinterlace || tonemap || !eraseText.isEmpty || !addSubs.isEmpty }
    var isEmpty: Bool { !changesContent && !clearTitle && setTitle == nil && audioDefault == nil && subDefault == .keep && lang.isEmpty && forcedFlags.isEmpty }
    mutating func merge(_ h: FixHint) {
        switch h {
        case .defaultAudio(let i): audioDefault = i
        case .defaultSub(let i): subDefault = i.map { .track($0) } ?? .none
        case .setLang(let k, let i): lang["\(k)\(i)"] = lang["\(k)\(i)"] ?? "ita"
        case .cleanSub(let i): cleanSubs.insert(i)
        case .dropSub(let i): dropSubs.insert(i)
        case .eraseText(let r): eraseText.append(r)
        case .normalize(let i): normalize.insert(i)
        case .boostCenter(let i): boostCenter.insert(i)
        case .levelGain(let i): levelGain.insert(i)
        case .deinterlace: deinterlace = true
        case .toDolby(let i): toDolby.insert(i)
        case .clearTitle: clearTitle = true
        case .setTitle(let t): setTitle = t
        case .tonemap: tonemap = true
        case .rename(let n): rename = n
        case .repairEncoding(let i): repairSubs.insert(i)
        case .setForced(let i, let f): forcedFlags[i] = f
        case .setLangTo(let k, let i, let code): lang["\(k)\(i)"] = code
        case .syncSubs(let i, let a, let b): syncSubs[i] = (a, b)
        case .retimeDub(let i, let r): retimeDub[i] = r
        }
    }
}
extension FixPlan {
    /// Descrizione in italiano di tutto quello che verrà fatto (per la conferma prima di applicare).
    func summary(_ rep: Report) -> [String] {
        var l: [String] = []
        func a(_ i: Int) -> String { "audio \(i + 1)" + (rep.audioTracks.indices.contains(i) && !rep.audioTracks[i].lang.isEmpty ? " (\(langLabel(rep.audioTracks[i].lang)))" : "") }
        func s(_ i: Int) -> String { "sottotitoli \(i + 1)" + (rep.subTracks.indices.contains(i) && !rep.subTracks[i].lang.isEmpty ? " (\(langLabel(rep.subTracks[i].lang)))" : "") }
        if let n = rename { l.append("Rinominare il file in «\(n)»") }
        if clearTitle && setTitle == nil { l.append("Togliere il titolo dai metadati del file") }
        if let t = setTitle { l.append("Impostare il titolo nei metadati del file su «\(t)»") }
        if let d = audioDefault { l.append("Rendere predefinita la traccia \(a(d))") }
        switch subDefault { case .none: l.append("Spegnere i sottotitoli di default"); case .track(let k): l.append("Rendere predefiniti i \(s(k))"); case .keep: break }
        for (k, v) in lang.sorted(by: { $0.key < $1.key }) { l.append("Impostare la lingua \(langLabel(v)) su \(k.hasPrefix("a") ? a(Int(k.dropFirst())!) : s(Int(k.dropFirst())!))") }
        for (i, f) in forcedFlags.sorted(by: { $0.key < $1.key }) { l.append(f ? "Marcare come «forzati» i \(s(i))" : "Togliere l'etichetta «forzati» dai \(s(i))") }
        for i in repairSubs.sorted() { l.append("Riparare gli accenti rovinati dei \(s(i))") }
        for i in cleanSubs.sorted() { l.append("Togliere pubblicità e crediti dai \(s(i))") }
        for (i, v) in syncSubs.sorted(by: { $0.key < $1.key }) { l.append(v.a == 1 ? String(format: "Spostare di %+.1f s i %@", v.b, s(i)) : "Risincronizzare (frame rate) i \(s(i))") }
        for i in dropSubs.sorted() { l.append("Eliminare i \(s(i))") }
        for x in addSubs { l.append("Aggiungere i sottotitoli in \(langLabel(x.lang)) come nuova traccia" + (x.isDefault ? ", attivi all'avvio" : ", non attivi all'avvio") + (x.position != nil ? ", sopra i sottotitoli impressi nell'immagine" : "") + (x.cover != nil ? ", con una fascia nera che copre i sottotitoli impressi mentre ci sono battute" : "")) }
        if let e = outputExt { l.append("Salvare la copia come .\(e) (immagine e audio identici, nessuna ricodifica)") }
        for i in dropAudio.sorted() { l.append("Eliminare la traccia \(a(i))") }
        for (i, r) in retimeDub.sorted(by: { $0.key < $1.key }) { l.append("Rimettere a tempo il doppiaggio \(a(i)) sulla traccia \(a(r)), tratto per tratto (ricodifica in Dolby Digital)") }
        for (i, v) in shiftAudio.sorted(by: { $0.key < $1.key }) { l.append("Spostare la traccia \(a(i)) in \(v.count) tratt\(v.count == 1 ? "o" : "i"): " + v.map { String(format: "%@–%@ %.0f ms %@", hms($0.start), hms($0.end), abs($0.shift) * 1000, $0.shift > 0 ? "prima" : "dopo") }.joined(separator: ", ") + " (ricodifica in Dolby Digital)") }
        for i in toDolby.sorted() { l.append("Convertire in Dolby Digital (AC-3) la traccia \(a(i))") }
        for i in levelGain.sorted() { l.append("Portare a -24 LUFS il volume della traccia \(a(i)) (guadagno fisso)") }
        for i in boostCenter.sorted() { l.append(String(format: "Alzare i dialoghi (centro +%.0f dB) nella traccia %@", centerDB, a(i))) }
        for i in normalize.sorted() { l.append("Compressione dinamica sulla traccia \(a(i)) (sconsigliata)") }
        for r in eraseText { l.append("Cancellare dall'immagine la scritta «\(r.label)» (da \(hms(r.from)) a \(hms(r.to))); si ricodificano solo i primi secondi, il resto non cambia") }
        if tonemap { l.append("Convertire l'immagine da HDR a SDR (ricodifica lunga)") }
        if deinterlace { l.append("Deinterlacciare l'immagine (ricodifica lunga)") }
        return l
    }
}
struct FixResult { var ok: Bool; var message: String; var lines: [String] = []; var backup: URL?; var newURL: URL?; var badTime: Double? = nil; var doubts: [DubDoubt] = []; var doubtTrack: Int? = nil; var labelsOnly = false }   // labelsOnly: cambiate solo le impostazioni (titolo, lingue, tracce predefinite), direttamente nel file   // doubts: tratti del doppiaggio rimesso a tempo da guardare a occhio (traccia doubtTrack del file nuovo)   // badTime: il momento da guardare se la verifica non passa

/// Filtro validato per "musica troppo forte, dialoghi troppo bassi" (vedi la libreria film): livella la dinamica e limita i picchi.
/// Livello obiettivo della regolazione a guadagno fisso (cinema/streaming: -24 LUFS integrati).
let levelTarget = -24.0
let dynamicsChain = "dynaudnorm=f=500:g=15:p=0.7:m=10,alimiter=limit=0.8:level=false"

/// Misura volume di una traccia audio: (integrato LUFS, LRA LU, picco dBFS).
func measureLoudness(_ path: String, _ ord: Int, progress: ((Double) -> Void)? = nil, duration: Double = 0) -> (Double, Double, Double)? {
    guard let ff = tool("ffmpeg") else { return nil }
    var i: Double?, l: Double?, p: Double?
    run(ff, ["-nostats", "-hide_banner", "-i", path, "-map", "0:a:\(ord)", "-vn", "-sn", "-af", "ebur128=peak=true", "-f", "null", "-"]) { line in
        if let m = line.match(#"^\s+I:\s+(-?[\d.]+) LUFS"#), i == nil { i = Double(m[1]) }
        else if let m = line.match(#"^\s+LRA:\s+([\d.]+) LU"#), l == nil { l = Double(m[1]) }
        else if let m = line.match(#"^\s+Peak:\s+(-?[\d.]+) dBFS"#), p == nil { p = Double(m[1]) }
    }
    guard let a = i, let b = l, let c = p else { return nil }; return (a, b, c)
}
private func lufs(_ m: (Double, Double, Double)) -> String { String(format: "%.1f LUFS · LRA %.1f LU · picco %+.1f dBFS", m.0, m.1, m.2) }
private func secs(_ s: Double) -> String { String(format: "%.3f", s) }

/// Copia istantanea (clone APFS: nessuno spazio in più finché non cambia) o, se non è possibile, copia normale.
func cloneFile(_ src: URL, _ dst: URL) throws {
    if clonefile(src.path, dst.path, 0) == 0 { return }
    try FileManager.default.copyItem(at: src, to: dst)
}
/// Etichetta colorata del Finder: verde se il film è pronto per la sala, rossa se no. Toglie l'altra e lascia le etichette dell'utente; è solo un attributo esteso, il contenuto del file non cambia.
func setVerdictTag(_ url: URL, ok: Bool) {
    let key = "com.apple.metadata:_kMDItemUserTags", path = url.path
    let n = getxattr(path, key, nil, 0, 0, 0)
    var tags: [String] = []
    if n > 0 { var buf = [UInt8](repeating: 0, count: n); if getxattr(path, key, &buf, n, 0, 0) == n, let a = try? PropertyListSerialization.propertyList(from: Data(buf), format: nil) as? [String] { tags = a } }
    tags.removeAll { ["Verde", "Rosso", "Green", "Red"].contains($0.components(separatedBy: "\n")[0]) }
    tags.append(ok ? "Verde\n2" : "Rosso\n6")
    if let d = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) { _ = d.withUnsafeBytes { setxattr(path, key, $0.baseAddress, d.count, 0, 0) } }
}
/// Il titolo scritto nei metadati del contenitore (nil se non c'è).
func containerTitle(_ url: URL) -> String? { Probe(url.path).flatMap { tags(["tags": $0.fmt["tags"] as Any])["title"] } }
/// Il nome del file senza estensione e senza il «(corretto)» aggiunto dall'app: è il titolo che il contenitore dovrebbe avere.
func titleBase(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: #" \(corretto\)( \d+)?$"#, with: "", options: .regularExpression) }
/// Dove salvare la versione corretta: accanto all'originale, con il nome nuovo (se c'è) o «… (corretto)»; mai su un file che esiste già.
func correctedURL(for url: URL, rename: String? = nil, ext newExt: String? = nil) -> URL {
    let dir = url.deletingLastPathComponent(), ext = newExt ?? url.pathExtension, orig = url.deletingPathExtension().lastPathComponent
    var base = (rename ?? "").replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
    if base.isEmpty || base == orig { base = orig.range(of: #" \(corretto\)( \d+)?$"#, options: .regularExpression) != nil && newExt != nil ? orig : orig + " (corretto)" }
    var u = dir.appendingPathComponent(base + "." + ext), n = 1
    while FileManager.default.fileExists(atPath: u.path) { n += 1; u = dir.appendingPathComponent("\(base) \(n)." + ext) }
    return u
}

/// Rinomina il file stesso (cambio di impostazioni, niente copia): mai sopra un file che esiste già.
func renameInPlace(_ url: URL, to base: String) -> (url: URL?, error: String?) {
    let b = base.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
    let dest = url.deletingLastPathComponent().appendingPathComponent(b + "." + url.pathExtension)
    if b.isEmpty || dest.standardizedFileURL == url.standardizedFileURL { return (url, nil) }
    if FileManager.default.fileExists(atPath: dest.path) { return (nil, "Esiste già un file chiamato «\(dest.lastPathComponent)»: non lo sovrascrivo.") }
    do { try FileManager.default.moveItem(at: url, to: dest); return (dest, nil) } catch { return (nil, "Non riesco a rinominare: \(error.localizedDescription)") }
}

/// Applica le correzioni a `url` scrivendo il risultato in `output`. L'originale non viene toccato, tranne quando `output` coincide con `url`:
/// modifica di una copia corretta che l'app ha già creato, oppure solo impostazioni (titolo, lingue, tracce predefinite), che si cambiano nel file stesso.
/// Le impostazioni non hanno bisogno di una nuova versione del film: «Booth crea sempre una copia» vale per le correzioni che cambiano il contenuto.
func applyFix(_ url: URL, _ plan: FixPlan, output: URL, progress: @escaping (Double, String) -> Void) -> FixResult {
    let inPlace = output.standardizedFileURL.path == url.standardizedFileURL.path
    guard let ff = tool("ffmpeg"), let fp = tool("ffprobe"), let pr = Probe(url.path) else { return FixResult(ok: false, message: "ffmpeg non trovato o file illeggibile.") }
    let ext = url.pathExtension.lowercased(), path = url.path
    let audio = pr.audio, subs = pr.subs; var lines: [String] = []
    // controlli di coerenza prima di toccare qualunque cosa
    if audio.count > 0 && plan.dropAudio.count >= audio.count { return FixResult(ok: false, message: "Non si possono eliminare tutte le tracce audio.") }
    if let d = plan.audioDefault, !audio.indices.contains(d) || plan.dropAudio.contains(d) { return FixResult(ok: false, message: "La traccia audio predefinita scelta non esiste o viene eliminata.") }
    if case .track(let k) = plan.subDefault, !subs.indices.contains(k) || plan.dropSubs.contains(k) { return FixResult(ok: false, message: "La traccia di sottotitoli predefinita scelta non esiste o viene eliminata.") }
    for k in plan.boostCenter { guard audio.indices.contains(k), (audio[k]["channels"] as? Int ?? 2) == 6 else { return FixResult(ok: false, message: "Il canale centrale si può alzare solo nelle tracce 5.1 (traccia \(k + 1)).") } }
    for k in plan.toDolby { guard audio.indices.contains(k), (audio[k]["channels"] as? Int ?? 2) <= 6 else { return FixResult(ok: false, message: "La traccia audio \(k + 1) non può essere convertita in Dolby Digital (più di 6 canali).") } }
    for k in plan.levelGain { guard audio.indices.contains(k), (audio[k]["channels"] as? Int ?? 2) <= 6 else { return FixResult(ok: false, message: "La traccia audio \(k + 1) non può essere regolata (più di 6 canali).") } }
    for k in plan.normalize { guard audio.indices.contains(k), (audio[k]["channels"] as? Int ?? 2) <= 6 else { return FixResult(ok: false, message: "La traccia audio \(k + 1) non può essere livellata (più di 6 canali).") } }
    if plan.tonemap {
        guard let v = pr.video, ["smpte2084", "arib-std-b67"].contains((v["color_transfer"] as? String) ?? "") else { return FixResult(ok: false, message: "Il video non è HDR (PQ o HLG): niente da convertire.") }
        if ((v["side_data_list"] as? [[String: Any]]) ?? []).contains(where: { ($0["side_data_type"] as? String ?? "").contains("DOVI") && (dbl($0["dv_profile"]) ?? 0) == 5 }) { return FixResult(ok: false, message: "Dolby Vision profilo 5: non ha un livello base HDR10, la conversione darebbe colori sbagliati. Serve un'altra sorgente.") }
    }
    let oext = output.pathExtension.lowercased()   // formato del file di uscita: di solito lo stesso; un mp4 diventa mkv quando i sottotitoli aggiunti devono stare in una posizione precisa
    if oext != ext && !(oext == "mkv" && ["mp4", "m4v", "mov"].contains(ext)) { return FixResult(ok: false, message: "Conversione da .\(ext) a .\(oext) non prevista.") }
    if oext != "mkv" && plan.addSubs.contains(where: { $0.position != nil || $0.cover != nil }) { return FixResult(ok: false, message: "I sottotitoli in una posizione precisa (sopra quelli impressi nell'immagine) si possono mettere solo in un .mkv.") }
    if ext == "avi" && (!plan.cleanSubs.isEmpty || plan.subDefault != .keep || !plan.addSubs.isEmpty) { return FixResult(ok: false, message: "Il formato AVI non può contenere sottotitoli.") }

    // 0) cancellazione di una scritta: si ricodificano solo i primi secondi (mkvmerge + ffmpeg) e poi, se serve, si applica il resto della correzione alla copia
    if !plan.eraseText.isEmpty {
        guard ext == "mkv" else { return FixResult(ok: false, message: "Cancellare una scritta dall'immagine funziona per ora solo sui file .mkv.") }
        let work = output.deletingLastPathComponent().appendingPathComponent(".booth-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: work) }
        let (erased, why) = eraseTextInVideo(source: url, probe: pr, regions: plan.eraseText, work: work, progress: { progress($0 * 0.9, $1) }, lines: &lines)
        guard let e = erased else { return FixResult(ok: false, message: (why ?? "Cancellazione non riuscita.") + " L'originale non è stato toccato.", lines: lines) }
        var rest = plan; rest.eraseText = []
        let old = work.appendingPathComponent("prev.mkv")
        do { if inPlace { try FileManager.default.moveItem(at: output, to: old) }; try FileManager.default.moveItem(at: e, to: output) }
        catch { if inPlace { try? FileManager.default.moveItem(at: old, to: output) }; return FixResult(ok: false, message: "Non riesco a salvare il file nuovo: \(error.localizedDescription)", lines: lines) }
        if rest.isEmpty { return FixResult(ok: true, message: inPlace ? "Scritta cancellata nella copia corretta." : "Creata «\(output.lastPathComponent)» senza la scritta. L'originale non è stato toccato.", lines: lines, backup: nil, newURL: output) }
        var r = applyFix(output, rest, output: output, progress: { progress(0.9 + $0 * 0.1, $1) })   // il resto della correzione, sulla copia appena creata
        r.lines = lines + r.lines
        if !r.ok { if inPlace { try? FileManager.default.removeItem(at: output); try? FileManager.default.moveItem(at: old, to: output) } else { try? FileManager.default.removeItem(at: output) } }
        return r
    }
    // 1) solo etichette in un mkv: si modifica l'intestazione sul posto, senza riscrivere il film
    if !plan.changesContent, ext == "mkv", let mp = tool("mkvpropedit") {
        progress(0.1, "Modifica delle etichette…")
        // sul posto si tiene un clone istantaneo (APFS, non occupa spazio) per tornare indietro se qualcosa non va
        let bak = url.deletingLastPathComponent().appendingPathComponent(".booth-prima-\(UUID().uuidString.prefix(8)).\(ext)")
        if inPlace { do { try cloneFile(url, bak) } catch { return FixResult(ok: false, message: "Non riesco a mettere da parte il file prima di cambiarlo: \(error.localizedDescription)") } }
        else { do { try cloneFile(url, output) } catch { return FixResult(ok: false, message: "Non riesco a creare la copia: \(error.localizedDescription)") } }
        defer { try? FileManager.default.removeItem(at: bak) }
        func discard() { if inPlace { _ = try? FileManager.default.replaceItemAt(output, withItemAt: bak) } else { try? FileManager.default.removeItem(at: output) } }
        var a = [output.path]
        if let t = plan.setTitle { a += ["--edit", "info", "--set", "title=\(t)"] } else if plan.clearTitle { a += ["--edit", "info", "--delete", "title"] }
        for (i, _) in audio.enumerated() {
            var sets: [String] = []
            if let d = plan.audioDefault { sets += ["flag-default=\(i == d ? 1 : 0)"] }
            if let l = plan.lang["a\(i)"] { sets += ["language=\(l)"] }
            for s in sets { a += ["--edit", "track:a\(i + 1)", "--set", s] }
        }
        for (i, _) in subs.enumerated() {
            var sets: [String] = []
            switch plan.subDefault { case .none: sets += ["flag-default=0"]; case .track(let k): sets += ["flag-default=\(i == k ? 1 : 0)"]; case .keep: break }
            if let l = plan.lang["s\(i)"] { sets += ["language=\(l)"] }
            if let f = plan.forcedFlags[i] { sets += ["flag-forced=\(f ? 1 : 0)"]; lines.append("Sottotitoli \(i + 1): etichetta «forzati» \(f ? "impostata" : "tolta")") }
            for s in sets { a += ["--edit", "track:s\(i + 1)", "--set", s] }
        }
        let o = run(mp, a); if o.status > 1 { discard(); return FixResult(ok: false, message: "mkvpropedit non è riuscito: \(o.text.suffix(200)). L'originale non è stato toccato.") }
        // verifica rileggendo il file
        guard let np = Probe(output.path) else { discard(); return FixResult(ok: false, message: "La copia modificata non è leggibile: l'originale non è stato toccato.") }
        if let d = plan.audioDefault { lines.append("Traccia audio predefinita: \(d + 1)"); if disp(np.audio[d], "default") != 1 { discard(); return FixResult(ok: false, message: "La modifica non risulta applicata: l'originale non è stato toccato.") } }
        switch plan.subDefault { case .none: lines.append("Nessun sottotitolo predefinito"); case .track(let k): lines.append("Sottotitoli predefiniti: traccia \(k + 1)"); case .keep: break }
        if let t = plan.setTitle { lines.append("Titolo del contenitore: «\(t)»") } else if plan.clearTitle { lines.append("Titolo del contenitore tolto") }
        for (k, v) in plan.lang.sorted(by: { $0.key < $1.key }) { lines.append("Lingua \(k.hasPrefix("a") ? "audio" : "sottotitoli") \(Int(k.dropFirst())! + 1): \(langLabel(v))") }
        progress(1, "Fatto"); return FixResult(ok: true, message: inPlace ? "Impostazioni aggiornate nel file, senza crearne una nuova versione." : "Creata «\(output.lastPathComponent)» (copia istantanea con le sole etichette cambiate). L'originale non è stato toccato.", lines: lines, backup: nil, newURL: output, labelsOnly: inPlace)
    }

    // 2) riscrittura con ffmpeg su un file temporaneo accanto all'originale
    let dir = output.deletingLastPathComponent(), base = output.deletingPathExtension().lastPathComponent
    if let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage, Double(free) < pr.size * 1.05 + 1e8 {
        return FixResult(ok: false, message: "Spazio insufficiente: servono almeno \(fmtBytes(pr.size * 1.05)) liberi.")
    }
    let tmp = dir.appendingPathComponent(".\(base).booth-tmp.\(oext)"); try? FileManager.default.removeItem(at: tmp)
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("booth-fix-" + UUID().uuidString); try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: tmp) }

    let s0 = 0.0, e0 = pr.duration
    // sottotitoli ripuliti: si riscrive la traccia senza le battute con pubblicità/crediti
    var extra: [Int: Int] = [:]; var inputs: [String] = []
    for k in plan.cleanSubs.union(Set(plan.syncSubs.keys)).union(plan.repairSubs).sorted() where subs.indices.contains(k) && !plan.dropSubs.contains(k) {
        let raw = work.appendingPathComponent("raw\(k).srt"); run(ff, ["-nostdin", "-y", "-v", "error", "-i", path, "-map", "0:s:\(k)", "-f", "srt", raw.path])
        guard let txt = try? String(contentsOf: raw, encoding: .utf8) else { return FixResult(ok: false, message: "Non riesco a leggere i sottotitoli \(k + 1).") }
        let all = parseSRT(txt); let (sa, sb) = plan.syncSubs[k] ?? (1, 0)
        let moved = all.map { Cue(s: $0.s * sa + sb, e: $0.e * sa + sb, t: plan.repairSubs.contains(k) ? repairMojibake($0.t) : $0.t) }
        if plan.repairSubs.contains(k) {
            let before = all.filter { $0.t.hasExact(mojibakePattern) }.count, left = moved.filter { $0.t.hasExact(mojibakePattern) }.count
            if before == 0 { return FixResult(ok: false, message: "I sottotitoli \(k + 1) non hanno caratteri rovinati da riparare.") }
            if left > max(2, before / 10) { return FixResult(ok: false, message: "La riparazione dei sottotitoli \(k + 1) non è riuscita (restano \(left) battute rovinate su \(before)): il file non è stato toccato.") }
            lines.append("Sottotitoli \(k + 1): riparati gli accenti di \(before - left) battute")
        }
        let keep = moved.filter { (!plan.cleanSubs.contains(k) || !$0.t.has(adPattern)) && $0.e > s0 && $0.s < e0 }
        func ts(_ x: Double) -> String { let v = max(0, x); let ms = Int((v * 1000).rounded()); return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
        let out = keep.enumerated().map { "\($0 + 1)\n\(ts($1.s)) --> \(ts($1.e))\n\($1.t)\n" }.joined(separator: "\n")
        let f = work.appendingPathComponent("clean\(k).srt"); try? out.write(to: f, atomically: true, encoding: .utf8)
        inputs += ["-i", f.path]; extra[k] = extra.count + 1
        if plan.cleanSubs.contains(k) { lines.append("Sottotitoli \(k + 1): tolte \(all.count - keep.count) battute con pubblicità o crediti") }
        if plan.syncSubs[k] != nil { lines.append(String(format: "Sottotitoli %d: risincronizzati (tempo × %.5f %+.2f s)", k + 1, sa, sb)) }
    }
    // doppiaggi da rimettere a tempo: si misurano rispetto alla traccia originale (musica ed effetti in comune) e si ricostruiscono tratto per tratto,
    // con la stessa funzione dell'unione; la traccia ricostruita (FLAC, senza perdite) entra poi nella scrittura al posto di quella originale
    var retimed: [Int: Int] = [:]
    if !plan.retimeDub.isEmpty, let src = loadMergeSource(url, src: 0) {
        for (k, ref) in plan.retimeDub.sorted(by: { $0.key < $1.key }) {
            guard audio.indices.contains(k), audio.indices.contains(ref), k != ref else { return FixResult(ok: false, message: "Tracce del doppiaggio non valide.") }
            let f = work.appendingPathComponent("dub\(k).mka")
            guard let (sg, _) = retimeDubTrack(src, dub: k, ref: ref, out: f, progress: { progress(0.04 * $0, $1) }), FileManager.default.fileExists(atPath: f.path) else { return FixResult(ok: false, message: "Non riesco a misurare o ricostruire il doppiaggio rispetto alla traccia \(ref + 1): musica ed effetti non coincidono abbastanza. Il file non è stato toccato.") }
            inputs += ["-i", f.path]; retimed[k] = extra.count + retimed.count + 1
            let ds = sg.compactMap(\.d)
            lines.append(String(format: "Audio %d: doppiaggio rimesso a tempo sulla traccia %d in %d tratti (correzioni da %+.0f a %+.0f ms)", k + 1, ref + 1, ds.count, -(ds.max() ?? 0) * 1000, -(ds.min() ?? 0) * 1000))
        }
    }
    // tratti spostati a mano: la traccia si ricostruisce con lo stesso montaggio a pezzi, spostando solo quei tratti
    if !plan.shiftAudio.isEmpty, let src = loadMergeSource(url, src: 0) {
        for (k, v) in plan.shiftAudio.sorted(by: { $0.key < $1.key }) where retimed[k] == nil {
            guard let t = src.tracks.first(where: { $0.kind == "a" && $0.ord == k }) else { return FixResult(ok: false, message: "Traccia da spostare non valida.") }
            var segs: [MergeSegment] = [], at = 0.0
            for x in v.sorted(by: { $0.start < $1.start }) where x.start >= at && x.end > x.start {
                if x.start > at { segs.append(MergeSegment(start: at, end: x.start, d: 0)) }
                segs.append(MergeSegment(start: x.start, end: x.end, d: x.shift)); at = x.end
            }
            segs.append(MergeSegment(start: at, end: pr.duration, d: 0))
            let f = work.appendingPathComponent("shift\(k).mka"), pg = pieceGraph(src, t, k: 1, segs: segs, from: 0, to: pr.duration, firstInput: 0, outLabel: "o")
            progress(0.03, "Sposto i tratti scelti della traccia \(k + 1)…")
            guard run(ff, ["-nostdin", "-y", "-v", "error"] + pg.inputs + ["-filter_complex", pg.graph, "-map", "[o]", "-c:a", "flac", f.path]).status == 0 else { return FixResult(ok: false, message: "Non riesco a ricostruire la traccia \(k + 1). Il file non è stato toccato.") }
            inputs += ["-i", f.path]; retimed[k] = extra.count + retimed.count + 1
            lines.append("Audio \(k + 1): " + v.map { String(format: "da %@ a %@ %.0f ms %@", hms($0.start), hms($0.end), abs($0.shift) * 1000, $0.shift > 0 ? "prima" : "dopo") }.joined(separator: "; "))
        }
    }
    // misure sull'originale: servono per calcolare il guadagno e per controllare dopo che l'audio non sia peggiorato
    var beforeLoud: [Int: (Double, Double, Double)] = [:], beforeDial: [Int: DialogueStats] = [:], gains: [Int: Double] = [:]
    for k in plan.audioTouched.sorted() {
        progress(0.03, "Misura dell'audio originale (traccia \(k + 1))…")
        if let l = measureLoudness(path, k) { beforeLoud[k] = l; if plan.levelGain.contains(k) { gains[k] = max(-15, min(18, levelTarget - l.0)) } }
        if (audio[k]["channels"] as? Int ?? 0) == 6, let d = dialogueStats(path, k) { beforeDial[k] = d }
    }
    for k in plan.levelGain where gains[k] == nil { return FixResult(ok: false, message: "Non riesco a misurare il volume della traccia audio \(k + 1).") }
    // sottotitoli esterni: ognuno entra come file in più (SRT in UTF-8)
    var added: [(AddedSub, Int)] = []
    for x in plan.addSubs {
        guard let txt = readSubText(x.file), !parseSRT(txt).isEmpty else { return FixResult(ok: false, message: "Il file «\(x.file.lastPathComponent)» non è un sottotitolo SRT leggibile. Il film non è stato toccato.") }
        let ass = oext == "mkv" && (x.position != nil || x.cover != nil), v = pr.video
        let f = work.appendingPathComponent("add\(added.count).\(ass ? "ass" : "srt")")
        try? (ass ? srtToASS(txt, width: Int(dbl(v?["width"]) ?? 1920), height: Int(dbl(v?["height"]) ?? 1080), bottom: x.position ?? 0.045, cover: x.cover) : txt).write(to: f, atomically: true, encoding: .utf8)
        inputs += ["-i", f.path]; added.append((x, inputs.count / 2))
    }
    var a = ["-nostdin", "-y", "-v", "error", "-progress", "pipe:2", "-nostats"]
    a += ["-i", path] + inputs
    a += ["-map_chapters", "0", "-map_metadata", "0", "-c", "copy"]
    if let t = plan.setTitle { a += ["-metadata", "title=\(t)"]; lines.append("Titolo del contenitore: «\(t)»") } else if plan.clearTitle { a += ["-metadata", "title="]; lines.append("Titolo del contenitore tolto") }   // base: tutto copiato; le opzioni per-traccia che seguono hanno la precedenza
    if oext == "mp4" || oext == "m4v" || oext == "mov" { a += ["-c:s", "mov_text", "-movflags", "+faststart"] }
    else if oext == "mkv" && ext != "mkv" && !subs.isEmpty { a += ["-c:s", "srt"] }   // mp4 → mkv: i sottotitoli mov_text diventano SRT
    var vOut = 0, vDone = false
    for s in pr.streams where s["codec_type"] as? String == "video" {
        a += ["-map", "0:\(s["index"] as? Int ?? 0)"]
        if (plan.deinterlace || plan.tonemap) && !vDone && disp(s, "attached_pic") == 0 {
            var chain: [String] = []; var enc = videoEncodeArgs(s, outIndex: vOut)
            if plan.deinterlace { chain.append(deinterlaceFilter); lines.append("Immagine: deinterlacciata con bwdif") }
            if plan.tonemap {   // HDR → SDR: linearizzazione con zimg, tone mapping Hable, ritorno a BT.709; l'uscita è SDR a 8 bit
                chain.append(tonemapFilter(s)); enc = ["-c:v:\(vOut)", "libx264", "-crf", "14", "-preset", "slow", "-pix_fmt", "yuv420p", "-colorspace:v:\(vOut)", "bt709", "-color_primaries:v:\(vOut)", "bt709", "-color_trc:v:\(vOut)", "bt709", "-color_range:v:\(vOut)", "tv"]
                lines.append("Immagine: convertita da HDR a SDR (zscale + tone mapping Hable, BT.709)")
            }
            a += enc + ["-filter:v:\(vOut)", chain.joined(separator: ",")]; vDone = true
            lines.append("Immagine: ricodificata (\(enc.contains("libx265") ? "x265 CRF 16" : "x264 CRF 14"))")
        }
        vOut += 1
    }
    var j = 0
    for (i, s) in audio.enumerated() where !plan.dropAudio.contains(i) {
        if let x = retimed[i] {   // traccia ricostruita: i suoi metadati vanno ripresi dall'originale
            a += ["-map", "\(x):a:0"]; if !lang(s).isEmpty { a += ["-metadata:s:a:\(j)", "language=\(lang(s))"] }; if let t = tags(s)["title"] { a += ["-metadata:s:a:\(j)", "title=\(t)"] }
            if plan.audioDefault == nil { a += ["-disposition:a:\(j)", disp(s, "default") == 1 ? "default" : "0"] }
        } else { a += ["-map", "0:a:\(i)"] }
        if let l = plan.lang["a\(i)"] { a += ["-metadata:s:a:\(j)", "language=\(l)"] }
        if let d = plan.audioDefault { a += ["-disposition:a:\(j)", i == d ? "default" : "0"] }
        if plan.audioTouched.contains(i) {
            let ch = (s["channels"] as? Int) ?? 2
            var br = min(dbl(s["bit_rate"]) ?? dbl(tags(s)["bps"]) ?? 448_000, 640_000)
            if retimed[i] != nil { br = ch >= 6 ? 640_000 : ch == 2 ? 384_000 : 192_000 }
            if plan.toDolby.contains(i) { br = ch >= 6 ? 640_000 : ch == 2 ? 384_000 : 192_000; lines.append("Audio \(i + 1): convertita da \((s["codec_name"] as? String ?? "?").uppercased()) a Dolby Digital (AC-3) a \(Int(br / 1000)) kb/s") }
            var chain: [String] = []
            if let g = gains[i] {   // guadagno fisso: nessun effetto sulla dinamica, il limitatore evita solo il clipping
                chain.append(String(format: "volume=%.2fdB,alimiter=limit=0.95:level=false", g)); lines.append(String(format: "Audio %d: volume portato a %.0f LUFS con un guadagno fisso di %+.1f dB", i + 1, levelTarget, g))
            }
            if plan.boostCenter.contains(i) {   // solo il canale centrale (i dialoghi), gli altri invariati; il limitatore evita il clipping
                let lay = (s["channel_layout"] as? String) ?? "5.1"
                chain.append(String(format: "pan=%@|c0=c0|c1=c1|c2=%.3f*c2|c3=c3|c4=c4|c5=c5,alimiter=limit=0.9:level=false", lay, pow(10, plan.centerDB / 20)))
                lines.append(String(format: "Audio %d: canale centrale (dialoghi) alzato di %.1f dB", i + 1, plan.centerDB))
            }
            if plan.normalize.contains(i) { chain.append(dynamicsChain); lines.append("Audio \(i + 1): compressione dinamica (\(dynamicsChain.split(separator: ",")[0]) + limitatore)") }
            a += ["-c:a:\(j)", "ac3", "-b:a:\(j)", "\(Int(max(br, 192_000)))"] + (chain.isEmpty ? [] : ["-filter:a:\(j)", chain.joined(separator: ",")])
            if !plan.toDolby.contains(i) && retimed[i] == nil { lines.append("Audio \(i + 1): ricodificata in AC3") }
        }
        j += 1
    }
    var m = 0, subOn: [Bool] = []   // subOn: quali tracce di sottotitoli devono risultare attive all'avvio (negli mp4 si ricontrolla dopo)
    for (i, s) in subs.enumerated() where !plan.dropSubs.contains(i) {
        if let x = extra[i] { a += ["-map", "\(x):0"]; let tg = tags(s); if !lang(s).isEmpty { a += ["-metadata:s:s:\(m)", "language=\(lang(s))"] }; if let t = tg["title"] { a += ["-metadata:s:s:\(m)", "title=\(t)"] } }
        else { a += ["-map", "0:s:\(i)"] }
        if let l = plan.lang["s\(i)"] { a += ["-metadata:s:s:\(m)", "language=\(l)"] }
        let forced = plan.forcedFlags[i] ?? (disp(s, "forced") == 1); var flags: [String] = []
        switch plan.subDefault { case .none: break; case .track(let k): if i == k { flags.append("default") }; case .keep: if disp(s, "default") == 1 { flags.append("default") } }
        if forced { flags.append("forced") }
        if plan.subDefault != .keep || extra[i] != nil || plan.forcedFlags[i] != nil { a += ["-disposition:s:\(m)", flags.isEmpty ? "0" : flags.joined(separator: "+")] }
        subOn.append(flags.contains("default")); m += 1
    }
    for (x, idx) in added {
        a += ["-map", "\(idx):0", "-metadata:s:s:\(m)", "language=\(x.lang)", "-disposition:s:\(m)", x.isDefault ? "default" : "0", "-c:s:\(m)", oext == "mkv" ? "copy" : "mov_text"] + (x.title.isEmpty ? [] : ["-metadata:s:s:\(m)", "title=\(x.title)"])
        lines.append("Sottotitoli \(m + 1): aggiunti da «\(x.file.lastPathComponent)» (\(langLabel(x.lang)))" + (x.isDefault ? ", attivi all'avvio" : "") + (x.position.map { String(format: ", sopra i sottotitoli impressi nell'immagine (a %.0f%% dell'altezza)", $0 * 100) } ?? "") + (x.cover.map { String(format: ", con una fascia nera che copre i sottotitoli impressi (%.0f%% dell'altezza, solo mentre ci sono battute)", $0 * 100) } ?? ""))
        subOn.append(x.isDefault); m += 1
    }
    if ext == "mkv" && oext == "mkv" { a += ["-map", "0:t?"] }
    if ext == "avi" { a += ["-sn"] }
    let final = a + [tmp.path]
    let total = max(1, e0 - s0)
    progress(0.05, "Scrittura del nuovo file…")
    var errs: [String] = []
    let o = run(ff, final) { l in
        if let mm = l.match(#"out_time_us=(\d+)"#), let us = Double(mm[1]) { progress(0.05 + 0.75 * min(1, us / 1e6 / total), "Scrittura del nuovo file…") }
        else if !l.contains("=") && !l.isEmpty { errs.append(l) }
    }
    guard o.status == 0, FileManager.default.fileExists(atPath: tmp.path) else { return FixResult(ok: false, message: "ffmpeg non è riuscito: \(errs.suffix(2).joined(separator: " "))") }
    // negli mp4 ffmpeg rende attiva la prima traccia di sottotitoli quando nessuna è predefinita: si spegne nell'intestazione, come deve essere
    if ["mp4", "m4v", "mov"].contains(oext), !subOn.isEmpty, !subOn.contains(true) { mp4SetSubtitlesEnabled(tmp, subOn) }

    // verifica del risultato prima di sostituire qualunque cosa
    progress(0.82, "Verifica del nuovo file…")
    guard let np = Probe(tmp.path) else { return FixResult(ok: false, message: "Il nuovo file non è leggibile: l'originale non è stato toccato.") }
    let expA = audio.count - plan.dropAudio.count, expS = oext == "avi" ? 0 : subs.count - plan.dropSubs.count + plan.addSubs.count
    if np.audio.count != expA || np.subs.count != expS { return FixResult(ok: false, message: "Il nuovo file ha un numero di tracce diverso dal previsto (audio \(np.audio.count)/\(expA), sottotitoli \(np.subs.count)/\(expS)): l'originale non è stato toccato.") }
    if abs(np.duration - (e0 - s0)) > 3 { return FixResult(ok: false, message: String(format: "Durata del nuovo file %@ diversa dal previsto %@: l'originale non è stato toccato.", hms(np.duration), hms(e0 - s0))) }
    // l'audio non deve avere buchi in più rispetto all'originale (un buco può nascere in silenzio dopo una ricodifica o un taglio)
    func packetIssues(_ p: Probe, _ path: String) -> Int { let c = Collector(); scanPackets(p, path, c); return c.findings.filter { $0.sev >= .warn }.count }
    // solo impostazioni: i flussi sono copiati tali e quali, rileggere tutti i pacchetti di due film non serve (bastano tracce e durata qui sopra)
    let before = plan.changesContent ? packetIssues(pr, path) : 0, after = plan.changesContent ? packetIssues(np, tmp.path) : 0
    if after > before { return FixResult(ok: false, message: "Il controllo dei flussi ha trovato \(after - before) problemi di audio/video nel nuovo file: l'originale non è stato toccato.") }
    var warn = ""
    if plan.tonemap {
        progress(0.84, "Controllo di qualità dell'immagine…")
        if let why = tonemapQC(new: tmp.path, duration: pr.duration, lines: &lines) { return FixResult(ok: false, message: "Conversione HDR→SDR annullata: \(why). Il file non è stato toccato.", lines: lines) }
    }
    if plan.deinterlace && !plan.tonemap {
        progress(0.84, "Controllo di qualità dell'immagine (VMAF)…")
        if let why = deinterlaceQC(source: path, new: tmp.path, duration: pr.duration, lines: &lines, progress: { progress(0.84 + 0.04 * $0, "Controllo di qualità dell'immagine (VMAF)…") }) {
            return FixResult(ok: false, message: "Correzione dell'immagine annullata: \(why). Il file non è stato toccato.", lines: lines)
        }
    }
    var doubts: [DubDoubt] = [], doubtTrack: Int?
    for k in plan.audioTouched.sorted() {
        let outOrd = (0..<k).filter { !plan.dropAudio.contains($0) }.count
        progress(0.85 + 0.1 * Double(outOrd) / Double(max(1, plan.audioTouched.count)), "Controllo del risultato (traccia \(k + 1))…")
        guard let b = beforeLoud[k], let af = measureLoudness(tmp.path, outOrd) else { return FixResult(ok: false, message: "Non riesco a misurare l'audio dopo la correzione: l'originale non è stato toccato.") }
        lines.append("Audio \(k + 1) prima: \(lufs(b))"); lines.append("Audio \(k + 1) dopo:  \(lufs(af))")
        // regola di fondo: meglio non toccare l'audio che peggiorarlo
        func reject(_ why: String) -> FixResult { FixResult(ok: false, message: "Correzione audio annullata: \(why). Il file non è stato toccato.", lines: lines) }
        if af.2 > 0.0 && af.2 > b.2 + 0.3 { return reject("avrebbe causato distorsione (il picco passa da \(String(format: "%+.1f", b.2)) a \(String(format: "%+.1f", af.2)) dBFS)") }   // conta il peggioramento, non il valore assoluto: molte tracce hanno già picchi sopra 0
        if let ref = plan.retimeDub[k] {   // il doppiaggio deve risultare a tempo con l'originale in tutto il film
            let refOut = (0..<ref).filter { !plan.dropAudio.contains($0) }.count
            guard let sg = dubSegments(tmp.path, dub: outOrd, ref: refOut, duration: np.duration) else { return reject("non riesco a verificare la sincronia del doppiaggio nel file nuovo") }
            let bad = sg.filter { ($0.d ?? 0) > syncLateTol || ($0.d ?? 0) < -syncEarlyTol }, ds = sg.compactMap(\.d)
            lines.append(String(format: "Audio %d dopo: scarto dal riferimento da %+.0f a %+.0f ms in tutto il film", k + 1, (ds.min() ?? 0) * 1000, (ds.max() ?? 0) * 1000))
            if bad.reduce(0, { $0 + $1.end - $1.start }) > 30 { return reject("il doppiaggio non risulta ancora a tempo (es. da \(hms(bad[0].start)) a \(hms(bad[0].end)))") }
            progress(0.9, "Cerco i tratti in cui la sincronia non si può misurare con certezza…")
            doubts = dubDoubts(ref: (tmp.path, refOut), dub: (tmp.path, outOrd), duration: np.duration); doubtTrack = outOrd
            if !doubts.isEmpty { lines.append("Da guardare a occhio (la misura non decide): " + doubts.map { "\(hms($0.start))–\(hms($0.end))" }.joined(separator: ", ")) }
        }
        if (plan.toDolby.contains(k) || plan.retimeDub[k] != nil), plan.levelGain.isDisjoint(with: [k]), abs(af.0 - b.0) > 1.0 { return reject(String(format: "la conversione avrebbe cambiato il volume (da %.1f a %.1f LUFS)", b.0, af.0)) }
        if plan.levelGain.contains(k), abs(af.0 - levelTarget) > 2.5 { return reject(String(format: "il volume ottenuto (%.1f LUFS) è lontano dall'obiettivo (%.0f)", af.0, levelTarget)) }
        if let bd = beforeDial[k] {
            guard let ad = dialogueStats(tmp.path, outOrd) else { return reject("non riesco a misurare i dialoghi dopo la correzione") }
            lines.append(String(format: "Audio %d musica sopra i dialoghi (>6 LU) prima: %.0f%% dei momenti con parlato — dopo: %.0f%%", k + 1, bd.coveredPct, ad.coveredPct))
            if ad.coveredPct > bd.coveredPct + 1.5 || ad.covered10Pct > bd.covered10Pct + 1.0 {
                return reject(String(format: "la musica sarebbe risultata più forte rispetto ai dialoghi (dal %.0f%% al %.0f%% dei momenti con parlato)", bd.coveredPct, ad.coveredPct))
            }
        } else if plan.normalize.contains(k), af.1 > b.1 + 0.5 {
            return reject(String(format: "l'escursione dinamica sarebbe aumentata (da %.1f a %.1f LU)", b.1, af.1))
        }
        if af.2 > -0.1 && af.2 > b.2 + 0.1 { warn = " Attenzione: il picco dopo la correzione è più alto di prima." }
    }
    // il risultato diventa il file di uscita; l'originale non viene mai toccato (a meno che non si stia correggendo una copia già corretta)
    progress(0.97, "Salvataggio…")
    do {
        if inPlace { _ = try FileManager.default.replaceItemAt(output, withItemAt: tmp) }
        else {
            if FileManager.default.fileExists(atPath: output.path) { return FixResult(ok: false, message: "Esiste già «\(output.lastPathComponent)»: non lo sovrascrivo. L'originale non è stato toccato.") }
            try FileManager.default.moveItem(at: tmp, to: output)
        }
    } catch { return FixResult(ok: false, message: "Salvataggio non riuscito: \(error.localizedDescription). L'originale non è stato toccato.") }
    progress(1, "Fatto")
    let labels = inPlace && !plan.changesContent   // solo impostazioni in un file non mkv: riscritto senza ricodifica e sostituito dopo i controlli
    return FixResult(ok: true, message: (labels ? "Impostazioni aggiornate nel file, senza crearne una nuova versione." : inPlace ? "Copia corretta aggiornata." : "Creata «\(output.lastPathComponent)». L'originale non è stato toccato.") + warn, lines: lines, backup: nil, newURL: output, doubts: doubts, doubtTrack: doubtTrack, labelsOnly: labels)
}

/// Un sottotitolo esterno da aggiungere al film: file, lingua (codice a 3 lettere) e nome della traccia.
struct AddedSub { var file: URL; var lang: String; var title: String = ""; var isDefault = false; var position: Double? = nil; var cover: Double? = nil }   // cover: altezza (frazione) della fascia nera che copre i sottotitoli impressi, solo mentre ci sono battute; solo mkv   // position: distanza dal basso (frazione dell'altezza) per stare sopra i sottotitoli impressi; solo mkv

/// Converte un SRT in ASS con i sottotitoli alzati a `bottom` (frazione dell'altezza dal basso): servono a non coprire quelli impressi nell'immagine.
func srtToASS(_ srt: String, width: Int, height: Int, bottom: Double, cover: Double? = nil) -> String {
    func t(_ x: Double) -> String { let cs = Int((max(0, x) * 100).rounded()); return String(format: "%d:%02d:%02d.%02d", cs / 360000, cs / 6000 % 60, cs / 100 % 60, cs % 100) }
    func body(_ s: String) -> String {
        var x = s.replacingOccurrences(of: "<i>", with: "{\\i1}").replacingOccurrences(of: "</i>", with: "{\\i0}").replacingOccurrences(of: "<b>", with: "{\\b1}").replacingOccurrences(of: "</b>", with: "{\\b0}")
        x = x.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\{\\an?\d\}"#, with: "", options: .regularExpression)
        return x.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\\N")
    }
    let fs = Int(Double(height) * 0.052), mv = Int(Double(height) * bottom)
    var out = "[Script Info]\nScriptType: v4.00+\nPlayResX: \(width)\nPlayResY: \(height)\nWrapStyle: 0\nScaledBorderAndShadow: yes\n\n[V4+ Styles]\n"
    out += "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
    out += "Style: Default,Helvetica Neue,\(fs),&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,\(max(2, fs / 18)),1,2,\(width / 12),\(width / 12),\(mv),1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    let cues = parseSRT(srt).filter { !$0.t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if let cv = cover {   // fascia nera a tutta larghezza (disegno vettoriale ASS) sotto le battute, unita quando le battute sono vicine
        var spans: [(Double, Double)] = []
        for c in cues.sorted(by: { $0.s < $1.s }) { let a = max(0, c.s - 0.3), b = c.e + 0.3; if let l = spans.last, a - l.1 < 3 { spans[spans.count - 1].1 = max(l.1, b) } else { spans.append((a, b)) } }
        let bh = Int(Double(height) * cv), y = height - bh
        for sp in spans { out += "Dialogue: 0,\(t(sp.0)),\(t(sp.1)),Default,,0,0,0,,{\\an7\\pos(0,\(y))\\bord0\\shad0\\1c&H000000&\\1a&H00&\\p1}m 0 0 l \(width) 0 \(width) \(bh) 0 \(bh){\\p0}\n" }
    }
    for c in cues { out += "Dialogue: 1,\(t(c.s)),\(t(c.e)),Default,,0,0,0,,\(body(c.t))\n" }
    return out
}

/// Negli mp4 la traccia attiva all'avvio è il flag «enabled» del suo tkhd: lo imposta per le tracce di sottotitoli, nell'ordine (modifica sul posto dell'intestazione).
func mp4SetSubtitlesEnabled(_ url: URL, _ on: [Bool]) {
    guard let h = try? FileHandle(forUpdating: url) else { return }
    defer { try? h.close() }
    func u32(_ d: Data, _ o: Int) -> Int { d.count >= o + 4 ? Int(d[d.startIndex + o]) << 24 | Int(d[d.startIndex + o + 1]) << 16 | Int(d[d.startIndex + o + 2]) << 8 | Int(d[d.startIndex + o + 3]) : 0 }
    // trova moov fra i box di primo livello
    var pos: UInt64 = 0; let end = (try? h.seekToEnd()) ?? 0
    while pos + 8 <= end {
        try? h.seek(toOffset: pos); guard let hd = try? h.read(upToCount: 16), hd.count >= 8 else { return }
        var size = UInt64(u32(hd, 0)); let type = String(decoding: hd[hd.startIndex + 4 ..< hd.startIndex + 8], as: UTF8.self)
        if size == 1, hd.count >= 16 { size = UInt64(u32(hd, 8)) << 32 | UInt64(u32(hd, 12)) } else if size == 0 { size = end - pos }
        if type == "moov", size < 512 << 20 {
            try? h.seek(toOffset: pos); guard let m = try? h.read(upToCount: Int(size)) else { return }
            var k = 0, o = 8
            while o + 8 <= m.count {   // ogni trak: hdlr dice il tipo, tkhd porta il flag
                let sz = u32(m, o), ty = String(decoding: m[m.startIndex + o + 4 ..< m.startIndex + o + 8], as: UTF8.self); guard sz >= 8 else { break }
                if ty == "trak", let tr = Optional(m.subdata(in: m.startIndex + o ..< m.startIndex + min(m.count, o + sz))) {
                    let isSub = ["sbtl", "text", "subt"].contains { tr.range(of: Data("hdlr".utf8)).map { r in String(decoding: tr[r.upperBound + 8 ..< r.upperBound + 12], as: UTF8.self) } == $0 }
                    if isSub, let r = tr.range(of: Data("tkhd".utf8)) {
                        let flagPos = pos + UInt64(o) + UInt64(r.upperBound - tr.startIndex) + 3   // versione (1 byte) + flag (3 byte): il bit 1 dell'ultimo è «enabled»
                        var b = tr[r.upperBound + 3]; if k < on.count { b = on[k] ? (b | 1) : (b & ~1) }
                        try? h.seek(toOffset: flagPos); try? h.write(contentsOf: Data([b])); k += 1
                    }
                }
                o += sz
            }
            return
        }
        pos += max(size, 8)
    }
}
/// Legge un file di sottotitoli in UTF-8 o, se non lo è, in Windows-1252 (la codifica dei vecchi SRT italiani), e ripara gli accenti rovinati.
func readSubText(_ url: URL) -> String? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    var t = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1)
    if t?.hasPrefix("\u{FEFF}") == true { t?.removeFirst() }
    return t.map { repairMojibake($0.replacingOccurrences(of: "\r\n", with: "\n")) }
}
