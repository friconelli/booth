import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Richiesta di cercare i sottotitoli per un film (dalla schermata iniziale, dal menu o dalla scheda del film).
struct SubRequest: Identifiable { let id = UUID(); var url: URL; var meta: MovieMeta?; var fps: Double }

extension Store {
    /// Trova sottotitoli: per il film aperto, oppure per un film scelto adesso.
    func findSubtitles(_ j: Job? = nil) {
        guard !compareBusy else { return }
        if let j = j { subRequest = SubRequest(url: j.url, meta: j.report?.meta, fps: filmFps(j.url)); return }
        let p = NSOpenPanel(); p.allowsMultipleSelection = false; p.canChooseDirectories = false; p.allowedContentTypes = Store.exts.compactMap { UTType(filenameExtension: $0) }
        p.message = "Scegli il film per cui cercare i sottotitoli"
        guard p.runModal() == .OK, let u = p.url else { return }
        subRequest = SubRequest(url: u, meta: jobs.first { $0.url == u }?.report?.meta, fps: filmFps(u))
    }
}
/// Fotogrammi al secondo del video (per scartare i sottotitoli fatti per un'altra velocità).
func filmFps(_ u: URL) -> Double { Probe(u.path)?.video.flatMap { ratio($0["avg_frame_rate"]) ?? ratio($0["r_frame_rate"]) } ?? 0 }

/// Cerca su OpenSubtitles (o usa un .srt che si ha già), controlla che il sottotitolo sia a tempo con il parlato e lo mette dentro al film.
struct SubtitleSearchView: View {
    let req: SubRequest; @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""; @State private var year = ""
    @State private var langs: Set<String> = ["it"]
    @State private var results: [SubResult] = []; @State private var searched = false
    @State private var busy = ""; @State private var error = ""
    @State private var configured = OpenSubtitles.configured
    @State private var chosen: SubResult?; @State private var saved: URL?; @State private var syncText = ""; @State private var syncOK: Bool?; @State private var syncFix: (a: Double, b: Double)?
    @State private var remaining: Int?; @State private var addResult = ""
    @State private var burned: BurnedIn?; @State private var placement = 1; @State private var defaultOn = false; @State private var hasItalianAudio: Bool?; @State private var localSource: URL?
    @State private var speech: FilmSpeech
    init(req: SubRequest, store: Store) { self.req = req; self.store = store; _speech = State(initialValue: FilmSpeech(req.url)) }

    private var langChoices: [(String, String)] {
        var l = [("it", "Italiano"), ("en", "Inglese")]
        if let o = req.meta?.originalLang, !["it", "en"].contains(o) { l.append((o, langLabel(iso2[o] ?? o))) }
        return l
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Trova i sottotitoli").font(.title3.weight(.semibold))
                    Text(req.url.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Ho già il file .srt…") { useLocalFile() }.disabled(!busy.isEmpty).help("Usa un file di sottotitoli che hai già: Booth lo controlla e lo mette nel film")
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let c = chosen, let sv = saved, c.fileID < 0 { resultPanel(c, sv) }   // file locale: si lavora anche senza la chiave di OpenSubtitles
            if !configured { SubtitleAccountForm(intro: true) { configured = OpenSubtitles.configured } }
            else {
                HStack(spacing: 8) {
                    TextField("Titolo", text: $title).frame(minWidth: 220)
                    TextField("Anno", text: $year).frame(width: 60)
                    ForEach(langChoices, id: \.0) { l in Toggle(l.1, isOn: Binding(get: { langs.contains(l.0) }, set: { if $0 { langs.insert(l.0) } else if langs.count > 1 { langs.remove(l.0) } })).toggleStyle(.button) }
                    Button("Cerca") { search() }.buttonStyle(.brand).keyboardShortcut(.defaultAction).disabled(!busy.isEmpty || title.isEmpty)
                }
                if !busy.isEmpty { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(.callout).foregroundStyle(.secondary) } }
                if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if let c = chosen, let s = saved, c.fileID >= 0 { resultPanel(c, s) }
                if searched && results.isEmpty && busy.isEmpty && error.isEmpty { Text("Nessun sottotitolo trovato per queste lingue. Prova a correggere il titolo o l'anno.").foregroundStyle(.secondary) }
                if !results.isEmpty {
                    Text("Prima quelli fatti per questa copia esatta del film, poi quelli con lo stesso frame rate e la stessa uscita.").font(.caption).foregroundStyle(.secondary)
                    ScrollView { LazyVStack(spacing: 6) { ForEach(results) { r in row(r) } } }.frame(minHeight: 220)
                }
                Spacer(minLength: 0)
                Text("A OpenSubtitles vanno solo l'impronta del file (un numero calcolato da 128 KB), il titolo, l'anno e le lingue: il film resta sul Mac. I sottotitoli finiscono dentro al film, nella copia «(corretto)»: nessun file .srt a parte." + (remaining.map { " Scaricamenti rimasti oggi: \($0)." } ?? ""))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 760, height: 600)
        .onAppear {
            let p = parseFileName(req.url)
            title = req.meta?.originalTitle ?? req.meta?.title ?? p.title; year = (req.meta?.year ?? p.year).map(String.init) ?? ""
            if configured && ProcessInfo.processInfo.environment["BOOTH_NOPROMPT"] == nil { search() }
        }
    }

    func row(_ r: SubResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(r.lang.prefix(5)).uppercased()).font(.caption.weight(.bold).monospaced()).frame(width: 44).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) {
                Text(r.release.isEmpty ? r.fileName : r.release).font(.callout).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 6) {
                    if r.hashMatch { badge("Combacia con il tuo file", .green) }
                    if r.fps > 0 { badge(String(format: "%.3f fps", r.fps).replacingOccurrences(of: ".", with: ","), req.fps > 0 && abs(r.fps - req.fps) >= 0.02 ? .orange : .secondary) }
                    if r.machine { badge("Tradotti in automatico", .orange) }
                    if r.hearingImpaired { badge("Per non udenti", .secondary) }
                    if r.trusted { badge("Autore affidabile", .blue) }
                    Text("\(r.downloads) download").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(chosen?.id == r.id && saved != nil ? "Scaricati" : "Scarica e controlla") { download(r) }.disabled(!busy.isEmpty)
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(chosen?.id == r.id ? Color.brand.opacity(0.12) : Color.secondary.opacity(0.06)))
    }
    func badge(_ t: String, _ c: Color) -> some View { Text(t).font(.caption2.weight(.semibold)).foregroundStyle(c).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().stroke(c.opacity(0.6))) }

    func resultPanel(_ c: SubResult, _ s: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) { Image(systemName: "captions.bubble").foregroundStyle(Color.brand); Text(c.fileID < 0 ? "Sottotitoli da «\(c.fileName)»" : "Sottotitoli scaricati: \(c.release.isEmpty ? c.fileName : c.release)").font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle) }
            if !syncText.isEmpty { note(syncOK == true ? "checkmark.circle.fill" : syncOK == false ? "exclamationmark.triangle.fill" : "questionmark.circle", syncOK == true ? .green : syncOK == false ? .orange : .secondary, syncText) }
            if let b = burned {
                note("text.below.photo", .blue, "Nell'immagine ci sono già sottotitoli impressi" + (b.lang.map { " (\(langLabel(iso2[$0] ?? $0)))" } ?? "") + String(format: ", fino al %.0f%% dell'altezza. Non si possono togliere: sono parte dell'immagine.", b.top * 100))
                Picker("Quelli impressi", selection: $placement) {
                    Text("Coprili con una fascia nera (solo mentre ci sono battute)").tag(1)
                    Text("Metti i nuovi sopra di loro").tag(2)
                    Text("Lasciali, i nuovi vanno in basso").tag(0)
                }.pickerStyle(.radioGroup).font(.callout)
                if placement == 1 { Text("La fascia è disegnata nella traccia dei sottotitoli: il video non viene ricodificato e, spegnendo i sottotitoli, torna com'era. Serve un lettore che legga i sottotitoli ASS (VLC, IINA, mpv).").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if placement != 0 && req.url.pathExtension.lowercased() != "mkv" { Text("La posizione si può fissare solo in un .mkv: la copia sarà un .mkv, con immagine e audio identici (nessuna ricodifica).").font(.caption).foregroundStyle(.secondary) }
            }
            Toggle(hasItalianAudio == false ? "Attivi all'avvio (il film non ha l'audio italiano)" : "Attivi all'avvio", isOn: $defaultOn).font(.callout)
            if !addResult.isEmpty { Text(addResult).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 10) {
                Button("Metti nel film") { addToFilm(s, c) }.buttonStyle(.brand).disabled(!busy.isEmpty).help("Crea la copia «(corretto)» con i sottotitoli dentro: nessun file .srt a parte, l'originale non viene toccato")
                if let f = syncFix { Button("Correggi i tempi") { retime(s, f) }.disabled(!busy.isEmpty) }
                if whisperModelPath() == nil { Button("Scarica il modello vocale per controllarli…") { store.offerSpeechModel() } }
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 8).stroke(Color.brand.opacity(0.5)))
    }
    func note(_ icon: String, _ c: Color, _ t: String) -> some View { HStack(alignment: .top, spacing: 6) { Image(systemName: icon).foregroundStyle(c); Text(t).font(.callout).fixedSize(horizontal: false, vertical: true) } }

    // MARK: azioni (in background, una per volta)
    func work(_ label: String, _ f: @escaping () -> Void) { busy = label; error = ""; DispatchQueue.global(qos: .userInitiated).async { f(); DispatchQueue.main.async { if busy == label { busy = "" } } } }
    func search() {
        let t = title.trimmingCharacters(in: .whitespaces), y = Int(year), l = Array(langs), u = req.url, fps = req.fps
        let imdb = t == (req.meta?.originalTitle ?? req.meta?.title) ? req.meta?.imdbID : nil   // se l'utente ha cambiato il titolo si cerca per titolo
        work("Cerco su OpenSubtitles…") {
            do { let r = try OpenSubtitles.search(film: u, title: t, year: y, imdb: imdb, langs: l, fps: fps); DispatchQueue.main.async { results = r; searched = true } }
            catch { let m = error.localizedDescription; DispatchQueue.main.async { self.error = m; searched = true } }
        }
    }
    /// File di lavoro dei sottotitoli: nella cartella temporanea, non accanto al film (finiscono dentro al film).
    private func workFile(_ lang: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("booth-sottotitoli"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(req.url.deletingPathExtension().lastPathComponent + ".\(lang.prefix(2)).\(UUID().uuidString.prefix(6)).srt")
    }
    func download(_ r: SubResult) {
        reset(r)
        work("Scarico i sottotitoli…") {
            do { let (text, rem) = try OpenSubtitles.download(r); DispatchQueue.main.async { remaining = rem }; prepare(text, r) }
            catch { let m = error.localizedDescription; DispatchQueue.main.async { self.error = m; chosen = nil } }
        }
    }
    /// Sottotitoli che si hanno già (un .srt scaricato altrove): stesso percorso, controllo e poi dentro al film.
    func useLocalFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "srt")].compactMap { $0 }; p.directoryURL = req.url.deletingLastPathComponent(); p.message = "Scegli il file di sottotitoli (.srt)"
        guard p.runModal() == .OK, let u = p.url else { return }
        let l = u.deletingPathExtension().pathExtension.lowercased(), code = l.count == 2 ? l : "it"
        let r = SubResult(fileID: -1, lang: code, release: "", fileName: u.lastPathComponent, downloads: 0, hashMatch: false, hearingImpaired: false, fps: 0, machine: false, trusted: false, uploader: "", feature: "", year: nil)
        reset(r); localSource = u
        work("Leggo i sottotitoli…") { guard let t = readSubText(u) else { DispatchQueue.main.async { error = "Il file non è un sottotitolo leggibile." }; return }; prepare(t, r) }
    }
    private func reset(_ r: SubResult) { chosen = r; saved = nil; syncText = ""; syncOK = nil; syncFix = nil; addResult = ""; burned = nil; localSource = nil }
    /// In background: salva il file di lavoro, controlla la sincronia, cerca i sottotitoli impressi e decide se vanno attivi all'avvio.
    private func prepare(_ text: String, _ r: SubResult) {
        let dest = workFile(r.lang), film = req.url, sp = speech
        do { try text.write(to: dest, atomically: true, encoding: .utf8) } catch { let m = error.localizedDescription; DispatchQueue.main.async { self.error = m }; return }
        let pr = Probe(film.path), ita = pr.map { $0.audio.contains { lang($0) == "ita" } }
        DispatchQueue.main.async { saved = dest; hasItalianAudio = ita; defaultOn = ita == false && r.lang3 == "ita"; busy = "Cerco sottotitoli impressi nell'immagine…" }
        let b = burnedInSubtitles(film, cues: parseSRT(text), duration: pr?.duration ?? 0)
        DispatchQueue.main.async { burned = b; placement = 1; busy = "Controllo che siano a tempo con il parlato (ascolto cinque tratti del film)…" }
        check(text, sp)
        DispatchQueue.main.async { busy = "" }
    }
    /// Misura la sincronia (in background): il parlato del film si riconosce una volta sola per tutti i sottotitoli provati.
    func check(_ text: String, _ sp: FilmSpeech) {
        guard let wins = sp.get() else {
            DispatchQueue.main.async { syncOK = nil; syncText = whisperModelPath() == nil ? "Per controllare che siano a tempo serve il modello vocale (148 MB, una sola volta)." : "Film troppo corto per controllare la sincronia." }; return
        }
        let d = describeSync(globalSubSync(parseSRT(text).filter { !$0.t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, wins, FilmSpeech.len))
        DispatchQueue.main.async { syncOK = d.ok; syncText = d.text; syncFix = d.fix }
    }
    func retime(_ s: URL, _ f: (a: Double, b: Double)) {
        let sp = speech
        work("Correggo i tempi e ricontrollo…") {
            guard let t = readSubText(s) else { return }
            let n = retimeSRT(t, a: f.a, b: f.b)
            do { try n.write(to: s, atomically: true, encoding: .utf8) } catch { let m = error.localizedDescription; DispatchQueue.main.async { self.error = m }; return }
            check(n, sp)
            DispatchQueue.main.async { if syncOK == true { syncText = "Tempi corretti. " + syncText } }
        }
    }
    /// Mette i sottotitoli dentro al film, nella copia «(corretto)» (mai nell'originale); nessun .srt resta accanto al film.
    func addToFilm(_ s: URL, _ c: SubResult) {
        var p = FixPlan()
        p.addSubs = [AddedSub(file: s, lang: c.lang3, title: langLabel(c.lang3), isDefault: defaultOn, position: placement == 2 ? burned.map { min(0.45, $0.top + 0.025) } : nil, cover: placement == 1 ? burned.map { min(0.4, $0.top + 0.02) } : nil)]
        if defaultOn, Probe(req.url.path)?.subs.contains(where: { disp($0, "default") == 1 }) == true { p.subDefault = .none }   // gli altri sottotitoli non devono essere attivi insieme a questi
        if placement != 0 && burned != nil && req.url.pathExtension.lowercased() != "mkv" { p.outputExt = "mkv" }
        let local = localSource
        if let j = store.jobs.first(where: { $0.url.standardizedFileURL == req.url.standardizedFileURL }), j.report != nil {
            if let l = local { try? FileManager.default.trashItem(at: l, resultingItemURL: nil) }   // il file originale dell'utente va nel Cestino: i sottotitoli finiscono nel film
            dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.confirmFix(j, p) {} }; return
        }
        let out = correctedURL(for: req.url, ext: p.outputExt)
        let a = NSAlert(); a.messageText = "Mettere i sottotitoli nel film?"
        a.informativeText = (p.summary(Report(file: req.url)).map { "• " + $0 }.joined(separator: "\n")) + "\n\nVerrà creata «\(out.lastPathComponent)» accanto al film. L'originale non viene toccato" + (local != nil ? "; il file «\(local!.lastPathComponent)» va nel Cestino." : ".")
        a.addButton(withTitle: "Metti nel film"); a.addButton(withTitle: "Annulla"); guard a.runModal() == .alertFirstButtonReturn else { return }
        let src = req.url
        work("Creo la copia con i sottotitoli…") {
            let r = applyFix(src, p, output: out) { v, st in DispatchQueue.main.async { busy = "\(st) \(Int(v * 100))%" } }
            if r.ok { try? FileManager.default.removeItem(at: s); if let l = local { try? FileManager.default.trashItem(at: l, resultingItemURL: nil) } }
            DispatchQueue.main.async {
                busy = ""; addResult = r.message
                guard r.ok else { return }
                dismiss()   // sottotitoli messi: la finestra si chiude, il risultato si vede nel Finder e in un avviso
                NSWorkspace.shared.activateFileViewerSelecting([out])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { let a = NSAlert(); a.messageText = "Sottotitoli messi nel film"; a.informativeText = r.message + (r.lines.isEmpty ? "" : "\n\n" + r.lines.joined(separator: "\n")); a.runModal() }
            }
        }
    }
}

/// Chiave API e account di OpenSubtitles (Impostazioni → Sottotitoli, o al primo uso della ricerca).
struct SubtitleAccountForm: View {
    var intro = false; var done: () -> Void = {}
    @State private var key = OpenSubtitles.apiKey; @State private var user = OpenSubtitles.username; @State private var pass = OpenSubtitles.password; @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if intro { Text("Per cercare i sottotitoli Booth usa OpenSubtitles.com, l'archivio più grande. Serve una chiave API gratuita, da creare una volta sola:").fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: 3) {
                Text("1. Crea un account gratuito su opensubtitles.com e accedi.")
                Text("2. Apri «API consumers», crea un consumer (nome: Booth) e copia la chiave.")
                Link("Apri la pagina delle chiavi API ↗", destination: URL(string: "https://www.opensubtitles.com/consumers")!).foregroundStyle(Color.brand)
            }.font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Chiave API", text: $key)
                TextField("Nome utente (facoltativo)", text: $user)
                SecureField("Password (facoltativa)", text: $pass)
            }.formStyle(.grouped).frame(height: 150)
            Text("Con nome utente e password si possono scaricare più sottotitoli al giorno. La password resta nel Portachiavi del Mac.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Salva") { OpenSubtitles.save(key: key, user: user, password: pass); saved = true; done() }.buttonStyle(.brand).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty); if saved { Text("Salvato").font(.caption).foregroundStyle(.green) } }
        }
    }
}
