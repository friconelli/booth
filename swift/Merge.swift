import Foundation
import Accelerate

// MARK: le due copie del film
/// Una traccia audio o di sottotitoli di uno dei due file. src 0 = primo file (A), 1 = secondo (B); ord = posizione all'interno del proprio tipo.
struct MergeTrack: Identifiable, Hashable {
    var src: Int; var kind: String; var ord: Int   // kind: "a" audio, "s" sottotitoli
    var lang: String; var title: String; var codec: String; var profile: String; var channels: Int; var bitrate: Double; var forced: Bool; var image: Bool; var isDefault: Bool; var sampleRate: Int
    var id: String { "\(src == 0 ? "A" : "B")\(kind)\(ord)" }
    /// La lingua dichiarata o, se manca, quella scritta nel titolo della traccia («Ita Mp3», «English»…).
    var effLang: String {
        if !lang.isEmpty { return lang == "it" ? "ita" : lang }
        let guesses: [(String, String)] = [(#"\bita(liano|lian)?\b"#, "ita"), (#"\beng(lish)?\b"#, "eng"), (#"\b(ger|deu|deutsch|german)\b"#, "ger"), (#"\b(fre|fra|fran[cç]ais|french)\b"#, "fre"), (#"\b(spa|esp|espa[nñ]ol|spanish)\b"#, "spa"), (#"\b(rus|russian)\b"#, "rus")]
        return guesses.first { title.has($0.0) }?.1 ?? ""
    }
    var isItalian: Bool { effLang == "ita" }
    var codecLabel: String {
        let c = codec.uppercased(); let p = profile.isEmpty || profile == "unknown" ? "" : " (\(profile))"
        switch codec { case "ac3": return "Dolby Digital"; case "eac3": return "Dolby Digital Plus"; case "truehd": return "Dolby TrueHD"; case "dts": return "DTS" + p; case "subrip": return "SRT"; case "hdmv_pgs_subtitle": return "PGS"; case "ass": return "ASS"; default: return c }
    }
    var channelLabel: String { switch channels { case 1: return "mono"; case 2: return "stereo"; case 6: return "5.1"; case 8: return "7.1"; case 0: return ""; default: return "\(channels) canali" } }
}
func mergeTracks(_ pr: Probe, src: Int) -> [MergeTrack] {
    func t(_ s: [String: Any], _ kind: String, _ i: Int) -> MergeTrack {
        let tg = tags(s), codec = (s["codec_name"] as? String) ?? "?"
        return MergeTrack(src: src, kind: kind, ord: i, lang: lang(s), title: tg["title"] ?? "", codec: codec, profile: (s["profile"] as? String) ?? "", channels: Int(dbl(s["channels"]) ?? 0),
                          bitrate: dbl(s["bit_rate"]) ?? dbl(tg["bps"]) ?? dbl(tg["bps-eng"]) ?? 0, forced: disp(s, "forced") == 1, image: imageSubs.contains(codec), isDefault: disp(s, "default") == 1, sampleRate: Int(dbl(s["sample_rate"]) ?? 48000))
    }
    return pr.audio.enumerated().map { t($1, "a", $0) } + pr.subs.enumerated().map { t($1, "s", $0) }
}

/// Qualità dell'immagine di una copia: prima la risoluzione, poi il bitrate effettivo (tenendo conto dell'efficienza del codec); penalità per Dolby Vision 5 e interlacciamento.
struct VideoInfo {
    var w = 0, h = 0, bits = 8; var codec = "", hdr = ""; var fps = 0.0, bitrate = 0.0, duration = 0.0, size = 0.0, score = 0.0; var dv5 = false, interlaced = false
    var summary: String {
        var s = "\(w)×\(h) · \(codec.uppercased())"; if bits > 8 { s += " \(bits) bit" }; if !hdr.isEmpty { s += " · \(hdr)" }
        if fps > 0 { s += String(format: " · %.3g fps", fps) }; if bitrate > 0 { s += " · " + fmtRate(bitrate) }; return s
    }
    var notes: [String] {
        var n: [String] = []
        if dv5 { n.append("Dolby Vision profilo 5: senza un lettore Dolby Vision i colori escono sbagliati") }
        if interlaced { n.append("Video interlacciato") }
        if !hdr.isEmpty && !dv5 { n.append("HDR: su un proiettore SDR va convertito (Booth lo fa dopo l'unione)") }
        return n
    }
}
func videoInfo(_ pr: Probe) -> VideoInfo? {
    guard let v = pr.video else { return nil }
    var i = VideoInfo(); let tg = tags(v)
    i.w = Int(dbl(v["width"]) ?? 0); i.h = Int(dbl(v["height"]) ?? 0); i.codec = (v["codec_name"] as? String) ?? "?"; i.duration = pr.duration; i.size = pr.size
    i.fps = ratio(v["r_frame_rate"]) ?? ratio(v["avg_frame_rate"]) ?? 0; if i.fps > 200 { i.fps = ratio(v["avg_frame_rate"]) ?? 0 }
    i.bits = Int(dbl(v["bits_per_raw_sample"]) ?? 0); if i.bits == 0 { i.bits = ((v["pix_fmt"] as? String) ?? "").contains("10") ? 10 : 8 }
    let trc = (v["color_transfer"] as? String) ?? ""; i.hdr = trc == "smpte2084" ? "HDR10" : trc == "arib-std-b67" ? "HLG" : ""
    let sd = (v["side_data_list"] as? [[String: Any]]) ?? []
    if let dv = sd.first(where: { ($0["side_data_type"] as? String ?? "").contains("DOVI") }) { let p = Int(dbl(dv["dv_profile"]) ?? 0); i.hdr = "Dolby Vision \(p)"; i.dv5 = p == 5 }
    i.interlaced = ["tt", "bb", "tb", "bt"].contains((v["field_order"] as? String) ?? "")
    let audioBits = pr.audio.reduce(0.0) { $0 + (dbl($1["bit_rate"]) ?? dbl(tags($1)["bps"]) ?? dbl(tags($1)["bps-eng"]) ?? 0) }
    i.bitrate = dbl(v["bit_rate"]) ?? dbl(tg["bps"]) ?? dbl(tg["bps-eng"]) ?? (pr.duration > 0 ? max(0, pr.size * 8 / pr.duration - audioBits) : 0)
    let eff: [String: Double] = ["av1": 2.0, "hevc": 1.6, "vp9": 1.5, "h264": 1.0, "vc1": 0.8, "mpeg4": 0.6, "mpeg2video": 0.5, "msmpeg4v3": 0.5]
    let effective = i.bitrate * (eff[i.codec] ?? 0.7)
    var tier = Double(i.w >= 3000 ? 4 : i.w >= 1700 ? 3 : i.w >= 1100 ? 2 : 1)
    if tier > 1, i.fps > 0, effective / (Double(i.w * i.h) * i.fps) < 0.02 { tier -= 1 }   // risoluzione alta ma bitrate da fame: vale quanto quella sotto
    i.score = tier * 1000 + min(effective / 1e6, 80) * 5 + (i.bits > 8 ? 20 : 0) - (i.interlaced ? 400 : 0) - (i.dv5 ? 3000 : 0)
    return i
}
/// Punteggio di una traccia audio: prima i canali, poi il formato e il bitrate.
func audioScore(_ t: MergeTrack) -> Double {
    let rank: [String: Double] = ["truehd": 6, "flac": 5.5, "pcm_s16le": 5.5, "pcm_s24le": 5.5, "eac3": 4.5, "dts": 4.2, "ac3": 4, "aac": 3, "opus": 3, "vorbis": 2.5, "mp3": 2, "mp2": 1.5]
    return Double(min(t.channels, 8)) * 10 + (rank[t.codec] ?? 2) + (t.profile.contains("MA") ? 1.5 : 0) + min(t.bitrate, 3e6) / 1e6
}

struct MergeSource { var url: URL; var probe: Probe; var video: VideoInfo?; var tracks: [MergeTrack] }
func loadMergeSource(_ u: URL, src: Int) -> MergeSource? { guard let p = Probe(u.path) else { return nil }; return MergeSource(url: u, probe: p, video: videoInfo(p), tracks: mergeTracks(p, src: src)) }

/// La scelta proposta: l'immagine migliore, la traccia italiana migliore (a parità, quella che sta già con l'immagine: niente allineamento), i sottotitoli italiani del file con l'immagine.
func autoSelect(_ s: [MergeSource]) -> (video: Int, audio: [String], subs: [String], def: String?) {
    let video = (s[1].video?.score ?? -1e9) > (s[0].video?.score ?? -1e9) ? 1 : 0
    let ita = (s[0].tracks + s[1].tracks).filter { $0.kind == "a" && $0.isItalian }
    let best = ita.max { audioScore($0) + ($0.src == video ? 0.6 : 0) < audioScore($1) + ($1.src == video ? 0.6 : 0) }
    var subs = s[video].tracks.filter { $0.kind == "s" && $0.isItalian }
    if subs.isEmpty { subs = s[1 - video].tracks.filter { $0.kind == "s" && $0.isItalian } }
    return (video, best.map { [$0.id] } ?? [], subs.map(\.id), best?.id)
}

// MARK: allineamento dell'audio
let envRate = 100.0   // valori di inviluppo al secondo (10 ms)
/// Catena ffmpeg che cambia la velocità dell'audio di un fattore k (k < 1 rallenta), riportando anche il tono a quello giusto (come al cinema: il PAL a 25 fps accelera e alza il tono).
func speedChain(_ k: Double, sampleRate sr: Int) -> String {
    let r = Int((Double(sr) * k).rounded())
    return String(format: "asetrate=%d,aresample=%d,atempo=%.9f", r, sr, k * Double(sr) / Double(r))   // asetrate vuole un intero: il resto lo corregge atempo
}
/// «Quando parte qualcosa» nell'audio: crescita del volume (in log) ogni 10 ms. Non dipende dalla lingua né dal livello: le musiche e gli effetti sono gli stessi nelle due copie.
/// `start` e `len` sono nel tempo della copia dopo la correzione di velocità k (il file viene letto da start·k per len·k secondi).
func onsetEnvelope(_ path: String, track: Int, start: Double, len: Double, k: Double = 1, sampleRate: Int = 48000) -> [Float] {
    guard let ff = tool("ffmpeg") else { return [] }
    let s = max(0, start), pad = Int(((s - start) * envRate).rounded())
    let af = "aresample=async=1:first_pts=0," + (abs(k - 1) > 1e-7 ? speedChain(k, sampleRate: sampleRate) + "," : "") + "aresample=8000"   // async: i buchi nei tempi del file restano buchi, come in un lettore
    let o = run(ff, ["-nostdin", "-v", "error", "-ss", String(format: "%.4f", s * k), "-t", String(format: "%.4f", (len - (s - start)) * k), "-i", path, "-map", "0:a:\(track)", "-vn", "-af", af, "-ac", "1", "-f", "s16le", "-acodec", "pcm_s16le", "-"])
    var env = [Float](repeating: 0, count: max(0, pad)); var prev: Float?
    let frame = 80, n = o.out.count / 2
    o.out.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        for f in 0..<(n / frame) {
            var e: Float = 0; for i in 0..<frame { let x = Float(p[f * frame + i]); e += x * x }
            let l = log10(e / Float(frame) + 1); env.append(prev.map { max(0, l - $0) } ?? 0); prev = l
        }
    }
    return env
}
/// Dove `ref` si trova dentro `hay`: correlazione normalizzata per ogni spostamento. Restituisce lo spostamento (frazionario, in campioni), la correlazione e
/// quanto il picco migliore supera il secondo (lontano almeno mezzo secondo): un picco netto vuol dire una corrispondenza sicura.
func bestLag(_ ref: [Float], _ hay: [Float]) -> (lag: Double, corr: Double, ratio: Double)? {
    let m = ref.count, n = hay.count; guard m > 300, n >= m else { return nil }
    var r = ref, mean: Float = 0; vDSP_meanv(r, 1, &mean, vDSP_Length(m)); var neg = -mean; vDSP_vsadd(r, 1, &neg, &r, 1, vDSP_Length(m))
    var rn: Float = 0; vDSP_svesq(r, 1, &rn, vDSP_Length(m)); guard rn > 0 else { return nil }
    var h = hay, hm: Float = 0; vDSP_meanv(h, 1, &hm, vDSP_Length(n)); var hneg = -hm; vDSP_vsadd(h, 1, &hneg, &h, 1, vDSP_Length(n))
    var cum = [Double](repeating: 0, count: n + 1); for i in 0..<n { cum[i + 1] = cum[i] + Double(h[i] * h[i]) }
    let L = n - m + 1; var c = [Float](repeating: 0, count: L)
    h.withUnsafeBufferPointer { hp in r.withUnsafeBufferPointer { rp in
        for lag in 0..<L { var dot: Float = 0; vDSP_dotpr(hp.baseAddress! + lag, 1, rp.baseAddress!, 1, &dot, vDSP_Length(m)); let e = cum[lag + m] - cum[lag]; c[lag] = e > 1e-9 ? dot / Float((Double(rn) * e).squareRoot()) : 0 }
    } }
    var best = 0; for i in 1..<L where c[i] > c[best] { best = i }
    var second: Float = 0; for i in 0..<L where abs(i - best) > 50 && c[i] > second { second = c[i] }
    var frac = 0.0
    if best > 0 && best < L - 1 { let y0 = Double(c[best - 1]), y1 = Double(c[best]), y2 = Double(c[best + 1]), den = y0 - 2 * y1 + y2; if abs(den) > 1e-9 { frac = max(-0.5, min(0.5, 0.5 * (y0 - y2) / den)) } }
    return (Double(best) + frac, Double(c[best]), Double(c[best]) / Double(max(second, 1e-3)))
}
struct AlignPoint { var t: Double; var d: Double; var corr: Double; var ratio: Double; var good: Bool }
/// Scarto in un punto del film (letto dai file, per le verifiche): l'audio dell'altra copia (dopo la correzione di velocità) al tempo t+d corrisponde all'audio di riferimento al tempo t.
func measurePoint(ref: (String, Int), other: (String, Int, Int), k: Double, t: Double, guess: Double, search: Double, len: Double = 40) -> AlignPoint? {
    let r = onsetEnvelope(ref.0, track: ref.1, start: t, len: len)
    let hs = t + guess - search; let h = onsetEnvelope(other.0, track: other.1, start: hs, len: len + 2 * search, k: k, sampleRate: other.2)
    guard let b = bestLag(r, h) else { return nil }
    return AlignPoint(t: t, d: hs + b.lag / envRate - t, corr: b.corr, ratio: b.ratio, good: b.corr >= 0.2 && b.ratio >= 1.25)
}
/// Inviluppo di un'intera traccia, con una sola lettura del file.
func fullEnvelope(_ path: String, track: Int, k: Double = 1, sampleRate: Int = 48000, duration: Double, progress: @escaping (Double) -> Void = { _ in }) -> [Float] {
    guard let ff = tool("ffmpeg") else { return [] }
    let af = "aresample=async=1:first_pts=0," + (abs(k - 1) > 1e-7 ? speedChain(k, sampleRate: sampleRate) + "," : "") + "aresample=8000"
    let o = run(ff, ["-nostdin", "-v", "error", "-progress", "pipe:2", "-nostats", "-i", path, "-map", "0:a:\(track)", "-vn", "-af", af, "-ac", "1", "-f", "s16le", "-acodec", "pcm_s16le", "-"]) { l in
        if let m = l.match(#"out_time_us=(\d+)"#), let us = Double(m[1]), duration > 0 { progress(min(1, us / 1e6 / (duration / k))) } }
    var env: [Float] = []; env.reserveCapacity(o.out.count / 160); var prev: Float?
    let frame = 80, n = o.out.count / 2
    o.out.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        for f in 0..<(n / frame) { var e: Float = 0; for i in 0..<frame { let x = Float(p[f * frame + i]); e += x * x }; let l = log10(e / Float(frame) + 1); env.append(prev.map { max(0, l - $0) } ?? 0); prev = l }
    }
    return env
}
/// Scarto nel tratto [t, t+len] del riferimento cercandolo nell'altra copia tra guess−search e guess+search.
func lagSearch(_ ev: [Float], _ eo: [Float], t: Double, len: Double, guess: Double, search: Double) -> AlignPoint? {
    let i0 = Int((t * envRate).rounded()), m = Int(len * envRate); guard i0 >= 0, i0 + m <= ev.count else { return nil }
    let j0 = Int(((t + guess - search) * envRate).rounded()), hn = m + Int(2 * search * envRate)
    var hay = [Float](repeating: 0, count: hn)
    let lo = max(0, j0), hi = min(eo.count, j0 + hn); guard hi - lo > m / 2 else { return nil }
    for j in lo..<hi { hay[j - j0] = eo[j] }
    guard let b = bestLag(Array(ev[i0..<(i0 + m)]), hay) else { return nil }
    return AlignPoint(t: t, d: (Double(j0) + b.lag) / envRate - t, corr: b.corr, ratio: b.ratio, good: b.corr >= 0.2 && b.ratio >= 1.25)
}
/// Somiglianza dei due inviluppi in [t, t+len] con uno scarto fisso d (correlazione normalizzata).
func localCorr(_ ev: [Float], _ eo: [Float], t: Double, len: Double, d: Double) -> Double {
    let i0 = Int((t * envRate).rounded()), j0 = Int(((t + d) * envRate).rounded()), m = Int(len * envRate)
    guard i0 >= 0, j0 >= 0, i0 + m <= ev.count, j0 + m <= eo.count, m > 2 else { return 0 }
    var sa = 0.0, sb = 0.0; for i in 0..<m { sa += Double(ev[i0 + i]); sb += Double(eo[j0 + i]) }
    let ma = sa / Double(m), mb = sb / Double(m); var c = 0.0, va = 0.0, vb = 0.0
    for i in 0..<m { let a = Double(ev[i0 + i]) - ma, b = Double(eo[j0 + i]) - mb; c += a * b; va += a * a; vb += b * b }
    return va > 1e-9 && vb > 1e-9 ? c / (va * vb).squareRoot() : 0
}

/// Un tratto del film (tempo dell'immagine scelta): [start, end) prende l'audio dell'altra copia da start+d; d nil = silenzio (lì l'altra copia non ha quella scena).
struct MergeSegment { var start: Double; var end: Double; var d: Double? }
struct Alignment {
    var k = 1.0; var segments: [MergeSegment] = []; var points: [AlignPoint] = []; var refLabel = ""; var refOrd = 0; var speedLabel = ""; var spread = 0.0; var nudge = 0.0   // correzione a mano dall'anteprima (secondi; positivo = l'audio arriva prima)
    var d: Double { (segments.first { $0.d != nil }?.d ?? 0) + nudge }
    /// Le parti con la correzione a mano applicata.
    var effSegments: [MergeSegment] { segments.map { MergeSegment(start: $0.start, end: $0.end, d: $0.d.map { $0 + nudge }) } }
    var isConstant: Bool { segments.count == 1 }
    /// I punti in cui le due copie hanno un montaggio diverso.
    var differences: [String] {
        var out: [String] = []
        for (i, s) in segments.enumerated() where i > 0 {
            if s.d == nil { out.append(String(format: "a %@ alla copia dell'audio mancano %.1f s: lì l'audio resta in silenzio", hms(s.start), s.end - s.start)) }
            else if let pd = segments[..<i].last(where: { $0.d != nil })?.d, let d = s.d, d - pd > 0.05 { out.append(String(format: "a %@ la copia dell'audio ha %.1f s in più (una scena che qui non c'è): vengono saltati", hms(s.start), d - pd)) }
        }
        return out
    }
    var lines: [String] {
        var l: [String] = []
        if abs(k - 1) > 1e-6 { l.append("Velocità corretta: " + (speedLabel.isEmpty ? String(format: "fattore %.6f", k) : speedLabel) + " (anche il tono torna quello giusto)") }
        l.append(abs(d) < 0.0005 ? "Nessuno sfasamento all'inizio" : String(format: "All'inizio l'audio dell'altra copia è %@ di %.3f s: viene spostato", d > 0 ? "in ritardo" : "in anticipo", abs(d)))
        let diff = differences; if !diff.isEmpty { l.append("Montaggio diverso in \(diff.count) punt\(diff.count == 1 ? "o" : "i"):"); l += diff.map { "  – " + $0 } }
        let good = points.filter(\.good); if !good.isEmpty { l.append(String(format: "Allineamento controllato in %d tratti di tutto il film: scarto massimo dentro ogni parte %.0f ms", good.count, spread * 1000)) }
        if abs(nudge) > 0.0005 { l.append(String(format: "Correzione a mano dopo il controllo a vista: audio %@ di %.0f ms", nudge > 0 ? "anticipato" : "ritardato", abs(nudge) * 1000)) }
        l.append("Riferimento: \(refLabel)")
        return l
    }
}
enum AlignOutcome { case ok(Alignment), fail(String, [AlignPoint]) }

let knownSpeeds: [(Double, String)] = [(23.976 / 25, "25 → 23,976 fps"), (25 / 23.976, "23,976 → 25 fps"), (24 / 25, "25 → 24 fps"), (25 / 24, "24 → 25 fps"), (23.976 / 24, "24 → 23,976 fps"), (24 / 23.976, "23,976 → 24 fps"), (29.97 / 25, "25 → 29,97 fps"), (25 / 29.97, "29,97 → 25 fps")]

/// Divide il film in parti a scarto costante. Restituisce le parti, i punti misurati, lo scarto massimo dentro le parti e, se lo scarto cresce in modo regolare, la deriva da correggere.
func segmentAlignment(_ ev: [Float], _ eo: [Float], vDur: Double) -> (segments: [MergeSegment], points: [AlignPoint], spread: Double, drift: Double?, why: String?) {
    let step = 5.0, L = 20.0, tol = 0.08
    // punto di partenza: ricerca larga (fino a 5 minuti, per esempio loghi diversi in testa)
    var start: Double?
    for f in [0.3, 0.5, 0.15, 0.7, 0.85] { if let p = lagSearch(ev, eo, t: f * vDur, len: 40, guess: 0, search: 300), p.good { start = p.d; break } }
    guard var prev = start else { return ([], [], 0, nil, "Non trovo corrispondenze tra l'audio delle due copie: forse non sono lo stesso film.") }
    var pts: [AlignPoint] = []; var t = 0.0
    while t + L <= vDur {
        var p = lagSearch(ev, eo, t: t, len: L, guess: prev, search: 8)
        if p?.good != true, let w = lagSearch(ev, eo, t: t, len: L, guess: prev, search: 300), w.good { p = w }
        if let p = p { pts.append(p); if p.good { prev = p.d } }
        t += step
    }
    // parti: punti affidabili consecutivi con lo stesso scarto (almeno 3, cioè 10 s di film); i punti isolati diversi sono scartati
    var runs: [[AlignPoint]] = []
    for p in pts where p.good {
        if var last = runs.last, abs(p.d - last.map(\.d).sorted()[last.count / 2]) <= tol { last.append(p); runs[runs.count - 1] = last } else { runs.append([p]) }
    }
    runs = runs.filter { $0.count >= 3 }
    var merged: [[AlignPoint]] = []
    for r in runs { if let last = merged.last, abs(med(last) - med(r)) <= tol { merged[merged.count - 1] += r } else { merged.append(r) } }
    func med(_ r: [AlignPoint]) -> Double { let s = r.map(\.d).sorted(); return s[s.count / 2] }
    // conferme: i punti affidabili delle parti e quelli deboli (dialoghi in lingue diverse) che danno lo stesso scarto della parte in cui cadono, al centesimo di secondo
    func support(_ p: AlignPoint) -> Bool { merged.contains { r in (p.good && r.contains { $0.t == p.t }) || (p.t >= r.first!.t && p.t <= r.last!.t && abs(p.d - med(r)) <= 0.03) } }
    let confirmed = pts.filter(support).map(\.t), all = pts.count
    let holes = zip([0.0] + confirmed, confirmed + [vDur]).map { $1 - $0 }.max() ?? vDur
    guard !merged.isEmpty, Double(confirmed.count) >= 0.35 * Double(all), holes <= 600 else {
        return ([], pts, 0, nil, holes > 600 ? String(format: "Per %.0f minuti di fila non trovo corrispondenze sicure tra le due copie: non posso garantire la sincronia.", holes / 60) : "Le due copie non si somigliano abbastanza per allinearle con sicurezza (\(confirmed.count) tratti confermati su \(all)). Forse non sono lo stesso film.")
    }
    // deriva: nella parte più lunga lo scarto cresce col tempo → velocità non esatta
    if let longest = merged.max(by: { $0.count < $1.count }), longest.count >= 20 {
        let n = Double(longest.count), mt = longest.reduce(0) { $0 + $1.t } / n, md = longest.reduce(0) { $0 + $1.d } / n
        let b = longest.reduce(0) { $0 + ($1.t - mt) * ($1.d - md) } / max(1e-9, longest.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) })
        if abs(b) * vDur > 0.03 { return ([], pts, 0, b, nil) }
    }
    let spread = merged.map { r in let m = med(r); return r.map { abs($0.d - m) }.max() ?? 0 }.max() ?? 0
    // confini precisi tra una parte e la successiva (passo 0,1 s)
    var segs: [MergeSegment] = []; var segStart = 0.0
    for i in 0..<merged.count {
        let d1 = med(merged[i])
        guard i + 1 < merged.count else { segs.append(MergeSegment(start: segStart, end: vDur, d: d1)); break }
        let d2 = med(merged[i + 1]), lo = merged[i].last!.t, hi = merged[i + 1].first!.t + L, gap = max(0, d1 - d2)
        if d2 < d1 && eoPos(lo, d1) > eoPos(merged[i + 1].first!.t, d2) + 1 && gap > 600 { return ([], pts, 0, nil, "Le due copie hanno le scene in un ordine diverso: non si possono unire.") }
        var m1: [Double] = [], m2: [Double] = []; var x = lo
        while x < hi { m1.append(localCorr(ev, eo, t: x, len: 1, d: d1)); m2.append(localCorr(ev, eo, t: x, len: 1, d: d2)); x += 0.1 }
        let gn = Int((gap * 10).rounded()); var bestT = lo, bestC = Double.infinity
        let pre = m1.reduce(into: [0.0]) { $0.append($0.last! + (1 - $1)) }, post = m2.reversed().reduce(into: [0.0]) { $0.append($0.last! + (1 - $1)) }
        for c in 0...max(0, m1.count - gn) {   // c = indice del confine; [c, c+gn) silenzio se all'altra copia manca un pezzo
            let after = m2.count - min(m2.count, c + gn)
            let cost = pre[c] + post[after] + 0.5 * Double(min(gn, m1.count - c))
            if cost < bestC { bestC = cost; bestT = lo + Double(c) * 0.1 }
        }
        segs.append(MergeSegment(start: segStart, end: bestT, d: d1))
        if gap > 0.05 { segs.append(MergeSegment(start: bestT, end: bestT + gap, d: nil)); segStart = bestT + gap } else { segStart = bestT }
    }
    return (segs.filter { $0.end - $0.start > 0.01 }, pts.map { p in var q = p; q.good = support(p); return q }, spread, nil, nil)
    func eoPos(_ t: Double, _ d: Double) -> Double { t + d }
}

/// Allinea l'audio dell'altra copia (`o`) all'immagine della copia scelta (`v`): velocità (frame rate diversi), spostamento iniziale e, se le copie hanno un montaggio
/// diverso, i punti in cui saltare un pezzo o lasciare silenzio. Ogni parte viene controllata in tutto il film.
func alignAudio(v: MergeSource, o: MergeSource, oTrack: MergeTrack, progress: @escaping (Double, String) -> Void = { _, _ in }) -> AlignOutcome {
    guard let vi = v.video, vi.duration > 120 else { return .fail("Il film con l'immagine scelta è troppo corto o illeggibile.", []) }
    // 1) velocità: dai frame rate, altrimenti dalla durata se coincide con un rapporto noto
    var k = 1.0, speedLabel = ""
    if let ofps = o.video?.fps, vi.fps > 0, ofps > 0, abs(vi.fps / ofps - 1) > 0.001 { k = vi.fps / ofps; speedLabel = knownSpeeds.first { abs($0.0 - k) < 0.0005 }?.1 ?? String(format: "%.3f → %.3f fps", ofps, vi.fps) }
    else if o.probe.duration > 0 { let rd = o.probe.duration / vi.duration; if abs(rd - 1) > 0.01, let kn = knownSpeeds.first(where: { abs($0.0 - rd) < 0.0015 }) { k = kn.0; speedLabel = kn.1 + " (dalla durata)" } }
    // 2) traccia di riferimento nella copia con l'immagine: stessa lingua se c'è (corrispondenza più forte), poi la predefinita, poi le altre
    let vAudio = v.tracks.filter { $0.kind == "a" }
    guard !vAudio.isEmpty else { return .fail("Il film con l'immagine scelta non ha audio: non c'è niente con cui allineare l'altra traccia.", []) }
    let refs = Array((vAudio.filter { $0.effLang == oTrack.effLang && !$0.effLang.isEmpty } + vAudio.filter(\.isDefault) + vAudio).reduce(into: [MergeTrack]()) { if !$0.contains($1) { $0.append($1) } }.prefix(2))
    var eo = fullEnvelope(o.url.path, track: oTrack.ord, k: k, sampleRate: oTrack.sampleRate, duration: o.probe.duration) { progress(0.3 * $0, "Leggo l'audio dell'altra copia…") }
    var lastFail: AlignOutcome = .fail("Non trovo corrispondenze tra l'audio delle due copie.", [])
    for (ri, rt) in refs.enumerated() {
        let ev = fullEnvelope(v.url.path, track: rt.ord, duration: vi.duration) { progress(0.3 + 0.3 * (Double(ri) + $0) / Double(refs.count), "Leggo l'audio del film con l'immagine…") }
        progress(0.6 + 0.3 * Double(ri) / Double(refs.count), "Confronto le due copie in tutto il film…")
        var r = segmentAlignment(ev, eo, vDur: vi.duration)
        if let b = r.drift {   // p = t·(1+b) + a  →  la velocità giusta è k·(1+b)
            k *= (1 + b); speedLabel = (speedLabel.isEmpty ? "" : speedLabel + ", ") + String(format: "deriva corretta (%+.4f%%)", b * 100)
            eo = fullEnvelope(o.url.path, track: oTrack.ord, k: k, sampleRate: oTrack.sampleRate, duration: o.probe.duration) { progress(0.6 + 0.3 * $0, "Rileggo l'audio dell'altra copia con la velocità corretta…") }
            r = segmentAlignment(ev, eo, vDur: vi.duration)
        }
        if let why = r.why { lastFail = .fail(why, r.points); continue }
        if r.drift != nil { lastFail = .fail("La velocità delle due copie non torna nemmeno dopo la correzione: non unisco.", r.points); continue }
        progress(1, "Allineamento trovato")
        return .ok(Alignment(k: k, segments: r.segments, points: r.points, refLabel: "audio \(rt.ord + 1) del film con l'immagine (\(langLabel(rt.effLang)))", refOrd: rt.ord, speedLabel: speedLabel, spread: r.spread))
    }
    return lastFail
}

/// Ingressi e grafo ffmpeg che ricostruiscono l'audio `t` dell'altra copia sul tempo dell'immagine nel tratto [from, to): per ogni parte un pezzo letto dal punto
/// giusto (velocità corretta), silenzio dove all'altra copia manca la scena, dissolvenze di 8 ms alle giunzioni per evitare i clic. Usato sia per il film sia per l'anteprima.
func pieceGraph(_ O: MergeSource, _ t: MergeTrack, k: Double, segs: [MergeSegment], from: Double, to: Double, firstInput: Int, outLabel: String) -> (inputs: [String], graph: String) {
    let lay = (O.probe.audio[t.ord]["channel_layout"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (t.channels == 1 ? "mono" : t.channels == 6 ? "5.1" : "stereo")
    let fmt = "aformat=sample_fmts=fltp:sample_rates=\(t.sampleRate):channel_layouts=\(lay)"
    var inputs: [String] = [], chains: [String] = [], n = 0
    func silence(_ len: Double) { guard len >= 0.001 else { return }; inputs += ["-f", "lavfi", "-t", String(format: "%.4f", len), "-i", "anullsrc=r=\(t.sampleRate):cl=\(lay)"]; chains.append("[\(firstInput + n):a]\(fmt)[p\(n)]"); n += 1 }
    for sg in segs where sg.end > from && sg.start < to {
        let s0 = max(sg.start, from), s1 = min(sg.end, to); var len = s1 - s0
        guard len > 0.001 else { continue }
        guard let sd = sg.d else { silence(len); continue }
        var a = s0 + sd                                   // tempo nell'altra copia (dopo la correzione di velocità)
        if a < -0.001 { silence(min(len, -a)); len += a }   // l'altra copia comincia dopo: silenzio in testa
        a = max(0, a); if len <= 0.01 { continue }
        inputs += ["-ss", String(format: "%.4f", a * k), "-t", String(format: "%.4f", len * k), "-i", O.url.path]
        let sp = abs(k - 1) > 1e-6 ? speedChain(k, sampleRate: t.sampleRate) + "," : ""
        chains.append(String(format: "[%d:a:%d]aresample=async=1:first_pts=0,%@%@,afade=t=in:d=0.008,apad=whole_dur=%.4f,atrim=end=%.4f,afade=t=out:st=%.4f:d=0.008[p%d]", firstInput + n, t.ord, sp, fmt, len, len, max(0, len - 0.008), n)); n += 1
    }
    if n == 0 { silence(max(0.1, to - from)) }
    return (inputs, chains.joined(separator: ";") + ";" + (0..<n).map { "[p\($0)]" }.joined() + "concat=n=\(n):v=0:a=1[\(outLabel)]")
}
/// Anteprima per il controllo a vista: `len` secondi dell'immagine scelta dal punto `at`, con l'audio predefinito già allineato come nel film finale.
func renderPreview(_ s: [MergeSource], _ plan: MergePlan, alignment: Alignment?, at: Double, len: Double = 15, out: URL) -> String? {
    guard let ff = tool("ffmpeg") else { return "ffmpeg non trovato." }
    let V = s[plan.video], O = s[1 - plan.video], all = s[0].tracks + s[1].tracks
    guard let aid = plan.defaultAudio ?? plan.audio.first, let at0 = all.first(where: { $0.id == aid }) else { return "Scegli una traccia audio." }
    let t0 = max(0, min(at, V.probe.duration - len)); try? FileManager.default.removeItem(at: out)
    var args = ["-nostdin", "-y", "-v", "error", "-ss", String(format: "%.3f", t0), "-t", String(format: "%.3f", len), "-i", V.url.path]
    if at0.src == plan.video { args += ["-map", "0:v:0", "-map", "0:a:\(at0.ord)"] }
    else {
        guard let a = alignment else { return "Prima serve l'allineamento." }
        let (inputs, graph) = pieceGraph(O, at0, k: a.k, segs: a.effSegments, from: t0, to: t0 + len, firstInput: 1, outLabel: "pa")
        args += inputs + ["-filter_complex", graph, "-map", "0:v:0", "-map", "[pa]"]
    }
    args += ["-vf", "scale=960:-2,setsar=1:1", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-shortest", out.path]
    let r = run(ff, args)
    return r.status == 0 && FileManager.default.fileExists(atPath: out.path) ? nil : "Anteprima non riuscita: \(r.err.suffix(160))"
}

// MARK: unione
struct MergePlan { var video = 0; var audio: [String] = []; var subs: [String] = []; var defaultAudio: String?; var output: URL? }
func mergeOutputURL(_ v: URL) -> URL {
    let dir = v.deletingLastPathComponent(), base = titleBase(v) + " (unito)"
    var u = dir.appendingPathComponent(base + ".mkv"), n = 1
    while FileManager.default.fileExists(atPath: u.path) { n += 1; u = dir.appendingPathComponent("\(base) \(n).mkv") }
    return u
}
/// Identificativi delle tracce per mkvmerge, per tipo e nell'ordine del file (lo stesso ordine di ffprobe).
func mkvTrackIDs(_ path: String) -> [String: [Int]] {
    guard let mm = tool("mkvmerge") else { return [:] }
    let o = run(mm, ["-J", path]); guard let j = try? JSONSerialization.jsonObject(with: o.out) as? [String: Any] else { return [:] }
    var r: [String: [Int]] = [:]; for t in j["tracks"] as? [[String: Any]] ?? [] { if let ty = t["type"] as? String, let id = t["id"] as? Int { r[ty, default: []].append(id) } }
    return r
}
func needsAlignment(_ plan: MergePlan) -> Bool { (plan.audio + plan.subs).contains { ($0.hasPrefix("A") ? 0 : 1) != plan.video } }

/// Crea il film unito: immagine (e capitoli) dalla copia scelta, le tracce scelte da entrambe; quelle dell'altra copia spostate (e se serve rallentate o accelerate)
/// per coincidere con l'immagine. Nessuno dei due file viene toccato; il risultato viene verificato prima di essere salvato.
func runMerge(_ s: [MergeSource], _ plan: MergePlan, alignment: Alignment?, progress: @escaping (Double, String) -> Void) -> FixResult {
    guard let mm = tool("mkvmerge") else { return FixResult(ok: false, message: "Per unire i film serve MKVToolNix (mkvmerge): installalo con «brew install mkvtoolnix».") }
    guard let ff = tool("ffmpeg") else { return FixResult(ok: false, message: "ffmpeg non trovato.") }
    let V = s[plan.video], O = s[1 - plan.video], vi = plan.video
    let all = Dictionary(uniqueKeysWithValues: (s[0].tracks + s[1].tracks).map { ($0.id, $0) })
    let chosenA = plan.audio.compactMap { all[$0] }, chosenS = plan.subs.compactMap { all[$0] }
    guard !chosenA.isEmpty else { return FixResult(ok: false, message: "Scegli almeno una traccia audio.") }
    let fromO = (chosenA + chosenS).filter { $0.src != vi }
    if !fromO.isEmpty && alignment == nil { return FixResult(ok: false, message: "Le tracce dell'altra copia vanno prima allineate.") }
    let k = alignment?.k ?? 1, d = alignment?.d ?? 0, segs = alignment?.effSegments ?? [MergeSegment(start: 0, end: V.probe.duration, d: 0)]
    let reencode = abs(k - 1) > 1e-6 || segs.count > 1   // velocità diversa o montaggio diverso: le tracce dell'altra copia si ricostruiscono; altrimenti si copiano senza perdite
    if reencode, let bad = fromO.first(where: { $0.kind == "s" && $0.image }) { return FixResult(ok: false, message: "I sottotitoli \(bad.ord + 1) dell'altra copia sono a immagine (\(bad.codecLabel)): con una velocità o un montaggio diversi non si possono risincronizzare. Toglili dalla scelta o usa quelli di testo.") }
    let output = plan.output ?? mergeOutputURL(V.url), dir = output.deletingLastPathComponent()
    let need = V.probe.size + (O.probe.size * 0.3)
    if let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage, Double(free) < need + 2e8 { return FixResult(ok: false, message: "Spazio insufficiente: servono circa \(fmtBytes(need)) liberi.") }
    let work = dir.appendingPathComponent(".booth-merge-\(UUID().uuidString.prefix(8))"); try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let tmp = work.appendingPathComponent("unito.mkv")
    defer { try? FileManager.default.removeItem(at: work) }
    var lines: [String] = ["Immagine da «\(V.url.lastPathComponent)»: \(V.video?.summary ?? "")"]
    if let a = alignment, !fromO.isEmpty { lines += a.lines }

    // tracce dell'altra copia da ricostruire: l'audio si rimonta tratto per tratto sul tempo dell'immagine (velocità corretta, pezzi in più saltati, silenzio dove manca)
    // e si ricodifica in Dolby Digital; i sottotitoli di testo si risincronizzano battuta per battuta
    var prepared: [String: (URL, MergeTrack)] = [:]
    if reencode {
        for (i, t) in fromO.enumerated() {
            progress(0.02 + 0.5 * Double(i) / Double(fromO.count), t.kind == "a" ? "Ricostruisco l'audio \(t.ord + 1) dell'altra copia…" : "Risincronizzo i sottotitoli \(t.ord + 1)…")
            if t.kind == "a" {
                let out = work.appendingPathComponent("\(t.id).mka"); let ch = min(t.channels, 6), br = ch >= 6 ? "640k" : ch == 2 ? "384k" : "192k"
                let (inputs, graph) = pieceGraph(O, t, k: k, segs: segs, from: 0, to: V.probe.duration, firstInput: 0, outLabel: "out")
                let dur = V.probe.duration
                let r = run(ff, ["-nostdin", "-y", "-v", "error", "-progress", "pipe:2", "-nostats"] + inputs + ["-filter_complex", graph, "-map", "[out]", "-c:a", "ac3", "-b:a", br, "-ac", "\(ch)", out.path]) { l in
                    if let m = l.match(#"out_time_us=(\d+)"#), let us = Double(m[1]) { progress(0.02 + 0.5 * (Double(i) + min(1, us / 1e6 / dur)) / Double(fromO.count), "Ricostruisco l'audio \(t.ord + 1) dell'altra copia…") } }
                guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else { return FixResult(ok: false, message: "ffmpeg non è riuscito a preparare l'audio \(t.ord + 1): \(r.err.suffix(200))", lines: lines) }
                prepared[t.id] = (out, t)
                lines.append("Audio \(t.ord + 1) dell'altra copia (\(langLabel(t.effLang)), \(t.codecLabel) \(t.channelLabel)): ricostruito sul tempo dell'immagine e ricodificato in Dolby Digital \(ch >= 6 ? "5.1" : t.channelLabel) \(br)b/s" + (t.channels > 6 ? " (ridotto da \(t.channelLabel) a 5.1)" : ""))
            } else {
                let raw = work.appendingPathComponent("\(t.id)-raw.srt"); run(ff, ["-nostdin", "-y", "-v", "error", "-i", O.url.path, "-map", "0:s:\(t.ord)", "-f", "srt", raw.path])
                guard let txt = try? String(contentsOf: raw, encoding: .utf8) else { return FixResult(ok: false, message: "Non riesco a leggere i sottotitoli \(t.ord + 1) dell'altra copia.", lines: lines) }
                func ts(_ x: Double) -> String { let ms = Int((max(0, x) * 1000).rounded()); return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
                // ogni battuta va nella parte del film in cui cade; quelle delle scene che qui non ci sono vengono tolte
                let all = parseSRT(txt)
                let cues = all.compactMap { c -> Cue? in
                    let p = c.s / k; guard let sg = segs.first(where: { sg in sg.d.map { p - $0 >= sg.start - 0.5 && p - $0 < sg.end } ?? false }), let sd = sg.d else { return nil }
                    return Cue(s: max(sg.start, p - sd), e: min(sg.end, c.e / k - sd), t: c.t)
                }.filter { $0.e > $0.s }
                let out = work.appendingPathComponent("\(t.id).srt")
                try? cues.enumerated().map { "\($0 + 1)\n\(ts($1.s)) --> \(ts($1.e))\n\($1.t)\n" }.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
                prepared[t.id] = (out, t); lines.append("Sottotitoli \(t.ord + 1) dell'altra copia: risincronizzati (\(cues.count) battute" + (all.count > cues.count ? ", \(all.count - cues.count) tolte perché in scene assenti" : "") + ")" + (t.codec == "ass" ? ", senza gli stili ASS" : ""))
            }
        }
    }

    // mkvmerge: file 0 = copia con l'immagine, file 1 = altra copia (tracce prese così come sono, spostate con --sync), poi i file preparati
    let vIDs = mkvTrackIDs(V.url.path), oIDs = mkvTrackIDs(O.url.path)
    func mid(_ ids: [String: [Int]], _ t: MergeTrack) -> Int? { let l = ids[t.kind == "a" ? "audio" : "subtitles"] ?? []; return l.indices.contains(t.ord) ? l[t.ord] : nil }
    guard let vid = vIDs["video"]?.first else { return FixResult(ok: false, message: "mkvmerge non trova l'immagine in «\(V.url.lastPathComponent)».", lines: lines) }
    var args = ["--gui-mode", "-o", tmp.path, "--title", titleBase(output).replacingOccurrences(of: " (unito)", with: "")]
    var order: [(Int, Int, MergeTrack?)] = [(0, vid, nil)]   // (file, id mkvmerge, traccia)
    func flags(_ id: Int, _ t: MergeTrack) -> [String] {
        var f = ["--default-track-flag", "\(id):\(t.kind == "a" && t.id == plan.defaultAudio ? 1 : 0)"]
        if t.kind == "s" { f += ["--forced-display-flag", "\(id):\(t.forced ? 1 : 0)"] }
        if !t.effLang.isEmpty { f += ["--language", "\(id):\(t.effLang)"] }
        return f
    }
    // file 0
    let vA = chosenA.filter { $0.src == vi }, vS = chosenS.filter { $0.src == vi }
    var vArgs = ["--video-tracks", "\(vid)"]
    let vAid = vA.compactMap { mid(vIDs, $0) }, vSid = vS.compactMap { mid(vIDs, $0) }
    guard vAid.count == vA.count, vSid.count == vS.count else { return FixResult(ok: false, message: "mkvmerge vede le tracce di «\(V.url.lastPathComponent)» in modo diverso da ffprobe: non unisco.", lines: lines) }
    vArgs += vAid.isEmpty ? ["--no-audio"] : ["--audio-tracks", vAid.map(String.init).joined(separator: ",")]
    vArgs += vSid.isEmpty ? ["--no-subtitles"] : ["--subtitle-tracks", vSid.map(String.init).joined(separator: ",")]
    for (t, id) in zip(vA + vS, vAid + vSid) { vArgs += flags(id, t) }
    args += vArgs + [V.url.path]
    var fileIndex = 1; var fileOf: [String: (Int, Int)] = [:]   // id traccia → (file, id mkvmerge)
    for (t, id) in zip(vA + vS, vAid + vSid) { fileOf[t.id] = (0, id) }
    // file 1: tracce dell'altra copia senza cambio di velocità, spostate di −d
    let direct = fromO.filter { prepared[$0.id] == nil }
    if !direct.isEmpty {
        let oA = direct.filter { $0.kind == "a" }, oS = direct.filter { $0.kind == "s" }
        let oAid = oA.compactMap { mid(oIDs, $0) }, oSid = oS.compactMap { mid(oIDs, $0) }
        guard oAid.count == oA.count, oSid.count == oS.count else { return FixResult(ok: false, message: "mkvmerge vede le tracce di «\(O.url.lastPathComponent)» in modo diverso da ffprobe: non unisco.", lines: lines) }
        var oArgs = ["--no-video", "--no-chapters", "--no-attachments", "--no-global-tags", "--no-buttons"]
        oArgs += oAid.isEmpty ? ["--no-audio"] : ["--audio-tracks", oAid.map(String.init).joined(separator: ",")]
        oArgs += oSid.isEmpty ? ["--no-subtitles"] : ["--subtitle-tracks", oSid.map(String.init).joined(separator: ",")]
        let ms = Int((-d * 1000).rounded())
        for (t, id) in zip(oA + oS, oAid + oSid) { oArgs += flags(id, t); if ms != 0 { oArgs += ["--sync", "\(id):\(ms)"] }; fileOf[t.id] = (fileIndex, id) }
        args += oArgs + [O.url.path]; fileIndex += 1
        for t in oA { lines.append("Audio \(t.ord + 1) dell'altra copia (\(langLabel(t.effLang)), \(t.codecLabel) \(t.channelLabel)): copiato senza perdite" + (ms != 0 ? String(format: ", spostato di %+.3f s", -d) : "")) }
        for t in oS { lines.append("Sottotitoli \(t.ord + 1) dell'altra copia (\(langLabel(t.effLang))): copiati" + (ms != 0 ? String(format: ", spostati di %+.3f s", -d) : "")) }
    }
    // file preparati (una traccia ciascuno, id 0)
    for t in fromO where prepared[t.id] != nil {
        let (u, tr) = prepared[t.id]!
        var a = flags(0, tr); if !tr.title.isEmpty { a += ["--track-name", "0:\(tr.title)"] }
        if u.pathExtension == "srt" { a += ["--sub-charset", "0:UTF-8"] }
        args += a + [u.path]; fileOf[t.id] = (fileIndex, 0); fileIndex += 1
    }
    // ordine: immagine, audio nell'ordine scelto, sottotitoli nell'ordine scelto
    for id in plan.audio + plan.subs { if let f = fileOf[id] { order.append((f.0, f.1, all[id])) } }
    args += ["--track-order", order.map { "\($0.0):\($0.1)" }.joined(separator: ",")]

    progress(reencode ? 0.55 : 0.05, "Creo il film unito…")
    let base = reencode ? 0.55 : 0.05
    let o = run(mm, args) { l in if let m = l.match(#"#GUI#progress (\d+)%"#), let v = Double(m[1]) { progress(base + (0.8 - base) * v / 100, "Creo il film unito…") } }
    guard o.status <= 1, FileManager.default.fileExists(atPath: tmp.path) else { return FixResult(ok: false, message: "mkvmerge non è riuscito: \(String((o.text + o.err).suffix(240)))", lines: lines) }

    // verifica
    progress(0.82, "Verifico il film unito…")
    guard let np = Probe(tmp.path) else { return FixResult(ok: false, message: "Il film unito non è leggibile.", lines: lines) }
    if np.audio.count != chosenA.count || np.subs.count != chosenS.count || np.of("video").count != 1 { return FixResult(ok: false, message: "Il film unito ha un numero di tracce diverso dal previsto (audio \(np.audio.count)/\(chosenA.count), sottotitoli \(np.subs.count)/\(chosenS.count)).", lines: lines) }
    if abs(np.duration - V.probe.duration) > 2 { return FixResult(ok: false, message: String(format: "La durata del film unito (%@) è diversa da quella della copia con l'immagine (%@).", hms(np.duration), hms(V.probe.duration)), lines: lines) }
    // la sincronia si rimisura sul file finito: ogni traccia arrivata dall'altra copia contro l'audio di riferimento della copia con l'immagine
    if let a = alignment {
        // punti di controllo: 20%, 50%, 80% e, per ogni parte del film, inizio, centro e fine: ogni parte deve essere confermata, altrimenti il file non si salva
        let L = 20.0, vd = V.probe.duration
        func clamp(_ x: Double) -> Double { max(2, min(x, vd - L - 2)) }
        let parts = segs.filter { $0.d != nil && $0.end - $0.start >= L + 4 }
        let global = [0.2, 0.5, 0.8].map { clamp($0 * vd) }
        let perPart = parts.map { sg in [sg.start + 2, (sg.start + sg.end - L) / 2, sg.end - L - 2].map(clamp) }
        for (pos, id) in plan.audio.enumerated() where all[id]?.src != vi {
            progress(0.85 + 0.1 * Double(pos) / Double(plan.audio.count), "Verifico la sincronia dell'audio \(pos + 1)…")
            let sr = Int(dbl(np.audio[pos]["sample_rate"]) ?? 48000)
            func meas(_ ts: [Double]) -> [AlignPoint] { ts.compactMap { measurePoint(ref: (V.url.path, a.refOrd), other: (tmp.path, pos, sr), k: 1, t: $0, guess: 0, search: 3, len: L) }.filter(\.good) }
            var pts = meas(global)
            for (pi, ts) in perPart.enumerated() {
                let got = meas(ts); pts += got
                if got.isEmpty && parts.count > 1 { return FixResult(ok: false, message: "Non riesco a confermare la sincronia dell'audio \(pos + 1) nella parte \(hms(parts[pi].start))–\(hms(parts[pi].end)) del film unito: non lo salvo.", lines: lines) }
            }
            guard pts.count >= 2 else { return FixResult(ok: false, message: "Non riesco a verificare la sincronia dell'audio \(pos + 1) nel film unito: non lo salvo.", lines: lines) }
            // con una correzione a mano di n secondi, l'audio deve risultare spostato proprio di n rispetto al riferimento
            let worst = pts.max { abs($0.d + a.nudge) < abs($1.d + a.nudge) }!, err = abs(worst.d + a.nudge)
            if err > 0.045 { return FixResult(ok: false, message: String(format: "Nel film unito l'audio %d risulta sfasato di %.0f ms a %@: non lo salvo.", pos + 1, err * 1000, hms(worst.t)), lines: lines) }
            lines.append(String(format: "Sincronia dell'audio %d nel film unito: verificata in %d punti%@, scarto massimo %.0f ms", pos + 1, pts.count, parts.count > 1 ? " (tutte le \(parts.count) parti del film)" : "", err * 1000))
        }
    }
    func packetIssues(_ p: Probe, _ path: String) -> Int { let c = Collector(); scanPackets(p, path, c); return c.findings.filter { $0.sev >= .warn }.count }
    let before = packetIssues(V.probe, V.url.path) + (fromO.isEmpty ? 0 : packetIssues(O.probe, O.url.path)), after = packetIssues(np, tmp.path)
    if after > before { return FixResult(ok: false, message: "Il controllo dei flussi ha trovato \(after - before) problemi di audio/video nel film unito: non lo salvo.", lines: lines) }

    progress(0.97, "Salvataggio…")
    if FileManager.default.fileExists(atPath: output.path) { return FixResult(ok: false, message: "Esiste già «\(output.lastPathComponent)»: non lo sovrascrivo.", lines: lines) }
    do { try FileManager.default.moveItem(at: tmp, to: output) } catch { return FixResult(ok: false, message: "Salvataggio non riuscito: \(error.localizedDescription)", lines: lines) }
    let def = plan.defaultAudio.flatMap { all[$0] }
    if let t = def { lines.append("Audio predefinito: \(langLabel(t.effLang)) (\(t.codecLabel) \(t.channelLabel))") }
    progress(1, "Fatto")
    return FixResult(ok: true, message: "Creato «\(output.lastPathComponent)». I due file di partenza non sono stati toccati.", lines: lines, backup: nil, newURL: output)
}
