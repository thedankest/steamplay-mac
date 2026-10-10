import SteamPlayCore
import SwiftUI
import UniformTypeIdentifiers

struct InstallOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var useDMG = false
    @State private var dmg: URL?
    @State private var picking = false

    /// Apple's GPTK disk image in ~/Downloads, newest first.
    private static func findDMG() -> URL? {
        let dl = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dl.path)) ?? []
        return names.filter { $0.hasPrefix("Game_Porting_Toolkit") && $0.hasSuffix(".dmg") }.sorted().last
            .map { dl.appending(path: $0) }
    }

    private var d3dmetalNeeded: Bool {
        guard let c = model.doctor?.check("d3dmetal") else { return true }
        return c.verdict != .ok
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.doctor?.isInstalled == true ? "Run the installer again" : "Install Steam Play")
                .font(.title3.weight(.semibold))
            Text("The installer checks this Mac and Steam first and shows exactly what it will change before it changes anything. Steam is asked to quit, never forced.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("DirectX 12 (D3DMetal)") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Install D3DMetal from Apple's Game Porting Toolkit disk image", isOn: $useDMG)
                    if useDMG {
                        HStack {
                            Text(dmg?.lastPathComponent ?? "No disk image chosen").foregroundStyle(dmg == nil ? .red : .primary)
                            Spacer()
                            Button("Choose…") { picking = true }
                        }
                    }
                    Text(useDMG
                         ? "Apple's licence from the disk image is shown before anything is installed."
                         : (d3dmetalNeeded
                            ? "Without the disk image the installer uses the pinned GPTK 3.0 copy (a download), and asks for Apple's licence first."
                            : "D3DMetal is already installed with an accepted licence; it is kept."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") {
                    dismiss()
                    model.start(.install(gptkDMG: useDMG ? dmg : nil))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(useDMG && dmg == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            dmg = Self.findDMG()
            useDMG = d3dmetalNeeded && dmg != nil
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "dmg") ?? .diskImage]) { r in
            if case .success(let u) = r { dmg = u }
        }
    }
}

struct UninstallOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removeRunners = false
    @State private var removeGlobalEnv = false
    @State private var removePrefixes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall Steam Play").font(.title3.weight(.semibold))
            Text("Valve's own Steam.app comes back from the backup, with Valve's signature, and Steam updates are unblocked. Backups in ~/SteamPlayBackup are never deleted. The installer shows its plan before it changes anything.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("Also remove") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Runners (the Windows compatibility layer, several GB)", isOn: $removeRunners)
                    Toggle("Settings for all games (global.env)", isOn: $removeGlobalEnv)
                    Toggle("Game prefixes (Windows-side saves that Steam Cloud does not sync are lost)", isOn: $removePrefixes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") {
                    dismiss()
                    model.start(.uninstall(removeRunners: removeRunners, removeGlobalEnv: removeGlobalEnv, removePrefixes: removePrefixes))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
