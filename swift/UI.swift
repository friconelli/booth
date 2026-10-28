import SwiftUI
import UniformTypeIdentifiers
import AppKit

final class Job: ObservableObject, Identifiable {
    let id = UUID(); @Published var url: URL
    @Published var progress = 0.0; @Published var stage = "In coda"; @Published var report: Report?
    @Published var fixProgress: Double?; @Published var fixStage = ""; @Published var fixResult: FixResult?
    @Published var origURL: URL?; @Published var origReport: Report?; @Published var fixLog: [String] = []   // originale (mai toccato) e suo rapporto, per il confronto prima/dopo
    var hasCorrected: Bool { origURL != nil && origURL != url }
    init(_ u: URL) { url = u }
}
final class Store: ObservableObject {
    @Published var jobs: [Job] = []; @Published var selection: UUID?; @Published var modelProgress: Double?; @Published var comparePair: ComparePair?; @Published var compareBusy = false; @Published var compareStatus = ""; @Published var compareProgress = 0.0; @Published var mergeRequest: MergeRequest?; @Published var better: BetterVerdict?
    private let q = DispatchQueue(label: "analisi")   // un film alla volta: le analisi usano già tutti i core
    static let exts: Set<String> = ["mp4", "mkv", "avi", "m4v", "mov"]
    func add(_ urls: [URL]) {
        guard !compareBusy else { return }   // durante l'analisi del confronto l'app non fa altro
        let files = urls.flatMap { u -> [URL] in
            var d: ObjCBool = false; FileManager.default.fileExists(atPath: u.path, isDirectory: &d)
            if d.boolValue { return ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path } }; return [u] }
            .filter { Store.exts.contains($0.pathExtension.lowercased()) }
        if !files.isEmpty { askOnline() }
        if !files.isEmpty && whisperModelPath() == nil && tool("whisper-cli") != nil && !UserDefaults.standard.bool(forKey: "speechOfferAsked") && ProcessInfo.processInfo.environment["BOOTH_NOPROMPT"] == nil { UserDefaults.standard.set(true, forKey: "speechOfferAsked"); offerSpeechModel() }
        for u in files { let j = Job(u); jobs.append(j); selection = j.id; startAnalysis(j) }
    }
    func startAnalysis(_ j: Job) {
        j.report = nil; j.progress = 0; j.stage = "In coda"; j.fixResult = nil
        q.async { [weak j] in
            guard let j = j else { return }
            let r = analyze(j.url) { p, s in DispatchQueue.main.async { j.progress = p; j.stage = s } }
            DispatchQueue.main.async {
                j.report = r; j.progress = 1; setVerdictTag(j.url, ok: r.essential.isEmpty)
                if ProcessInfo.processInfo.environment["BOOTH_AUTOFIX"] != nil, j.origURL == nil {   // solo per le prove a vista: applica le correzioni sicure senza chiedere
                    var p = FixPlan(); r.findings.forEach { $0.fixes.filter { !isHeavy($0) }.forEach { p.merge($0) } }; p.rename = nil; if !p.isEmpty { self.fix(j, p) } }
            }
        }
    }
    /// Chiede il consenso e scarica il modello vocale (whisper, open source, 148 MB) per i controlli sulla lingua parlata e sulla sincronia dei sottotitoli.
    func offerSpeechModel() {
        guard !compareBusy else { return }
        let a = NSAlert()
        if whisperModelPath() != nil { a.messageText = "Controlli sul parlato attivi"; a.informativeText = "Il modello vocale è già installato."; a.runModal(); return }
        a.messageText = "Controlli sul parlato"
        a.informativeText = "Per verificare la lingua realmente parlata nelle tracce audio e la sincronia dei sottotitoli serve un modello vocale open source (whisper, 148 MB, scaricato una sola volta). I film non vengono mai inviati da nessuna parte: l'analisi resta sul tuo Mac."
        a.addButton(withTitle: "Scarica"); a.addButton(withTitle: "Non ora")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        modelProgress = 0
        DispatchQueue.global().async { [weak self] in
            let ok = downloadWhisperModel { p in DispatchQueue.main.async { self?.modelProgress = p } }
            DispatchQueue.main.async {
                self?.modelProgress = nil
                if !ok { let e = NSAlert(); e.messageText = "Scaricamento non riuscito"; e.informativeText = "Controlla la connessione e riprova da File → Controlli sul parlato…"; e.runModal() }
                else { let e = NSAlert(); e.messageText = "Modello scaricato"; e.informativeText = "Premi «Rianalizza» sui film già analizzati per aggiungere i controlli sul parlato."; e.runModal() }
            }
        }
    }
    /// Applica una correzione (una per volta, dopo l'analisi in corso) e poi rianalizza il film per mostrare l'effetto.
    func fix(_ j: Job, _ plan: FixPlan) {
        var p = plan; let newBase = p.rename; p.rename = nil; if p.setTitle == nil, let n = newBase { p.setTitle = n }   // il titolo nei metadati segue il nuovo nome
        let source = j.url, editing = j.hasCorrected, orig = j.origURL ?? j.url, origReport = j.origReport ?? j.report
        let output = editing ? j.url : correctedURL(for: j.url, rename: newBase)
        j.fixProgress = 0; j.fixStage = "In attesa…"; j.fixResult = nil
        q.async {
            var r: FixResult
            if p.isEmpty {
                if editing { r = FixResult(ok: true, message: "Nessuna modifica al contenuto.", newURL: output) }
                else { do { try cloneFile(source, output); r = FixResult(ok: true, message: "Creata «\(output.lastPathComponent)» (copia istantanea). L'originale non è stato toccato.", newURL: output) } catch { r = FixResult(ok: false, message: "Non riesco a creare la copia: \(error.localizedDescription)") } }
            } else { r = applyFix(source, p, output: output) { v, s in DispatchQueue.main.async { j.fixProgress = v; j.fixStage = s } } }
            if r.ok, editing, let nb = newBase {   // rinomina della copia corretta (è un file dell'app, non l'originale)
                let dest = correctedURL(for: output, rename: nb)
                if (try? FileManager.default.moveItem(at: output, to: dest)) != nil { r = FixResult(ok: true, message: r.message + " Rinominata in «\(dest.lastPathComponent)».", lines: r.lines, backup: nil, newURL: dest) }
            }
            let target = r.newURL ?? output
            let rep = r.ok ? analyze(target) : nil
            DispatchQueue.main.async {
                if r.ok { if j.origURL == nil { j.origURL = orig; j.origReport = origReport }; j.url = target; j.fixLog += r.lines }
                j.fixResult = r; j.fixProgress = nil; if let rep = rep { j.report = rep; setVerdictTag(target, ok: rep.essential.isEmpty) }
            }
        }
    }
    /// «Prepara per la sala»: mostra le correzioni che servono e quello che resta da fare a mano, poi corregge, rianalizza il film nuovo, lo scarta se è peggiorato
    /// e scrive accanto la scheda per la sala.
    func prepare(_ j: Job) {
        guard let rep = j.report, j.fixProgress == nil else { return }
        let pp = preparePlan(rep), lines = pp.plan.summary(rep), manual = pp.unresolved.map { "• " + splitTitle($0.title).0 }
        let a = NSAlert()
        if lines.isEmpty {
            a.messageText = pp.unresolved.isEmpty ? "Il film è già pronto per la sala" : "Booth da solo non può sistemare questo film"
            a.informativeText = (pp.unresolved.isEmpty ? "Non c'è niente da correggere. Salvo accanto al film la scheda con i consigli per la proiezione?" : "Da risolvere a mano o con un'altra copia («Unisci»):\n" + manual.joined(separator: "\n") + "\n\nSalvo comunque la scheda accanto al film?")
            a.addButton(withTitle: "Salva la scheda"); a.addButton(withTitle: "Annulla")
            if a.runModal() == .alertFirstButtonReturn, let u = writeScreeningSheet(rep, done: [], original: j.origURL) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            return
        }
        let editing = j.hasCorrected, output = editing ? j.url : correctedURL(for: j.url)
        a.messageText = "Preparare il film per la sala?"
        a.informativeText = lines.map { "• " + $0 }.joined(separator: "\n") + (manual.isEmpty ? "" : "\n\nDa risolvere a mano o con un'altra copia:\n" + manual.joined(separator: "\n"))
            + "\n\n" + (editing ? "La copia corretta verrà aggiornata." : "Verrà creata «\(output.lastPathComponent)» accanto al film.") + " Poi Booth la ricontrolla da capo: se qualcosa peggiora la scarta. Accanto al film salva la scheda per la sala. L'originale non viene mai modificato."
        a.addButton(withTitle: "Prepara"); a.addButton(withTitle: "Annulla"); guard a.runModal() == .alertFirstButtonReturn else { return }
        let source = j.url, orig = j.origURL ?? j.url, origReport = j.origReport ?? rep
        j.fixProgress = 0; j.fixStage = "In attesa…"; j.fixResult = nil
        q.async {
            var r = applyFix(source, pp.plan, output: output) { v, s in DispatchQueue.main.async { j.fixProgress = v * 0.8; j.fixStage = s } }
            var after: Report?
            if r.ok {
                DispatchQueue.main.async { j.fixStage = "Ricontrollo il film corretto…" }
                let ar = analyze(output) { v, _ in DispatchQueue.main.async { j.fixProgress = 0.8 + v * 0.2 } }
                if let why = checkPrepared(before: rep, after: ar, fixLines: r.lines) {
                    if !editing { try? FileManager.default.trashItem(at: output, resultingItemURL: nil) }
                    r = FixResult(ok: false, message: "Preparazione annullata: \(why). " + (editing ? "" : "La copia è nel Cestino; ") + "l'originale non è stato toccato.", lines: r.lines)
                } else {
                    after = ar; let sheet = writeScreeningSheet(ar, done: lines, original: orig)
                    r.message = (ar.essential.isEmpty ? "Pronto per la sala." : "Migliorato, ma resta qualcosa da guardare.") + (sheet.map { " Scheda salvata: «\($0.lastPathComponent)»." } ?? "") + " L'originale non è stato toccato."
                }
            }
            DispatchQueue.main.async {
                if r.ok, let ar = after { if j.origURL == nil { j.origURL = orig; j.origReport = origReport }; j.url = output; j.fixLog += r.lines; j.report = ar; setVerdictTag(output, ok: ar.essential.isEmpty) }
                j.fixResult = r; j.fixProgress = nil
            }
        }
    }
    /// Mostra tutto quello che verrà fatto e applica solo dopo il consenso (Correggi / Altre opzioni… / Annulla).
    func confirmFix(_ j: Job, _ plan: FixPlan, more: @escaping () -> Void) {
        guard let rep = j.report else { return }
        let lines = plan.summary(rep); guard !lines.isEmpty else { return }
        let a = NSAlert(); a.messageText = lines.count == 1 ? "Correggere questo?" : "Correggere queste cose?"
        let dest = j.hasCorrected ? "La copia corretta «\(j.url.lastPathComponent)» verrà aggiornata." : "Verrà creata la copia «\(correctedURL(for: j.url, rename: plan.rename).lastPathComponent)» accanto al film."
        a.informativeText = lines.map { "• " + $0 }.joined(separator: "\n") + "\n\n" + dest + " L'originale non viene mai modificato e potrai confrontare prima e dopo."
        a.addButton(withTitle: "Correggi"); a.addButton(withTitle: "Altre opzioni…"); a.addButton(withTitle: "Annulla")
        switch a.runModal() { case .alertFirstButtonReturn: fix(j, plan); case .alertSecondButtonReturn: more(); default: break }
    }
    /// Elimina la copia corretta (va nel Cestino) e torna all'originale, che non è mai stato toccato.
    func discardCorrected(_ j: Job) {
        guard j.hasCorrected, let o = j.origURL else { return }
        let a = NSAlert(); a.messageText = "Eliminare la copia corretta?"; a.informativeText = "«\(j.url.lastPathComponent)» va nel Cestino. L'originale «\(o.lastPathComponent)» resta com'è."
        a.addButton(withTitle: "Elimina la copia"); a.addButton(withTitle: "Annulla"); guard a.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: j.url, resultingItemURL: nil)
        j.url = o; j.report = j.origReport; j.origURL = nil; j.origReport = nil; j.fixResult = nil; j.fixLog = []
    }
    /// Confronta due film qualsiasi (per esempio un originale e la sua versione corretta, anche di versioni precedenti dell'app): li analizza se serve e apre il confronto.
    func compareFiles() {
        guard !compareBusy else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.message = "Scegli le due copie da confrontare (⌘-clic per sceglierne due)"
        guard p.runModal() == .OK else { return }
        guard p.urls.count == 2 else { let a = NSAlert(); a.messageText = "Servono due film"; a.informativeText = "Seleziona esattamente due file (⌘-clic per sceglierne due)."; a.runModal(); return }
        compare(p.urls)
    }
    func compare(_ urls: [URL]) {
        // «prima» è quello chiamato .orig_backup, altrimenti il più vecchio
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var pair = urls
        if pair[1].lastPathComponent.contains(".orig_backup") && !pair[0].lastPathComponent.contains(".orig_backup") { pair.reverse() }
        else if !pair[0].lastPathComponent.contains(".orig_backup") && date(pair[1]) < date(pair[0]) { pair.reverse() }
        compareBusy = true; compareProgress = 0; compareStatus = "Preparo l'analisi…"
        q.async { [weak self] in
            func rep(_ u: URL, _ n: Int) -> Report {
                var existing: Report?; DispatchQueue.main.sync { existing = self?.jobs.first { $0.url == u }?.report }
                return existing ?? analyze(u) { p, st in DispatchQueue.main.async { self?.compareProgress = (Double(n) + p) / 2; self?.compareStatus = "Film \(n + 1) di 2 · \(u.lastPathComponent)\n\(st)" } }
            }
            let a = rep(pair[0], 0), b = rep(pair[1], 1)
            let src = [loadMergeSource(pair[0], src: 0), loadMergeSource(pair[1], src: 1)]
            var dub: DubCheck?
            if let x = src[0], let y = src[1] { dub = dubCheckBetween([x, y]) { p, st in DispatchQueue.main.async { self?.compareProgress = 0.99; self?.compareStatus = "Sincronia del doppiaggio · \(st)" } } }
            DispatchQueue.main.async {
                self?.compareBusy = false
                if let x = src[0], let y = src[1] { self?.better = whichIsBetter([x, y], [a, b], dub: dub) } else { self?.comparePair = ComparePair(before: pair[0], beforeReport: a, after: pair[1], afterReport: b) }
            }
        }
    }
    /// Rimette a tempo il doppiaggio della copia italiana con l'originale dell'altra copia; il risultato si apre e si ricontrolla come ogni film.
    func fixDub(_ urls: [URL], _ d: DubCheck) {
        guard !compareBusy, let x = loadMergeSource(urls[0], src: 0), let y = loadMergeSource(urls[1], src: 1) else { return }
        compareBusy = true; compareProgress = 0; compareStatus = "Rimetto a tempo il doppiaggio…"
        q.async { [weak self] in
            let r = retimeDubFromOther([x, y], d) { p, st in DispatchQueue.main.async { self?.compareProgress = p; self?.compareStatus = "Rimetto a tempo il doppiaggio\n\(st)" } }
            DispatchQueue.main.async {
                self?.compareBusy = false
                let a = NSAlert(); a.messageText = r.ok ? "Doppiaggio rimesso a tempo" : "Doppiaggio non corretto"; a.informativeText = r.message + (r.lines.isEmpty ? "" : "\n\n" + r.lines.suffix(6).joined(separator: "\n")); a.runModal()
                if let u = r.newURL { self?.add([u]) }
            }
        }
    }
    /// Unisce due copie dello stesso film: l'immagine migliore da una, l'audio italiano dall'altra.
    func mergeFiles() {
        guard !compareBusy else { return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.message = "Scegli le due copie dello stesso film (⌘-clic per sceglierne due)"
        guard p.runModal() == .OK else { return }
        guard p.urls.count == 2 else { let a = NSAlert(); a.messageText = "Servono due film"; a.informativeText = "Seleziona esattamente due file: per esempio quello con l'immagine migliore e quello con l'audio italiano."; a.runModal(); return }
        mergeRequest = MergeRequest(urls: p.urls)
    }
    /// Consenso alle ricerche online (solo il titolo ricavato dal nome del file viene inviato a Wikidata e Wikipedia).
    func askOnline(force: Bool = false) {
        guard !compareBusy || !force else { return }
        if ProcessInfo.processInfo.environment["BOOTH_NOPROMPT"] != nil { onlineLookups = ProcessInfo.processInfo.environment["BOOTH_ONLINE"] != nil; return }   // solo per le prove a vista
        if !force && UserDefaults.standard.object(forKey: "metaConsent") != nil { return }
        let a = NSAlert(); a.messageText = "Cercare i dati del film online?"
        a.informativeText = "Booth può trovare titolo, anno, regista, durata, locandina e descrizione su Wikidata e Wikipedia (servizi liberi, nessuna chiave). Per farlo invia soltanto il titolo e l'anno ricavati dal nome del file: i film non vengono mai inviati. Servono per confrontare la durata, suggerire il nome del file e mostrare la scheda del film."
        a.addButton(withTitle: UserDefaults.standard.bool(forKey: "metaConsent") ? "Lascia attivo" : "Consenti"); a.addButton(withTitle: UserDefaults.standard.bool(forKey: "metaConsent") ? "Disattiva" : "Non ora")
        let yes = a.runModal() == .alertFirstButtonReturn; UserDefaults.standard.set(yes, forKey: "metaConsent"); onlineLookups = yes
    }
    init() {
        onlineLookups = UserDefaults.standard.bool(forKey: "metaConsent")   // il consenso dato in precedenza vale anche ai prossimi avvii
        let e = ProcessInfo.processInfo.environment   // solo per le prove a vista
        if let a = e["BOOTH_MERGE_A"], let b = e["BOOTH_MERGE_B"] { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.mergeRequest = MergeRequest(urls: [URL(fileURLWithPath: a), URL(fileURLWithPath: b)]) } }
        if let a = e["BOOTH_COMPARE_A"], let b = e["BOOTH_COMPARE_B"] { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.compare([URL(fileURLWithPath: a), URL(fileURLWithPath: b)]) } }
    }
    func open() { guard !compareBusy else { return }; let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true; p.message = "Scegli uno o più film"; if p.runModal() == .OK { add(p.urls) } }
}

extension Sev {
    var color: Color { switch self { case .ok: return .green; case .info: return .blue; case .warn: return .orange; case .error: return .red } }
    var symbol: String { ["checkmark.circle.fill", "info.circle.fill", "exclamationmark.triangle.fill", "xmark.octagon.fill"][rawValue] }
}

struct ContentView: View {
    @ObservedObject var store: Store; @State private var hover = false
    var body: some View {
        Group {
            if store.jobs.isEmpty { DropHint(store: store).sheet(item: $store.mergeRequest) { r in MergeView(urls: r.urls, store: store) } }
            else { HStack(spacing: 0) {
                if store.jobs.count > 1 { List(store.jobs, selection: $store.selection) { j in JobRow(job: j).tag(j.id) }.frame(width: 250).listStyle(.sidebar); Divider() }   // la barra laterale serve solo con più film
                if let j = store.jobs.first(where: { $0.id == store.selection }) { JobDetail(job: j, store: store).id(j.id) } else { Spacer() }
            }.sheet(item: $store.mergeRequest) { r in MergeView(urls: r.urls, store: store) } }
        }
        .frame(minWidth: 900, minHeight: 600)
        .overlay { if store.compareBusy { CompareBusyOverlay(store: store) } }
        .sheet(item: $store.better) { v in BetterView(v: v, sideBySide: { store.better = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.comparePair = ComparePair(before: v.urls[0], beforeReport: v.reports[0], after: v.urls[1], afterReport: v.reports[1]) } },
                                                         merge: { store.better = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.mergeRequest = MergeRequest(urls: v.urls) } },
                                                         fixDub: { store.better = nil; if let d = v.dub { store.fixDub(v.urls, d) } }) }
        .sheet(item: $store.comparePair) { pair in CompareView(pair: pair, swap: { store.comparePair = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.comparePair = pair.swapped } }) }
        .onDrop(of: [.fileURL], isTargeted: $hover) { ps in
            guard !store.compareBusy else { return false }
            for p in ps { _ = p.loadObject(ofClass: URL.self) { u, _ in if let u = u { DispatchQueue.main.async { store.add([u]) } } } }; return true }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: hover ? 3 : 0).padding(6).allowsHitTesting(false))
        .toolbar {
            if let p = store.modelProgress { ToolbarItem { HStack { Text("Scarico il modello vocale…").font(.caption).foregroundStyle(.secondary); ProgressView(value: p).frame(width: 110) } } }
            if !store.jobs.isEmpty && !store.compareBusy {   // sulla schermata iniziale le tre scelte ci sono già
                ToolbarItem { Button { store.mergeFiles() } label: { Label("Unisci due copie", systemImage: "arrow.triangle.merge") }.help("Unisci due copie: immagine migliore da una, audio italiano dall'altra") }
                ToolbarItem { Button { store.compareFiles() } label: { Label("Confronta due film", systemImage: "rectangle.split.2x1") }.help("Quale delle due copie è meglio e perché") }
                ToolbarItem { Button { store.open() } label: { Label("Controlla un altro film", systemImage: "plus") }.help("Controlla un altro film") } }
        }
    }
}
/// Copre la finestra mentre si analizzano i due film da confrontare: niente altri clic finché non c'è il verdetto.
struct CompareBusyOverlay: View {
    @ObservedObject var store: Store
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 14) {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                Text("Confronto i due film").font(.title2.weight(.semibold))
                ProgressView(value: store.compareProgress).frame(width: 360)
                Text(store.compareStatus).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3).frame(width: 420)
                Text("Attendi la fine dell'analisi: nel frattempo l'app non fa altro.").font(.caption).foregroundStyle(.tertiary)
            }.padding(30).background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 18))
        }
    }
}
/// Schermata iniziale: le tre cose che l'app sa fare, ognuna con una riga di spiegazione e il suo pulsante.
struct DropHint: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Prepara un film per la sala").font(.largeTitle.weight(.semibold))
                Text("Trascina qui un film (mp4, mkv, avi), anche più di uno o una cartella intera.").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                Choice(icon: "checkmark.seal", title: "Controlla un film", text: "Immagine, audio e sottotitoli: lingue, volume, sincronia, crediti del torrent e difetti tecnici. Poi lo corregge in una copia nuova.", button: "Scegli un film…", primary: true) { store.open() }
                Choice(icon: "arrow.triangle.merge", title: "Unisci due copie", text: "Prende l'immagine migliore da una copia e l'audio italiano dall'altra, li allinea e te li fa controllare prima di salvare.", button: "Scegli le due copie…") { store.mergeFiles() }
                Choice(icon: "rectangle.split.2x1", title: "Confronta due film", text: "Due copie dello stesso film: ti dice quale è meglio per la sala e perché (immagine, audio italiano, sottotitoli, problemi).", button: "Scegli i due film…") { store.compareFiles() }
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: 820)
            Text("Il file originale non viene mai modificato: ogni correzione o unione crea una copia nuova accanto.").font(.caption).foregroundStyle(.tertiary)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct Choice: View {
    let icon: String, title: String, text: String, button: String; var primary = false; let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(primary ? Color.accentColor : .secondary).frame(height: 34, alignment: .leading)
            Text(title).font(.title3.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if primary { Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.large) } else { Button(button, action: action).controlSize(.large) }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(primary ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
    }
}
struct JobRow: View {
    @ObservedObject var job: Job
    var body: some View {
        HStack(spacing: 8) {
            if let r = job.report { Image(systemName: r.worst.symbol).foregroundStyle(r.worst.color) } else { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 1) {
                Text(job.report?.meta?.title ?? job.url.deletingPathExtension().lastPathComponent).lineLimit(2).font(.callout)
                Text(job.report?.verdict ?? job.stage).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
    }
}
struct FixBanner: View {
    let result: FixResult; var compare: (() -> Void)?; var reveal: (() -> Void)?; var discard: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(result.ok ? Color.green : Color.red).font(.system(size: 17))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.message).font(.callout.weight(.semibold)).textSelection(.enabled)
                ForEach(Array(result.lines.enumerated()), id: \.offset) { Text($0.element).font(.callout.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled) }
                if result.ok && (compare != nil) { HStack {
                    Button { compare?() } label: { Label("Confronta prima e dopo", systemImage: "rectangle.split.2x1") }.controlSize(.small).buttonStyle(.borderedProminent)
                    Button("Mostra nel Finder") { reveal?() }.controlSize(.small)
                    Button("Elimina la copia corretta") { discard?() }.controlSize(.small) }.padding(.top, 3) }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill((result.ok ? Color.green : Color.red).opacity(0.09)))
    }
}
