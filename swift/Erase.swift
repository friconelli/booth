import Foundation
import Vision

/// Una scritta da cancellare dall'immagine: rettangolo normalizzato (origine in alto a sinistra) e tratto di film in cui compare.
struct EraseRegion { var x: Double, y: Double, w: Double, h: Double; var from: Double, to: Double; var label: String }

private func clock(_ s: Double) -> String { let ns = Int((s * 1e9).rounded()); return String(format: "%02d:%02d:%02d.%09d", ns / 3_600_000_000_000, ns / 60_000_000_000 % 60, ns / 1_000_000_000 % 60, ns % 1_000_000_000) }
private func even(_ v: Double) -> Int { Int(v.rounded()) / 2 * 2 }

/// Rettangolo in pixel da ricoprire (scritta + margine; se arriva vicino a un bordo dell'immagine lo raggiunge) e da dove copiare il pezzo che lo ricopre.
private func patchRect(_ r: EraseRegion, _ W: Int, _ H: Int) -> (x: Int, y: Int, w: Int, h: Int, srcY: Int)? {
    let th = r.h * Double(H), padX = max(16, 0.6 * th), padY = max(12, 0.5 * th), snap = 12.0
    var x0 = r.x * Double(W) - padX, x1 = (r.x + r.w) * Double(W) + padX, y0 = r.y * Double(H) - padY, y1 = (r.y + r.h) * Double(H) + padY
    if x0 < snap { x0 = 0 }; if y0 < snap { y0 = 0 }; if x1 > Double(W) - snap { x1 = Double(W) }; if y1 > Double(H) - snap { y1 = Double(H) }
    // bordi pari (serve alla crominanza 4:2:0); se il rettangolo arriva a un bordo dell'immagine ci arriva esattamente, altrimenti lì si sfumerebbe un pezzo di scritta
    let x = even(x0), y = even(y0), xe = x1 >= Double(W) ? W : min(W, (Int(x1.rounded(.up)) + 1) / 2 * 2), ye = y1 >= Double(H) ? H : min(H, (Int(y1.rounded(.up)) + 1) / 2 * 2)
    let w = xe - x, h = ye - y
    guard w > 0, h > 0 else { return nil }
    let above = y - h, below = y + h
    let preferAbove = Double(y) + Double(h) / 2 > Double(H) / 2
    if preferAbove, above >= 0 { return (x, y, w, h, above) }
    if below + h <= H { return (x, y, w, h, below) }
    if above >= 0 { return (x, y, w, h, above) }
    return nil
}

/// «Cancella» le scritte ricoprendole con un pezzo di immagine copiato da subito accanto (bordi sfumati), solo nel tratto in cui compaiono.
/// Si ricodifica soltanto il tratto dall'inizio del film al primo fotogramma chiave dopo la scritta; tutto il resto resta com'è (copia senza perdite).
/// Restituisce il file nuovo (un mkv in `work`) oppure il motivo del fallimento.
func eraseTextInVideo(source: URL, probe pr: Probe, regions: [EraseRegion], work: URL, progress: @escaping (Double, String) -> Void, lines: inout [String]) -> (url: URL?, why: String?) {
    guard let mm = tool("mkvmerge") else { return (nil, "Per cancellare una scritta serve MKVToolNix (mkvmerge): installalo con «brew install mkvtoolnix».") }
    guard let ff = tool("ffmpeg"), let fp = tool("ffprobe"), let v = pr.video else { return (nil, "ffmpeg non trovato o file illeggibile.") }
    let codec = (v["codec_name"] as? String) ?? "", pix = (v["pix_fmt"] as? String) ?? ""
    guard ["hevc", "h264"].contains(codec), ["yuv420p", "yuv420p10le"].contains(pix) else { return (nil, "Il formato dell'immagine (\(codec) \(pix)) non è ancora supportato per cancellare una scritta.") }
    let W = Int(dbl(v["width"]) ?? 0), H = Int(dbl(v["height"]) ?? 0); guard W > 0, H > 0 else { return (nil, "Non riesco a leggere le dimensioni dell'immagine.") }
    guard regions.allSatisfy({ $0.from < 150 }) else { return (nil, "Per ora si cancellano solo scritte che compaiono nei primi minuti del film.") }
    // fine del tratto da ricodificare: il primo fotogramma chiave dopo la fine delle scritte
    progress(0.02, "Ricerca del punto di taglio…")
    let pt = packetTimes(fp, source.path, "v:0"), keys = pt.keys, last = regions.map(\.to).max() ?? 0
    guard let kE = keys.first(where: { $0 >= last + 0.3 }) else { return (nil, "Non trovo un fotogramma chiave dopo la scritta.") }
    guard kE <= 150 else { return (nil, String(format: "Il tratto da ricodificare sarebbe troppo lungo (%.0f s): i fotogrammi chiave sono troppo distanti.", kE)) }
    let k2 = keys.first(where: { $0 > kE + 0.5 })                     // il fotogramma chiave successivo: da lì in poi il film resta com'è
    let nHead = pt.pts.filter { $0 < kE - 0.0005 }.count              // fotogrammi da ricodificare (tutti quelli che si vedono prima di kE)
    let isDV = ((v["side_data_list"] as? [[String: Any]]) ?? []).contains { ($0["side_data_type"] as? String ?? "").contains("DOVI") }
    let es = codec == "hevc" ? "hevc" : "h264"
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let sp = work.appendingPathComponent("p.mkv"), h = work.appendingPathComponent("head." + es), a1 = work.appendingPathComponent("a." + es), b1 = work.appendingPathComponent("b." + es), all = work.appendingPathComponent("video." + es), out = work.appendingPathComponent("out.mkv")
    guard let sj = try? JSONSerialization.jsonObject(with: run(mm, ["-J", source.path]).out) as? [String: Any], let st = (sj["tracks"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "video" }), let vid = st["id"] as? Int else { return (nil, "Non riesco a leggere le tracce del film.") }
    let src = (st["properties"] as? [String: Any]) ?? [:]
    if isDV && !((run(ff, ["-hide_banner", "-bsfs"]).text).contains("dovi_rpu")) { return (nil, "L'ffmpeg in uso non sa togliere i dati Dolby Vision (filtro dovi_rpu).") }

    // 1) dal film si estrae solo il video, diviso al fotogramma chiave kE (e al successivo), senza ricodificare
    progress(0.05, "Divisione del video…")
    var spArgs = ["-o", sp.path, "--video-tracks", "\(vid)", "--no-audio", "--no-subtitles", "--no-chapters", "--no-attachments", "--no-global-tags", "--split", "timestamps:" + clock(kE) + (k2.map { "," + clock($0) } ?? ""), source.path]
    let so = run(mm, spArgs); spArgs = []
    let p2 = work.appendingPathComponent("p-002.mkv"), p3 = work.appendingPathComponent("p-003.mkv"), p1f = work.appendingPathComponent("p-001.mkv")
    guard so.status <= 1, FileManager.default.fileExists(atPath: p2.path) else { return (nil, "mkvmerge non è riuscito a dividere il video: \(String(so.text.suffix(160)))") }
    try? FileManager.default.removeItem(at: p1f)

    // 2) i primi fotogrammi (fino a kE, compresi quelli «di testa» del fotogramma chiave) si ricodificano con la scritta ricoperta
    var chain = "[0:v:0]", g: [String] = []
    for (i, r) in regions.enumerated() {
        guard let pr_ = patchRect(r, W, H) else { return (nil, "Non c'è abbastanza immagine intorno alla scritta «\(r.label)» per ricoprirla.") }
        let ramp = max(8, W / 160), big = 100000
        let l = pr_.x > 0 ? 0 : big, rr = pr_.x + pr_.w < W ? 0 : big, t = pr_.y > 0 ? 0 : big, b = pr_.y + pr_.h < H ? 0 : big   // i bordi dell'immagine non si sfumano
        let mask = "color=c=black:s=\(pr_.w)x\(pr_.h):d=1,format=gray,geq=lum='255*min(1\\,min(min(X+\(l)\\,\(pr_.w)-1-X+\(rr))\\,min(Y+\(t)\\,\(pr_.h)-1-Y+\(b)))/\(ramp))',format=\(pix == "yuv420p" ? "gray" : "gray10le")[m\(i)]"
        g.append("\(chain)split[a\(i)][b\(i)];[b\(i)]crop=\(pr_.w):\(pr_.h):\(pr_.x):\(pr_.srcY),format=\(pix)[c\(i)];\(mask);[c\(i)][m\(i)]alphamerge[cm\(i)];[a\(i)][cm\(i)]overlay=\(pr_.x):\(pr_.y):format=yuv420:enable='between(t,\(String(format: "%.3f", max(0, r.from))),\(String(format: "%.3f", r.to)))'[o\(i)]")
        chain = "[o\(i)]"
        lines.append(String(format: "Scritta «%@»: coperta nell'immagine da %@ a %@ (zona %d×%d px a x %d, y %d; pezzo copiato da y %d)", r.label, hms(r.from), hms(r.to), pr_.w, pr_.h, pr_.x, pr_.y, pr_.srcY))
    }
    g.append("\(chain)format=\(pix)[out]")
    var enc: [String] = []
    func tag(_ k: String) -> String? { (v[k] as? String).flatMap { $0 == "unknown" ? nil : $0 } }
    var colorArgs: [String] = []
    if let x = tag("color_primaries") { colorArgs += ["-color_primaries", x] }; if let x = tag("color_transfer") { colorArgs += ["-color_trc", x] }
    if let x = tag("color_space") { colorArgs += ["-colorspace", x] }; if let x = tag("color_range") { colorArgs += ["-color_range", x] }
    if codec == "hevc" {
        var xp = ["log-level=error", "open-gop=0", "keyint=250", "repeat-headers=1", "aud=1"]
        if let x = tag("color_primaries") { xp.append("colorprim=\(x)") }; if let x = tag("color_transfer") { xp.append("transfer=\(x)") }; if let x = tag("color_space") { xp.append("colormatrix=\(x)") }
        if let cl = ["left": 0, "center": 1, "topleft": 2, "top": 3, "bottomleft": 4, "bottom": 5][(v["chroma_location"] as? String) ?? ""] { xp.append("chromaloc=\(cl)") }   // come l'originale: se cambia, il lettore si riconfigura alla giunzione
        for sd in (v["side_data_list"] as? [[String: Any]]) ?? [] {   // metadati HDR10 (display di masterizzazione e luminosità massima)
            func n(_ k: String, _ unit: Double) -> Int { Int(((ratio(sd[k]) ?? 0) * unit).rounded()) }
            switch sd["side_data_type"] as? String ?? "" {
            case "Mastering display metadata": xp.append("master-display=G(\(n("green_x", 50000)),\(n("green_y", 50000)))B(\(n("blue_x", 50000)),\(n("blue_y", 50000)))R(\(n("red_x", 50000)),\(n("red_y", 50000)))WP(\(n("white_point_x", 50000)),\(n("white_point_y", 50000)))L(\(n("max_luminance", 10000)),\(n("min_luminance", 10000)))"); xp.append("hdr10-opt=1")
            case "Content light level metadata": xp.append("max-cll=\(Int(dbl(sd["max_content"]) ?? 0)),\(Int(dbl(sd["max_average"]) ?? 0))")
            default: break }
        }
        enc = ["-c:v", "libx265", "-preset", "medium", "-crf", "12", "-pix_fmt", pix, "-x265-params", xp.joined(separator: ":")] + colorArgs
    } else { enc = ["-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", pix, "-x264-params", "aud=1" + ([("left", 0), ("center", 1), ("topleft", 2), ("top", 3), ("bottomleft", 4), ("bottom", 5)].first { $0.0 == (v["chroma_location"] as? String) }.map { ":chromaloc=\($0.1)" } ?? "")] + colorArgs }
    progress(0.1, "Ricodifica dei primi secondi…")
    var errs: [String] = []
    let eo = run(ff, ["-nostdin", "-y", "-v", "error", "-progress", "pipe:2", "-nostats", "-i", source.path, "-frames:v", "\(nHead)", "-an", "-sn", "-filter_complex", g.joined(separator: ";"), "-map", "[out]", "-fps_mode", "passthrough"] + enc + ["-f", es, h.path]) { l in
        if let m = l.match(#"out_time_us=(\d+)"#), let us = Double(m[1]) { progress(0.1 + 0.4 * min(1, us / 1e6 / kE), "Ricodifica dei primi secondi…") } else if !l.contains("=") && !l.isEmpty { errs.append(l) }
    }
    guard eo.status == 0, FileManager.default.fileExists(atPath: h.path) else { return (nil, "ffmpeg non è riuscito a ricodificare il tratto: \(errs.suffix(2).joined(separator: " "))") }
    lines.append(String(format: "Ricodificati solo i primi %.1f s (%@ CRF 12); il resto del film è copiato senza perdite", kE, codec == "hevc" ? "x265" : "x264"))

    // 3) il resto del video: nel primo tratto si tolgono i fotogrammi «di testa» del fotogramma chiave (non decodificabili senza quelli che lo precedevano; sono già nel tratto ricodificato);
    //    in tutto il resto si tolgono i dati Dolby Vision, che mancherebbero nel tratto ricodificato (cambiare formato a metà film fa scattare i lettori)
    progress(0.55, "Preparazione del resto del video…")
    func toES(_ i: URL, _ o: URL, _ bsf: String?) -> Bool { run(ff, ["-nostdin", "-y", "-v", "error", "-i", i.path, "-map", "0:v:0", "-c", "copy"] + (bsf.map { ["-bsf:v", $0] } ?? []) + ["-f", es, o.path]).status == 0 }
    let bsfA = [codec == "hevc" ? "filter_units=remove_types=8|9" : nil, isDV ? "dovi_rpu=strip=1" : nil].compactMap { $0 }.joined(separator: ",")
    guard toES(p2, a1, bsfA.isEmpty ? nil : bsfA) else { return (nil, "ffmpeg non è riuscito a preparare il resto del video.") }
    try? FileManager.default.removeItem(at: p2)
    var parts = [h, a1]
    if k2 != nil { guard FileManager.default.fileExists(atPath: p3.path), toES(p3, b1, isDV ? "dovi_rpu=strip=1" : nil) else { return (nil, "ffmpeg non è riuscito a preparare il resto del video.") }; try? FileManager.default.removeItem(at: p3); parts.append(b1) }
    if isDV { lines.append("Dolby Vision: tolto dal video (resta l'HDR10 di base), perché il tratto ricodificato non può contenerlo") }
    // un marcatore di «fine sequenza» tra i due tratti: dice ai lettori che da lì comincia un nuovo flusso (parametri diversi, nessun riferimento ai fotogrammi precedenti)
    if codec == "hevc" { let eos = work.appendingPathComponent("eos.bin"); try? Data([0, 0, 0, 1, 0x48, 0x01]).write(to: eos); parts.insert(eos, at: 1) }
    guard run("/bin/sh", ["-c", "o=\"$1\"; shift; cat \"$@\" > \"$o\"", "sh", all.path] + parts.map(\.path)).status == 0 else { return (nil, "Non riesco a riunire i tratti del video.") }
    for f in parts { try? FileManager.default.removeItem(at: f) }

    // 4) il nuovo video sostituisce quello del film; audio, sottotitoli, capitoli e tutto il resto vengono dal film originale, senza toccarli
    progress(0.8, "Creazione del film nuovo…")
    var ma = ["-o", out.path]
    if let t = tags(["tags": pr.fmt["tags"] as Any])["title"] { ma += ["--title", t] }
    ma += ["--language", "0:\((src["language"] as? String) ?? "und")", "--default-track-flag", "0:\((src["default_track"] as? Bool ?? true) ? "yes" : "no")"]
    if let n = src["track_name"] as? String { ma += ["--track-name", "0:\(n)"] }
    let fr = (v["r_frame_rate"] as? String) ?? "24000/1001"
    ma += ["--default-duration", "0:\(fr)p", all.path, "--video-tracks", "!\(vid)", source.path]
    let mo = run(mm, ma)
    guard mo.status <= 1, FileManager.default.fileExists(atPath: out.path) else { return (nil, "mkvmerge non è riuscito a creare il film: \(String(mo.text.suffix(200)))") }
    try? FileManager.default.removeItem(at: all)

    // 4) controlli prima di consegnare: stesse tracce, stessa durata (± un fotogramma), scritta davvero sparita
    progress(0.85, "Verifica del nuovo file…")
    guard let np = Probe(out.path) else { return (nil, "Il nuovo file non è leggibile.") }
    if np.audio.count != pr.audio.count || np.subs.count != pr.subs.count || np.of("video").count != pr.of("video").count { return (nil, "Il nuovo file ha un numero di tracce diverso dall'originale.") }
    if abs(np.duration - pr.duration) > 1.0 { return (nil, String(format: "Durata del nuovo file %@ diversa dall'originale %@.", hms(np.duration), hms(pr.duration))) }
    if (np.video?["codec_name"] as? String) != codec { return (nil, "Il codec del video è cambiato.") }
    // la giunzione deve decodificarsi senza errori (è lì che il primo tentativo faceva scattare i lettori)
    let jd = run(ff, ["-nostdin", "-v", "error", "-ss", String(max(0, kE - 2)), "-i", out.path, "-t", "4", "-map", "0:v:0", "-f", "null", "-"])
    if jd.err.contains("Could not find ref") || jd.err.contains("Error constructing") || jd.err.contains("Invalid") { return (nil, "Il punto di unione fra il tratto ricodificato e il resto non si decodifica bene (\(String(jd.err.split(separator: "\n").first ?? ""))).") }
    for r in regions {
        for f in [0.25, 0.5, 0.75] {
            let t = r.from + (r.to - r.from) * f, jpg = work.appendingPathComponent("chk.jpg"); try? FileManager.default.removeItem(at: jpg)
            run(ff, ["-nostdin", "-v", "error", "-y", "-ss", String(t), "-i", out.path, "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=1280:-2", "-q:v", "3", jpg.path])
            if FileManager.default.fileExists(atPath: jpg.path), let hit = creditHits(in: jpg, t: t) { return (nil, "La scritta è ancora visibile a \(hms(t)) («\(hit.boxes.first?.0 ?? hit.text)»).") }
        }
    }
    lines.append("Controllo: nessuna scritta riconosciuta nell'immagine dopo la correzione")
    progress(0.95, "Fatto")
    return (out, nil)
}
