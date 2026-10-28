import Foundation

/// Il proiettore della sala: Epson EB-L530U, laser 5200 lm, WUXGA 1920×1200 (16:10), senza HDR, ottica 1,35–2,2:1.
/// Oltre questa risoluzione il film non si vede meglio: serve solo come riferimento per scegliere, consigliare e ingrandire senza esagerare.
enum Projector {
    static let name = "Epson EB-L530U", w = 1920, h = 1200
    static var label: String { "\(name), \(w)×\(h)" }
}
