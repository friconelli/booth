import SwiftUI
import AppKit

/// Colori di Booth, presi dall'icona (lente nera su giallo).
extension Color {
    /// Giallo pieno dell'icona: fondo dei pulsanti principali (testo nero sopra).
    static let boothYellow = Color(red: 1.0, green: 0.776, blue: 0.227)          // #FFC63A
    /// Nero dell'icona: testo sui fondi gialli.
    static let boothInk = Color(red: 0.086, green: 0.086, blue: 0.102)           // #16161A
    /// Accento per icone, selezioni e bordi: ambra scuro in chiaro (si legge sul bianco), giallo in scuro.
    static let brand = Color(nsColor: NSColor(name: "BoothAccent") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.776, blue: 0.227, alpha: 1)          // #FFC63A
            : NSColor(srgbRed: 0.784, green: 0.525, blue: 0.0, alpha: 1)           // #C88600
    })
}

/// Pulsante principale: giallo Booth con testo nero (al posto di .borderedProminent, che metterebbe testo bianco sul giallo).
struct BrandProminentStyle: ButtonStyle {
    @Environment(\.controlSize) private var size
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let large = size == .large
        let small = size == .small || size == .mini
        let shape = RoundedRectangle(cornerRadius: large ? 7 : 5, style: .continuous)
        return configuration.label
            .font(.system(size: small ? 11 : 13, weight: .semibold))
            .foregroundStyle(Color.boothInk)
            .padding(.horizontal, large ? 14 : small ? 8 : 10)
            .padding(.vertical, large ? 6 : small ? 2 : 3)
            .background(shape.fill(Color.boothYellow.opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(shape.stroke(Color.black.opacity(0.15), lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == BrandProminentStyle {
    static var brand: BrandProminentStyle { BrandProminentStyle() }
}
