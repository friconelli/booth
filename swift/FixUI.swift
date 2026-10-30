import SwiftUI

private let commonLangs: [(String, String)] = [("ita", "italiano"), ("eng", "inglese"), ("fre", "francese"), ("spa", "spagnolo"), ("ger", "tedesco"), ("por", "portoghese"), ("rus", "russo"), ("jpn", "giapponese"), ("chi", "cinese"), ("kor", "coreano"), ("dut", "olandese"), ("pol", "polacco")]

/// Finestra di conferma: mostra tutto quello che verrà fatto al file e lo applica solo dopo il consenso.
struct FixSheet: View {
    @ObservedObject var job: Job; let report: Report; @State var plan: FixPlan; let store: Store; @Environment(\.dismiss) private var dismiss
    @State private var showAdv = false
    var url: URL { job.url }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Correggi il film").font(.title3.weight(.semibold)).padding([.horizontal, .top], 20)
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 20).padding(.bottom, 8)
            if let p = job.fixProgress { running(p) } else { form }
        }.frame(width: 640, height: 640)
    }
    func running(_ p: Double) -> some View {
        VStack(spacing: 12) { Spacer(); ProgressView(value: p).frame(width: 360); Text(job.fixStage).foregroundStyle(.secondary); Text("Non chiudere l'app: il file originale non viene toccato finché la verifica non è finita.").font(.caption).foregroundStyle(.tertiary); Spacer() }.frame(maxWidth: .infinity)
    }
    var form: some View {
        VStack(spacing: 0) {
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                if !report.audioTracks.isEmpty { group("Audio") {
                    HStack { Text("Traccia predefinita").frame(width: 150, alignment: .leading)
                        Picker("", selection: Binding(get: { plan.audioDefault ?? -1 }, set: { plan.audioDefault = $0 < 0 ? nil : $0 })) { Text("Invariata").tag(-1); ForEach(report.audioTracks) { Text(label($0)).tag($0.ord) } }.labelsHidden() }
                    ForEach(report.audioTracks) { t in trackRow(t, kind: "a") {
                        if t.codec != "ac3" && t.codec != "eac3" && t.codec != "truehd" && t.channels <= 6 { Toggle("Converti in Dolby Digital (AC-3)", isOn: Binding(get: { plan.toDolby.contains(t.ord) }, set: { if $0 { plan.toDolby.insert(t.ord) } else { plan.toDolby.remove(t.ord) } })).disabled(plan.dropAudio.contains(t.ord)) }
                        Toggle("Porta il volume a un livello standard (-24 LUFS, guadagno fisso)", isOn: Binding(get: { plan.levelGain.contains(t.ord) }, set: { if $0 { plan.levelGain.insert(t.ord) } else { plan.levelGain.remove(t.ord) } })).disabled(plan.dropAudio.contains(t.ord) || t.channels > 6)
                        Text("Sale o scende tutto insieme: la dinamica del film non cambia.").font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                        Accordion(title: "Avanzate", expanded: $showAdv, font: .callout) {
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Compressione dinamica", isOn: Binding(get: { plan.normalize.contains(t.ord) }, set: { if $0 { plan.normalize.insert(t.ord) } else { plan.normalize.remove(t.ord) } })).disabled(plan.dropAudio.contains(t.ord) || t.channels > 6)
                                Text("Può abbassare la musica nelle scene con il parlato e rialzarla dove c'è solo musica. Non è consigliata: se il risultato peggiora, l'app annulla la correzione.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if t.channels == 6 { Toggle("Alza i dialoghi (canale centrale +4 dB)", isOn: Binding(get: { plan.boostCenter.contains(t.ord) }, set: { if $0 { plan.boostCenter.insert(t.ord) } else { plan.boostCenter.remove(t.ord) } })).disabled(plan.dropAudio.contains(t.ord)) }
                        Toggle("Elimina questa traccia", isOn: Binding(get: { plan.dropAudio.contains(t.ord) }, set: { if $0 { plan.dropAudio.insert(t.ord); plan.normalize.remove(t.ord); plan.boostCenter.remove(t.ord); plan.levelGain.remove(t.ord); plan.toDolby.remove(t.ord) } else { plan.dropAudio.remove(t.ord) } })).disabled(report.audioTracks.count < 2)
                    } } } }
                if !report.subTracks.isEmpty { group("Sottotitoli") {
                    HStack { Text("Predefiniti").frame(width: 150, alignment: .leading)
                        Picker("", selection: Binding(get: { switch plan.subDefault { case .keep: return -2; case .none: return -1; case .track(let k): return k } }, set: { plan.subDefault = $0 == -2 ? .keep : $0 == -1 ? .none : .track($0) })) {
                            Text("Invariati").tag(-2); Text("Nessuno (partono spenti)").tag(-1); ForEach(report.subTracks) { Text(label($0)).tag($0.ord) } }.labelsHidden() }
                    ForEach(report.subTracks) { t in trackRow(t, kind: "s") {
                        Toggle("Togli le battute con pubblicità e crediti", isOn: Binding(get: { plan.cleanSubs.contains(t.ord) }, set: { if $0 { plan.cleanSubs.insert(t.ord) } else { plan.cleanSubs.remove(t.ord) } })).disabled(t.image || plan.dropSubs.contains(t.ord))
                        if !t.image { HStack { Text("Sposta i sottotitoli di").font(.callout)
                            TextField("0", text: Binding(get: { plan.syncSubs[t.ord].map { String(format: "%g", $0.b) } ?? "" }, set: { v in if let d = Double(v.replacingOccurrences(of: ",", with: ".")), d != 0 { plan.syncSubs[t.ord] = (plan.syncSubs[t.ord]?.a ?? 1, d) } else if v.isEmpty || Double(v.replacingOccurrences(of: ",", with: ".")) == 0 { if (plan.syncSubs[t.ord]?.a ?? 1) == 1 { plan.syncSubs[t.ord] = nil } } })).frame(width: 70).textFieldStyle(.roundedBorder)
                            Text("s (negativo = prima)").font(.caption).foregroundStyle(.secondary)
                            if let a = plan.syncSubs[t.ord]?.a, a != 1 { Text(String(format: "· allungati × %.5f", a)).font(.caption).foregroundStyle(.secondary) } } }
                        Toggle("Elimina questa traccia", isOn: Binding(get: { plan.dropSubs.contains(t.ord) }, set: { if $0 { plan.dropSubs.insert(t.ord); plan.cleanSubs.remove(t.ord) } else { plan.dropSubs.remove(t.ord) } }))
                    } } } }
                group("Contenitore") {
                    Toggle("Titolo nei metadati uguale al nome del file (\(titleBase(url)))", isOn: Binding(get: { plan.setTitle != nil }, set: { plan.setTitle = $0 ? titleBase(url) : nil; if $0 { plan.clearTitle = false } }))
                    Toggle("Togli il titolo dai metadati del file", isOn: Binding(get: { plan.clearTitle }, set: { plan.clearTitle = $0; if $0 { plan.setTitle = nil } }))
                }
                group("Immagine") {
                    Toggle("Converti da HDR a SDR (zscale + tone mapping)", isOn: $plan.tonemap)
                    Toggle("Rimuovi l'interlacciamento (bwdif)", isOn: $plan.deinterlace)
                    Text("Ricodifica l'immagine con codec ad alta qualità: può durare quanto il film. Dopo la scrittura l'app misura la qualità (VMAF) e annulla tutto se l'immagine peggiora.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20) }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                let p = effective
                if p.isEmpty { Text("Scegli qualcosa da correggere.").foregroundStyle(.secondary) }
                else {
                    Text(!p.changesContent ? "Sono solo impostazioni: si cambiano direttamente in «\(url.lastPathComponent)», senza creare una nuova versione del film." : job.hasCorrected ? "La copia corretta «\(url.lastPathComponent)» verrà aggiornata: l'originale non viene toccato." : "Verrà creata la copia «\(correctedURL(for: url, rename: p.rename).lastPathComponent)» accanto al film: l'originale non viene mai modificato e potrai confrontare prima e dopo.").font(.callout)
                    Text(p.changesContent ? "Dopo la scrittura il nuovo file viene controllato (tracce, durata, buchi nell'audio, qualità); se qualcosa non torna non viene creato nulla." : (url.pathExtension.lowercased() == "mkv" ? "Si cambia solo l'intestazione del file, in un attimo; se qualcosa non torna il file resta com'era." : "Il film viene riscritto senza ricodifica e sostituito solo dopo i controlli; se qualcosa non torna resta com'era.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Applica") { let p = effective; store.fix(job, p); } .keyboardShortcut(.defaultAction).disabled(p.isEmpty) }
            }.padding(16)
        }
    }
    var effective: FixPlan { plan }
    func label(_ t: TrackInfo) -> String { "\(t.ord + 1) · \(langLabel(t.lang))\(t.forced ? " (forzati)" : "") · \(t.codec.uppercased())\(t.channels > 0 ? " \(t.channels)ch" : "")" + (t.title.isEmpty ? "" : " · \(t.title)") }
    func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); c() }
    }
    func trackRow<C: View>(_ t: TrackInfo, kind: String, @ViewBuilder _ extra: () -> C) -> some View {
        let key = "\(kind)\(t.ord)"
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label(t)).font(.callout.weight(.medium)).lineLimit(1); Spacer()
                Text("Lingua").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { plan.lang[key] ?? "" }, set: { plan.lang[key] = $0.isEmpty ? nil : $0 })) {
                    Text(t.lang.isEmpty ? "Non indicata" : "Invariata (\(langLabel(t.lang)))").tag(""); ForEach(commonLangs, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 190) }
            extra()
        }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
