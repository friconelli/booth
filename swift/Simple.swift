import SwiftUI
import AppKit

/// Etichetta breve e chiara del pulsante per una correzione.
func fixLabel(_ h: FixHint) -> String {
    switch h {
    case .repairEncoding: return "Ripara gli accenti"
    case .cleanSub: return "Togli la pubblicità"
    case .defaultAudio: return "Imposta come predefinita"
    case .defaultSub: return "Spegni di default"
    case .setLang, .setLangTo: return "Imposta la lingua"
    case .setForced(_, let f): return f ? "Marca come forzati" : "Togli «forzati»"
    case .dropSub: return "Elimina la traccia"
    case .toDolby: return "Converti in Dolby"
    case .levelGain: return "Regola il volume"
    case .boostCenter: return "Alza i dialoghi"
    case .normalize: return "Compressione"
    case .eraseText: return "Togli la scritta"
    case .deinterlace: return "Deinterlaccia"
    case .tonemap: return "Converti in SDR"
    case .clearTitle: return "Togli il titolo"
    case .setTitle: return "Allinea il titolo al nome del file"
    case .syncSubs: return "Risincronizza"
    case .rename: return "Rinomina il file"
    }
}
/// Operazioni che «Correggi tutto» non include: cancellano tracce o richiedono una ricodifica lunga.
func isHeavy(_ h: FixHint) -> Bool { switch h { case .dropSub, .deinterlace, .tonemap, .normalize: return true; default: return false } }

/// Una correzione proposta, con le segnalazioni che la richiedono raggruppate (es. 40 battute con pubblicità = una sola voce).
struct FixItem: Identifiable { let id: String; var sev: Sev; var title: String; var detail: String; var hints: [FixHint]; var count: Int; var thumb: URL?; var times: [Double]; var area: String; var essential: Bool; var sigs: Set<String> }
func fixItems(_ r: Report) -> [FixItem] {
    var out: [FixItem] = []; var idx: [String: Int] = [:]
    for f in r.visible.sorted(by: { $0.sev > $1.sev }) where !f.fixes.isEmpty && f.sev > .ok {
        let key = f.fixes.map { String(describing: $0) }.joined(separator: "|")
        if let i = idx[key] { out[i].count += 1; out[i].sev = max(out[i].sev, f.sev); out[i].essential = out[i].essential || isEssential(f); out[i].sigs.insert(f.sig); if let t = f.time { out[i].times.append(t) }; if out[i].thumb == nil { out[i].thumb = f.thumb } }
        else { idx[key] = out.count; out.append(FixItem(id: key, sev: f.sev, title: f.title, detail: f.detail, hints: f.fixes, count: 1, thumb: f.thumb, times: f.time.map { [$0] } ?? [], area: f.area, essential: isEssential(f), sigs: [f.sig])) }
    }
    return out.sorted { $0.sev > $1.sev }
}

/// Sezione richiudibile: tutta la riga del titolo è cliccabile (il DisclosureGroup di macOS risponde solo alla freccina).
struct Accordion<Content: View>: View {
    let title: String; @Binding var expanded: Bool; var font: Font = .headline; @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) { Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 14)
                    Text(title).font(font); Spacer(minLength: 0) }
                .padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded { content().padding(.top, 6).padding(.leading, 22).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

/// Fotogramma del film a un dato secondo, estratto quando serve (e ricordato).
final class FrameCache {
    static let shared = FrameCache(); private var cache: [String: NSImage] = [:]; private let lock = NSLock()
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moviepreflight-frames"); private let q = DispatchQueue(label: "fotogrammi", qos: .utility)
    func frame(_ url: URL, _ t: Double, _ done: @escaping (NSImage?) -> Void) {
        let key = "\(url.path)@\(Int(t))"; lock.lock(); let hit = cache[key]; lock.unlock()
        if let h = hit { done(h); return }
        q.async { [self] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let img = CompareMedia.still(url, at: t, tmp: dir, name: UUID().uuidString)
            if let i = img { lock.lock(); cache[key] = i; lock.unlock() }
            DispatchQueue.main.async { done(img) }
        }
    }
}
struct FrameThumb: View {
    let url: URL; let time: Double; @State private var img: NSImage?
    var body: some View {
        ZStack { Rectangle().fill(Color.secondary.opacity(0.12)); if let i = img { Image(nsImage: i).resizable().scaledToFit() } else { ProgressView().controlSize(.small) } }
            .frame(width: 190, height: 107).cornerRadius(5).overlay(alignment: .bottomTrailing) { Text(hms(time)).font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.black.opacity(0.6))).foregroundColor(.white).padding(4) }
            .onAppear { FrameCache.shared.frame(url, time) { img = $0 } }
    }
}
/// «Ai secondi: 1:20, 5:03, 12:44 …»
func timesText(_ ts: [Double], more: Int) -> String { "Nei punti: " + ts.prefix(8).map { hms($0) }.joined(separator: " · ") + (ts.count > 8 || more > 0 ? " …" : "") }

/// Titolo breve in italiano semplice: «Caratteri rovinati — sottotitoli 2 (italiano)» → («Caratteri rovinati», «Sottotitoli 2 · italiano»).
func splitTitle(_ t: String) -> (String, String) {
    let parts = t.components(separatedBy: " — ")
    guard parts.count >= 2 else { return (t, "") }
    var ctx = parts.dropFirst().joined(separator: " — ").replacingOccurrences(of: " (", with: " · ").replacingOccurrences(of: ")", with: "")
    ctx = ctx.prefix(1).uppercased() + ctx.dropFirst()
    return (parts[0], ctx)
}
/// Prima frase di una spiegazione, accorciata.
func firstSentence(_ d: String) -> String {
    let one = d.replacingOccurrences(of: "\n", with: " "); let s = one.components(separatedBy: ". ").first ?? one
    return s.count > 110 ? String(s.prefix(108)) + "…" : s
}

struct JobDetail: View {
    @ObservedObject var job: Job; let store: Store
    @State private var sheetPlan: FixPlan?; @State private var showCompare = false; @State private var tab = 0; @State private var showPlus = false; @State private var open: Set<String> = []; @State private var showIgnored = false
    func plan(_ hints: [FixHint]) -> FixPlan { var p = FixPlan(); hints.forEach { p.merge($0) }; return p }
    /// «Ho controllato a mano: non è un problema» — esclude queste segnalazioni (ricordato per questo film).
    func dismiss(_ sigs: Set<String>) { guard let r = job.report else { return }; Dismissals.set(job.url, Dismissals.get(job.url).union(sigs)); refresh(r) }
    func restore(_ sigs: Set<String>) { guard let r = job.report else { return }; Dismissals.set(job.url, Dismissals.get(job.url).subtracting(sigs)); refresh(r) }
    func refresh(_ r: Report) { setVerdictTag(job.url, ok: r.essential.isEmpty); job.objectWillChange.send() }
    func dismissButton(_ sigs: Set<String>) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.16)) { dismiss(sigs) } } label: { Label("Ho controllato: non è un problema", systemImage: "checkmark.circle") }.buttonStyle(.bordered).controlSize(.small)
    }
    func toggle(_ id: String) { withAnimation(.easeInOut(duration: 0.16)) { if open.contains(id) { open.remove(id) } else { open.insert(id) } } }

    var body: some View {
        if let r = job.report {
            let items = fixItems(r)
            let todo = r.visible.filter { $0.fixes.isEmpty && $0.sev >= .warn }.sorted { $0.sev > $1.sev }
            let notes = r.visible.filter { $0.fixes.isEmpty && $0.sev == .info }
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                header(r)
                if let fr = job.fixResult { FixBanner(result: fr, compare: job.hasCorrected ? { showCompare = true } : nil, reveal: { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }, discard: { store.discardCorrected(job) }) }
                if job.fixProgress != nil { HStack(spacing: 10) { ProgressView(value: job.fixProgress).frame(width: 220); Text(job.fixStage).font(.callout).foregroundStyle(.secondary) } }
                HStack(spacing: 4) { ForEach([(0, "Riepilogo"), (1, "Dettagli")], id: \.0) { t in
                    Button { tab = t.0 } label: { Text(t.1).font(.callout.weight(tab == t.0 ? .semibold : .regular)).padding(.horizontal, 14).padding(.vertical, 5).background(Capsule().fill(tab == t.0 ? Color.secondary.opacity(0.18) : Color.clear)) }.buttonStyle(.plain) } }
                if tab == 0 { summary(r, items, todo) } else { details(r, notes) }
            }.padding(24).frame(maxWidth: 760, alignment: .leading) }
            .sheet(isPresented: $showCompare) { CompareView(pair: ComparePair(before: job.origURL ?? job.url, beforeReport: job.origReport ?? job.report!, after: job.url, afterReport: job.report!, lines: job.fixLog)) }
            .sheet(isPresented: Binding(get: { sheetPlan != nil }, set: { if !$0 { sheetPlan = nil } })) { FixSheet(job: job, report: r, plan: sheetPlan ?? FixPlan(), store: store) }
            .onChange(of: job.fixProgress != nil) { running in if !running { sheetPlan = nil } }
            .onChange(of: job.hasCorrected) { c in if c && ProcessInfo.processInfo.environment["MOVIEPREFLIGHT_OPENCOMPARE"] != nil { showCompare = true } }
            .onAppear { if ProcessInfo.processInfo.environment["MOVIEPREFLIGHT_EXPAND"] != nil { showPlus = true; open = Set(items.map(\.id) + todo.map { $0.id.uuidString }) } }   // solo per le prove a vista
            .onAppear { if ProcessInfo.processInfo.environment["MOVIEPREFLIGHT_SHEET"] != nil { var p = FixPlan(); r.findings.forEach { $0.fixes.forEach { p.merge($0) } }; sheetPlan = p } }   // solo per le prove a vista
        } else {
            VStack(spacing: 12) {
                Text(job.url.lastPathComponent).font(.headline).lineLimit(2)
                ProgressView(value: job.progress).frame(width: 320)
                Text(job.stage).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: riepilogo: prima ciò che serve per la sala, poi le migliorie facoltative
    func summary(_ r: Report, _ items: [FixItem], _ todo: [Finding]) -> some View {
        let eItems = items.filter(\.essential), pItems = items.filter { !$0.essential }
        let eTodo = todo.filter { isEssential($0) }, pTodo = r.visible.filter { $0.fixes.isEmpty && $0.sev >= .warn && !isEssential($0) }
        let safeE = eItems.flatMap { $0.hints }.filter { !isHeavy($0) }, safeP = pItems.flatMap { $0.hints }.filter { !isHeavy($0) }
        let nE = eItems.count + eTodo.count, nP = pItems.count + pTodo.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: nE == 0 ? "checkmark.circle.fill" : (r.worst == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")).font(.system(size: 30)).foregroundStyle(nE == 0 ? Color.green : r.worst.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nE == 0 ? "Pronto per la sala" : (eItems.count > 0 ? "\(nE) \(nE == 1 ? "cosa indispensabile" : "cose indispensabili") da sistemare" : "\(nE) \(nE == 1 ? "cosa" : "cose") da controllare")).font(.title3.weight(.semibold))
                    Text(nE == 0 ? (nP > 0 ? "Nessun problema indispensabile. Ci sono \(nP) migliorie facoltative." : "Non ho trovato problemi.") : (nP > 0 ? "Più \(nP) migliorie facoltative, qui sotto." : "Prima di fare qualsiasi cosa ti mostro cosa cambia.")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if eItems.filter({ $0.hints.allSatisfy { !isHeavy($0) } }).count >= 2 {
                    Button { store.confirmFix(job, plan(safeE)) { sheetPlan = plan(safeE) } } label: { Label("Sistema tutto", systemImage: "wand.and.stars").font(.headline).padding(.horizontal, 6).padding(.vertical, 3) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(job.fixProgress != nil)
                }
            }
            if nE > 0 { VStack(spacing: 8) { ForEach(eItems) { fixRow($0) }; ForEach(eTodo) { manualRow($0) } } }
            if nP > 0 {
                Accordion(title: "Migliorie facoltative (\(nP))", expanded: $showPlus, font: .subheadline.weight(.semibold)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Non servono per andare in sala: rendono il file più compatibile o più bello.").font(.caption).foregroundStyle(.secondary)
                        if !safeP.isEmpty && pItems.filter({ $0.hints.allSatisfy { !isHeavy($0) } }).count >= 2 { Button("Applica le migliorie sicure") { store.confirmFix(job, plan(safeP)) { sheetPlan = plan(safeP) } }.disabled(job.fixProgress != nil) }
                        ForEach(pItems) { fixRow($0, plus: true) }; ForEach(pTodo) { manualRow($0, plus: true) }
                    }
                }
            }
            let ign = r.ignored
            if !ign.isEmpty {
                Accordion(title: "Verificate da te, non sono un problema (\(Set(ign.map(\.sig)).count))", expanded: $showIgnored, font: .subheadline.weight(.semibold)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(Set(ign.map(\.sig))).sorted(), id: \.self) { sg in
                            let t = ign.first { $0.sig == sg }!.title
                            HStack { Image(systemName: "checkmark.circle").foregroundStyle(.green); Text(splitTitle(t).0 + (splitTitle(t).1.isEmpty ? "" : " — " + splitTitle(t).1)).font(.callout); Spacer(); Button("Rimetti tra le segnalazioni") { withAnimation { restore([sg]) } }.controlSize(.small) }
                        }
                    }
                }
            }
        }
    }
    func fixRow(_ it: FixItem, plus: Bool = false) -> some View {
        let (title, ctx) = splitTitle(it.title); let isOpen = open.contains(it.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { toggle(it.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: plus ? "sparkles" : it.sev.symbol).foregroundStyle(plus ? Color.blue : it.sev.color).font(.system(size: 17)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title + (it.count > 1 ? " (+\(it.count - 1))" : "")).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
                            HStack(spacing: 6) { if !ctx.isEmpty { Text(ctx) }; if let t = it.times.first { Text("a \(hms(t))" + (it.times.count > 1 ? " e altri" : "")).monospacedDigit() } }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary).rotationEffect(.degrees(isOpen ? 90 : 0))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button(fixLabel(it.hints[0])) { store.confirmFix(job, plan(it.hints)) { sheetPlan = plan(it.hints) } }.disabled(job.fixProgress != nil)
            }
            if isOpen { VStack(alignment: .leading, spacing: 6) {
                if !it.detail.isEmpty { Text(it.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if it.times.count > 1 { Text(timesText(it.times, more: it.count - it.times.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if let t = it.thumb, let img = NSImage(contentsOf: t) { Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 120).cornerRadius(5) }
                else if let t0 = it.times.first, ["Video", "Sottotitoli", "File"].contains(it.area) { FrameThumb(url: job.url, time: t0) }
                dismissButton(it.sigs)
            }.padding(.leading, 32) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10).background(RoundedRectangle(cornerRadius: 10).fill((plus ? Color.blue : it.sev.color).opacity(0.07)))
    }
    func manualRow(_ f: Finding, plus: Bool = false) -> some View {
        let (title, ctx) = splitTitle(f.title); let isOpen = open.contains(f.id.uuidString)
        return VStack(alignment: .leading, spacing: 8) {
            Button { toggle(f.id.uuidString) } label: {
                HStack(spacing: 10) {
                    Image(systemName: plus ? "sparkles" : f.sev.symbol).foregroundStyle(plus ? Color.blue : f.sev.color).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) { Text(title).font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                        HStack(spacing: 6) { if !ctx.isEmpty { Text(ctx) }; if let t = f.time { Text("a \(hms(t))").monospacedDigit() } }.font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 6); Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary).rotationEffect(.degrees(isOpen ? 90 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isOpen { VStack(alignment: .leading, spacing: 6) {
                if !f.detail.isEmpty { Text(f.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let t = f.thumb, let img = NSImage(contentsOf: t) { Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 120).cornerRadius(5) }
                else if let t0 = f.time, ["Video", "Sottotitoli"].contains(f.area) { FrameThumb(url: job.url, time: t0) }
                dismissButton([f.sig])
            }.padding(.leading, 32) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    // MARK: dettagli: note, dati tecnici, rapporto
    func details(_ r: Report, _ notes: [Finding]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Button("Rianalizza") { store.startAnalysis(job) }
                Button("Correggi a mano…") { sheetPlan = FixPlan() }
                Button("Copia il rapporto") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.text, forType: .string) }
                Button("Salva il rapporto…") { save(r) }
            }.disabled(job.fixProgress != nil)
            if !notes.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("Note").font(.headline)
                ForEach(notes) { f in HStack(alignment: .top, spacing: 8) { Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 18); VStack(alignment: .leading) { Text(f.title).font(.callout); if !f.detail.isEmpty { Text(f.detail).font(.caption).foregroundStyle(.secondary) } } } } } }
            VStack(alignment: .leading, spacing: 12) { Text("Dati tecnici").font(.headline)
                ForEach(r.tech.sorted { $0.order < $1.order }) { sec in
                    VStack(alignment: .leading, spacing: 3) { Text(sec.title).font(.subheadline.weight(.semibold))
                        ForEach(sec.rows) { row in HStack(alignment: .top) { Text(row.k).foregroundStyle(.secondary).frame(width: 190, alignment: .leading); Text(row.v).textSelection(.enabled) }.font(.callout) } } } }
        }
    }

    func header(_ r: Report) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if let m = r.meta, let u = m.posterURL { AsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.12) }.frame(width: 72, height: 105).cornerRadius(6).shadow(radius: 2) }
            else { Image(systemName: "film").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary).frame(width: 52, height: 52).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10))) }
            VStack(alignment: .leading, spacing: 4) {
                Text(r.meta?.title ?? r.file.deletingPathExtension().lastPathComponent).font(.title2.weight(.semibold)).lineLimit(2)
                Text(subtitle(r)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if job.hasCorrected, let o = job.origURL { HStack(spacing: 6) { Image(systemName: "doc.on.doc"); Text("Copia corretta di «\(o.lastPathComponent)» — l'originale non è stato toccato") }.font(.caption).foregroundStyle(.secondary) }
                else if let s = r.meta?.summary { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Rianalizza") { store.startAnalysis(job) }
                Button("Correggi a mano…") { sheetPlan = FixPlan() }
                if job.hasCorrected { Divider(); Button("Confronta prima e dopo…") { showCompare = true }; Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }; Button("Elimina la copia corretta…") { store.discardCorrected(job) } }
                Divider()
                Button("Dati del film online…") { store.askOnline(force: true) }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }.menuStyle(.borderlessButton).frame(width: 34).disabled(job.fixProgress != nil)
        }
    }
    func subtitle(_ r: Report) -> String {
        var p: [String] = []
        if let y = r.meta?.year { p.append("\(y)") }
        if let d = r.meta?.directors, !d.isEmpty { p.append(d.joined(separator: ", ")) }
        p.append(hmLabel(r.duration)); p.append(r.file.pathExtension.uppercased())
        return p.joined(separator: " · ")
    }
    func hmLabel(_ s: Double) -> String { let m = Int(s / 60); return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }
    func save(_ r: Report) {
        let p = NSSavePanel(); p.nameFieldStringValue = r.file.deletingPathExtension().lastPathComponent + " — preflight.txt"; p.allowedContentTypes = [.plainText]
        if p.runModal() == .OK, let u = p.url { try? r.text.write(to: u, atomically: true, encoding: .utf8) }
    }
}
