import Foundation

enum Sev: Int, Comparable { case ok, info, warn, error
    static func < (a: Sev, b: Sev) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["OK", "Nota", "Attenzione", "Problema"][rawValue] }
}
/// Correzione suggerita da una segnalazione (i numeri sono posizioni all'interno del proprio tipo: audio 0, 1…, sottotitoli 0, 1…).
enum FixHint { case defaultAudio(Int), defaultSub(Int?), setLang(String, Int), cleanSub(Int), dropSub(Int), eraseText(EraseRegion), normalize(Int), boostCenter(Int), levelGain(Int), deinterlace, toDolby(Int), clearTitle, setTitle(String), tonemap, repairEncoding(Int), setForced(Int, Bool), rename(String), setLangTo(String, Int, String), syncSubs(Int, Double, Double) }   // syncSubs: tempo nuovo = a·tempo + b
struct Finding: Identifiable { let id = UUID(); var sev: Sev; var area: String; var title: String; var detail: String; var time: Double?; var thumb: URL?; var fixes: [FixHint] = [] }
extension Finding { var sig: String { area + "|" + title } }
/// Segnalazioni che l'utente ha verificato a mano e giudicato non importanti: restano escluse anche rianalizzando il film (e la sua copia «(corretto)»).
enum Dismissals {
    static let key = "dismissedFindings"
    static func name(_ f: URL) -> String { f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " (corretto)", with: "") }
    static func get(_ f: URL) -> Set<String> { Set(((UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:])[name(f)] ?? []) }
    static func set(_ f: URL, _ v: Set<String>) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        d[name(f)] = v.isEmpty ? nil : v.sorted(); UserDefaults.standard.set(d, forKey: key)
    }
}
struct TrackInfo: Identifiable { var id: Int { ord }; var ord: Int; var lang: String; var title: String; var codec: String; var channels: Int; var isDefault: Bool; var forced: Bool; var image: Bool; var bitrate: Double }
struct KV: Identifiable { let id = UUID(); var k: String; var v: String }
struct Section: Identifiable { let id = UUID(); var title: String; var order: Int; var rows: [KV] }

/// Indispensabile per la sala = visibile o udibile dal pubblico, oppure rompe la riproduzione. Tutto il resto è una miglioria facoltativa.
func isEssential(_ f: Finding) -> Bool {
    if f.sev == .error { return true }
    guard f.sev == .warn else { return false }
    let essentialWarnings = ["Sottotitoli attivi di default", "La lingua parlata non corrisponde", "sfasati", "si sfasano", "finiscono molto prima del film", "più lunghi del film", "iniziano molto tardi",
                             "Buco nel flusso video", "Buco nell'audio", "L'audio finisce prima", "finiscono a istanti diversi", "non partono insieme", "Errori di decodifica", "Schermo nero di",
                             "HDR (", "Dolby Vision profilo 5", "Video interlacciato", "dura meno del previsto", "non è a tempo con l'originale"]
    return essentialWarnings.contains { f.title.contains($0) }
}

/// Consiglio pratico per la proiezione, ricavato dalle misure (dove provare il volume, da dove partire, che collegamento usare…).
struct Tip: Identifiable { let id = UUID(); var icon: String; var title: String; var text: String }

struct Report {
    var tips: [Tip] = []
    var file: URL; var duration = 0.0; var findings: [Finding] = []; var tech: [Section] = []; var seconds = 0.0; var audioTracks: [TrackInfo] = []; var subTracks: [TrackInfo] = []; var meta: MovieMeta?
    var ignored: [Finding] { let d = Dismissals.get(file); return findings.filter { $0.sev > .ok && d.contains($0.sig) } }   // verificate a mano dall'utente
    var visible: [Finding] { let d = Dismissals.get(file); return findings.filter { !d.contains($0.sig) } }
    var essential: [Finding] { visible.filter { $0.sev > .ok && isEssential($0) } }      // indispensabili per andare in sala
    var extras: [Finding] { visible.filter { $0.sev > .ok && !isEssential($0) } }        // migliorie facoltative e note
    var worst: Sev { essential.map(\.sev).max() ?? .ok }                                  // il verdetto dipende solo dalle indispensabili
    var verdict: String { switch worst { case .error: return "Problemi da risolvere"; case .warn: return "Da controllare"; default: return "Pronto per la sala" } }
    var text: String {
        var s = "BOOTH — \(file.lastPathComponent)\nEsito: \(verdict)  (\(essential.count) indispensabili per la sala, \(extras.count) migliorie facoltative)\n"
        if !tips.isEmpty { s += "\nCONSIGLI PER LA PROIEZIONE\n"; for t in tips { s += "• \(t.title): \(t.text)\n" } }
        func block(_ title: String, _ fs: [Finding]) {
            guard !fs.isEmpty else { return }; s += "\n\(title)\n"
            for f in fs.sorted(by: { $0.sev > $1.sev }) {
                s += "[\(f.sev.label.uppercased())] \(f.area): \(f.title)" + (f.time.map { " (a \(hms($0)))" } ?? "") + "\n" + (f.detail.isEmpty ? "" : "    \(f.detail.replacingOccurrences(of: "\n", with: "\n    "))\n")
            }
        }
        block("INDISPENSABILE PER LA SALA", essential); block("MIGLIORIE FACOLTATIVE", extras)
        s += "\nDATI TECNICI\n"
        for sec in tech.sorted(by: { $0.order < $1.order }) { s += "\n\(sec.title)\n"; for r in sec.rows { s += "  \(r.k): \(r.v)\n" } }
        return s
    }
}

/// Raccoglie segnalazioni e dati dalle analisi che girano in parallelo.
final class Collector {
    private let lock = NSLock(); private var fs: [Finding] = []; private var secs: [String: Section] = [:]; private var fx: [String: Double] = [:]
    /// Misure numeriche che servono ai consigli per la proiezione (es. «a0.talkT» = secondo di dialogo tipico della traccia audio 1).
    func fact(_ k: String, _ v: Double) { lock.lock(); fx[k] = v; lock.unlock() }
    var facts: [String: Double] { lock.lock(); defer { lock.unlock() }; return fx }
    func add(_ sev: Sev, _ area: String, _ title: String, _ detail: String = "", time: Double? = nil, thumb: URL? = nil, fix: [FixHint] = []) {
        lock.lock(); fs.append(Finding(sev: sev, area: area, title: title, detail: detail, time: time, thumb: thumb, fixes: fix)); lock.unlock()
    }
    func rows(_ title: String, order: Int, _ kv: [(String, String)]) {
        lock.lock(); var s = secs[title] ?? Section(title: title, order: order, rows: []); s.rows += kv.map { KV(k: $0.0, v: $0.1) }; secs[title] = s; lock.unlock()
    }
    var findings: [Finding] { lock.lock(); defer { lock.unlock() }; return fs }
    var sections: [Section] { lock.lock(); defer { lock.unlock() }; return Array(secs.values) }
}
