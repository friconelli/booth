import Foundation
import SwiftUI
import AppKit

/// Un proiettore di riferimento: risoluzione nativa e supporto HDR.
/// Oltre la sua risoluzione il film non si vede meglio: serve come riferimento per scegliere, consigliare e ingrandire senza esagerare;
/// senza HDR un film HDR va convertito in SDR (indispensabile per la sala), con HDR la conversione non serve.
struct ProjectorModel: Codable, Hashable, Identifiable {
    var id: String; var name: String; var w: Int; var h: Int; var hdr: Bool
}

/// Il proiettore scelto (Impostazioni → Proiettore). Predefinito: Epson EB-L530U della sala, laser 5200 lm, WUXGA 1920×1200 (16:10), senza HDR.
enum Projector {
    static let presets: [ProjectorModel] = [
        ProjectorModel(id: "epson-l530u", name: "Epson EB-L530U", w: 1920, h: 1200, hdr: false),
        ProjectorModel(id: "wuxga", name: "Proiettore WUXGA", w: 1920, h: 1200, hdr: false),
        ProjectorModel(id: "fullhd", name: "Proiettore Full HD", w: 1920, h: 1080, hdr: false),
        ProjectorModel(id: "hd", name: "Proiettore HD (WXGA)", w: 1280, h: 800, hdr: false),
        ProjectorModel(id: "4k-hdr", name: "Proiettore 4K con HDR", w: 3840, h: 2160, hdr: true),
        ProjectorModel(id: "4k-sdr", name: "Proiettore 4K senza HDR", w: 3840, h: 2160, hdr: false),
        ProjectorModel(id: "dci-2k", name: "Cinema digitale DCI 2K", w: 2048, h: 1080, hdr: false),
        ProjectorModel(id: "dci-4k", name: "Cinema digitale DCI 4K", w: 4096, h: 2160, hdr: false),
    ]
    static let defaultsKey = "projector"
    /// Il proiettore in uso: uno dei preimpostati o quello personalizzato (id "custom"), salvato nelle preferenze.
    static var current: ProjectorModel {
        if let d = UserDefaults.standard.data(forKey: defaultsKey), let p = try? JSONDecoder().decode(ProjectorModel.self, from: d), p.w > 0, p.h > 0 { return p }
        return presets[0]
    }
    static func set(_ p: ProjectorModel) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: defaultsKey) }
        NotificationCenter.default.post(name: .projectorChanged, object: nil)
    }
    static var name: String { current.name }
    static var w: Int { current.w }
    static var h: Int { current.h }
    static var hdr: Bool { current.hdr }
    static var label: String { "\(name), \(w)×\(h)" }
    /// Proporzioni dello schermo in forma leggibile: 16:10, 16:9, 1,90:1…
    static var ratio: String { ratioLabel(w, h) }
    static func ratioLabel(_ w: Int, _ h: Int) -> String {
        let r = Double(w) / Double(max(h, 1))
        if abs(r - 16.0 / 10) < 0.01 { return "16:10" }
        if abs(r - 16.0 / 9) < 0.01 { return "16:9" }
        if abs(r - 4.0 / 3) < 0.01 { return "4:3" }
        return String(format: "%.2f:1", r).replacingOccurrences(of: ".", with: ",")
    }
}

/// Apre le Impostazioni: SettingsLink da macOS 14 (lì il vecchio selettore non funziona più), selettore classico su macOS 13.
struct OpenSettingsButton<Label: View>: View {
    @ViewBuilder let label: () -> Label
    var body: some View {
        if #available(macOS 14, *) { SettingsLink(label: label) }
        else { Button(action: { NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) }, label: label) }
    }
}
/// Solo per i collaudi (BOOTH_OPEN_SETTINGS): apre le Impostazioni all'avvio.
@available(macOS 14, *)
struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View { Color.clear.frame(width: 0, height: 0).onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openSettings() } } }
}

extension Notification.Name { static let projectorChanged = Notification.Name("BoothProjectorChanged") }

/// Impostazioni → Proiettore: elenco dei modelli o un proiettore personalizzato (nome, risoluzione, HDR).
struct ProjectorSettings: View {
    static let intFormatter: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 1; f.maximum = 20000; return f }()
    @State private var sel: String = Projector.current.id
    @State private var custom: ProjectorModel = Projector.current.id == "custom" ? Projector.current : ProjectorModel(id: "custom", name: "Il mio proiettore", w: 1920, h: 1080, hdr: false)
    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Proiettore di riferimento", selection: $sel) {
                    ForEach(Projector.presets) { p in Text("\(p.name) — \(p.w)×\(p.h)\(p.hdr ? ", HDR" : "")").tag(p.id) }
                    Divider()
                    Text("Personalizzato…").tag("custom")
                }
                if sel == "custom" {
                    TextField("Nome", text: $custom.name)
                    HStack {
                        TextField("Larghezza", value: $custom.w, formatter: Self.intFormatter).frame(width: 90)
                        Text("×")
                        TextField("Altezza", value: $custom.h, formatter: Self.intFormatter).frame(width: 90)
                        Text("pixel (\(Projector.ratioLabel(custom.w, custom.h)))").foregroundStyle(.secondary)
                    }
                    Toggle("Supporta l'HDR", isOn: $custom.hdr)
                }
            }
            SwiftUI.Section {
                Text("Booth giudica l'immagine per come appare su questo proiettore: oltre la sua risoluzione un film non si vede meglio, le proporzioni dello schermo decidono le bande nere e, se il proiettore non supporta l'HDR, un film HDR va convertito in SDR. Vale per le prossime analisi: per i film già aperti usa «Rianalizza».")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: sel == "custom" ? 330 : 200)
        .padding(.vertical, 8)
        .onChange(of: sel) { _ in save() }
        .onChange(of: custom) { _ in if sel == "custom" { save() } }
    }
    private func save() {
        if sel == "custom" { if custom.w > 0 && custom.h > 0 { Projector.set(custom) } }
        else if let p = Projector.presets.first(where: { $0.id == sel }) { Projector.set(p) }
    }
}
