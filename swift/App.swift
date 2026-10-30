import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let store = Store()
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
