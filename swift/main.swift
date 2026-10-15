import Foundation

func arg(_ n: String) -> [String] { CommandLine.arguments.enumerated().filter { $0.element == n && $0.offset + 1 < CommandLine.arguments.count }.map { CommandLine.arguments[$0.offset + 1] } }

if CommandLine.arguments.contains("--online") { onlineLookups = true }
if let f = arg("--analyze").first {
    let r = analyze(URL(fileURLWithPath: f)) { p, s in FileHandle.standardError.write(Data(String(format: "\r%3.0f%% %@                    ", p * 100, s).utf8)) }
    FileHandle.standardError.write(Data("\n".utf8)); if CommandLine.arguments.contains("--tag") { setVerdictTag(URL(fileURLWithPath: f), ok: r.essential.isEmpty) }; print(r.text); print(String(format: "(analisi in %.0f s)", r.seconds)); exit(0)
}
if let f = arg("--dialogue").first {   // prova: --dialogue FILE ORD
    let ord = Int(arg("--dialogue-ord").first ?? "0") ?? 0
    if let d = dialogueStats(f, ord) { print(String(format: "centro %.1f  fronte %.1f  >6LU %.1f%%  >10LU %.1f%%  (%d s con parlato)  peggiori: %@", d.centerMedian, d.frontMedian, d.coveredPct, d.covered10Pct, d.seconds, d.worst.prefix(5).map { "\(hms(Double($0.0)))(\(Int($0.1)))" }.joined(separator: " "))) } else { print("non misurabile") }
    exit(0)
}
if let f = arg("--meta").first {   // prova: cerca i dati del film dal nome del file
    let u = URL(fileURLWithPath: f); let p = parseFileName(u); print("dal nome: titolo «\(p.title)» anno \(p.year.map(String.init) ?? "—") regista \(p.director ?? "—")")
    if let m = fetchMovieMeta(for: u) { print("trovato \(m.wikidataID): «\(m.title)» (\(m.originalTitle ?? "—")) \(m.year.map(String.init) ?? "—") · \(m.directors.joined(separator: ", ")) · \(m.runtimeMin.map { "\(Int($0)) min" } ?? "durata ?") · lingua \(m.originalLang ?? "?") · poster \(m.posterURL != nil ? "sì" : "no")\nnome libreria: \(m.libraryName)\n\(String((m.summary ?? "").prefix(160)))") } else { print("non trovato") }
    exit(0)
}
// Correzioni da riga di comando (per i test): --fix FILE [--audio-default N] [--sub-default none|N] [--lang a0=ita,s1=eng] [--clean-sub N] [--drop-sub N] [--drop-audio N] [--erase-text] [--normalize N]   (N parte da 0)
if let f = arg("--fix").first {
    var p = FixPlan()
    p.audioDefault = arg("--audio-default").first.flatMap { Int($0) }
    if let s = arg("--sub-default").first { p.subDefault = s == "none" ? .none : Int(s).map { .track($0) } ?? .keep }
    for l in arg("--lang") { for kv in l.split(separator: ",") { let x = kv.split(separator: "="); if x.count == 2 { p.lang[String(x[0])] = String(x[1]) } } }
    arg("--clean-sub").compactMap { Int($0) }.forEach { p.cleanSubs.insert($0) }; arg("--drop-sub").compactMap { Int($0) }.forEach { p.dropSubs.insert($0) }
    arg("--drop-audio").compactMap { Int($0) }.forEach { p.dropAudio.insert($0) }; arg("--normalize").compactMap { Int($0) }.forEach { p.normalize.insert($0) }; if let r = arg("--rename").first { p.rename = r }; arg("--repair-sub").compactMap { Int($0) }.forEach { p.repairSubs.insert($0) }; for v in arg("--forced") { let x = v.split(separator: ":"); if x.count == 2, let i = Int(x[0]) { p.forcedFlags[i] = x[1] == "1" } }; if CommandLine.arguments.contains("--tonemap") { p.tonemap = true }; if CommandLine.arguments.contains("--deinterlace") { p.deinterlace = true }; for v in arg("--sync-sub") { let x = v.split(separator: ":").compactMap { Double($0) }; if x.count == 3 { p.syncSubs[Int(x[0])] = (x[1], x[2]) } }; if CommandLine.arguments.contains("--clear-title") { p.clearTitle = true }; arg("--dolby").compactMap { Int($0) }.forEach { p.toDolby.insert($0) }; arg("--level").compactMap { Int($0) }.forEach { p.levelGain.insert($0) }; if let d = arg("--boost-db").first.flatMap({ Double($0) }) { p.centerDB = d }; arg("--boost-center").compactMap { Int($0) }.forEach { p.boostCenter.insert($0) }
    for v in arg("--erase-at") { let n = v.split(separator: ",").compactMap { Double($0) }; if n.count == 6 { p.eraseText.append(EraseRegion(x: n[0], y: n[1], w: n[2], h: n[3], from: n[4], to: n[5], label: "prova")) } }   // prova: x,y,w,h (frazioni, origine in alto a sinistra),da,a
    if CommandLine.arguments.contains("--erase-text") { analyze(URL(fileURLWithPath: f)) { _, _ in }.findings.flatMap(\.fixes).forEach { if case .eraseText = $0 { p.merge($0) } } }   // cancella le scritte pubblicitarie che l'analisi trova nei primi secondi
    // di default il risultato è una copia «… (corretto)» accanto al file: l'originale non viene mai toccato. --output PATH sceglie il nome, --replace modifica il file indicato (solo per copie già corrette e per i test)
    let src = URL(fileURLWithPath: f), replace = CommandLine.arguments.contains("--replace")
    var p2 = p; let nb = p2.rename; p2.rename = nil; if let t = arg("--set-title").first { p2.setTitle = t } else if let n = nb { p2.setTitle = n }
    let out: URL = arg("--output").first.map { URL(fileURLWithPath: $0) } ?? (replace ? src : correctedURL(for: src, rename: nb))
    var r: FixResult
    if p2.isEmpty {
        if out == src { r = FixResult(ok: true, message: "Nessuna modifica.") }
        else { do { try cloneFile(src, out); r = FixResult(ok: true, message: "Creata «\(out.lastPathComponent)». L'originale non è stato toccato.", newURL: out) } catch { r = FixResult(ok: false, message: "\(error.localizedDescription)") } }
    } else { r = applyFix(src, p2, output: out) { v, s in FileHandle.standardError.write(Data(String(format: "\r%3.0f%% %@                    ", v * 100, s).utf8)) } }
    if r.ok, replace, let nb = nb {   // --replace con --rename: la copia corretta prende il nuovo nome
        let dest = src.deletingLastPathComponent().appendingPathComponent(nb + "." + src.pathExtension)
        if FileManager.default.fileExists(atPath: dest.path) { r = FixResult(ok: false, message: "Esiste già un file chiamato «\(dest.lastPathComponent)»: non lo sovrascrivo.") }
        else if (try? FileManager.default.moveItem(at: src, to: dest)) != nil { r = FixResult(ok: true, message: r.message + " Rinominato in «\(dest.lastPathComponent)».", lines: r.lines, backup: nil, newURL: dest) }
    }
    FileHandle.standardError.write(Data("\n".utf8)); print((r.ok ? "OK: " : "ERRORE: ") + r.message); r.lines.forEach { print("  " + $0) }; exit(r.ok ? 0 : 1)
}
MoviePreflightApp.main()
