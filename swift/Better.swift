import SwiftUI
import AppKit

// MARK: quale delle due copie è meglio per la sala
/// Un motivo del verdetto: chi vince (0 = primo film, 1 = secondo), quanto pesa e la frase da mostrare.
struct BetterReason: Identifiable { let id = UUID(); var winner: Int; var weight: Double; var text: String }
struct BetterVerdict: Identifiable {
    let id = UUID(); var urls: [URL]; var reports: [Report]; var winner: Int?; var reasons: [BetterReason] = []; var facts: [[String]] = [[], []]; var dub: DubCheck?   // dub: il doppiaggio della copia italiana misurato con l'originale dell'altra
    /// Una ha l'immagine migliore, l'altra l'audio italiano: la cosa migliore è unirle.
    var mergeHint: Bool { reasons.contains { $0.text.hasPrefix("Immagine") } && reasons.contains { $0.text.hasPrefix("Ha l'audio italiano") } && Set(reasons.filter { $0.text.hasPrefix("Immagine") || $0.text.hasPrefix("Ha l'audio italiano") }.map(\.winner)).count == 2 }
    var headline: String {
        guard let w = winner else { return "Si equivalgono" }
        return "Meglio «\(urls[w].lastPathComponent)»"
    }
}

/// Confronta due copie con i criteri della sala, in ordine di importanza: problemi indispensabili, audio italiano, immagine, sottotitoli italiani, qualità dell'audio, durata.
func whichIsBetter(_ s: [MergeSource], _ r: [Report], dub: DubCheck? = nil) -> BetterVerdict {
    var v = BetterVerdict(urls: s.map(\.url), reports: r); v.dub = dub
    func add(_ a: Double, _ b: Double, _ weight: Double, _ text: (Int) -> String) {   // a e b: quanto vale ciascuna copia per quel criterio
        guard a != b else { return }; let w = a > b ? 0 : 1; v.reasons.append(BetterReason(winner: w, weight: weight, text: text(w)))
    }
    func name(_ i: Int) -> String { i == 0 ? "la prima" : "la seconda" }

    // problemi che si vedono o si sentono in sala
    let errs = r.map { Double($0.essential.filter { $0.sev == .error }.count) }, warns = r.map { Double($0.essential.filter { $0.sev == .warn }.count) }
    let bad = [errs[0] * 3 + warns[0], errs[1] * 3 + warns[1]]
    add(-bad[0], -bad[1], 300 * abs(bad[0] - bad[1]) / max(1, max(bad[0], bad[1])) + 100 * abs(bad[0] - bad[1])) { w in
        let o = 1 - w; let n = r[o].essential.count
        return "L'altra ha \(n == 1 ? "un problema indispensabile" : "\(n) problemi indispensabili") per la sala" + (r[w].essential.isEmpty ? ", questa nessuno" : " (questa \(r[w].essential.count))") + ": " + r[o].essential.prefix(2).map(\.title).joined(separator: "; ")
    }
    // audio italiano
    let ita = s.map { $0.tracks.filter { $0.kind == "a" && $0.isItalian } }
    add(ita[0].isEmpty ? 0 : 1, ita[1].isEmpty ? 0 : 1, 800) { _ in "Ha l'audio italiano, l'altra no" }
    // immagine
    if let a = s[0].video, let b = s[1].video {
        let sa = screenScore(a, block: r[0].facts["v.block"], blur: r[0].facts["v.blur"]), sb = screenScore(b, block: r[1].facts["v.block"], blur: r[1].facts["v.blur"]), d = abs(sa - sb)
        if d <= visibleScreenGap {   // sul proiettore si equivalgono: meglio la più leggera
            let za = s[0].probe.size, zb = s[1].probe.size
            if max(za, zb) > min(za, zb) * 1.2 { add(-za, -zb, 40) { w in "Sul proiettore (\(Projector.label)) le due immagini si equivalgono, e questa è più leggera: \(fmtBytes(w == 0 ? za : zb)) contro \(fmtBytes(w == 0 ? zb : za))" } }
        }
        else { add(sa, sb, min(600, d * 0.4)) { w in
            let x = w == 0 ? a : b, y = w == 0 ? b : a
            var t = "Immagine migliore sul proiettore: \(x.w)×\(x.h) \(x.codec.uppercased())" + (x.bitrate > 0 ? " a \(fmtRate(x.bitrate))" : "") + " contro \(y.w)×\(y.h) \(y.codec.uppercased())" + (y.bitrate > 0 ? " a \(fmtRate(y.bitrate))" : "")
            if x.w > Projector.w { t += " (sul proiettore, \(Projector.w)×\(Projector.h), il \(x.w >= 3000 ? "4K" : "file") si vede come un 1080p molto pulito, non di più)" }
            if y.dv5 { t += "; l'altra è Dolby Vision 5 (colori sbagliati senza un lettore apposito)" } else if y.interlaced { t += "; l'altra è interlacciata" }
            return t } }
    }
    // sottotitoli italiani (di testo: si possono spostare e correggere)
    let sub = s.map { t -> Double in let i = t.tracks.filter { $0.kind == "s" && $0.isItalian }; return i.contains { !$0.image } ? 2 : i.isEmpty ? 0 : 1 }
    add(sub[0], sub[1], 150) { w in sub[1 - w] == 0 ? "Ha i sottotitoli italiani, l'altra no" : "Sottotitoli italiani di testo, nell'altra sono immagini (non si correggono)" }
    // qualità della traccia italiana (o della migliore, se nessuna delle due è italiana)
    let pool = ita[0].isEmpty || ita[1].isEmpty ? s.map { $0.tracks.filter { $0.kind == "a" } } : ita
    let best = pool.map { $0.max { audioScore($0) < audioScore($1) } }
    if let a = best[0], let b = best[1], ita[0].isEmpty == ita[1].isEmpty, abs(audioScore(a) - audioScore(b)) > 1 {
        add(audioScore(a), audioScore(b), min(200, abs(audioScore(a) - audioScore(b)) * 6)) { w in
            let x = w == 0 ? a : b, y = w == 0 ? b : a
            return "Audio\(ita[0].isEmpty ? "" : " italiano") migliore: \(x.codecLabel) \(x.channelLabel) contro \(y.codecLabel) \(y.channelLabel)" }
    }
    // durata: a 25 fps (PAL) un film dura il 4% in meno senza mancare niente
    let dur = s.indices.map { i -> Double in let d = s[i].video?.duration ?? r[i].duration, f = s[i].video?.fps ?? 0; return abs(f - 25) < 0.05 ? d * 25 / 23.976 : d }
    if min(dur[0], dur[1]) > 0, abs(dur[0] - dur[1]) > 90 {
        add(dur[0], dur[1], 250) { w in "Dura \(Int((abs(dur[0] - dur[1]) / 60).rounded())) minuti in più: all'altra potrebbero mancare delle scene" }
    }

    v.reasons.sort { $0.weight > $1.weight }
    let total = v.reasons.reduce(0.0) { $0 + ($1.winner == 0 ? $1.weight : -$1.weight) }
    v.winner = abs(total) < 30 ? nil : total > 0 ? 0 : 1
    for i in 0..<2 {
        var f: [String] = []
        if let x = s[i].video { f.append("Immagine: " + x.summary) }
        let au = s[i].tracks.filter { $0.kind == "a" }.map { "\(langLabel($0.effLang)) \($0.codecLabel) \($0.channelLabel)".trimmingCharacters(in: .whitespaces) }
        f.append("Audio: " + (au.isEmpty ? "nessuno" : au.joined(separator: ", ")))
        let su = s[i].tracks.filter { $0.kind == "s" }.map { langLabel($0.effLang) + ($0.forced ? " (forzati)" : "") }
        f.append("Sottotitoli: " + (su.isEmpty ? "nessuno" : su.joined(separator: ", ")))
        f.append("Durata: " + hms(r[i].duration) + " · " + r[i].verdict.lowercased())
        if let d = dub, d.ita == i { f.append("Doppiaggio: " + d.summary) }
        v.facts[i] = f
    }
    return v
}

struct BetterView: View {
    let v: BetterVerdict; var sideBySide: (() -> Void)?; var merge: (() -> Void)?; var fixDub: (() -> Void)?; @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: v.winner == nil ? "equal.circle.fill" : "trophy.fill").font(.system(size: 30)).foregroundStyle(v.winner == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.headline).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    Text(v.winner == nil ? "Nessuna delle due ha un vantaggio che conti per la sala." : "È la copia da proiettare\(v.reasons.isEmpty ? "" : ", per questi motivi:")").foregroundStyle(.secondary)
                }
            }
            if let w = v.winner {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(v.reasons.filter { $0.winner == w }) { r in HStack(alignment: .top, spacing: 8) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(r.text) } }
                    ForEach(v.reasons.filter { $0.winner != w }) { r in HStack(alignment: .top, spacing: 8) { Image(systemName: "minus.circle").foregroundStyle(.orange); Text("A favore dell'altra: " + r.text.prefix(1).lowercased() + r.text.dropFirst()) } }
                }.font(.callout)
            }
            if v.mergeHint { HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(Color.accentColor)
                Text("Ancora meglio: unirle, con l'immagine di una e l'audio italiano dell'altra.").font(.callout)
                Spacer(); if let m = merge { Button("Unisci le due copie…") { m() }.buttonStyle(.borderedProminent) }
            }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08))) }
            if let d = v.dub, !d.ok { HStack(spacing: 10) {
                Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(.orange)
                Text(String(format: "Il doppiaggio di «%@» non è a tempo con l'immagine: fuori tolleranza per %@ di film, fino a %.0f ms. Booth può rimetterlo a tempo usando come riferimento %@ dell'altra copia: stessa immagine, stesso peso.", v.urls[d.ita].lastPathComponent, hms(d.badDur), abs(d.worst) * 1000, d.refText)).font(.callout)
                Spacer(); if let f = fixDub { Button("Rimetti a tempo…") { f() }.buttonStyle(.borderedProminent) }
            }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08))) }
            HStack(alignment: .top, spacing: 14) { ForEach(0..<2, id: \.self) { i in card(i) } }
            HStack {
                if let s = sideBySide { Button("Guarda le immagini fianco a fianco…") { s() } }
                Spacer(); Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 760)
    }
    func card(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) { if v.winner == i { Image(systemName: "trophy.fill").foregroundStyle(.green) }; Text(v.urls[i].lastPathComponent).fontWeight(.medium).lineLimit(2) }
            ForEach(v.facts[i], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(v.winner == i ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(v.winner == i ? Color.green.opacity(0.5) : Color.clear))
    }
}
