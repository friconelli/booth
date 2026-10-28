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
    // il proiettore mostra al massimo 1920×1200: un 4K vale come un 1080p (il bitrate più alto conta lo stesso, sotto, perché ridotto a 1920 è più pulito)
    var tier = Double(i.w >= 1700 ? 3 : i.w >= 1100 ? 2 : 1)
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
struct MergeSegment { var start: Double; var end: Double; var d: Double?; var sure = true }   // sure: il confine d'inizio è stato trovato con certezza
struct Alignment {
    var k = 1.0; var segments: [MergeSegment] = []; var points: [AlignPoint] = []; var refLabel = ""; var refOrd = 0; var speedLabel = ""; var spread = 0.0; var auto: [Int: Double] = [:]; var nudges: [Int: Double] = [:]; var measOrd: Int? = nil; var notes: [String] = []; var dubAt: Set<Int> = []   // dubAt: parti all'inizio delle quali le immagini delle due copie sono uguali (lo scarto che cambia è del doppiaggio, non del montaggio); auto: correzione trovata dalla verifica del film unito; nudges: correzione a mano per parte (indice della parte → secondi dall'anteprima (secondi; positivo = l'audio arriva prima)
    var d: Double { (segments.first { $0.d != nil }?.d ?? 0) + (nudges[segments.firstIndex { $0.d != nil } ?? 0] ?? 0) }
    /// Indice della parte che contiene il tempo t (dell'immagine scelta).
    func part(at t: Double) -> Int { segments.lastIndex { $0.start <= t } ?? 0 }
    /// Correzione a mano valida al tempo t.
    func nudge(at t: Double) -> Double { nudges[part(at: t)] ?? 0 }
    /// Le parti con la correzione a mano applicata.
    var effSegments: [MergeSegment] { segments.enumerated().map { i, s in MergeSegment(start: s.start, end: s.end, d: s.d.map { $0 + (nudges[i] ?? 0) + (auto[i] ?? 0) }, sure: s.sure) } }
    var isConstant: Bool { segments.count == 1 }
    /// Tutti i cambi controllati sulle immagini sono del doppiaggio: le due copie hanno lo stesso montaggio.
    var onlyDub: Bool { !dubAt.isEmpty && segments.indices.dropFirst().allSatisfy { dubAt.contains($0) } }
    /// I punti in cui cambia lo scarto: montaggio diverso delle due copie, oppure doppiaggio dell'altra copia a gradini (se le immagini sono uguali).
    var differences: [String] {
        var out: [String] = []
        for (i, s) in segments.enumerated() where i > 0 {
            if dubAt.contains(i) {
                let pd = segments[..<i].last(where: { $0.d != nil })?.d
                if s.d == nil { out.append("a \(hms(s.start)) il doppiaggio dell'altra copia torna indietro di \(dur(s.end - s.start)): lì l'audio resta in silenzio") }
                else if segments[i - 1].d == nil && dubAt.contains(i - 1) { continue }
                else if let pd = pd, let d = s.d { out.append("a \(hms(s.start)) il doppiaggio dell'altra copia si sposta di \(dur(abs(d - pd))) \(d > pd ? "in avanti: vengono saltati" : "indietro: lì l'audio resta in silenzio")") }
                continue
            }
            if s.d == nil { out.append("a \(hms(s.start)) alla copia dell'audio mancano \(dur(s.end - s.start)): lì l'audio resta in silenzio") }
            else if let pd = segments[..<i].last(where: { $0.d != nil })?.d, let d = s.d, d - pd > 0.02 { out.append("a \(hms(s.start)) la copia dell'audio ha \(dur(d - pd)) in più: vengono saltati") }
        }
        return out
    }
    private func dur(_ x: Double) -> String { x >= 1 ? String(format: "%.1f s", x) : String(format: "%.0f ms", x * 1000) }
    /// I momenti da guardare prima di creare il file: tagli trovati con poca certezza, misure in disaccordo con la parte e lunghi tratti senza misure sicure.
    var risks: [RiskMoment] {
        var r: [RiskMoment] = []
        // un taglio incerto conta solo se lo spostamento supera un fotogramma: sotto, anche un punto sbagliato non si vede
        func jump(_ i: Int) -> Double { let pd = segments[..<i].last { $0.d != nil }?.d, nd = segments[i...].first { $0.d != nil }?.d; return segments[i].d == nil ? segments[i].end - segments[i].start : abs((nd ?? 0) - (pd ?? 0)) }
        for (i, s) in segments.enumerated() where i > 0 && !s.sure && jump(i) > 0.045 { r.append(RiskMoment(t: s.start, why: dubAt.contains(i) ? "Qui il doppiaggio cambia scarto, ma il punto esatto è incerto" : s.d == nil ? "Qui manca un pezzo all'altra copia, ma il punto esatto è incerto" : "Cambio di montaggio in un punto poco chiaro")) }
        for p in points where p.good {
            let a = part(at: p.t), b = part(at: p.t + 20)
            guard a == b, let d = segments[a].d, abs(p.d - d) > 0.045 else { continue }
            r.append(RiskMoment(t: p.t + 10, why: String(format: "Una misura qui dà uno scarto diverso di %.0f ms", abs(p.d - d) * 1000)))
        }
        let sure = points.filter(\.good).map(\.t)
        for (x, y) in zip(sure, sure.dropFirst()) where y - x > 120 { r.append(RiskMoment(t: (x + y) / 2, why: String(format: "Per %.0f minuti non ci sono misure sicure (dialoghi senza musica?)", (y - x) / 60))) }
        var out: [RiskMoment] = []
        for m in r.sorted(by: { $0.t < $1.t }) { if let l = out.last, m.t - l.t < 20 { continue }; out.append(m) }
        return out
    }
    var lines: [String] {
        var l: [String] = []
        if abs(k - 1) > 1e-6 { l.append("Velocità corretta: " + (speedLabel.isEmpty ? String(format: "fattore %.6f", k) : speedLabel) + " (anche il tono torna quello giusto)") }
        l.append(abs(d) < 0.0005 ? "Nessuno sfasamento all'inizio" : String(format: "All'inizio l'audio dell'altra copia è %@ di %.3f s: viene spostato", d > 0 ? "in ritardo" : "in anticipo", abs(d)))
        let diff = differences; if !diff.isEmpty { l.append((onlyDub ? "Doppiaggio a gradini, cambia scarto in \(diff.count) punt\(diff.count == 1 ? "o" : "i") (le immagini delle due copie sono uguali)" : dubAt.isEmpty ? "Montaggio diverso in \(diff.count) punt\(diff.count == 1 ? "o" : "i")" : "Lo scarto cambia in \(diff.count) punt\(diff.count == 1 ? "o" : "i")") + ":"); l += diff.map { "  – " + $0 } }
        let good = points.filter(\.good); if !good.isEmpty { l.append(String(format: "Allineamento controllato in %d tratti di tutto il film: scarto massimo dentro ogni parte %.0f ms", good.count, spread * 1000)) }
        for (i, n) in nudges.sorted(by: { $0.key < $1.key }) where abs(n) > 0.0005 && segments.indices.contains(i) { l.append(String(format: "Correzione a mano dopo il controllo a vista: audio %@ di %.0f ms %@", n > 0 ? "anticipato" : "ritardato", abs(n) * 1000, segments.count > 1 ? "da \(hms(segments[i].start)) a \(hms(segments[i].end))" : "in tutto il film")) }
        l.append("Riferimento: \(refLabel)"); l += notes
        return l
    }
}
struct RiskMoment: Hashable { var t: Double; var why: String }
enum AlignOutcome { case ok(Alignment), fail(String, [AlignPoint]) }

let knownSpeeds: [(Double, String)] = [(23.976 / 25, "25 → 23,976 fps"), (25 / 23.976, "23,976 → 25 fps"), (24 / 25, "25 → 24 fps"), (25 / 24, "24 → 25 fps"), (23.976 / 24, "24 → 23,976 fps"), (24 / 23.976, "23,976 → 24 fps"), (29.97 / 25, "25 → 29,97 fps"), (25 / 29.97, "29,97 → 25 fps")]

/// Divide il film in parti a scarto costante. Restituisce le parti, i punti misurati, lo scarto massimo dentro le parti e, se lo scarto cresce in modo regolare, la deriva da correggere.
func segmentAlignment(_ ev: [Float], _ eo: [Float], vDur: Double, maxSearch: Double = 300) -> (segments: [MergeSegment], points: [AlignPoint], spread: Double, drift: Double?, why: String?) {
    let step = 5.0, L = 20.0, tol = 0.03   // le misure sono precise al centesimo: anche i micro-tagli di 1-2 fotogrammi diventano parti
    // punto di partenza: ricerca larga (fino a 5 minuti, per esempio loghi diversi in testa)
    var start: Double?
    for f in [0.3, 0.5, 0.15, 0.7, 0.85] { if let p = lagSearch(ev, eo, t: f * vDur, len: 40, guess: 0, search: maxSearch), p.good { start = p.d; break } }
    guard var prev = start else { return ([], [], 0, nil, "Non trovo corrispondenze tra l'audio delle due copie: forse non sono lo stesso film.") }
    var pts: [AlignPoint] = []; var t = 0.0
    while t + L <= vDur {
        var p = lagSearch(ev, eo, t: t, len: L, guess: maxSearch < 8 ? 0 : prev, search: min(8, maxSearch))
        if maxSearch > 8, p?.good != true, let w = lagSearch(ev, eo, t: t, len: L, guess: prev, search: maxSearch), w.good { p = w }
        if let p = p { pts.append(p); if p.good { prev = p.d } }
        t += step
    }
    // misure deboli (somiglianza bassa, per esempio dialoghi in lingue diverse) che però coincidono al millesimo per almeno 3 tratti di fila: non è un caso, valgono come affidabili
    var i0 = 0
    while i0 < pts.count {
        var j = i0 + 1; while j < pts.count && abs(pts[j].d - pts[j - 1].d) < 0.005 && pts[j].t - pts[j - 1].t < step + 0.5 { j += 1 }
        if j - i0 >= 3 { for i in i0..<j where pts[i].corr >= 0.1 { pts[i].good = true } }
        i0 = j
    }
    // parti: punti affidabili consecutivi con lo stesso scarto (almeno 2: le misure sono precise al centesimo, due che coincidono non sono un caso); i punti isolati sono scartati
    var runs: [[AlignPoint]] = []
    for p in pts where p.good {
        if var last = runs.last, abs(p.d - last.map(\.d).sorted()[last.count / 2]) <= tol { last.append(p); runs[runs.count - 1] = last } else { runs.append([p]) }
    }
    runs = runs.filter { $0.count >= 2 }
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
    // deriva: lo scarto cresce in modo regolare in tutto il film → velocità non esatta. Si guarda la mediana ogni 5 minuti: una deriva vera è una retta
    // che spiega quasi tutta la variazione; i micro-tagli di montaggio invece fanno salire e scendere lo scarto e non vanno scambiati per una deriva
    var bt: [Double] = [], bd: [Double] = []
    for (_, g) in Dictionary(grouping: merged.flatMap { $0 }, by: { Int($0.t / 300) }) where g.count >= 5 { bt.append(g.map(\.t).reduce(0.0, +) / Double(g.count)); bd.append(med(g)) }
    if bt.count >= 6 {
        let n = Double(bt.count), mt: Double = bt.reduce(0.0, +) / n, md: Double = bd.reduce(0.0, +) / n
        var sxy = 0.0, sxx = 0.0; for i in bt.indices { sxy += (bt[i] - mt) * (bd[i] - md); sxx += (bt[i] - mt) * (bt[i] - mt) }
        let b = sxy / max(1e-9, sxx)
        var before = 0.0, after = 0.0; for i in bt.indices { let e = bd[i] - md; before += e * e; let r = e - b * (bt[i] - mt); after += r * r }
        if abs(b) * vDur > 0.06 && after < 0.2 * before { return ([], pts, 0, b, nil) }
    }
    for i in 1..<max(1, merged.count) {   // scene in ordine diverso (si tornerebbe indietro di oltre 10 minuti): non si può fare
        let d1 = med(merged[i - 1]), d2 = med(merged[i]); if d1 - d2 > 600 { return ([], pts, 0, nil, "Le due copie hanno le scene in un ordine diverso: non si possono unire.") }
    }
    // confini precisi tra una parte e la successiva (passo 0,1 s)
    var segs: [MergeSegment] = []; var segStart = 0.0; var pendingSure = true
    for i in 0..<merged.count {
        let d1 = med(merged[i])
        guard i + 1 < merged.count else { segs.append(MergeSegment(start: segStart, end: vDur, d: d1, sure: pendingSure)); break }
        let d2 = med(merged[i + 1]), lo = max(segStart + 0.1, merged[i].last!.t), hi = max(lo + 0.2, merged[i + 1].first!.t + L), gap = max(0, d1 - d2)
        var m1: [Double] = [], m2: [Double] = []; var x = lo
        while x < hi { m1.append(localCorr(ev, eo, t: x - 1, len: 2, d: d1)); m2.append(localCorr(ev, eo, t: x - 1, len: 2, d: d2)); x += 0.1 }   // finestre di 2 s: in un passaggio sommesso 1 s non basta
        let gn = Int((gap * 10).rounded()); var bestT = lo, bestC = Double.infinity, bestI = 0
        let pre = m1.reduce(into: [0.0]) { $0.append($0.last! + (1 - $1)) }, post = m2.reversed().reduce(into: [0.0]) { $0.append($0.last! + (1 - $1)) }
        for c in 0...max(0, m1.count - gn) {   // c = indice del confine; [c, c+gn) silenzio se all'altra copia manca un pezzo
            let after = m2.count - min(m2.count, c + gn)
            let cost = pre[c] + post[after] + 0.5 * Double(min(gn, m1.count - c))
            if cost < bestC { bestC = cost; bestT = lo + Double(c) * 0.1; bestI = c }
        }
        // certezza: nei 3 s prima del taglio lo scarto vecchio deve somigliare chiaramente più del nuovo, e viceversa dopo
        let w = 30, b0 = max(0, bestI - w), a0 = min(m1.count, bestI + gn), a1 = min(m1.count, a0 + w)
        let before = (b0..<bestI).map { m1[$0] - m2[$0] }, after = (a0..<a1).map { m2[$0] - m1[$0] }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let sure = mean(before) > 0.08 && mean(after) > 0.08
        segs.append(MergeSegment(start: segStart, end: bestT, d: d1, sure: pendingSure))
        if gap > 0.05 { segs.append(MergeSegment(start: bestT, end: bestT + gap, d: nil, sure: sure)); segStart = bestT + gap; pendingSure = true } else { segStart = bestT; pendingSure = sure }
    }
    // ogni parte deve finire dopo che è cominciata; i pezzi di meno di 10 ms si uniscono alla parte prima (senza buchi nel tempo)
    var clean: [MergeSegment] = []
    for sg in segs { if sg.end - sg.start > 0.01 || clean.isEmpty { clean.append(sg) } else { clean[clean.count - 1].end = sg.end } }
    // conferme e scarto massimo rispetto alle parti trovate
    func dAt(_ t: Double) -> Double? { clean.last { $0.start <= t }?.d }
    let spread = pts.filter(\.good).compactMap { p -> Double? in guard let a = dAt(p.t), dAt(p.t + L) == a, clean.last(where: { $0.start <= p.t })!.end >= p.t + L else { return nil }; return abs(p.d - a) }.filter { $0 < 0.1 }.max() ?? 0
    return (clean, pts.map { p in var q = p; q.good = support(p); return q }, spread, nil, nil)
}

/// Scarto del doppiaggio (traccia scelta rispetto alla traccia misurata, nello stesso file) al tempo u dell'altra copia; nil dove al doppiaggio manca il pezzo.
func dubOffset(_ b: [MergeSegment], at u: Double) -> Double? { (b.last { $0.start <= u } ?? b.first)?.d }
/// Compone le parti copia→copia (tempo dell'immagine t → tempo dell'altra copia u = t + d) con quelle del doppiaggio (tempo u → u + d'):
/// ogni parte di `a` viene tagliata dove, nel tempo dell'altra copia, comincia una nuova parte del doppiaggio.
func composeSegments(_ a: [MergeSegment], _ b: [MergeSegment]) -> [MergeSegment] {
    var out: [MergeSegment] = []
    for sg in a {
        guard let d = sg.d else { out.append(sg); continue }
        var cuts = [sg.start]
        for bs in b.dropFirst() { let t = bs.start - d; if t > sg.start + 0.01 && t < sg.end - 0.01 { cuts.append(t) } }
        cuts.append(sg.end)
        for (x, y) in zip(cuts, cuts.dropFirst()) {
            let bi = b.lastIndex { $0.start <= x + d + 0.001 } ?? 0, piece = b[bi]
            out.append(MergeSegment(start: x, end: y, d: piece.d.map { d + $0 }, sure: x == sg.start ? sg.sure : piece.sure))
        }
    }
    var clean: [MergeSegment] = []   // pezzi consecutivi con lo stesso scarto (entro 1 ms) tornano una parte sola
    for sg in out {
        if var l = clean.last, sg.end - sg.start < 0.01 || (l.d != nil && sg.d != nil && abs(l.d! - sg.d!) < 0.001) || (l.d == nil && sg.d == nil) { l.end = sg.end; clean[clean.count - 1] = l } else { clean.append(sg) }
    }
    return clean
}

/// Tagli d'inquadratura (secondi, tempo del file) nel tratto [from, from + len): fotogrammi molto diversi dal precedente, a bassa risoluzione.
func sceneCuts(_ path: String, from: Double, len: Double) -> [Double] {
    guard let ff = tool("ffmpeg") else { return [] }
    let s = max(0, from); var out: [Double] = [], t = 0.0
    let o = run(ff, ["-nostats", "-hide_banner", "-hwaccel", "videotoolbox", "-ss", String(format: "%.3f", s), "-t", String(format: "%.3f", len), "-i", path, "-map", "0:v:0", "-an", "-sn", "-vf", "scale=160:-2,scdet=threshold=5,metadata=mode=print:file=-", "-f", "null", "-"])
    for l in o.text.split(separator: "\n") {
        if let m = String(l).match(#"pts_time:([\d.]+)"#) { t = Double(m[1]) ?? 0 }
        else if l.hasPrefix("lavfi.scd.score="), (Double(l.dropFirst(16)) ?? 0) >= 5 { out.append(s + t) }
    }
    return out
}
/// Scarto dell'immagine (altra copia − copia scelta) dai tagli che si corrispondono, cercato vicino agli scarti attesi; nil con meno di 2 tagli in comune.
func cutOffset(_ b: [Double], _ a: [Double], near: [Double]) -> Double? {
    func e(_ n: [Double], _ v: Double) -> Double { n.map { abs(v - $0) }.min() ?? 1e9 }
    var offs: [Double] = []
    for x in b { if let y = a.min(by: { e(near, $0 - x) < e(near, $1 - x) }), e(near, y - x) < 0.3 { offs.append(y - x) } }
    guard offs.count >= 2 else { return nil }
    // il valore con più tagli entro mezzo fotogramma
    let best = offs.max { a, b in offs.filter { abs($0 - a) < 0.021 }.count < offs.filter { abs($0 - b) < 0.021 }.count }!
    let c = offs.filter { abs($0 - best) < 0.021 }; guard c.count >= 2 else { return nil }
    return c.sorted()[c.count / 2]
}
/// Ai cambi di scarto guarda le immagini: se i tagli d'inquadratura delle due copie restano allo stesso posto prima e dopo, il montaggio è uguale
/// e a cambiare è il doppiaggio dell'altra copia. Restituisce le parti in cui è così e lo scarto dell'immagine trovato.
func pictureCheck(v: MergeSource, o: MergeSource, segs: [MergeSegment], progress: @escaping (Double) -> Void = { _ in }) -> (dub: Set<Int>, checked: Int, video: [Double]) {
    var jobs: [(i: Int, t: Double, dp: Double, dn: Double)] = []
    for (i, s) in segs.enumerated() where i > 0 {
        guard let dp = segs[..<i].last(where: { $0.d != nil })?.d, let dn = (s.d ?? segs[i...].first(where: { $0.d != nil })?.d), abs(dn - dp) < 2 else { continue }
        jobs.append((i, s.start, dp, dn))
    }
    guard !jobs.isEmpty else { return ([], 0, []) }
    jobs.sort { abs($0.dn - $0.dp) > abs($1.dn - $1.dp) }   // prima i salti più grandi, i più facili da riconoscere
    var dub = Set<Int>(), video: [Double] = [], checked = 0, done = 0; let lock = NSLock()
    let total = min(jobs.count, 24)
    for batch in stride(from: 0, to: total, by: 8) {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 4
        for j in jobs[batch..<min(batch + 8, total)] {
            q.addOperation {
                let w = 15.0, end = segs[j.i].d == nil ? segs[j.i].end : j.t   // dopo un tratto di silenzio si guarda dopo la sua fine
                let bc = sceneCuts(v.url.path, from: j.t - w, len: (end - j.t) + 2 * w)
                let ac = sceneCuts(o.url.path, from: min(j.t + j.dp, j.t + j.dn) - w - 1, len: (end - j.t) + 2 * w + abs(j.dn - j.dp) + 2)
                let before = cutOffset(bc.filter { $0 < j.t - 0.3 }, ac, near: [j.dp, j.dn]), after = cutOffset(bc.filter { $0 > end + 0.3 }, ac, near: [j.dp, j.dn])
                lock.lock(); defer { lock.unlock() }
                done += 1; progress(Double(done) / Double(total))
                guard let vb = before, let va = after else { return }
                checked += 1; video += [vb, va]
                if abs(va - vb) < 0.03 && abs(j.dn - j.dp) > 0.04 { dub.insert(j.i) }   // stesso montaggio, l'audio invece salta: è il doppiaggio
            }
        }
        q.waitUntilAllOperationsAreFinished()
        // con almeno 6 cambi controllati, tutti del doppiaggio e con l'immagine sempre allo stesso scarto, il montaggio delle due copie è lo stesso in tutto il film
        if checked >= 6, dub.count == checked, let lo = video.min(), let hi = video.max(), hi - lo < 0.045 {
            return (Set(segs.indices.dropFirst()), checked, video)
        }
    }
    return (dub, checked, video)
}

/// Allinea l'audio dell'altra copia (`o`) all'immagine della copia scelta (`v`): velocità (frame rate diversi), spostamento iniziale e, se le copie hanno un montaggio
/// diverso, i punti in cui saltare un pezzo o lasciare silenzio. Ogni parte viene controllata in tutto il film.
func alignAudio(v: MergeSource, o: MergeSource, oTrack: MergeTrack, progress: @escaping (Double, String) -> Void = { _, _ in }) -> AlignOutcome {
    guard let vi = v.video, vi.duration > 120 else { return .fail("Il film con l'immagine scelta è troppo corto o illeggibile.", []) }
    // 1) velocità: dai frame rate, altrimenti dalla durata se coincide con un rapporto noto
    var k = 1.0, speedLabel = ""
    if let ofps = o.video?.fps, vi.fps > 0, ofps > 0, abs(vi.fps / ofps - 1) > 0.001 { k = vi.fps / ofps; speedLabel = knownSpeeds.first { abs($0.0 - k) < 0.0005 }?.1 ?? String(format: "%.3f → %.3f fps", ofps, vi.fps) }
    else if o.probe.duration > 0 { let rd = o.probe.duration / vi.duration; if abs(rd - 1) > 0.01, let kn = knownSpeeds.first(where: { abs($0.0 - rd) < 0.0015 }) { k = kn.0; speedLabel = kn.1 + " (dalla durata)" } }
    // 2) quali tracce confrontare. Meglio di tutto: una lingua che hanno tutte e due le copie (di solito l'originale), perché due registrazioni uguali
    //    combaciano molto meglio di due doppiaggi; la traccia scelta sta nello stesso file della seconda, quindi si sposta allo stesso modo.
    //    Altrimenti, come prima: la traccia scelta contro quella della copia con l'immagine nella stessa lingua, la predefinita o le altre.
    let vAudio = v.tracks.filter { $0.kind == "a" }, oAudio = o.tracks.filter { $0.kind == "a" }
    guard !vAudio.isEmpty else { return .fail("Il film con l'immagine scelta non ha audio: non c'è niente con cui allineare l'altra traccia.", []) }
    var pairs: [(ref: MergeTrack, meas: MergeTrack)] = []
    func addPair(_ r: MergeTrack, _ m: MergeTrack) { if !pairs.contains(where: { $0.ref == r && $0.meas == m }) { pairs.append((r, m)) } }
    for rt in vAudio where !oTrack.effLang.isEmpty && rt.effLang == oTrack.effLang { addPair(rt, oTrack) }
    let shared = Set(vAudio.map(\.effLang)).intersection(oAudio.map(\.effLang)).subtracting(["", oTrack.effLang])
    for l in shared.sorted() {   // per ogni lingua in comune la traccia migliore di ciascuna copia
        if let rt = vAudio.filter({ $0.effLang == l }).max(by: { audioScore($0) < audioScore($1) }), let mt = oAudio.filter({ $0.effLang == l }).max(by: { audioScore($0) < audioScore($1) }) { addPair(rt, mt) }
    }
    for rt in (vAudio.filter(\.isDefault) + vAudio).prefix(2) { addPair(rt, oTrack) }
    pairs = Array(pairs.prefix(3))
    var envO: [Int: [Float]] = [:]   // inviluppi dell'altra copia per traccia, alla velocità k attuale
    func eoFor(_ t: MergeTrack, _ lab: String) -> [Float] {
        if let e = envO[t.ord] { return e }
        let e = fullEnvelope(o.url.path, track: t.ord, k: k, sampleRate: t.sampleRate, duration: o.probe.duration) { progress(0.25 * $0, lab) }; envO[t.ord] = e; return e
    }
    var lastFail: AlignOutcome = .fail("Non trovo corrispondenze tra l'audio delle due copie.", [])
    for (ri, pr) in pairs.enumerated() {
        let rt = pr.ref, mt = pr.meas, viaShared = mt.ord != oTrack.ord
        var eo = eoFor(mt, "Leggo l'audio dell'altra copia…")
        let ev = fullEnvelope(v.url.path, track: rt.ord, duration: vi.duration) { progress(0.25 + 0.3 * (Double(ri) + $0) / Double(pairs.count), "Leggo l'audio del film con l'immagine…") }
        progress(0.55 + 0.3 * Double(ri) / Double(pairs.count), "Confronto le due copie in tutto il film…")
        var r = segmentAlignment(ev, eo, vDur: vi.duration)
        if let b = r.drift {   // p = t·(1+b) + a  →  la velocità giusta è k·(1+b)
            k *= (1 + b); speedLabel = (speedLabel.isEmpty ? "" : speedLabel + ", ") + String(format: "deriva corretta (%+.4f%%)", b * 100); envO = [:]
            eo = eoFor(mt, "Rileggo l'audio dell'altra copia con la velocità corretta…")
            r = segmentAlignment(ev, eo, vDur: vi.duration)
        }
        if let why = r.why { lastFail = .fail(why, r.points); continue }
        if r.drift != nil { lastFail = .fail("La velocità delle due copie non torna nemmeno dopo la correzione: non unisco.", r.points); continue }
        var segs = r.segments, extra: [String] = []
        var pts = r.points, spread = r.spread
        if viaShared {
            // la traccia scelta e quella misurata stanno nello stesso file, ma un doppiaggio montato male può essere spostato, anche a gradini diversi nel film.
            // Si misura anche questo, con la musica e gli effetti che le due tracce hanno in comune, e si somma: scarto finale = copia→copia + doppiaggio→originale.
            let et = eoFor(oTrack, "Leggo la traccia scelta dell'altra copia…")
            progress(0.9, "Controllo il doppiaggio rispetto all'originale…")
            let ib = segmentAlignment(eo, et, vDur: Double(eo.count) / envRate, maxSearch: 1)   // un doppiaggio nello stesso file non salta di secondi: si cerca entro ±1 s
            if ib.why == nil, ib.drift == nil, !ib.segments.isEmpty {
                segs = composeSegments(segs, ib.segments)
                pts = pts.map { p in var q = p; if let x = dubOffset(ib.segments, at: p.t + p.d) { q.d += x }; return q }
                spread = max(spread, ib.spread)
                let steps = ib.segments.compactMap(\.d), lo = steps.min() ?? 0, hi = steps.max() ?? 0
                if hi - lo > 0.02 || abs(lo) > 0.02 { extra.append(String(format: "Nell'altra copia il doppiaggio non è sempre a tempo con la traccia in %@ (da %+.0f a %+.0f ms in %d tratti): corretto tratto per tratto", langLabel(mt.effLang), lo * 1000, hi * 1000, ib.segments.filter { $0.d != nil }.count)) }
                else { extra.append("Nell'altra copia il doppiaggio è a tempo con la traccia in \(langLabel(mt.effLang))") }
            } else { extra.append("Non ho potuto misurare il doppiaggio rispetto alla traccia in \(langLabel(mt.effLang)) nell'altra copia (\(ib.why ?? "misure discordanti")): lo considero a tempo, controlla l'anteprima") }
        }
        var dubAt = Set<Int>()
        if segs.count > 1 && abs(k - 1) < 1e-6 && !CommandLine.arguments.contains("--no-picture") {
            progress(0.93, "Guardo le immagini nei punti in cui lo scarto cambia…")
            let pc = pictureCheck(v: v, o: o, segs: segs) { progress(0.93 + 0.06 * $0, "Guardo le immagini nei punti in cui lo scarto cambia…") }
            dubAt = pc.dub
            if pc.checked > 0 {
                let vs = pc.video.sorted(), vc = vs[vs.count / 2], same = vs.last! - vs.first! < 0.045
                let off = segs.compactMap(\.d).map { $0 - vc }, lo = off.min() ?? 0, hi = off.max() ?? 0
                if pc.dub.count >= pc.checked && same {
                    extra.append(String(format: "Immagini controllate in %d punti in cui lo scarto cambia: i tagli d'inquadratura delle due copie sono sempre allo stesso posto, quindi il montaggio è uguale in tutto il film. A cambiare è il doppiaggio dell'altra copia, che già nel suo file non è a tempo con l'immagine (fuori fino a %.0f ms): qui viene rimesso a tempo tratto per tratto", pc.checked, max(abs(lo), abs(hi)) * 1000))
                } else if !pc.dub.isEmpty {
                    extra.append("Immagini controllate in \(pc.checked) punti in cui lo scarto cambia: in \(pc.dub.count) il montaggio è uguale e a cambiare è il doppiaggio dell'altra copia, negli altri le copie sono montate in modo diverso")
                } else { extra.append("Immagini controllate in \(pc.checked) punti in cui lo scarto cambia: le due copie sono montate in modo diverso") }
            }
        }
        progress(1, "Allineamento trovato")
        let label = viaShared ? "\(langLabel(rt.effLang)) di tutte e due le copie (audio \(rt.ord + 1) e audio \(mt.ord + 1)): la traccia scelta sta nello stesso file e si sposta allo stesso modo"
                              : "audio \(rt.ord + 1) del film con l'immagine (\(langLabel(rt.effLang)))"
        return .ok(Alignment(k: k, segments: segs, points: pts, refLabel: label, refOrd: rt.ord, speedLabel: speedLabel, spread: spread, measOrd: viaShared ? mt.ord : nil, notes: extra, dubAt: dubAt))
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
/// La traccia che si ascolta nell'anteprima: con l'allineamento, sempre una dell'altra copia (la predefinita se è sua, altrimenti la prima scelta), perché è quella
/// che «Audio prima/dopo» sposta; se fosse quella della copia con l'immagine i pulsanti non cambierebbero niente di udibile.
func previewTrack(_ s: [MergeSource], _ plan: MergePlan, aligned: Bool) -> MergeTrack? {
    let all = s[0].tracks + s[1].tracks, chosen = plan.audio.compactMap { id in all.first { $0.id == id } }
    let def = (plan.defaultAudio ?? plan.audio.first).flatMap { id in all.first { $0.id == id } }
    if aligned, let o = (def.map { [$0] } ?? []).first(where: { $0.src != plan.video }) ?? chosen.first(where: { $0.src != plan.video }) { return o }
    return def ?? chosen.first
}
/// Anteprima per il controllo a vista: `len` secondi dell'immagine scelta dal punto `at`, con l'audio predefinito già allineato come nel film finale.
func renderPreview(_ s: [MergeSource], _ plan: MergePlan, alignment: Alignment?, at: Double, len: Double = 15, out: URL) -> String? {
    guard let ff = tool("ffmpeg") else { return "ffmpeg non trovato." }
    let V = s[plan.video], O = s[1 - plan.video]
    guard let at0 = previewTrack(s, plan, aligned: alignment != nil) else { return "Scegli una traccia audio." }
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
func runMerge(_ s: [MergeSource], _ plan: MergePlan, alignment: Alignment?, attempt: Int = 1, progress: @escaping (Double, String) -> Void) -> FixResult {
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
    defer { if let k = ProcessInfo.processInfo.environment["BOOTH_KEEP_MERGE"] { try? FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: k)) }; try? FileManager.default.removeItem(at: work) }   // diagnosi: conserva anche il file scartato
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
    // la sincronia si rimisura sul file finito: ogni traccia arrivata dall'altra copia contro l'audio di riferimento della copia con l'immagine.
    // Se in una parte l'audio risulta spostato in modo costante, la correzione si applica da sola e il film si rifà (al massimo due volte);
    // i tratti troppo sommessi per essere misurati non bloccano: vengono indicati da guardare.
    if let a = alignment {
        let L = 20.0, vd = V.probe.duration
        func clamp(_ x: Double) -> Double { max(2, min(x, vd - L - 2)) }
        let parts = segs.indices.filter { segs[$0].d != nil && segs[$0].end - segs[$0].start >= L + 4 }
        let global = [0.2, 0.5, 0.8].map { clamp($0 * vd) }
        var corrected = a; var needRedo = false
        // un dubbio in un momento già proposto per il controllo a vista (per esempio musica ripetitiva, dove l'audio da solo non può decidere) non blocca:
        // resta da guardare. Altrove invece è un errore vero.
        let risky = a.risks.map(\.t)
        func flagged(_ t: Double) -> Bool { risky.contains { abs($0 - t) < 25 } }
        var watch: [Double] = []
        for (pos, id) in plan.audio.enumerated() where all[id]?.src != vi {
            progress(0.85 + 0.1 * Double(pos) / Double(plan.audio.count), "Verifico la sincronia dell'audio \(pos + 1)…")
            let sr = Int(dbl(np.audio[pos]["sample_rate"]) ?? 48000)
            // allineamento fatto su una lingua comune: la sincronia l'ha già misurata quella traccia (due registrazioni uguali), qui si controlla che il film unito
            // contenga proprio la traccia scelta messa al posto giusto, confrontandola con la stessa traccia nell'altra copia (scarto atteso: quello della parte)
            let construct = a.measOrd != nil, ot = all[id]
            func expected(_ t: Double) -> Double? { segs.last { $0.start <= t }?.d }
            func meas(_ t: Double) -> AlignPoint? {
                if construct, let ot = ot { let tc = clamp(t); guard let e = expected(tc), expected(tc + L) == e else { return nil }
                    return measurePoint(ref: (tmp.path, pos), other: (O.url.path, ot.ord, ot.sampleRate), k: a.k, t: tc, guess: e, search: 1, len: L).flatMap { $0.good ? $0 : nil } }
                return measurePoint(ref: (V.url.path, a.refOrd), other: (tmp.path, pos, sr), k: 1, t: clamp(t), guess: 0, search: 3, len: L).flatMap { $0.good ? $0 : nil }
            }
            func raw(_ p: AlignPoint) -> Double { construct ? p.d - (expected(p.t) ?? p.d) : p.d + a.nudge(at: p.t) }   // con una correzione a mano di n secondi l'audio deve risultare spostato proprio di n
            // uno sfasamento vale solo se lo conferma almeno un'altra misura (finestre spostate di ±6 s o lunga 40 s): nei passaggi con musica
            // ripetitiva una singola correlazione può trovare il picco sbagliato. Se le altre misure danno sincronia, conta quella.
            var memo: [Double: Double] = [:]
            func res(_ p: AlignPoint) -> Double {
                let r0 = raw(p); guard abs(r0) > 0.045 else { return r0 }
                if let m = memo[p.t] { return m }
                let more = [p.t - 6, p.t + 6].compactMap(meas).map(raw) + [measurePoint(ref: (V.url.path, a.refOrd), other: (tmp.path, pos, sr), k: 1, t: clamp(p.t - 10), guess: 0, search: 3, len: 40)].compactMap { $0?.good == true ? raw($0!) : nil }
                let agree = more.filter { abs($0 - r0) < 0.02 }.count, ok = more.filter { abs($0) <= 0.045 }
                let r = agree >= 1 || ok.isEmpty ? r0 : ok.sorted()[ok.count / 2]; memo[p.t] = r; return r
            }
            var pts = global.compactMap(meas); var unverified: [MergeSegment] = []
            for pi in parts {
                let sg = segs[pi]
                // inizio, centro e fine della parte; se l'audio è troppo sommesso si prova ogni 10 s (al massimo 12 tentativi)
                var got = [sg.start + 2, (sg.start + sg.end - L) / 2, sg.end - L - 2].compactMap(meas)
                if got.isEmpty { var t = sg.start + 7; var n = 0; while got.isEmpty && t < sg.end - L && n < 12 { if let p = meas(t) { got.append(p) }; t += 10; n += 1 } }
                if got.isEmpty { unverified.append(sg); continue }
                pts += got
                let r = got.map(res), m = r.reduce(0, +) / Double(r.count)
                if abs(m) > 0.045 {
                    // spostamento costante in tutta la parte → si corregge da solo; altrimenti il taglio è nel punto sbagliato e va guardato
                    if construct { return FixResult(ok: false, message: String(format: "Nel film unito l'audio %d non è nella posizione prevista (%.0f ms verso %@): non lo salvo.", pos + 1, abs(m) * 1000, hms(sg.start)), lines: lines) }
                    if r.count >= 2 && (r.max()! - r.min()!) < 0.02 && attempt < 3 { corrected.auto[a.part(at: sg.start + 0.01), default: 0] += m; needRedo = true }
                    else if flagged(sg.start + (sg.end - sg.start) / 2) || got.contains(where: { abs(res($0)) > 0.045 && flagged($0.t + L / 2) }) { watch += got.filter { abs(res($0)) > 0.045 }.map { $0.t + L / 2 }; continue }
                    else { let w = got.max { abs(res($0)) < abs(res($1)) }!; return FixResult(ok: false, message: String(format: "Nel film unito l'audio %d risulta sfasato di %.0f ms verso %@: guardalo nell'anteprima e correggilo con «Audio prima/dopo».", pos + 1, abs(res(w)) * 1000, hms(w.t + L / 2)), lines: lines, badTime: w.t + L / 2) }
                }
            }
            if needRedo { continue }
            guard pts.count >= 2 else { return FixResult(ok: false, message: "Non riesco a verificare la sincronia dell'audio \(pos + 1) nel film unito: non lo salvo.", lines: lines) }
            let checked = pts.filter { !(abs(res($0)) > 0.045 && flagged($0.t + L / 2)) }; watch += pts.filter { abs(res($0)) > 0.045 && flagged($0.t + L / 2) }.map { $0.t + L / 2 }
            guard let worst = checked.max(by: { abs(res($0)) < abs(res($1)) }) else { return FixResult(ok: false, message: "Non riesco a verificare la sincronia dell'audio \(pos + 1) nel film unito: non lo salvo.", lines: lines) }
            let err = abs(res(worst))
            if err > 0.045 { return FixResult(ok: false, message: String(format: "Nel film unito l'audio %d risulta sfasato di %.0f ms verso %@: guardalo nell'anteprima e correggilo con «Audio prima/dopo».", pos + 1, err * 1000, hms(worst.t + L / 2)), lines: lines, badTime: worst.t + L / 2) }
            lines.append(String(format: "Sincronia dell'audio %d nel film unito: verificata in %d punti%@, scarto massimo %.0f ms", pos + 1, pts.count, parts.count > 1 ? " (\(parts.count - unverified.count) parti su \(parts.count))" : "", err * 1000))
            if !watch.isEmpty { lines.append("Audio dubbio anche nel film unito, da guardare: " + Set(watch.map { Int($0) }).sorted().map { hms(Double($0)) }.joined(separator: ", ")) }
            if !unverified.isEmpty { lines.append("Audio troppo sommesso per verificarlo da sola, da guardare: " + unverified.map { "\(hms($0.start))–\(hms($0.end))" }.joined(separator: ", ")) }
        }
        if needRedo {
            let fixed = corrected.auto.filter { abs($0.value) > 0.0005 }.sorted { $0.key < $1.key }
            progress(0.05, "Correggo da solo \(fixed.count) part\(fixed.count == 1 ? "e" : "i") e rifaccio il film…")
            var r = runMerge(s, plan, alignment: corrected, attempt: attempt + 1, progress: progress)
            r.lines.insert(contentsOf: fixed.map { String(format: "Correzione automatica dopo la verifica: audio %@ di %.0f ms da %@ a %@", $0.value > 0 ? "anticipato" : "ritardato", abs($0.value) * 1000, hms(segs[$0.key].start), hms(segs[$0.key].end)) }, at: min(r.lines.count, 1))
            return r
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
