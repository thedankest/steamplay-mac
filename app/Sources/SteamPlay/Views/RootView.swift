import SteamPlayCore
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case status, games, backups
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: "Status"
        case .games: "Games"
        case .backups: "Steam Backups"
        }
    }
    var symbol: String {
        switch self {
        case .status: "checkmark.seal"
        case .games: "gamecontroller"
        case .backups: "externaldrive"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: Pane? = .status

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                if model.engine == nil {
                    EngineMissingView()
                } else {
                    switch pane ?? .status {
                    case .status: StatusView()
                    case .games: GamesView()
                    case .backups: BackupsView()
                    }
                }
            }
        }
        .sheet(item: $model.run) { _ in
            RunSheet()
                .environment(model)
                .interactiveDismissDisabled(model.isBusy)
        }
    }
}

struct EngineMissingView: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        ContentUnavailableView {
            Label("Installer not found", systemImage: "questionmark.folder")
        } description: {
            Text("Steam Play runs the steamplay-mac installer (scripts/install.sh). Choose the steamplay-mac folder.")
        } actions: {
            Button("Choose Folder…") { picking = true }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.chooseEngine(url) }
        }
    }
}
