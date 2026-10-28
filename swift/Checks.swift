import Foundation

private let stdFps: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60]
let adPattern = #"www\.|https?://|\b[a-z0-9-]{4,}\.(com|net|org|info|tv|to|me|ws|cc|io|ru|mx|pw|se)\b|\byify\b|\byts\b|rarbg|torrent|\bettv\b|eztv|1337x|opensubtitles|subscene|addic7ed|podnapisi|\bsub(titles?)? (by|from)\b|sottotitoli (di|by|a cura)|traduzione( di| a cura)?:|tradotto da|translated by|sync(ed|hronized)?( (and|&) (corrected|edited))? by|ripped by|encoded by|downloaded from|scaricato da|italiansubs|itasa|please rate|advertise|your ad here|vip member|\bfgt\b|\bntb\b|\bpsa\b|megusta|\btigole\b|\bqxr\b|galaxytv|\bamiable\b|\bpublichd\b|\bsparks\b|\bgeckos\b|licdom|mir ?crew|phadron|jeddak|sp33dy94|g4tpuz|ebleep|paso77|\bgege\b|dr\.? ?mzu|novarip|lordbangs|ilcorsaronero|corsaronero|tntvillage|torrentgalaxy|piratebay|ddlvalle|italiashare|streamingcommunity|altadefinizione|cb01|guardaserie|\bnuita\b|\bnueng\b"#

func checkContainer(_ pr: Probe, _ url: URL, _ c: Collector) {
    let ext = url.pathExtension.lowercased(); let fname = (pr.fmt["format_name"] as? String) ?? ""; let ft = tags(["tags": pr.fmt["tags"] as Any])
    let sz = pr.size, d = pr.duration
    var rows: [(String, String)] = [("File", url.lastPathComponent), ("Dimensione", fmtBytes(sz)), ("Durata", hms(d) + String(format: " (%.0f s)", d)), ("Contenitore", (pr.fmt["format_long_name"] as? String) ?? fname)]
    if let br = dbl(pr.fmt["bit_rate"]) { rows.append(("Bitrate totale", fmtRate(br))) }
    if let t = ft["title"] { rows.append(("Titolo nei metadati", t)) }
    if let e = ft["encoder"] ?? ft["writing_application"] { rows.append(("Creato con", e)) }
    rows.append(("Capitoli", pr.chapters.isEmpty ? "nessuno" : "\(pr.chapters.count)"))
    c.rows("File", order: 0, rows)
    let ok = ["mp4": ["mov", "mp4"], "m4v": ["mov", "mp4"], "mkv": ["matroska"], "avi": ["avi"], "mov": ["mov"]]
    if let exp = ok[ext], !exp.contains(where: { fname.contains($0) }) { c.add(.warn, "File", "L'estensione non corrisponde al contenuto", "Il file è .\(ext) ma il contenitore è «\(fname)».") }
    if !["mp4", "mkv", "avi", "m4v", "mov"].contains(ext) { c.add(.info, "File", "Formato insolito (.\(ext))", "Pensato per mp4, mkv, avi.") }
    if pr.video == nil { c.add(.error, "Video", "Nessuna traccia video", "Il file non contiene immagini.") }
    if d > 0 && d < 60 { c.add(.warn, "File", "Durata molto breve", "Il file dura solo \(hms(d)).") }
    let want = titleBase(url), norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
    if let t = ft["title"], t.has(adPattern) { c.add(.warn, "File", "Il titolo nei metadati contiene pubblicità", "«\(t)» — compare in alcuni lettori. Si può sostituire con il nome del file («\(want)»).", fix: [.setTitle(want)]) }
    else if let t = ft["title"], !t.isEmpty, norm(t) != norm(want) { c.add(.info, "File", "Il titolo nei metadati è diverso dal nome del file", "Nei metadati c'è «\(t)», il file si chiama «\(want)»: alcuni lettori mostrano il titolo dei metadati, che non cambia se rinomini il file nel Finder.", fix: [.setTitle(want)]) }
    if let t = ft["comment"] ?? ft["description"], t.has(adPattern) { c.add(.info, "File", "Commento dei metadati con pubblicità", "«\(String(t.prefix(120)))»") }
    if ext == "avi", let cn = pr.video?["codec_name"] as? String, ["h264", "hevc"].contains(cn) { c.add(.info, "File", "H.264/HEVC dentro AVI", "Il contenitore AVI gestisce male il flusso moderno: possibili scatti nella ricerca e nella sincronia.") }
    if let n = Optional(pr.of("video").count + pr.streams.filter { disp($0, "attached_pic") == 1 }.count), n > 1 { c.add(.info, "File", "Più flussi video o copertina incorporata", "\(n) flussi: viene riprodotto il primo.") }
    if pr.chapters.isEmpty && d > 3600 { c.add(.info, "File", "Nessun capitolo", "Utile per saltare tra le scene durante la proiezione.") }
}

func checkVideo(_ pr: Probe, _ c: Collector) {
    guard let v = pr.video else { return }
    let w = Int(dbl(v["width"]) ?? 0), h = Int(dbl(v["height"]) ?? 0); let codec = (v["codec_name"] as? String) ?? "?"; let tg = tags(v)
    let fpsR = ratio(v["r_frame_rate"]) ?? 0, fpsA = ratio(v["avg_frame_rate"]) ?? 0; let fps = fpsA > 0 ? fpsA : fpsR
    let pix = (v["pix_fmt"] as? String) ?? ""; let bits = Int(dbl(v["bits_per_raw_sample"]) ?? 0) > 0 ? Int(dbl(v["bits_per_raw_sample"])!) : (pix.has("10") ? 10 : pix.has("12") ? 12 : 8)
    let br = dbl(v["bit_rate"]) ?? dbl(tg["bps"]) ?? max(0, (dbl(pr.fmt["bit_rate"]) ?? 0) - pr.audio.reduce(0) { $0 + (dbl($1["bit_rate"]) ?? dbl(tags($1)["bps"]) ?? 0) })
    let field = (v["field_order"] as? String) ?? "unknown"; let trc = (v["color_transfer"] as? String) ?? ""; let prim = (v["color_primaries"] as? String) ?? ""
    var rows: [(String, String)] = [("Codec", codec.uppercased() + ((v["profile"] as? String).map { " · \($0)" } ?? "") + (dbl(v["level"]).map { " · livello \($0 > 9 ? String(format: "%.1f", $0 / 10) : String(Int($0)))" } ?? "")),
        ("Risoluzione", "\(w)×\(h)"), ("Proporzioni", ((v["display_aspect_ratio"] as? String) ?? String(format: "%.2f:1", Double(w) / Double(max(h, 1)))) + " (pixel \((v["sample_aspect_ratio"] as? String) ?? "1:1"))"),
        ("Fotogrammi al secondo", fps > 0 ? String(format: "%.3f", fps) + (abs(fpsA - fpsR) > fpsR * 0.005 && fpsA > 0 ? " (variabile)" : "") : "?"), ("Profondità colore", "\(bits) bit · \(pix)")]
    if br > 0 { rows.append(("Bitrate video", fmtRate(br))) }
    rows.append(("Scansione", field == "progressive" ? "progressiva" : field == "unknown" ? "non dichiarata" : "interlacciata (\(field))"))
    rows.append(("Colore", [trc, prim, (v["color_space"] as? String) ?? "", (v["color_range"] as? String) ?? ""].filter { !$0.isEmpty && $0 != "unknown" }.joined(separator: " · ").isEmpty ? "non dichiarato" : [trc, prim, (v["color_space"] as? String) ?? "", (v["color_range"] as? String) ?? ""].filter { !$0.isEmpty && $0 != "unknown" }.joined(separator: " · ")))
    c.rows("Video", order: 1, rows)
    c.fact("v.w", Double(w)); c.fact("v.h", Double(h)); if br > 0 { c.fact("v.br", br) }; if br > 0 && fps > 0 && w > 0 && h > 0 { c.fact("v.bpp", br / (Double(w * h) * fps)) }; c.fact("v.modern", ["hevc", "av1", "vp9"].contains(codec) ? 1 : 0)

    if w > 0 && w < 960 { c.add(.warn, "Video", "Risoluzione bassa per la proiezione", "\(w)×\(h): su uno schermo grande si vedrà morbida e a blocchi.") }
    else if w > 0 && w < 1280 { c.add(.info, "Video", "Risoluzione inferiore a HD", "\(w)×\(h).") }
    if br > 0 && fps > 0 && w > 0 && h > 0 {
        let bpp = br / (Double(w * h) * fps); let modern = ["hevc", "av1", "vp9"].contains(codec)
        if bpp < (modern ? 0.022 : 0.04) { c.add(.warn, "Video", "Bitrate video basso", String(format: "%@ per %dx%d: %.3f bit/pixel, sotto il minimo consigliato (%.3f) per %@. Attese sgranature nelle scene scure e in movimento.", fmtRate(br), w, h, bpp, modern ? 0.022 : 0.04, codec.uppercased())) }
    }
    if ["tt", "bb", "tb", "bt"].contains(field) { c.add(.warn, "Video", "Video interlacciato", "Il file dichiara scansione interlacciata (\(field)): in proiezione compaiono righe a pettine nei movimenti, serve il deinterlacciamento.", fix: [.deinterlace]) }
    if fpsA > 0 && fpsR > 0 && abs(fpsA - fpsR) > fpsR * 0.005 { c.add(.warn, "Video", "Frame rate variabile", String(format: "Dichiarato %.3f ma in media %.3f fps: rischio di scatti e perdita di sincronia.", fpsR, fpsA)) }
    if fps > 0 && !stdFps.contains(where: { abs($0 - fps) < 0.02 }) && !(fpsA > 0 && abs(fpsA - fpsR) > fpsR * 0.005) { c.add(.warn, "Video", "Frame rate insolito", String(format: "%.3f fps: non è uno standard del cinema o della TV, la fluidità può risentirne.", fps)) }
    if trc == "smpte2084" || trc == "arib-std-b67" { c.add(.warn, "Video", trc == "smpte2084" ? "HDR (PQ)" : "HDR (HLG)", "Su un proiettore SDR i colori appaiono spenti e grigi se non c'è la conversione (tone mapping). Si può convertire in SDR.", fix: [.tonemap]) }
    else if prim == "bt2020" { c.add(.info, "Video", "Gamma colori allargata (BT.2020)", "Senza HDR dichiarato: controlla i colori sul proiettore.") }
    if (v["color_space"] as? String ?? "unknown") == "unknown" && h >= 720 { c.add(.info, "Video", "Matrice colore non dichiarata", "Il lettore deve indovinarla: sulle immagini HD può dare colori leggermente sbagliati.") }
    if let sar = v["sample_aspect_ratio"] as? String, sar != "1:1", sar != "0:1", sar != "N/A" { c.add(.info, "Video", "Pixel non quadrati (SAR \(sar))", "L'immagine viene allargata in riproduzione: verifica che la forma sia corretta.") }
    if let st = dbl(v["start_time"]), abs(st) > 0.5 { c.add(.info, "Video", "Il video non parte da zero", String(format: "Inizia a %.2f s.", st)) }
}

/// Famiglia Dolby di una traccia audio (nil se non è Dolby): Dolby Digital (AC-3), Dolby Digital Plus (E-AC-3), Dolby TrueHD; con Atmos se il profilo lo dichiara.
func dolbyKind(_ s: [String: Any]) -> String? {
    let codec = (s["codec_name"] as? String) ?? "", prof = (s["profile"] as? String) ?? ""; let atmos = prof.lowercased().contains("atmos") ? " con Atmos" : ""
    switch codec { case "ac3": return "Dolby Digital (AC-3)"; case "eac3": return "Dolby Digital Plus (E-AC-3)" + atmos; case "truehd": return "Dolby TrueHD" + atmos; default: return nil }
}
func checkAudioStreams(_ pr: Probe, _ c: Collector) {
    let a = pr.audio
    if a.isEmpty { c.add(.error, "Audio", "Nessuna traccia audio", "Il film non ha suono."); return }
    for (i, s) in a.enumerated() {
        let tg = tags(s); let ch = Int(dbl(s["channels"]) ?? 0); let codec = (s["codec_name"] as? String) ?? "?"; let br = dbl(s["bit_rate"]) ?? dbl(tg["bps"])
        var rows: [(String, String)] = [("Lingua", langLabel(lang(s))), ("Codec", codec.uppercased() + ((s["profile"] as? String).map { " · \($0)" } ?? "")), ("Canali", ((s["channel_layout"] as? String) ?? "\(ch)") + " (\(ch))"), ("Campionamento", "\(Int(dbl(s["sample_rate"]) ?? 0)) Hz")]
        if let br = br { rows.append(("Bitrate", fmtRate(br))) }
        if let t = tg["title"] { rows.append(("Nome", t)) }
        rows.append(("Dolby", dolbyKind(s).map { "sì — " + $0 } ?? "no (\(codec.uppercased()))"))
        rows.append(("Predefinita", disp(s, "default") == 1 ? "sì" : "no"))
        c.rows("Audio \(i + 1)", order: 10 + i, rows)
        let n = "traccia audio \(i + 1)" + (lang(s).isEmpty ? "" : " (\(langLabel(lang(s))))")
        if dolbyKind(s) == nil {   // formato diverso da Dolby: si può convertire in Dolby Digital (AC-3) fino a 5.1
            let isMain = disp(s, "default") == 1 || a.count == 1
            c.add(isMain ? .warn : .info, "Audio", "Audio non Dolby (\(codec.uppercased())) — \(n)", "Il formato non fa parte della famiglia Dolby (AC-3, E-AC-3, TrueHD)." + (ch > 6 ? " Con più di 6 canali la conversione non è disponibile." : " Si può convertire in Dolby Digital (AC-3), il formato più compatibile con amplificatori e proiettori; da un formato già compresso (AAC, DTS, MP3) si perde un po' di qualità, quindi l'app usa il bitrate più alto."), fix: ch <= 6 ? [.toDolby(i)] : [])
        } else if (dolbyKind(s) ?? "").contains("Atmos") { c.add(.info, "Audio", "Traccia con Dolby Atmos — \(n)", "Contiene audio a oggetti: non convertirla, si perderebbero gli oggetti.") }
        if lang(s).isEmpty { c.add(.warn, "Audio", "Lingua non indicata — \(n)", "Senza lingua il lettore non sceglie la traccia giusta da solo.", fix: [.setLang("a", i)]) }
        if ch == 1 && a.count > 0 { c.add(.info, "Audio", "Audio mono — \(n)", "In sala uscirà solo da un canale se l'impianto non lo duplica.") }
        if let br = br, br < 64_000 * Double(max(ch, 1)) / 2 && ch <= 2 { c.add(.warn, "Audio", "Bitrate audio basso — \(n)", "\(fmtRate(br)): qualità da telefono, fruscii e suono metallico in sala.") }
        if (dbl(s["sample_rate"]) ?? 48000) < 44100 { c.add(.warn, "Audio", "Campionamento basso — \(n)", "\(Int(dbl(s["sample_rate"]) ?? 0)) Hz: perdita di acuti.") }
        if ch > 2 { c.add(.info, "Audio", "Audio multicanale (\(ch) canali) — \(n)", "Se l'impianto della sala è stereo la riduzione a 2 canali può rendere i dialoghi più bassi della musica.") }
        if let st = dbl(s["start_time"]), let vs = dbl(pr.video?["start_time"]), abs(st - vs) > 0.12 { c.add(.warn, "Audio", "Audio e video non partono insieme — \(n)", String(format: "Scarto iniziale di %.0f ms: possibile fuori sincrono.", (st - vs) * 1000)) }
    }
    let defs = a.filter { disp($0, "default") == 1 }.count
    if a.count > 1 && defs == 0 { c.add(.warn, "Audio", "Nessuna traccia audio predefinita", "Con più tracce, il lettore sceglie a caso.", fix: [.defaultAudio(0)]) }
    if defs > 1 { c.add(.warn, "Audio", "Più tracce audio predefinite", "\(defs) tracce marcate come predefinite: la scelta è ambigua.", fix: [.defaultAudio(a.firstIndex(where: { disp($0, "default") == 1 }) ?? 0)]) }
    let ls = a.map { lang($0) }.filter { !$0.isEmpty }
    if Set(ls).count < ls.count { c.add(.info, "Audio", "Due tracce audio nella stessa lingua", "Controlla che siano davvero diverse (es. stereo e 5.1).") }
}

let imageSubs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]
func checkSubStreams(_ pr: Probe, _ c: Collector) {
    let ss = pr.subs
    if ss.isEmpty { c.add(.info, "Sottotitoli", "Nessun sottotitolo incorporato", "Se il film non è in italiano serviranno sottotitoli esterni."); return }
    for (i, s) in ss.enumerated() {
        let tg = tags(s); let codec = (s["codec_name"] as? String) ?? "?"; let forced = disp(s, "forced") == 1
        var rows: [(String, String)] = [("Lingua", langLabel(lang(s))), ("Formato", codec + (imageSubs.contains(codec) ? " (immagine)" : " (testo)"))]
        if let t = tg["title"] { rows.append(("Nome", t)) }
        rows.append(("Predefinito", disp(s, "default") == 1 ? "sì" : "no")); rows.append(("Forzato", forced ? "sì" : "no"))
        if let n = tg["number_of_frames"] { rows.append(("Sottotitoli", n)) }
        c.rows("Sottotitoli \(i + 1)", order: 30 + i, rows)
        let n = "sottotitoli \(i + 1)" + (lang(s).isEmpty ? "" : " (\(langLabel(lang(s)))" + (forced ? ", forzati)" : ")"))
        if lang(s).isEmpty { c.add(.warn, "Sottotitoli", "Lingua non indicata — \(n)", "Impossibile sceglierli in automatico.", fix: [.setLang("s", i)]) }
        if disp(s, "default") == 1 && !forced { c.add(.warn, "Sottotitoli", "Sottotitoli attivi di default — \(n)", "Compaiono da soli all'avvio: in sala potrebbero apparire senza volerlo.", fix: [.defaultSub(nil)]) }
        if imageSubs.contains(codec) { c.add(.info, "Sottotitoli", "Sottotitoli a immagine — \(n)", "Formato \(codec): non si possono controllare nel testo né cambiare dimensione/colore.") }
        if let t = tg["title"]?.lowercased(), (t.contains("forced") || t.contains("forzat")) && !forced { c.add(.warn, "Sottotitoli", "Si chiamano «forzati» ma non sono marcati come tali — \(n)", "Il lettore li tratterà come sottotitoli completi.", fix: [.setForced(i, true)]) }
    }
    let keys = ss.map { lang($0) + ($0["disposition"].flatMap { ($0 as? [String: Any])?["forced"] as? Int } == 1 ? "F" : "") + (tags($0)["title"] ?? "") }
    if Set(keys).count < keys.count { c.add(.info, "Sottotitoli", "Tracce di sottotitoli duplicate", "Due tracce con stessa lingua, tipo e nome.") }
}
