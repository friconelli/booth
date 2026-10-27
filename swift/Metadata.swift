import Foundation

/// Dati del film da Wikidata e Wikipedia (liberi, senza chiave). Servono solo il titolo e l'anno ricavati dal nome del file.
struct MovieMeta {
    var wikidataID: String; var title: String; var originalTitle: String?; var year: Int?; var directors: [String] = []; var runtimeMin: Double?
    var originalLang: String?; var posterURL: URL?; var summary: String?
    /// Nome file secondo la convenzione della libreria: «Titolo (Anno - Regista)».
    var libraryName: String {
        let t = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        let d = directors.joined(separator: ", ").replacingOccurrences(of: "/", with: "-")
        return t + (year.map { y in " (\(y)" + (d.isEmpty ? ")" : " - \(d))") } ?? "")
    }
}

/// Titolo e anno dal nome del file: «Titolo (1994 - Regista).mkv», «Titolo (1994).mkv», «Titolo.1994.1080p.BluRay.x264-GRUPPO.mkv».
func parseFileName(_ url: URL) -> (title: String, year: Int?, director: String?) {
    var base = url.deletingPathExtension().lastPathComponent
    base = base.replacingOccurrences(of: ".orig_backup", with: "")
    if let m = base.match(#"^(.*?)\s*\((\d{4})(?:\s*-\s*([^)]*))?\)"#) { return (m[1].trimmingCharacters(in: .whitespaces), Int(m[2]), m[3].isEmpty ? nil : m[3]) }
    if let m = base.match(#"^(.*?)[.\s_\[(-]+((?:19|20)\d{2})(?:[.\s_\])-]|$)"#) { return (m[1].replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces), Int(m[2]), nil) }
    let cleaned = base.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    return (cleaned.replacingOccurrences(of: #"\s*[\[(].*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces), nil, nil)
}

private func httpJSON(_ urlString: String) -> [String: Any]? {
    guard let u = URL(string: urlString) else { return nil }
    var rq = URLRequest(url: u, timeoutInterval: 15); rq.setValue("Booth/0.2 (https://github.com/friconelli/movie-preflight)", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0); var out: [String: Any]?
    URLSession.shared.dataTask(with: rq) { d, _, _ in if let d = d { out = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }; sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 20); return out
}
private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? s }

func fetchMovieMeta(for url: URL) -> MovieMeta? {
    let p = parseFileName(url); guard p.title.count >= 2 else { return nil }
    var cands: [String] = []
    // titolo intero e, se contiene «A - B», anche A e B separatamente (es. «Le Iene - Reservoir Dogs»)
    let queries = [p.title] + p.title.components(separatedBy: " - ").filter { $0.count >= 3 && $0 != p.title }
    for q in queries { for lang in ["it", "en"] {
        guard let r = httpJSON("https://www.wikidata.org/w/api.php?action=wbsearchentities&format=json&type=item&limit=10&language=\(lang)&uselang=\(lang)&search=\(enc(q))") else { continue }
        for x in r["search"] as? [[String: Any]] ?? [] { if let id = x["id"] as? String, !cands.contains(id) { cands.append(id) } }
    } }
    guard !cands.isEmpty, let r = httpJSON("https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=claims|labels|sitelinks&languages=it|en&ids=\(cands.prefix(20).joined(separator: "|"))"), let ents = r["entities"] as? [String: Any] else { return nil }
    func claims(_ e: [String: Any], _ prop: String) -> [[String: Any]] { ((e["claims"] as? [String: Any])?[prop] as? [[String: Any]] ?? []).compactMap { (($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? [String: Any] } }
    func label(_ e: [String: Any]) -> (it: String?, en: String?) { let l = e["labels"] as? [String: Any]; return (((l?["it"] as? [String: Any])?["value"]) as? String, ((l?["en"] as? [String: Any])?["value"]) as? String) }
    struct C { var id: String; var e: [String: Any]; var score: Int }
    var scored: [C] = []
    for id in cands { guard let e = ents[id] as? [String: Any] else { continue }
        let dates = claims(e, "P577").compactMap { ($0["time"] as? String).flatMap { Int($0.dropFirst().prefix(4)) } }
        let isFilm = !claims(e, "P57").isEmpty && !dates.isEmpty; guard isFilm else { continue }
        var sc = 1; let (it, en) = label(e)
        if let y = p.year { if dates.contains(y) { sc += 4 } else if dates.contains(where: { abs($0 - y) <= 1 }) { sc += 2 } else { sc -= 3 } }
        if queries.contains(where: { q in [it, en].compactMap({ $0?.lowercased() }).contains(q.lowercased()) }) { sc += 2 }
        scored.append(C(id: id, e: e, score: sc)) }
    guard let best = scored.max(by: { $0.score < $1.score }), best.score >= 3 || (scored.count == 1 && best.score >= 1) else { return nil }
    let e = best.e; let (it, en) = label(e)
    var m = MovieMeta(wikidataID: best.id, title: it ?? en ?? p.title, originalTitle: en != it ? en : nil)
    m.year = claims(e, "P577").compactMap { ($0["time"] as? String).flatMap { Int($0.dropFirst().prefix(4)) } }.min()
    m.runtimeMin = claims(e, "P2047").compactMap { ($0["amount"] as? String).flatMap { Double($0) } }.first
    let dirIDs = claims(e, "P57").compactMap { $0["id"] as? String }, langID = claims(e, "P364").compactMap { $0["id"] as? String }.first
    if let r2 = httpJSON("https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=labels|claims&languages=it|en&ids=\((dirIDs.prefix(4) + (langID.map { [$0] } ?? [])).joined(separator: "|"))"), let e2 = r2["entities"] as? [String: Any] {
        m.directors = dirIDs.prefix(4).compactMap { (e2[$0] as? [String: Any]).flatMap { label($0).en ?? label($0).it } }
        if let l = langID, let le = e2[l] as? [String: Any] { m.originalLang = claims(le, "P218").compactMap { $0["id"] as? String ?? nil }.first; if m.originalLang == nil, let c = (le["claims"] as? [String: Any])?["P218"] as? [[String: Any]] { m.originalLang = c.compactMap { (($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? String }.first } }
    }
    // poster e descrizione da Wikipedia (italiano, poi inglese)
    let links = e["sitelinks"] as? [String: Any]
    for (code, key) in [("it", "itwiki"), ("en", "enwiki")] {
        guard let t = (links?[key] as? [String: Any])?["title"] as? String, let s = httpJSON("https://\(code).wikipedia.org/api/rest_v1/page/summary/\(enc(t.replacingOccurrences(of: " ", with: "_")))") else { continue }
        if m.summary == nil, let x = s["extract"] as? String, !x.isEmpty { m.summary = x }
        if m.posterURL == nil, let th = (s["thumbnail"] as? [String: Any])?["source"] as? String { m.posterURL = URL(string: th) }
        if m.summary != nil && m.posterURL != nil { break }
    }
    return m
}

/// Interrogazioni online (Wikidata/Wikipedia): attive solo se l'utente ha acconsentito (nell'app) o con --online (riga di comando).
var onlineLookups = false

private func norm(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber } }

/// Confronta il file con i dati del film: durata attesa, lingua originale, nome secondo la convenzione della libreria.
func metaFindings(_ pr: Probe, _ url: URL, _ m: MovieMeta, _ c: Collector) {
    var rows: [(String, String)] = [("Titolo", m.title)]
    if let o = m.originalTitle { rows.append(("Titolo originale", o)) }
    if let y = m.year { rows.append(("Anno", "\(y)")) }
    if !m.directors.isEmpty { rows.append(("Regia", m.directors.joined(separator: ", "))) }
    if let r = m.runtimeMin { rows.append(("Durata attesa", "\(Int(r)) min")) }
    if let l = m.originalLang { rows.append(("Lingua originale", langLabel(iso2[l] ?? l))) }
    rows.append(("Fonte", "Wikidata \(m.wikidataID)"))
    c.rows("Film (dati online)", order: -1, rows)
    if let r = m.runtimeMin, pr.duration > 0 {
        let diff = pr.duration / 60 - r
        if diff < -max(10, 0.15 * r) { c.add(.warn, "File", "Il film dura meno del previsto", String(format: "Il file dura %@ ma il film dovrebbe durare circa %d minuti: potrebbe essere tagliato o incompleto.", hms(pr.duration), Int(r))) }
        else if diff > max(12, 0.2 * r) { c.add(.info, "File", "Il film dura più del previsto", String(format: "Il file dura %@ ma la durata nota è circa %d minuti: forse è una versione estesa, o ci sono titoli di coda molto lunghi.", hms(pr.duration), Int(r))) }
    }
    if let ol = m.originalLang, ol != "it", !pr.audio.contains(where: { (langNames[lang($0)]?.nl.replacingOccurrences(of: "nb", with: "no")) == ol }) {
        c.add(.info, "Audio", "Manca la traccia audio in lingua originale (\(langLabel(iso2[ol] ?? ol)))", "Il film è in \(langLabel(iso2[ol] ?? ol)); nel file ci sono solo: " + (pr.audio.map { langLabel(lang($0)) }.joined(separator: ", ")) + ".")
    }
    // nome del file secondo la convenzione «Titolo (Anno - Regista)»
    let p = parseFileName(url); let current = url.deletingPathExtension().lastPathComponent
    guard !current.contains(".orig_backup") else { return }
    var mm = m
    let titleOK = !p.title.isEmpty && [m.title, m.originalTitle ?? ""].contains { !$0.isEmpty && (norm($0).contains(norm(p.title)) || norm(p.title).contains(norm($0))) }
    if titleOK { mm.title = p.title }
    let expected = mm.libraryName
    if norm(current) != norm(expected) { c.add(.info, "File", "Il nome del file non segue lo schema «Titolo (Anno - Regista)»", "Nome suggerito: «\(expected)».", fix: [.rename(expected)]) }
}
