import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let store = Store()
    func applicationWillFinishLaunching(_ notification: Notification) { migrateFromMoviePreflight() }
    func application(_ application: NSApplication, open urls: [URL]) { AppDelegate.store.add(urls) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct BoothApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Booth") { ContentView(store: AppDelegate.store) }
            .commands { CommandGroup(replacing: .newItem) { Button("Apri film…") { AppDelegate.store.open() }.keyboardShortcut("o"); Button("Confronta due film…") { AppDelegate.store.compareFiles() }.keyboardShortcut("c", modifiers: [.command, .shift]); Button("Unisci due copie…") { AppDelegate.store.mergeFiles() }.keyboardShortcut("u", modifiers: [.command, .shift]); Divider(); Button("Controlli sul parlato…") { AppDelegate.store.offerSpeechModel() }; Button("Dati del film online…") { AppDelegate.store.askOnline(force: true) } } }
    }
}
/// L'app si chiamava Movie Preflight: al primo avvio come Booth ne riprende le impostazioni (consenso ai dati online,
/// segnalazioni ignorate…) e il modello del parlato già scaricato, così non va rifatto niente.
func migrateFromMoviePreflight() {
    let d = UserDefaults.standard
    guard !d.bool(forKey: "migratedFromMoviePreflight") else { return }
    for (k, v) in d.persistentDomain(forName: "app.moviepreflight.MoviePreflight") ?? [:] where d.object(forKey: k) == nil { d.set(v, forKey: k) }
    let old = NSHomeDirectory() + "/Library/Application Support/Movie Preflight/models", fm = FileManager.default
    if fm.fileExists(atPath: old + "/ggml-base.bin") && !fm.fileExists(atPath: modelDir + "/ggml-base.bin") {
        try? fm.createDirectory(atPath: modelDir, withIntermediateDirectories: true)
        try? fm.moveItem(atPath: old + "/ggml-base.bin", toPath: modelDir + "/ggml-base.bin")
    }
    d.set(true, forKey: "migratedFromMoviePreflight")
}
