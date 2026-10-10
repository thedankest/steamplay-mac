import Foundation
import Testing
@testable import SteamPlayCore

/// Drives the real scripts/install.sh, in its test mode, against a fake Steam.app
/// (Tests/fixtures/fake-world.sh): install with the licence and plan questions, doctor, a declined
/// uninstall, then uninstall. Nothing outside the temp dir is touched.
@Suite(.serialized) struct EngineEndToEnd {
    static let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let engine = Engine(root: appDir.deletingLastPathComponent())

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    /// Makes the world and exports its NP_* variables into this test process, which
    /// EngineProcess passes on to install.sh.
    static func makeWorld() throws -> (URL, Paths) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sp-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [appDir.appending(path: "Tests/fixtures/fake-world.sh").path, dir.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        var env: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]), v = String(line[line.index(after: eq)...])
            env[k] = v
            setenv(k, v, 1)
        }
        return (dir, Paths(environment: env))
    }

    @Test func installDoctorUninstall() async throws {
        #expect(Self.engine.isValid)
        let (dir, paths) = try Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        // This test answers yes to everything: never let it reach the real Steam.app.
        let env = ProcessInfo.processInfo.environment
        try #require(env["NP_TEST_MODE"] == "1")
        let root = try #require(env["NP_TEST_ROOT"])
        try #require(root.hasSuffix("/" + dir.lastPathComponent))
        try #require(paths.steamApp.path.hasPrefix(root + "/") && paths.support.path.hasPrefix(root + "/"))
        let asked = Asked()
        let licence = URL(fileURLWithPath: root).appending(path: "fake-License.rtf")

        // 1. Install: the licence comes first, then the plan; both accepted.
        let installEnd = await Driver.run(engine: Self.engine, arguments: ["all"]) { c in
            asked.add(c.id)
            if c.isLicence {
                #expect(c.licensePath == licence.path)
                return .licence(file: licence, sha256: (try? ConfirmationLedger.fileSHA256(licence)) ?? "")
            }
            return .yes
        }
        guard case .finished(let installed) = installEnd else { Issue.record("install ended \(installEnd)"); return }
        #expect(installed.exitCode == 0, "install log:\n\(installed.log.joined(separator: "\n"))")
        #expect(asked.all == ["d3dmetal_license", "plan"])
        let steps = installed.events.compactMap { if case .step(let s) = $0, s.status != .start { s } else { nil } }
        #expect(steps.first { $0.id == "patch" }?.status == .ok)
        #expect(steps.contains { $0.id == "runner" && $0.status == .ok })
        #expect(FileManager.default.fileExists(atPath: paths.support.appending(path: "runners/selfbuilt-test-r1/lib/external/D3DMetal.source").path))
        #expect(InstallState.load(paths.stateFile)?.currentRunner == "selfbuilt-test-r1")
        #expect(BackupStore.scan(paths, state: InstallState.load(paths.stateFile)).contains { $0.kind == .original && $0.isActive })

        // 2. Doctor sees an installed Steam Play.
        let doc = try await EngineProcess.run(engine: Self.engine, arguments: ["doctor"])
        let report = try #require(doc.doctor)
        #expect(report.isInstalled && !report.hasInterruptedRun)
        #expect(report.check("steam_app")?.verdict == .ok)

        // 3. Uninstall, declined: nothing changes.
        let declined = await Driver.run(engine: Self.engine, arguments: ["uninstall"]) { _ in .no }
        guard case .declined(let c) = declined else { Issue.record("expected a declined uninstall, got \(declined)"); return }
        #expect(c.id == "uninstall")
        #expect(InstallState.load(paths.stateFile) != nil)

        // 4. Uninstall, confirmed: Valve's copy is back and the state is archived.
        let removed = await Driver.run(engine: Self.engine, arguments: ["uninstall"]) { _ in .yes }
        guard case .finished(let un) = removed else { Issue.record("uninstall ended \(removed)"); return }
        #expect(un.exitCode == 0, "uninstall log:\n\(un.log.joined(separator: "\n"))")
        #expect(!FileManager.default.fileExists(atPath: paths.stateFile.path))
        let after = try await EngineProcess.run(engine: Self.engine, arguments: ["doctor"])
        #expect(after.doctor?.isInstalled == false)
    }
}
