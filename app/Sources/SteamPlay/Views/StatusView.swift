import SteamPlayCore
import SwiftUI

/// doctor's checks, grouped and named for people. Ids are the engine's (install.sh header).
enum CheckCatalog {
    static let sections: [(String, [String])] = [
        ("Steam", ["steam_app", "insert", "dylib_hash", "codesign", "gate", "client_changed", "last_session",
                   "update_block_outer", "update_block_inner", "backup", "leftovers"]),
        ("Windows runner", ["rosetta", "runner", "runner_manifest", "d3dmetal", "bridge", "run_script"]),
        ("Game fixes and settings", ["autofix", "fixes", "global_env"]),
        ("Installer", ["state", "journal"]),
    ]

    static let titles: [String: String] = [
        "rosetta": "Rosetta 2",
        "state": "Install record",
        "journal": "Last installer run",
        "steam_app": "Steam.app",
        "insert": "Steam Play loader in Steam.app",
        "dylib_hash": "Loader version",
        "codesign": "Steam.app signature",
        "leftovers": "Leftover copies",
        "backup": "Backup of Valve's Steam.app",
        "gate": "Steam client matches the signatures",
        "client_changed": "Steam client since install",
        "last_session": "Last Steam session",
        "run_script": "Game launch script",
        "runner": "Runner",
        "runner_manifest": "Runner files",
        "d3dmetal": "D3DMetal (DirectX 12)",
        "bridge": "Steam bridge DLLs",
        "update_block_outer": "Steam updates blocked",
        "update_block_inner": "Steam updates blocked (client)",
        "autofix": "Automatic game fixes",
        "fixes": "Per-game fixes",
        "global_env": "Settings for all games",
    ]

    static func title(_ id: String) -> String { titles[id] ?? id.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct VerdictIcon: View {
    var verdict: DoctorReport.Verdict
    var body: some View {
        switch verdict {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skip: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var showInstall = false
    @State private var showUninstall = false

    var body: some View {
        Form {
            Section { header }
            if let d = model.doctor {
                ForEach(CheckCatalog.sections, id: \.0) { title, ids in
                    let rows = ids.compactMap { d.check($0) }
                    if !rows.isEmpty {
                        Section(title) {
                            ForEach(rows) { c in CheckRow(check: c) }
                        }
                    }
                }
                let known = Set(CheckCatalog.sections.flatMap(\.1))
                let other = d.checks.filter { !known.contains($0.id) }
                if !other.isEmpty {
                    Section("Other") { ForEach(other) { c in CheckRow(check: c) } }
                }
            } else if let err = model.doctorError {
                Section { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Status")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .disabled(model.checking || model.isBusy)
            }
        }
        .sheet(isPresented: $showInstall) { InstallOptionsSheet().environment(model) }
        .sheet(isPresented: $showUninstall) { UninstallOptionsSheet().environment(model) }
    }

    private var headline: (String, String, DoctorReport.Verdict) {
        guard let d = model.doctor else {
            return model.checking ? ("Checking…", "Asking the installer how things stand.", .skip)
                                  : ("Not checked", "", .skip)
        }
        if d.hasInterruptedRun {
            return ("An installer run was interrupted", "Steam.app may be half changed. Uninstall restores Valve's copy; or, if every Steam check below is fine, mark the run as handled.", .fail)
        }
        if !d.isInstalled {
            return ("Steam Play is not installed", "Install adds Steam Play to Steam on this Mac. Steam.app is backed up first, and Uninstall puts Valve's copy back.", .skip)
        }
        switch d.verdict {
        case .ok, .skip: return ("Steam Play is installed and working", "Pick a Windows game in Steam: Properties › Compatibility › Steam Play.", .ok)
        case .warn: return ("Steam Play is installed, with warnings", "Games should run. The rows marked below say what to look at.", .warn)
        case .fail: return ("Steam Play needs attention", "Something below is broken. Repair runs the installer again; it changes nothing unless the checks pass.", .fail)
        }
    }

    @ViewBuilder private var header: some View {
        let (title, sub, verdict) = headline
        HStack(alignment: .top, spacing: 14) {
            if model.checking { ProgressView().controlSize(.large).frame(width: 34) }
            else { VerdictIcon(verdict: verdict).font(.system(size: 30)).frame(width: 34) }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                if !sub.isEmpty { Text(sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let s = model.state {
                    Text(summary(s)).font(.callout).foregroundStyle(.secondary)
                }
                actions.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func summary(_ s: InstallState) -> String {
        var parts: [String] = []
        if let r = s.currentRunner { parts.append("Runner \(r)") }
        if let v = s.dylibVersion { parts.append("loader \(v)") }
        if let b = s.clientBuild { parts.append("Steam client \(b)") }
        if let g = s.gate { parts.append("signatures \(g)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        let d = model.doctor
        HStack {
            if let d, d.hasInterruptedRun {
                Button("Uninstall…") { showUninstall = true }
                Button("Mark as Handled…") { model.start(.journalClear) }
            } else if let d, d.isInstalled {
                if d.verdict == .fail {
                    Button("Repair…") { showInstall = true }.buttonStyle(.borderedProminent)
                }
                if d.check("steam_app")?.detail.contains("not patched") == true || d.check("client_changed")?.verdict == .fail {
                    Button("Re-apply After Steam Update") { model.start(.reapply) }
                }
                Button("Open Steam") { model.openSteam() }
                Menu("More") {
                    Button("Run Install Again…") { showInstall = true }
                    Button("Uninstall…") { showUninstall = true }
                }
                .fixedSize()
            } else {
                Button("Install…") { showInstall = true }.buttonStyle(.borderedProminent)
            }
        }
        .disabled(model.isBusy || model.checking || d == nil)
    }
}

struct CheckRow: View {
    var check: DoctorReport.Check
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VerdictIcon(verdict: check.verdict)
            VStack(alignment: .leading, spacing: 2) {
                Text(CheckCatalog.title(check.id))
                if !check.detail.isEmpty {
                    Text(check.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
