import Foundation

/// Tolleranza della sincronia labiale (EBU R37): l'audio può arrivare fino a 40 ms prima dell'immagine e fino a 60 ms dopo senza che il pubblico se ne accorga.
let syncEarlyTol = 0.040, syncLateTol = 0.060

/// Il doppiaggio confrontato con la traccia originale dello stesso file: musica ed effetti sono gli stessi, quindi si vede se il doppiaggio è spostato (anche a gradini).
/// La traccia originale viene dal master ed è quella a tempo con l'immagine.
func scanDubSync(_ pr: Probe, _ path: String, _ c: Collector, progress: @escaping (Double) -> Void = { _ in }) {
    let a = pr.audio; guard a.count >= 2, pr.duration > 300 else { return }
    let ls = a.map { lang($0) }
    guard let ref = a.indices.filter({ !ls[$0].isEmpty && ls[$0] != "ita" }).max(by: { (dbl(a[$0]["channels"]) ?? 0) < (dbl(a[$1]["channels"]) ?? 0) }) else { return }
    for k in a.indices where ls[k] == "ita" {
        let n = "traccia audio \(k + 1) (\(langLabel(ls[k])))"
        var er: [Float] = [], ed: [Float] = []; let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { er = fullEnvelope(path, track: ref, duration: pr.duration) { progress(0.5 * $0) }; g.leave() }
        g.enter(); DispatchQueue.global().async { ed = fullEnvelope(path, track: k, duration: pr.duration); g.leave() }
        g.wait()
        let r = segmentAlignment(er, ed, vDur: pr.duration, maxSearch: 1)   // nello stesso file un doppiaggio non salta di secondi
        guard r.why == nil, r.drift == nil, !r.segments.isEmpty else {
            c.rows("Audio \(k + 1)", order: 10 + k, [("Sincronia con l'originale", "non misurabile (musica ed effetti diversi da quelli della traccia in \(langLabel(ls[ref])))")]); continue
        }
        let parts = r.segments.filter { $0.d != nil }, ds = parts.map { $0.d! }, lo = ds.min() ?? 0, hi = ds.max() ?? 0
        c.rows("Audio \(k + 1)", order: 10 + k, [("Sincronia con l'originale", lo > -0.02 && hi < 0.02 ? "a tempo con la traccia in \(langLabel(ls[ref])) (entro 20 ms)" : String(format: "da %+.0f a %+.0f ms rispetto alla traccia in %@, in %d tratti (+ = in ritardo)", lo * 1000, hi * 1000, langLabel(ls[ref]), parts.count))])
        let bad = parts.filter { $0.d! > syncLateTol || $0.d! < -syncEarlyTol }, badDur = bad.reduce(0) { $0 + $1.end - $1.start }
        guard badDur > 60 else { continue }
        func desc(_ s: MergeSegment) -> String { String(format: "da %@ a %@ %@ di %.0f ms", hms(s.start), hms(s.end), s.d! > 0 ? "in ritardo" : "in anticipo", abs(s.d!) * 1000) }
        let worst = bad.sorted { abs($0.d!) > abs($1.d!) }.prefix(6).sorted { $0.start < $1.start }
        c.add(.warn, "Audio", "Il doppiaggio non è a tempo con l'originale — \(n)", String(format: "Confrontato con la traccia in %@ dello stesso file (stessa musica e stessi effetti): per %@ di film il doppiaggio è fuori dalla tolleranza (40 ms in anticipo, 60 ms in ritardo): ", langLabel(ls[ref]), hms(badDur)) + worst.map(desc).joined(separator: "; ") + ". In sala le labbra non vanno a tempo con le voci. Unendo questa copia a un'altra con «Unisci» Booth lo rimette a tempo tratto per tratto.", time: worst.first?.start)
        c.fact("a\(k).dubOff", hi > -lo ? hi : lo)
    }
}

/// Consigli pratici per chi proietta, ricavati dalle misure: niente teoria, cosa fare e dove guardare.
func projectionTips(_ r: Report, _ f: [String: Double]) -> [Tip] {
    var t: [Tip] = []
    let main = r.audioTracks.prefix(3).firstIndex { $0.isDefault } ?? 0
    // 1) da dove partire
    if let s = f["v.startAt"] { t.append(Tip(icon: "play.circle", title: "Da dove partire", text: "Fai partire il film da \(hms(s.rounded(.down))): prima ci sono \(Int(s)) s di nero o di immagine ferma.")) }
    // 2) volume della sala
    if let talk = f["a\(main).talkT"], let p50 = f["a\(main).p50"] {
        var s = "Regola il volume dell'impianto su un tratto dal livello tipico del film, \(hms(talk))–\(hms(talk + 20)): lì i dialoghi devono essere chiari e comodi."
        if let loud = f["a\(main).loudT"], let ll = f["a\(main).loudL"], ll - p50 > 6 { s += String(format: " Poi ascolta %@, il punto più forte (%.0f dB sopra): se lì è troppo, abbassa un poco e non toccare più il volume durante la proiezione.", hms(loud), ll - p50) }
        if let i = f["a\(main).I"], i < -28 { s += String(format: " Il film è registrato basso (%.0f LUFS): ti servirà più volume del solito, è normale.", i) }
        else if let i = f["a\(main).I"], i > -18 { s += String(format: " Il film è registrato alto (%.0f LUFS, master da TV): parti con il volume più basso del solito.", i) }
        t.append(Tip(icon: "speaker.wave.2", title: "Volume", text: s))
    }
    // 3) volume del lettore: picchi oltre lo 0 dB
    if let p = f["a\(main).peak"], p > 0.5 { t.append(Tip(icon: "slider.horizontal.3", title: "Volume del lettore", text: String(format: "Il file ha picchi a %+.1f dB oltre il massimo digitale: con il lettore al 100%% in quei punti il suono gracchia. Abbassa il volume del lettore di almeno %.0f dB e compensa alzando l'amplificatore.", p, (p + 1).rounded(.up)))) }
    // 4) dialoghi
    if let cv = f["a\(main).cover"] {
        t.append(Tip(icon: "person.wave.2", title: "Dialoghi", text: cv < 1 ? "Sono chiari: la musica non li copre quasi mai. Non serve alzare il canale centrale." : cv < 8 ? String(format: "Sono chiari: la musica li copre solo nel %.0f%% del parlato. Non serve alzare il canale centrale.", cv)
            : String(format: "La musica copre i dialoghi nel %.0f%% del parlato: sull'amplificatore alza il canale centrale di 2–3 dB, oppure usa «Alza i dialoghi».", cv)))
    }
    // 5) collegamento audio
    if r.audioTracks.indices.contains(main) {
        let a = r.audioTracks[main], multi = a.channels > 2
        let txt: String
        switch a.codec {
        case "ac3": txt = "Dolby Digital: va bene sia con il cavo HDMI sia con quello ottico."
        case "eac3", "truehd": txt = "\(a.codec == "eac3" ? "Dolby Digital Plus" : "Dolby TrueHD"): passa solo via HDMI. Con il cavo ottico l'amplificatore non lo riceve: in quel caso usa «Converti in Dolby»."
        case "dts": txt = "DTS: va bene via HDMI e via ottico, se l'amplificatore lo decodifica (quasi tutti)."
        default: txt = multi ? "\(a.codec.uppercased()) \(a.channels == 6 ? "5.1" : "\(a.channels) canali"): con il Mac collegato via HDMI arriva intatto all'amplificatore, non serve convertirlo. Solo con il cavo ottico arriverebbe in stereo: in quel caso usa «Converti in Dolby»."
                             : "Audio stereo: in sala esce da sinistra e destra. Se vuoi i dialoghi anche dal centrale, attiva sull'amplificatore la modalità che ricava il 5.1 dallo stereo (Dolby Surround/Pro Logic)."
        }
        t.append(Tip(icon: "cable.connector", title: "Collegamento audio", text: txt))
    }
    // 6) immagine sullo schermo grande
    if let w = f["v.w"], w > 0 {
        let block = f["v.block"], blur = f["v.blur"], bpp = f["v.bpp"], low = (bpp ?? 1) < ((f["v.modern"] ?? 0) == 1 ? 0.022 : 0.04)
        let mb = f["v.br"].map { String(format: "%.1f Mb/s", $0 / 1e6) } ?? ""
        let txt: String
        if w < 1280 || (block ?? 0) > 4 || (blur ?? 0) > 14 { txt = "Scarsa per uno schermo grande: si vedranno immagine morbida e quadretti. Se puoi, cerca un'altra copia (Blu-ray 1080p, almeno 8 Mb/s) e confrontale con «Confronta due copie»; se l'altra copia ha l'audio sbagliato, «Unisci» prende l'immagine migliore e l'audio giusto." }
        else if low, let b = block, b <= 2.5, (blur ?? 0) <= 8 { txt = "Buona: il file è molto compresso (\(mb)) ma le misure sull'immagine sono nella norma. Al massimo qualche fascia di colore nelle scene buie, nel fumo e nella nebbia, visibile solo dalle prime file." }
        else if low { txt = "Discreta: il file è molto compresso (\(mb)), nelle scene buie e in movimento si vedrà un po' di grana a blocchi. Se ne trovi una copia più pesante è meglio." }
        else { txt = w >= 3000 ? "Ottima: 4K ben codificato." : "Ottima per la sala: risoluzione e compressione nella norma." }
        t.append(Tip(icon: "photo", title: "Immagine sullo schermo", text: txt))
    }
    // 7) sottotitoli in base alla lingua dell'audio
    if r.audioTracks.indices.contains(main) {
        let al = r.audioTracks[main].lang, ita = r.subTracks.filter { $0.lang == "ita" && !$0.forced && !$0.title.lowercased().contains("forc") && !$0.title.lowercased().contains("forz") }
        if al == "ita" { if ita.contains(where: \.isDefault) { t.append(Tip(icon: "captions.bubble", title: "Sottotitoli", text: "Film in italiano con i sottotitoli italiani accesi all'avvio: spegnili, in sala apparirebbero sopra il film.")) } }
        else if !al.isEmpty {
            if ita.isEmpty { t.append(Tip(icon: "captions.bubble", title: "Sottotitoli", text: "L'audio predefinito è in \(langLabel(al)) e non ci sono sottotitoli italiani: per la sala servono, cercali prima della proiezione.")) }
            else if !ita.contains(where: \.isDefault) { t.append(Tip(icon: "captions.bubble", title: "Sottotitoli", text: "L'audio predefinito è in \(langLabel(al)): ricordati di accendere i sottotitoli italiani (traccia \(ita[0].ord + 1)), oppure rendili predefiniti.")) }
        }
    }
    // 8) titoli di coda: dall'ultima battuta dei sottotitoli
    let lasts = r.subTracks.indices.compactMap { i in f["s\(i).last"].map { (i, $0) } }.filter { (f["s\($0.0).n"] ?? 0) > 200 }
    if let last = lasts.map(\.1).max(), r.duration - last > 150, last > r.duration * 0.7 {
        t.append(Tip(icon: "lightbulb", title: "Fine del film", text: "L'ultima battuta è a \(hms(last)); dopo restano circa \(Int(((r.duration - last) / 60).rounded())) minuti, quasi certamente i titoli di coda: da lì puoi riaccendere le luci di sala."))
    }
    return t
}

/// Rende le segnalazioni più realistiche alla luce delle altre misure (es. bitrate basso ma immagine misurata buona).
func refineFindings(_ fs: inout [Finding], _ f: [String: Double], _ r: Report) {
    for i in fs.indices {
        let x = fs[i]
        if x.title == "Bitrate video basso", let b = f["v.block"], b <= 2.5, (f["v.blur"] ?? 0) <= 8 {
            fs[i].sev = .info; fs[i].detail += String(format: " Le misure sull'immagine però sono nella norma (blocchettatura %.1f, nitidezza normale): sullo schermo grande regge.", b)
        }
        if x.title.hasPrefix("Picchi a 0 dB"), let k = Int(x.title.split(separator: " ").last { Int($0) != nil } ?? ""), let p = f["a\(k - 1).peak"] {
            fs[i].detail = String(format: "Il picco arriva a %+.1f dB oltre il massimo digitale: con il volume del lettore al 100%% in quei punti il suono gracchia. Basta tenere il volume del lettore più basso di %.0f dB e alzare l'amplificatore; «Regola il volume» abbassa il file di quanto serve.", p, (p + 1).rounded(.up))
            if p < 1 { fs[i].sev = .info }
        }
        if x.title.hasPrefix("Audio non Dolby") {
            fs[i].detail = "Serve solo se l'audio arriva all'amplificatore con il cavo ottico (che porta il 5.1 solo in Dolby o DTS) o se il lettore manda il flusso così com'è. Con il Mac collegato via HDMI l'audio arriva intatto e convertirlo fa solo perdere un po' di qualità."
            fs[i].sev = .info
        }
        if x.title.hasPrefix("Durata dell'audio diversa dal film"), r.duration > 0, let k = Int(x.title.split(separator: " ").last { Int($0) != nil } ?? ""), let e = f["a\(k - 1).end"], e < r.duration, r.duration - e < 60 {
            fs[i].detail += " Sono gli ultimi secondi dei titoli di coda senza suono: non si nota."
        }
    }
}
