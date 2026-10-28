import Foundation

/// «Prepara per la sala»: dal rapporto di un film, le correzioni che servono davvero per la proiezione e quello che Booth da solo non può risolvere.
/// Entrano tutte le correzioni delle segnalazioni indispensabili (anche quelle lunghe, come HDR → SDR) e, tra le migliorie, solo quelle sicure che
/// non cambiano il suono né l'immagine (etichette, titolo, accenti, pubblicità nei sottotitoli). Niente conversioni in Dolby né regolazioni del volume:
/// con il proiettore e l'impianto della sala non servono, e ogni ricodifica in più è un rischio in più.
struct PrepPlan { var plan: FixPlan; var unresolved: [Finding] }
func preparePlan(_ r: Report) -> PrepPlan {
    var p = FixPlan(), unresolved: [Finding] = []
    for f in r.essential {
        if f.fixes.isEmpty { unresolved.append(f) } else { f.fixes.forEach { p.merge($0) } }
    }
    for f in r.extras {
        for h in f.fixes {
            switch h {
            case .setTitle, .clearTitle, .setLang, .setLangTo, .defaultAudio, .repairEncoding, .cleanSub, .setForced: p.merge(h)
            case .boostCenter where f.sev >= .warn && f.title.hasPrefix("Musica ed effetti coprono i dialoghi"): p.merge(h)   // solo se la musica copre davvero i dialoghi
            default: break
            }
        }
    }
    p.rename = nil
    return PrepPlan(plan: p, unresolved: unresolved)
}

/// Controllo finale dopo la preparazione: il film nuovo non deve avere segnalazioni indispensabili nuove e deve averne meno di prima.
/// Se passa, scrive accanto al film la scheda per la sala. Restituisce nil se va bene, altrimenti il motivo.
func checkPrepared(before: Report, after: Report, fixLines: [String]) -> String? {
    let old = Set(before.essential.map(\.sig)), new = after.essential.filter { !old.contains($0.sig) }
    if let n = new.first { return "il film corretto ha un problema che prima non c'era: «\(splitTitle(n.title).0)»" }
    if !before.essential.isEmpty && after.essential.count >= before.essential.count { return "le correzioni non hanno risolto nessuna delle cose indispensabili" }
    return nil
}
/// La scheda per la sala, accanto al film: esito, consigli per la proiezione, cosa ha fatto Booth e cosa resta da guardare.
@discardableResult
func writeScreeningSheet(_ r: Report, done: [String], original: URL?) -> URL? {
    let u = r.file.deletingLastPathComponent().appendingPathComponent(r.file.deletingPathExtension().lastPathComponent + " — scheda per la sala.txt")
    let df = DateFormatter(); df.locale = Locale(identifier: "it_IT"); df.dateStyle = .long; df.timeStyle = .short
    var s = "SCHEDA PER LA SALA — \(r.file.lastPathComponent)\nPreparata da Booth il \(df.string(from: Date())) per il proiettore \(Projector.label)\n"
    if let o = original { s += "Dal file originale «\(o.lastPathComponent)», che non è stato toccato.\n" }
    s += "\nESITO: \(r.verdict)\n"
    if !r.tips.isEmpty { s += "\nCONSIGLI PER LA PROIEZIONE\n" + r.tips.map { "• \($0.title): \($0.text)" }.joined(separator: "\n") + "\n" }
    if !done.isEmpty { s += "\nCOSA HA FATTO BOOTH\n" + done.map { "• " + $0 }.joined(separator: "\n") + "\n" }
    let todo = r.essential + r.extras.filter { $0.sev >= .warn }
    if !todo.isEmpty { s += "\nDA GUARDARE PRIMA DELLA PROIEZIONE\n" + todo.map { "• " + $0.title + ($0.time.map { " (a \(hms($0)))" } ?? "") }.joined(separator: "\n") + "\n" }
    var full = r; full.tips = []; s += "\n" + full.text   // i consigli sono già in cima
    do { try s.write(to: u, atomically: true, encoding: .utf8); return u } catch { return nil }
}

/// Tutto il percorso, senza interfaccia (riga di comando e prove): analisi, correzioni, nuova analisi del film corretto, controllo e scheda.
func prepareForScreening(_ url: URL, output: URL? = nil, progress: @escaping (Double, String) -> Void = { _, _ in }) -> FixResult {
    progress(0, "Controllo del film…")
    let before = analyze(url) { p, s in progress(p * 0.3, s) }
    let pp = preparePlan(before)
    let manual = pp.unresolved.map { "Da risolvere a mano o con un'altra copia: " + splitTitle($0.title).0 }
    if pp.plan.isEmpty {
        let sheet = writeScreeningSheet(before, done: [], original: nil)
        return FixResult(ok: pp.unresolved.isEmpty, message: pp.unresolved.isEmpty ? "Il film è già pronto per la sala: niente da correggere." + (sheet.map { " Scheda: «\($0.lastPathComponent)»." } ?? "") : "Booth non può correggere da solo quello che serve.", lines: manual)
    }
    let out = output ?? correctedURL(for: url)
    var r = applyFix(url, pp.plan, output: out) { p, s in progress(0.3 + p * 0.5, s) }
    guard r.ok else { return r }
    progress(0.85, "Controllo del film corretto…")
    let after = analyze(out) { p, s in progress(0.85 + p * 0.14, s) }
    if let why = checkPrepared(before: before, after: after, fixLines: r.lines) {
        try? FileManager.default.trashItem(at: out, resultingItemURL: nil)
        return FixResult(ok: false, message: "Preparazione annullata: \(why). La copia è stata spostata nel Cestino, l'originale non è stato toccato.", lines: r.lines)
    }
    setVerdictTag(out, ok: after.essential.isEmpty)
    let sheet = writeScreeningSheet(after, done: pp.plan.summary(before), original: url)
    r.message = (after.essential.isEmpty ? "Pronto per la sala: «\(out.lastPathComponent)»." : "Migliorato, ma resta qualcosa da guardare: «\(out.lastPathComponent)».") + (sheet.map { " Scheda: «\($0.lastPathComponent)»." } ?? "") + " L'originale non è stato toccato."
    r.lines += manual
    progress(1, "Fatto")
    return r
}
