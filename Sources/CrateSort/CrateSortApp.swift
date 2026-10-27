import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CrateSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup("CrateSort") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Dodaj folder z muzyką…") { store.addFoldersViaPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Skanuj ponownie") { store.rescanAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isScanning || store.roots.isEmpty)
            }
            CommandMenu("Kategorie") {
                CategoryMenuContent(store: store)
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}
