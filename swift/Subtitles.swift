import Foundation
import Security
import Vision
import NaturalLanguage

// MARK: sottotitoli online (OpenSubtitles.com)
/// Cerca i sottotitoli adatti a un film su OpenSubtitles.com: prima per impronta del file (moviehash: combaciano con questa copia esatta),
/// poi per titolo e anno (o codice IMDb dai dati online). Serve una chiave API gratuita dell'utente; l'accesso con nome utente e password
/// è facoltativo e alza il numero di scaricamenti al giorno. Al servizio vanno solo impronta, titolo, anno e lingue: il film non lascia mai il Mac.

/// Impronta OpenSubtitles: dimensione del file + somma (64 bit, little endian) dei primi e degli ultimi 64 KB.
func movieHash(_ url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value, size >= 131072 else { return nil }
    var sum = size
    func add(_ d: Data) { d.withUnsafeBytes { b in for i in stride(from: 0, to: b.count - 7, by: 8) { sum = sum &+ b.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian } } }
    guard let a = try? h.read(upToCount: 65536) else { return nil }; add(a)
    try? h.seek(toOffset: size - 65536); guard let b = try? h.read(upToCount: 65536) else { return nil }; add(b)
    return String(format: "%016llx", sum)
}

/// Un risultato della ricerca.
struct SubResult: Identifiable, Hashable {
    var id: Int { fileID }
    var fileID: Int; var lang: String; var release: String; var fileName: String; var downloads: Int
    var hashMatch: Bool; var hearingImpaired: Bool; var fps: Double; var machine: Bool; var trusted: Bool; var uploader: String
    var feature: String; var year: Int?
    var score = 0.0
    /// Codice a 3 lettere della lingua (per l'etichetta della traccia e langLabel).
    var lang3: String { let b = String(lang.prefix(2)).lowercased(); return iso2[b] ?? b }
}

struct OSError: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

enum OpenSubtitles {
    static let keyDefaults = "osApiKey", userDefaults = "osUser"
    static var apiKey: String { (UserDefaults.standard.string(forKey: keyDefaults) ?? ProcessInfo.processInfo.environment["BOOTH_OS_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var username: String { UserDefaults.standard.string(forKey: userDefaults) ?? "" }
    static var password: String { Keychain.get("opensubtitles") ?? "" }
    static var configured: Bool { !apiKey.isEmpty }
    private static var token: String?, base = "api.opensubtitles.com"
    static func save(key: String, user: String, password: String) {
        UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyDefaults)
        UserDefaults.standard.set(user.trimmingCharacters(in: .whitespaces), forKey: userDefaults)
        if password.isEmpty { Keychain.delete("opensubtitles") } else { Keychain.set("opensubtitles", password) }
        token = nil; base = "api.opensubtitles.com"
    }

    private static func call(_ method: String, _ path: String, query: [(String, String)] = [], body: [String: Any]? = nil, auth: Bool = false) throws -> [String: Any] {
        guard configured else { throw OSError(message: "Manca la chiave API di OpenSubtitles.") }
        // l'API vuole i parametri in minuscolo e in ordine alfabetico (altrimenti risponde con un reindirizzamento)
        var c = URLComponents(); c.scheme = "https"; c.host = base; c.path = "/api/v1" + path
        if !query.isEmpty { c.queryItems = query.sorted { $0.0 < $1.0 }.map { URLQueryItem(name: $0.0, value: $0.1.lowercased()) } }
        guard let u = c.url else { throw OSError(message: "Richiesta non valida.") }
        var rq = URLRequest(url: u, timeoutInterval: 25); rq.httpMethod = method
        rq.setValue(apiKey, forHTTPHeaderField: "Api-Key"); rq.setValue("Booth v\(Updater.current)", forHTTPHeaderField: "User-Agent"); rq.setValue("application/json", forHTTPHeaderField: "Accept")
        if let b = body { rq.httpBody = try? JSONSerialization.data(withJSONObject: b); rq.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if auth, let t = token { rq.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0); var data: Data?, resp: HTTPURLResponse?, err: Error?
        URLSession.shared.dataTask(with: rq) { d, r, e in data = d; resp = r as? HTTPURLResponse; err = e; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 40)
        if let e = err { throw OSError(message: "OpenSubtitles non risponde: \(e.localizedDescription)") }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let msg = (json["message"] as? String) ?? (json["errors"] as? [String])?.joined(separator: " ") ?? ""
        let code = resp?.statusCode ?? 0
        if path == "/download" && (code == 406 || code == 429) { throw OSError(message: "Hai finito gli scaricamenti disponibili per oggi su OpenSubtitles. \(msg) Con un account (Impostazioni → Sottotitoli) se ne hanno di più.") }
        switch code {
        case 200...299: return json
        case 401: throw OSError(message: path == "/login" ? "Nome utente o password di OpenSubtitles non validi." : "La chiave API di OpenSubtitles non è valida. Controllala in Impostazioni → Sottotitoli.")
        case 403: throw OSError(message: "OpenSubtitles rifiuta la richiesta: la chiave API non è valida o non è abilitata. \(msg)")
        case 429: throw OSError(message: "Troppe richieste a OpenSubtitles in poco tempo: riprova tra qualche secondo.")
        default: throw OSError(message: "OpenSubtitles ha risposto con un errore (\(resp?.statusCode ?? 0)). \(msg)")
        }
    }
    /// Accesso con l'account (facoltativo): dà più scaricamenti al giorno. Il token vale per la sessione dell'app.
    static func loginIfNeeded() throws {
        guard token == nil, !username.isEmpty, !password.isEmpty else { return }
        let r = try call("POST", "/login", body: ["username": username, "password": password])
        token = r["token"] as? String; if let b = r["base_url"] as? String, !b.isEmpty { base = b.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "/api/v1", with: "") }
    }

    /// Cerca per impronta del file e per titolo/anno (o IMDb), unisce i risultati e li ordina dal più adatto.
    static func search(film url: URL, title: String, year: Int?, imdb: String?, langs: [String], fps: Double) throws -> [SubResult] {
        let lg = langs.map { $0.lowercased() }.sorted().joined(separator: ",")
        var all: [Int: SubResult] = [:]
        func parse(_ j: [String: Any]) {
            for x in j["data"] as? [[String: Any]] ?? [] {
                guard let a = x["attributes"] as? [String: Any], let f = (a["files"] as? [[String: Any]])?.first, let fid = f["file_id"] as? Int else { continue }
                let fd = a["feature_details"] as? [String: Any] ?? [:]
                let r = SubResult(fileID: fid, lang: (a["language"] as? String) ?? "", release: (a["release"] as? String) ?? "", fileName: (f["file_name"] as? String) ?? "",
                                  downloads: (a["download_count"] as? Int) ?? 0, hashMatch: (a["moviehash_match"] as? Bool) ?? false, hearingImpaired: (a["hearing_impaired"] as? Bool) ?? false,
                                  fps: dbl(a["fps"]) ?? 0, machine: ((a["machine_translated"] as? Bool) ?? false) || ((a["ai_translated"] as? Bool) ?? false), trusted: (a["from_trusted"] as? Bool) ?? false,
                                  uploader: ((a["uploader"] as? [String: Any])?["name"] as? String) ?? "", feature: (fd["title"] as? String) ?? (fd["movie_name"] as? String) ?? "", year: fd["year"] as? Int)
                if var old = all[fid] { old.hashMatch = old.hashMatch || r.hashMatch; all[fid] = old } else { all[fid] = r }
            }
        }
        if let h = movieHash(url) { parse(try call("GET", "/subtitles", query: [("languages", lg), ("moviehash", h)])) }
        var q: [(String, String)] = [("languages", lg)]
        if let i = imdb?.replacingOccurrences(of: "tt", with: ""), let n = Int(i) { q.append(("imdb_id", String(n))) }
        else { q.append(("query", title)); if let y = year { q.append(("year", String(y))) } }
        q.append(("type", "movie"))
        parse(try call("GET", "/subtitles", query: q))
        let tokens = releaseTokens(url.deletingPathExtension().lastPathComponent)
        return all.values.map { r in
            var r = r, s = 0.0
            if r.hashMatch { s += 100 }                                                           // stessa copia esatta: tempi giusti in partenza
            if r.fps > 0 && fps > 0 { s += abs(r.fps - fps) < 0.02 ? 12 : -12 }                   // frame rate diverso: si sfasano col passare del tempo
            s += Double(min(5, releaseTokens(r.release + " " + r.fileName).intersection(tokens).count)) * 3   // stessa uscita (BluRay, WEB-DL, gruppo…)
            if r.machine { s -= 40 }
            if r.trusted { s += 4 }
            if r.hearingImpaired { s -= 2 }
            s += log10(Double(max(1, r.downloads))) * 3
            r.score = s; return r
        }.sorted { $0.score > $1.score }
    }
    /// Scarica un sottotitolo in formato SRT. Restituisce il testo e quanti scaricamenti restano oggi.
    static func download(_ r: SubResult) throws -> (text: String, remaining: Int?) {
        try? loginIfNeeded()
        let j = try call("POST", "/download", body: ["file_id": r.fileID, "sub_format": "srt"], auth: true)
        guard let l = j["link"] as? String, let u = URL(string: l) else { throw OSError(message: "OpenSubtitles non ha dato il collegamento per scaricare.") }
        let sem = DispatchSemaphore(value: 0); var data: Data?
        URLSession.shared.dataTask(with: URLRequest(url: u, timeoutInterval: 30)) { d, _, _ in data = d; sem.signal() }.resume(); _ = sem.wait(timeout: .now() + 45)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("booth-sub-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let d = data, (try? d.write(to: tmp)) != nil, let t = readSubText(tmp), !parseSRT(t).isEmpty else { throw OSError(message: "Il file scaricato non è un sottotitolo leggibile.") }
        return (t, j["remaining"] as? Int)
    }
}

/// Parole di un nome di uscita utili a riconoscere la stessa versione: sorgente, risoluzione, gruppo («BluRay», «1080p», «YTS»…).
func releaseTokens(_ s: String) -> Set<String> {
    let stop: Set<String> = ["the", "a", "of", "and", "il", "la", "le", "di", "srt", "ita", "eng", "sub", "subs", "x264", "h264", "x265", "hevc", "aac", "ac3"]
    return Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 && !stop.contains($0) && Int($0) == nil || ["720p", "1080p", "2160p"].contains($0) })
}

/// Dove salvare il sottotitolo accanto al film: «Film.it.srt» (lo trovano VLC, IINA, Infuse…), mai sopra un file che esiste.
func sidecarURL(for film: URL, lang: String) -> URL {
    let base = film.deletingPathExtension(), l = String(lang.prefix(2)).lowercased()
    var u = URL(fileURLWithPath: base.path + ".\(l).srt"), n = 1
    while FileManager.default.fileExists(atPath: u.path) { n += 1; u = URL(fileURLWithPath: base.path + ".\(l).\(n).srt") }
    return u
}

/// Riscrive un SRT con i tempi corretti: tempo nuovo = a·tempo + b (spostamento fisso o frame rate diverso).
func retimeSRT(_ text: String, a: Double, b: Double) -> String {
    func ts(_ x: Double) -> String { let ms = Int((max(0, x) * 1000).rounded()); return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
    return parseSRT(text).filter { a * $0.e + b > 0 }.enumerated().map { "\($0 + 1)\n\(ts(a * $1.s + b)) --> \(ts(a * $1.e + b))\n\($1.t)\n" }.joined(separator: "\n")
}

/// Il parlato del film in cinque tratti, riconosciuto una volta sola (serve a controllare la sincronia di ogni sottotitolo provato).
final class FilmSpeech {
    let url: URL; private(set) var wins: [SpeechWindow]?; static let len = 70.0
    init(_ url: URL) { self.url = url }
    /// nil se manca il modello vocale o il film è troppo corto; [] se non si riconosce abbastanza parlato.
    func get(progress: @escaping (Double) -> Void = { _ in }) -> [SpeechWindow]? {
        if let w = wins { return w }
        guard let model = whisperModelPath(), let pr = Probe(url.path), pr.duration > 600, !pr.audio.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("booth-sp-" + UUID().uuidString); try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let k = pr.audio.firstIndex { disp($0, "default") == 1 } ?? 0, d = pr.duration
        var out: [SpeechWindow] = []
        let at = [0.12, 0.3, 0.5, 0.7, 0.88]
        for (i, f) in at.enumerated() {
            if let w = transcribe(pr, url.path, audio: k, start: max(60, min(f * d, d - 120)), len: FilmSpeech.len, model: model, tmp: tmp), w.segments.count >= 4 { out.append(w) }
            progress(Double(i + 1) / Double(at.count))
        }
        wins = out; return out
    }
}

/// Esito leggibile della sincronia di un sottotitolo esterno, con la correzione da proporre (a, b) se serve.
func describeSync(_ r: SubSyncResult) -> (ok: Bool?, text: String, fix: (a: Double, b: Double)?) {
    switch r {
    case .unknown: return (nil, "Sincronia non verificabile: nei tratti ascoltati il parlato e le battute non bastano per una misura sicura. Controllala a occhio all'inizio del film.", nil)
    case .aligned(let n): return (true, "A tempo con il parlato del film (verificato in \(n) tratti).", nil)
    case .shifted(let d, let n, _):
        if abs(d) < 0.3 { return (true, "A tempo con il parlato del film (verificato in \(n) tratti).", nil) }
        return (false, String(format: "Sfasati di %.1f s: le battute arrivano %@ rispetto al parlato (misurato in %d tratti).", abs(d), d < 0 ? "in ritardo" : "in anticipo", n), (1, d))
    case .drift(let d0, let d1, let a, let b, let label, _):
        return (false, String(format: "Si sfasano col passare del tempo (da %+.1f s a %+.1f s)%@.", d0, d1, label.map { ": frame rate diverso, \($0)" } ?? ""), label != nil ? (a, b) : nil)
    }
}

/// Portachiavi del Mac per la password di OpenSubtitles (mai nelle preferenze in chiaro).
enum Keychain {
    static let service = "app.booth.Booth"
    static func get(_ k: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: k, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?; guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }; return String(data: d, encoding: .utf8)
    }
    static func set(_ k: String, _ v: String) {
        delete(k)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: k, kSecValueData as String: Data(v.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ k: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: k] as CFDictionary) }
}

// MARK: sottotitoli impressi nell'immagine

/// Sottotitoli già impressi nell'immagine (es. inglesi «bruciati» nel video): li cerca con l'OCR nei momenti in cui si parla
/// (gli istanti delle battute del sottotitolo scaricato) e dice fin dove arrivano dal basso, per mettere i nuovi sopra.
struct BurnedIn { var top: Double; var share: Double; var lang: String?; var sample: String }
func burnedInSubtitles(_ film: URL, cues: [Cue], duration: Double) -> BurnedIn? {
    guard let ff = tool("ffmpeg"), duration > 0 else { return nil }
    let usable = cues.filter { $0.e - $0.s >= 1.2 && $0.s > 30 && $0.e < duration - 30 }
    guard usable.count >= 12 else { return nil }
    let picks = (0..<16).map { usable[$0 * (usable.count - 1) / 15] }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("booth-burn-" + UUID().uuidString); try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    var tops: [Double] = [], texts: [String] = []; let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: picks.count) { i in
        let c = picks[i], f = tmp.appendingPathComponent("f\(i).jpg")
        run(ff, ["-nostdin", "-v", "error", "-ss", String(format: "%.2f", (c.s + c.e) / 2), "-i", film.path, "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=1280:-2", "-q:v", "3", f.path])
        let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate; req.usesLanguageCorrection = false
        try? VNImageRequestHandler(url: f).perform([req])
        // righe di testo nella parte bassa, centrate: i sottotitoli impressi (i titoli di testa o le scritte nella scena sono altrove o rari)
        let lines = (req.results ?? []).compactMap { o -> (String, CGRect)? in
            guard let s = o.topCandidates(1).first?.string, s.count >= 4, o.boundingBox.minY < 0.35, abs(o.boundingBox.midX - 0.5) < 0.2 else { return nil }; return (s, o.boundingBox) }
        if !lines.isEmpty { lock.lock(); tops.append(lines.map { Double($0.1.maxY) }.max()!); texts.append(lines.map(\.0).joined(separator: " ")); lock.unlock() }
    }
    let share = Double(tops.count) / Double(picks.count)
    guard share >= 0.35 else { return nil }
    let sorted = tops.sorted(), top = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.85))]   // quasi la riga più alta: anche i sottotitoli su due righe restano sotto
    let r = NLLanguageRecognizer(); r.processString(texts.joined(separator: " "))
    return BurnedIn(top: top, share: share, lang: r.dominantLanguage?.rawValue, sample: texts.first ?? "")
}
