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
    let keys = packetTimes(fp, source.path, "v:0").keys, last = regions.map(\.to).max() ?? 0
    guard let kE = keys.first(where: { $0 >= last + 0.3 }) else { return (nil, "Non trovo un fotogramma chiave dopo la scritta.") }
    guard kE <= 150 else { return (nil, String(format: "Il tratto da ricodificare sarebbe troppo lungo (%.0f s): i fotogrammi chiave sono troppo distanti.", kE)) }
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let p = work.appendingPathComponent("p.mkv"), p1 = work.appendingPathComponent("p-001.mkv"), p2 = work.appendingPathComponent("p-002.mkv"), h = work.appendingPathComponent("h.mkv"), out = work.appendingPathComponent("out.mkv")

    // 1) il film viene diviso in due al fotogramma chiave (senza ricodificare): una testa e il resto
    progress(0.05, "Divisione del film…")
    let sp = run(mm, ["-o", p.path, "--split", "timestamps:" + clock(kE), source.path])
    guard sp.status <= 1, FileManager.default.fileExists(atPath: p1.path), FileManager.default.fileExists(atPath: p2.path) else { return (nil, "mkvmerge non è riuscito a dividere il film: \(String(sp.text.suffix(160)))") }

    // 2) la testa si ricodifica con la scritta ricoperta
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
        var xp = ["log-level=error", "open-gop=0", "keyint=250", "repeat-headers=1"]
        if let x = tag("color_primaries") { xp.append("colorprim=\(x)") }; if let x = tag("color_transfer") { xp.append("transfer=\(x)") }; if let x = tag("color_space") { xp.append("colormatrix=\(x)") }
        for sd in (v["side_data_list"] as? [[String: Any]]) ?? [] {   // metadati HDR10 (display di masterizzazione e luminosità massima)
            func n(_ k: String, _ unit: Double) -> Int { Int(((ratio(sd[k]) ?? 0) * unit).rounded()) }
            switch sd["side_data_type"] as? String ?? "" {
            case "Mastering display metadata": xp.append("master-display=G(\(n("green_x", 50000)),\(n("green_y", 50000)))B(\(n("blue_x", 50000)),\(n("blue_y", 50000)))R(\(n("red_x", 50000)),\(n("red_y", 50000)))WP(\(n("white_point_x", 50000)),\(n("white_point_y", 50000)))L(\(n("max_luminance", 10000)),\(n("min_luminance", 10000)))"); xp.append("hdr10-opt=1")
            case "Content light level metadata": xp.append("max-cll=\(Int(dbl(sd["max_content"]) ?? 0)),\(Int(dbl(sd["max_average"]) ?? 0))")
            default: break }
        }
        enc = ["-c:v", "libx265", "-preset", "medium", "-crf", "12", "-pix_fmt", pix, "-x265-params", xp.joined(separator: ":")] + colorArgs
    } else { enc = ["-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", pix] + colorArgs }
    progress(0.1, "Ricodifica dei primi secondi…")
    var errs: [String] = []
    let eo = run(ff, ["-nostdin", "-y", "-v", "error", "-progress", "pipe:2", "-nostats", "-i", p1.path, "-an", "-sn", "-filter_complex", g.joined(separator: ";"), "-map", "[out]", "-fps_mode", "passthrough"] + enc + [h.path]) { l in
        if let m = l.match(#"out_time_us=(\d+)"#), let us = Double(m[1]) { progress(0.1 + 0.6 * min(1, us / 1e6 / kE), "Ricodifica dei primi secondi…") } else if !l.contains("=") && !l.isEmpty { errs.append(l) }
    }
    guard eo.status == 0, FileManager.default.fileExists(atPath: h.path) else { return (nil, "ffmpeg non è riuscito a ricodificare il tratto: \(errs.suffix(2).joined(separator: " "))") }
    lines.append(String(format: "Ricodificati solo i primi %.1f s (%@ CRF 12); il resto del film è copiato senza perdite", kE, codec == "hevc" ? "x265" : "x264"))

    // 3) la testa ricodificata e il resto vengono riuniti, insieme a tutte le altre tracce
    progress(0.75, "Riunione del film…")
    guard let jd = try? JSONSerialization.jsonObject(with: run(mm, ["-J", p2.path]).out) as? [String: Any], let tr2 = jd["tracks"] as? [[String: Any]], let vt = tr2.first(where: { $0["type"] as? String == "video" }), let vid = vt["id"] as? Int else { return (nil, "Non riesco a leggere le tracce del film diviso.") }
    var src: [String: Any] = [:]
    if let sj = try? JSONSerialization.jsonObject(with: run(mm, ["-J", source.path]).out) as? [String: Any], let st = (sj["tracks"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "video" }) { src = (st["properties"] as? [String: Any]) ?? [:] }
    var a = ["-o", out.path]
    if let t = tags(["tags": pr.fmt["tags"] as Any])["title"] { a += ["--title", t] }
    a += ["--language", "0:\((src["language"] as? String) ?? "und")", "--default-track-flag", "0:\((src["default_track"] as? Bool ?? true) ? "yes" : "no")"]
    if let n = src["track_name"] as? String { a += ["--track-name", "0:\(n)"] }
    a += [h.path, "--video-tracks", "!\(vid)", p1.path, "+", p2.path, "--append-to", tr2.compactMap { $0["id"] as? Int }.map { $0 == vid ? "2:\($0):0:0" : "2:\($0):1:\($0)" }.joined(separator: ",")]
    let mo = run(mm, a)
    guard mo.status <= 1, FileManager.default.fileExists(atPath: out.path) else { return (nil, "mkvmerge non è riuscito a riunire il film: \(String(mo.text.suffix(200)))") }
    for f in [p1, p2, h] { try? FileManager.default.removeItem(at: f) }

    // 4) controlli prima di consegnare: stesse tracce, stessa durata (± un fotogramma), scritta davvero sparita
    progress(0.85, "Verifica del nuovo file…")
    guard let np = Probe(out.path) else { return (nil, "Il nuovo file non è leggibile.") }
    if np.audio.count != pr.audio.count || np.subs.count != pr.subs.count || np.of("video").count != pr.of("video").count { return (nil, "Il nuovo file ha un numero di tracce diverso dall'originale.") }
    if abs(np.duration - pr.duration) > 1.0 { return (nil, String(format: "Durata del nuovo file %@ diversa dall'originale %@.", hms(np.duration), hms(pr.duration))) }
    if (np.video?["codec_name"] as? String) != codec { return (nil, "Il codec del video è cambiato.") }
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
