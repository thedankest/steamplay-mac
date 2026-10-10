import AppKit
import SteamPlayCore
import SwiftUI

@main
struct SteamPlayApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Steam Play", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 520)
                .task { await model.refresh() }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Check Again") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(model.checking || model.isBusy)
            }
            CommandMenu("Steam Play") {
                Button("Open Steam") { model.openSteam() }
                Divider()
                Button("Reveal Installer Logs") { model.reveal(model.paths.logs) }
                Button("Reveal Support Folder") { model.reveal(model.paths.support) }
                Button("Reveal Steam.app Backups") { model.reveal(model.paths.backups) }
                if let e = model.engine {
                    Button("Reveal Engine Folder") { model.reveal(e.root) }
                }
            }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a shell (swift run) the process is not yet a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
