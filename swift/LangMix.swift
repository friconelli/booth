import Foundation

/// Tratti in un'altra lingua dentro una traccia audio italiana (scene recuperate da director's cut o versioni estese, lasciate in lingua originale).
/// whisper riconosce la lingua su finestre di 30 s lungo tutto il film (ogni 30 s, senza trascrivere: pochi decimi di secondo l'una);
/// un tratto è segnalato solo se la lingua diversa è riconosciuta con sicurezza e una trascrizione vera trova parlato (musica, urla e canzoni senza parole non contano).
struct LangStretch { var start: Double; var end: Double; var lang: String }

/// Lingua riconosciuta da whisper su un tratto di audio già estratto in WAV: (codice a 2 lettere, probabilità).
func detectLanguage(_ wav: String, model: String) -> (String, Double)? {
    guard let wc = tool("whisper-cli") else { return nil }
    let o = run(wc, ["-m", model, "-f", wav, "-l", "auto", "-dl", "-t", "4"])
    guard let m = (o.err + "\n" + o.text).match(#"auto-detected language: (\w+) \(p = ([\d.]+)\)"#), let p = Double(m[2]) else { return nil }
    return (m[1], p)
}

func scanLanguageMix(_ pr: Probe, _ path: String, _ tmp: URL, _ c: Collector, model: String, progress: @escaping (Double) -> Void) {
    let d = pr.duration; guard d > 600, let ff = tool("ffmpeg") else { return }
    let dir = tmp.appendingPathComponent("mix"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let debug = ProcessInfo.processInfo.environment["BOOTH_DEBUG"] != nil
    let step = 30.0, L = 30.0, from = 30.0, to = d - 150   // si salta l'inizio e i titoli di coda, dove le canzoni in inglese sono normali
    let starts = Array(stride(from: from, to: to - L + 1, by: step)); guard starts.count >= 12 else { return }
    let tracks = Array(0..<min(2, pr.audio.count)); var done = 0.0; let total = Double(starts.count * tracks.count)
    for k in tracks {
        let ch = Int(dbl(pr.audio[k]["channels"]) ?? 2), pan = ch == 6 ? "pan=mono|c0=FC" : "pan=mono|c0=0.5*c0+0.5*c1"
        let wav = dir.appendingPathComponent("m\(k).wav").path
        var det: [(t: Double, lang: String, p: Double)] = []
        for s in starts {
            run(ff, ["-nostdin", "-y", "-v", "error", "-ss", String(s), "-t", String(L), "-i", path, "-map", "0:a:\(k)", "-vn", "-af", ch == 1 ? "anull" : pan, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav])
            if let r = detectLanguage(wav, model: model) { det.append((s, r.0, r.1)) }
            done += 1; progress(done / total)
        }
        // lingua principale della traccia: la più frequente tra i tratti riconosciuti con sicurezza
        var tally: [String: Int] = [:]; det.filter { $0.p >= 0.6 }.forEach { tally[$0.lang, default: 0] += 1 }
        guard let (main, n) = tally.max(by: { $0.value < $1.value }), n >= 8, main == "it" else { continue }   // solo le tracce italiane: in un originale le altre lingue sono normali
        if debug { FileHandle.standardError.write(Data("lingue traccia \(k + 1): \(tally) · altre: \(det.filter { $0.lang != main && $0.p >= 0.75 }.map { String(format: "%.0f:%@", $0.t, $0.lang) })\n".utf8)) }
        // candidati: altra lingua con sicurezza; conferma con una trascrizione vera (almeno 5 s di parlato in quella lingua)
        var found: [LangStretch] = []
        for x in det where x.lang != main && x.p >= 0.75 {
            guard let w = transcribe(pr, path, audio: k, start: x.t, len: L, model: model, tmp: dir), w.lang == x.lang, w.nseg >= 2, w.speechSecs >= 5 else { continue }
            if let last = found.last, last.lang == x.lang, x.t - last.end <= 1 { found[found.count - 1].end = x.t + L } else { found.append(LangStretch(start: x.t, end: x.t + L, lang: x.lang)) }
        }
        guard !found.isEmpty else { continue }
        let label = { (s: LangStretch) in langLabel(iso2[s.lang] ?? s.lang) }
        let list = found.prefix(6).map { "\(hms($0.start)) → \(hms($0.end)) (\(label($0)))" }.joined(separator: ", ") + (found.count > 6 ? " e altri \(found.count - 6)" : "")
        let secs = Int(found.reduce(0) { $0 + $1.end - $1.start })
        c.rows("Audio \(k + 1)", order: 12 + k, [("Parti in un'altra lingua", "\(found.count) tratt\(found.count == 1 ? "o" : "i"), circa \(secs) s")])
        c.add(.warn, "Audio", "Parti in un'altra lingua nella traccia italiana — traccia audio \(k + 1)",
              "La traccia è in italiano, ma in \(found.count) \(found.count == 1 ? "punto" : "punti") (circa \(secs) s in tutto) si sente parlato in un'altra lingua: \(list). Succede nelle versioni estese o director's cut, dove le scene recuperate non sono doppiate. Controllale a vista: se non sono canzoni o battute volute, in sala il pubblico sentirebbe il film cambiare lingua. Rimedio: «Unisci due copie» con una versione che abbia il doppiaggio completo, oppure sottotitoli in italiano per quei tratti.",
              time: found[0].start)
    }
    progress(1)
}
