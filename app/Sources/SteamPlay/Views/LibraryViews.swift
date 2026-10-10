import SteamPlayCore
import SwiftUI

struct GamesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Game.ID?

    var body: some View {
        Group {
            if model.games.isEmpty {
                ContentUnavailableView("No games yet", systemImage: "gamecontroller",
                                       description: Text("Windows games show up here after their first start through Steam Play."))
            } else {
                Table(model.games, selection: $selection) {
                    TableColumn("Game", value: \.name)
                    TableColumn("App ID") { g in Text(String(g.appID)).monospacedDigit() }.width(80)
                    TableColumn("Last started") { g in
                        Text(g.lastRun.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–")
                    }.width(150)
                    TableColumn("Fix") { g in
                        if g.hasFix { Image(systemName: "wrench.and.screwdriver").help("A per-game fix is installed") }
                    }.width(40)
                }
                .contextMenu(forSelectionType: Game.ID.self) { ids in
                    if let g = model.games.first(where: { ids.contains($0.id) }) { actions(g) }
                } primaryAction: { ids in
                    if let id = ids.first { model.open(URL(string: "steam://rungameid/\(id)")!) }
                }
            }
        }
        .navigationTitle("Games")
        .toolbar {
            ToolbarItem {
                Button { model.reloadLocal() } label: { Label("Reload", systemImage: "arrow.clockwise") }
            }
        }
    }

    @ViewBuilder private func actions(_ g: Game) -> some View {
        Button("Play") { model.open(URL(string: "steam://rungameid/\(g.appID)")!) }
        Button("Show in Steam") { model.open(URL(string: "steam://nav/games/details/\(g.appID)")!) }
        Divider()
        if let log = g.runLog { Button("Open Run Log") { model.open(log) } }
        Button("Reveal Prefix in Finder") { model.reveal(g.prefix) }
    }
}

struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SteamBackup.ID?

    var body: some View {
        Group {
            if model.backups.isEmpty {
                ContentUnavailableView("No backups", systemImage: "externaldrive",
                                       description: Text("Install backs up Valve's Steam.app here before changing it."))
            } else {
                Table(model.backups, selection: $selection) {
                    TableColumn("Copy") { b in
                        HStack {
                            Text(b.url.lastPathComponent)
                            if b.isActive { Text("restored on uninstall").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    TableColumn("Kind") { b in Text(kind(b)) }.width(170)
                    TableColumn("Made") { b in
                        Text(b.created.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–")
                    }.width(150)
                }
                .contextMenu(forSelectionType: SteamBackup.ID.self) { ids in
                    if let b = model.backups.first(where: { ids.contains($0.id) }) {
                        Button("Reveal in Finder") { model.reveal(b.url) }
                    }
                }
            }
        }
        .navigationTitle("Steam Backups")
        .safeAreaInset(edge: .bottom) {
            Text("Copies are never deleted by Steam Play. Remove old ones yourself in Finder once you no longer need them.")
                .font(.callout).foregroundStyle(.secondary).padding(10)
        }
    }

    private func kind(_ b: SteamBackup) -> String {
        switch b.kind {
        case .original: "Valve's original"
        case .snapshot: "Before a re-patch"
        case .patched: "Patched copy"
        case .other: "Unrecorded"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        Form {
            Section {
                ForEach(GlobalSwitch.all) { s in
                    Toggle(isOn: Binding(get: { s.isOn(in: model.globalEnv) }, set: { model.setSwitch(s, on: $0) })) {
                        Text(s.title)
                        Text(s.help)
                    }
                }
            } header: {
                Text("For all games")
            } footer: {
                Text("Stored in global.env and used from the next game start. A game's own Steam launch options or Compatibility settings still win.")
            }
            .disabled(!FileManager.default.fileExists(atPath: model.paths.support.path))
            Section("Installer") {
                LabeledContent("Engine folder", value: model.engine?.root.path ?? "not found")
                Button("Choose Folder…") { picking = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { model.reloadLocal() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { model.chooseEngine(u) }
        }
    }
}
