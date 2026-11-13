import Foundation
import AppKit
import CryptoKit
import SwiftUI

/// Aggiornamenti di Booth dalle release GitHub (friconelli/booth): ultima release, zip «Booth-X.Y.Z-arm64.zip» con il suo SHA-256 (campo `digest`).
/// Contatta GitHub solo quando l'utente lo chiede (pulsante nella schermata iniziale o menu Booth → Controlla aggiornamenti…).
struct UpdateError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
struct UpdateInfo { let version: String, url: URL, sha256: String, bytes: Int64, notes: String }

/// Un tentativo di scarico: scrive sul file parziale man mano e, se il file c'è già, chiede solo il resto (Range).
final class UpdateDownloader: NSObject, URLSessionDataDelegate {
    enum Outcome { case done(Int64), retry(Error, Int64), fatal(Error) }
    let url: URL, part: String; var got: Int64; var total: Int64; let onProgress: (Int64, Int64) -> Void
    private var fh: FileHandle?, outcome: Outcome?; private let sem = DispatchSemaphore(value: 0); private var lastReport = Date.distantPast
    init(url: URL, part: String, have: Int64, total: Int64, onProgress: @escaping (Int64, Int64) -> Void) { self.url = url; self.part = part; got = have; self.total = total; self.onProgress = onProgress }
    func run() -> Outcome {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60          // 60 s senza ricevere un byte prima di riprovare (rete lentissima ma viva)
        c.timeoutIntervalForResource = 6 * 3600   // lo scarico intero può durare ore
        c.waitsForConnectivity = true
        let s = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        var rq = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        rq.setValue("Booth/\(Updater.current)", forHTTPHeaderField: "User-Agent")
        if got > 0 { rq.setValue("bytes=\(got)-", forHTTPHeaderField: "Range"); rq.setValue("identity", forHTTPHeaderField: "Accept-Encoding") }
        s.dataTask(with: rq).resume(); onProgress(got, total)
        sem.wait(); try? fh?.close(); s.finishTasksAndInvalidate()
        return outcome ?? .retry(UpdateError("nessuna risposta"), total)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let h = r as? HTTPURLResponse, status = h?.statusCode ?? 0
        switch status {
        case 206: if let cr = h?.value(forHTTPHeaderField: "Content-Range"), let t = cr.split(separator: "/").last.flatMap({ Int64($0) }) { total = t }
        case 200: got = 0; if r.expectedContentLength > 0 { total = r.expectedContentLength }; try? FileManager.default.removeItem(atPath: part)
        case 416: try? FileManager.default.removeItem(atPath: part); got = 0; outcome = .retry(UpdateError("HTTP 416"), total); completionHandler(.cancel); sem.signal(); return
        case 500...599, 408, 429: outcome = .retry(UpdateError("HTTP \(status)"), total); completionHandler(.cancel); sem.signal(); return
        default: outcome = .fatal(UpdateError("GitHub ha risposto con errore \(status)")); completionHandler(.cancel); sem.signal(); return
        }
        if !FileManager.default.fileExists(atPath: part) { FileManager.default.createFile(atPath: part, contents: nil) }
        fh = FileHandle(forWritingAtPath: part); _ = try? fh?.seekToEnd()
        completionHandler(.allow)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        fh?.write(data); got += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.1 { lastReport = Date(); onProgress(got, total) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        if outcome == nil {
            if let e = e { outcome = .retry(e, total) }
            else if total > 0 && got < total { outcome = .retry(UpdateError("connessione interrotta"), total) }
            else { onProgress(got, total); outcome = .done(got) }
        }
        sem.signal()
    }
}

enum Updater {
    static let bundleID = "app.booth.Booth"
    static var apiURL: URL { URL(string: ProcessInfo.processInfo.environment["BOOTH_UPDATE_URL"] ?? "https://api.github.com/repos/friconelli/booth/releases/latest")! }
    static var current: String { ProcessInfo.processInfo.environment["BOOTH_VERSION"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }   // BOOTH_VERSION solo per i collaudi

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
        return false
    }
    /// Legge l'ultima release: versione dal tag (v0.3.0 → 0.3.0), lo zip «Booth-…-arm64.zip» e il suo SHA-256.
    static func fetch() throws -> UpdateInfo {
        var rq = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        rq.setValue("Booth/\(current)", forHTTPHeaderField: "User-Agent"); rq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        var out: (Data, URLResponse)?, err: Error?; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: rq) { d, r, e in if let d = d, let r = r { out = (d, r) } else { err = e }; sem.signal() }.resume(); sem.wait()
        guard let (data, resp) = out else { throw err ?? UpdateError("nessuna risposta") }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tag = o["tag_name"] as? String else { throw UpdateError("risposta di GitHub non valida") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = o["assets"] as? [[String: Any]] ?? []
        guard let a = assets.first(where: { ($0["name"] as? String).map { $0.hasPrefix("Booth-") && $0.hasSuffix(".zip") } ?? false }),
              let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)), u.scheme == "https" || u.host == "127.0.0.1"
        else { return UpdateInfo(version: version, url: URL(string: "about:blank")!, sha256: "", bytes: 0, notes: "") }   // release senza lo zip di Booth: trattata come «nessun aggiornamento scaricabile»
        let digest = (a["digest"] as? String ?? "").lowercased()
        return UpdateInfo(version: version, url: u, sha256: digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : "", bytes: (a["size"] as? NSNumber)?.int64Value ?? 0, notes: o["body"] as? String ?? "")
    }
    typealias Progress = (_ got: Int64, _ total: Int64, _ attempt: Int, _ retryIn: Int) -> Void
    /// Scarica lo zip riprendendo da dove si è interrotto (fino a 12 tentativi), controlla lo SHA-256, lo apre e verifica che sia Booth alla versione annunciata. Ritorna il percorso della nuova app.
    static func download(_ i: UpdateInfo, progress: Progress? = nil) throws -> String {
        guard !i.sha256.isEmpty else { throw UpdateError("la release non indica lo SHA-256 dello zip: aggiornamento annullato") }
        let dir = NSTemporaryDirectory() + "booth-update-\(i.version)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)   // la cartella resta: se si riprova più tardi riparte dal file parziale
        let part = dir + "/app.zip.part", zip = dir + "/app.zip"
        let maxAttempts = Int(ProcessInfo.processInfo.environment["BOOTH_UPDATE_RETRIES"] ?? "") ?? 12
        var attempt = 0, finished = false, lastError: Error = UpdateError("download non riuscito"), total = i.bytes
        while attempt < maxAttempts && !finished {
            attempt += 1
            let have = (try? FileManager.default.attributesOfItem(atPath: part)[.size] as? Int64) ?? 0
            if total > 0 && have == total { finished = true; break }
            let d = UpdateDownloader(url: i.url, part: part, have: have, total: total) { g, t in progress?(g, t, attempt, 0) }
            switch d.run() {
            case .done: finished = true
            case .retry(let e, let t): lastError = e; if t > 0 { total = t }
                if attempt < maxAttempts { for left in stride(from: min(15, 2 * attempt), to: 0, by: -1) { progress?(d.got, total, attempt + 1, left); Thread.sleep(forTimeInterval: 1) } }
            case .fatal(let e): throw e
            }
        }
        guard finished else { throw UpdateError("download non riuscito dopo \(maxAttempts) tentativi (\(lastError)). Riprova più tardi: ripartirà da dove era arrivato.") }
        try? FileManager.default.removeItem(atPath: zip); try FileManager.default.moveItem(atPath: part, toPath: zip)
        let h = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: zip), options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard h == i.sha256 else { try? FileManager.default.removeItem(atPath: zip); throw UpdateError("il file scaricato non corrisponde (SHA-256 diverso): aggiornamento annullato") }
        let x = dir + "/x"; try? FileManager.default.removeItem(atPath: x)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip, x]; try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, let app = (try? FileManager.default.contentsOfDirectory(atPath: x))?.first(where: { $0.hasSuffix(".app") }) else { throw UpdateError("archivio non valido") }
        let path = x + "/" + app, info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        guard info?["CFBundleIdentifier"] as? String == bundleID, info?["CFBundleShortVersionString"] as? String == i.version else { throw UpdateError("l'archivio non contiene Booth \(i.version)") }
        return path
    }
    /// Sostituisce l'app dopo la chiusura e la riapre; se la cartella non è scrivibile apre la nuova app dove si trova.
    static func installAndRelaunch(newApp: String) {
        let dest = Bundle.main.bundlePath, pid = getpid()
        let writable = FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent)
        let script = writable
            ? "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; rm -rf \"$2\" && ditto \"$1\" \"$2\" && open \"$2\" || open \"$1\""
            : "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; open \"$1\""
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script, "sh", newApp, dest]
        try? p.run()
    }
}

/// Stato dell'aggiornamento mostrato nella finestra (barra in basso), non in finestre di dialogo separate.
final class UpdateModel: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available, downloading, failed(String) }
    @Published var state: State = .idle
    @Published var info: UpdateInfo?
    @Published var got: Int64 = 0; @Published var total: Int64 = 0; @Published var attempt = 1; @Published var retryIn = 0
    static let shared = UpdateModel()
    init() { if ProcessInfo.processInfo.environment["BOOTH_UPDATE_AUTOCHECK"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.check() } } }   // solo per i collaudi

    func check() {
        guard state != .checking && state != .downloading else { return }
        state = .checking
        DispatchQueue.global().async {
            let r = Result { try Updater.fetch() }
            DispatchQueue.main.async {
                switch r {
                case .failure(let e): self.state = .failed("Non riesco a controllare gli aggiornamenti: verifica la connessione. (\(e))")
                case .success(let i): self.info = i
                    self.state = Updater.isNewer(i.version, than: Updater.current) && i.url.scheme != "about" ? .available : .upToDate
                }
            }
        }
    }
    func install() {
        guard let i = info else { return }
        state = .downloading; got = 0; total = i.bytes; attempt = 1; retryIn = 0
        DispatchQueue.global().async {
            let r = Result { try Updater.download(i) { g, t, a, w in DispatchQueue.main.async { self.got = g; self.total = t; self.attempt = a; self.retryIn = w } } }
            DispatchQueue.main.async {
                switch r {
                case .failure(let e): self.state = .failed("Aggiornamento non riuscito: \(e)")
                case .success(let path): Updater.installAndRelaunch(newApp: path); NSApp.terminate(nil)
                }
            }
        }
    }
    func dismiss() { if state != .downloading && state != .checking { state = .idle } }
}

private func mb(_ b: Int64) -> String { String(format: "%.1f", Double(b) / 1_000_000) }

/// Barra in fondo alla finestra con l'esito del controllo e, durante lo scarico, MB scaricati e mancanti.
struct UpdateBar: View {
    @ObservedObject var m: UpdateModel
    var busy: Bool
    var body: some View {
        if m.state != .idle {
            HStack(alignment: .center, spacing: 12) {
                icon.font(.system(size: 18)).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    switch m.state {
                    case .checking: Text("Controllo gli aggiornamenti…").font(.callout.weight(.semibold))
                    case .upToDate: Text("Booth è aggiornato (versione \(Updater.current)).").font(.callout.weight(.semibold))
                    case .available:
                        Text("È disponibile Booth \(m.info?.version ?? "") (hai la \(Updater.current)).").font(.callout.weight(.semibold))
                        Text("Si scarica (\(mb(m.info?.bytes ?? 0)) MB), si controlla e l'app si riapre da sola." + (busy ? " ⚠︎ Le analisi e le correzioni in corso verranno interrotte." : "")).font(.caption).foregroundStyle(.secondary)
                    case .downloading:
                        HStack { Text("Scarico Booth \(m.info?.version ?? "")…").font(.callout.weight(.semibold)); Spacer()
                            if m.total > 0 { Text("\(Int(min(100, Double(m.got) * 100 / Double(m.total))))%").font(.callout.monospacedDigit().weight(.semibold)) } }
                        if m.total > 0 { ProgressView(value: min(1, Double(m.got) / Double(m.total))) } else { ProgressView() }
                        HStack {
                            Text(m.total > 0 ? "\(mb(m.got)) MB scaricati · \(mb(max(0, m.total - m.got))) MB mancanti" : "\(mb(m.got)) MB scaricati").font(.caption.monospacedDigit())
                            Spacer()
                            if m.retryIn > 0 { Text("Connessione debole: nuovo tentativo \(m.attempt) tra \(m.retryIn) s, riprende da dove era arrivato").font(.caption) }
                            else if m.attempt > 1 { Text("Tentativo \(m.attempt): riprende da dove era arrivato").font(.caption) }
                        }.foregroundStyle(.secondary)
                    case .failed(let s): Text(s).font(.callout).fixedSize(horizontal: false, vertical: true)
                    case .idle: EmptyView()
                    }
                }
                if m.state != .downloading { Spacer(minLength: 0) }
                switch m.state {
                case .available: Button("Aggiorna e riavvia") { m.install() }.buttonStyle(.brand); Button("Più tardi") { m.dismiss() }
                case .failed: Button("Riprova") { m.state = .idle; m.check() }; Button("Chiudi") { m.dismiss() }
                case .upToDate: Button("Chiudi") { m.dismiss() }
                default: EmptyView()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 720)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial).shadow(color: .black.opacity(0.18), radius: 10, y: 3))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.brand.opacity(m.state == .available || m.state == .downloading ? 0.6 : 0.15)))
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    @ViewBuilder var icon: some View {
        switch m.state {
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .available, .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.brand)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: EmptyView()
        }
    }
}
