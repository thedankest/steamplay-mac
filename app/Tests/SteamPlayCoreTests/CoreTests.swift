import Foundation
import Testing
@testable import SteamPlayCore

@Suite struct EventParsing {
    @Test func step() {
        let e = EngineEvent.parse(#"{"event":"step","id":"gate","title":"Checking","status":"ok","detail":"17/17"}"#)
        #expect(e == .step(.init(id: "gate", title: "Checking", status: .ok, detail: "17/17")))
    }

    @Test func confirmAndLicence() {
        guard case .confirm(let c)? = EngineEvent.parse(#"{"event":"confirm","id":"plan","text":"Install\n- x","token":"ab"}"#) else {
            Issue.record("no confirm"); return
        }
        #expect(c.id == "plan" && c.text == "Install\n- x" && !c.isLicence)
        guard case .confirm(let l)? = EngineEvent.parse(#"{"event":"confirm","id":"d3dmetal_license","text":"t","license_path":"/x/License.rtf","url":null,"token":"cd","env":"NP_D3DMETAL_LICENSE_TOKEN"}"#) else {
            Issue.record("no licence"); return
        }
        #expect(l.isLicence && l.licensePath == "/x/License.rtf" && l.url == nil && l.env == "NP_D3DMETAL_LICENSE_TOKEN")
    }

    @Test func result() {
        let e = EngineEvent.parse(#"{"event":"result","op":"all","status":"needs_confirmation","exit":3,"detail":"needs confirmation: plan"}"#)
        #expect(e == .result(.init(op: "all", status: .needsConfirmation, exit: 3, detail: "needs confirmation: plan")))
    }

    @Test func doctor() throws {
        let line = #"{"event":"doctor","schema":1,"verdict":"warn","exit":2,"quick":false,"checks":[{"id":"state","verdict":"warn","detail":"no install-state.json: not installed with install.sh all"},{"id":"journal","verdict":"ok","detail":"idle"}]}"#
        guard case .doctor(let d)? = EngineEvent.parse(line) else { Issue.record("no doctor"); return }
        #expect(d.verdict == .warn && d.checks.count == 2)
        #expect(!d.isInstalled)
        #expect(!d.hasInterruptedRun)
    }

    @Test func unknownAndBlank() {
        #expect(EngineEvent.parse("   ") == nil)
        #expect(EngineEvent.parse("not json") == .unknown("not json"))
        #expect(EngineEvent.parse(#"{"event":"future","x":1}"#) == .unknown(#"{"event":"future","x":1}"#))
    }
}

@Suite struct Confirmations {
    // printf 'plan\nhello' | shasum -a 256
    @Test func tokenMatchesTheEngine() {
        #expect(ConfirmationLedger.token(id: "plan", text: "hello")
                == "f15ccf18b6f667da13a7f953418fe0f07fb24d796e130489fbfd261f2669d528")
    }

    @Test func acceptsOnlyTheShownText() throws {
        var l = ConfirmationLedger()
        let good = EngineEvent.Confirm(id: "plan", text: "A", token: ConfirmationLedger.token(id: "plan", text: "A"))
        try l.accept(good)
        #expect(l.arguments == ["--confirmed-plan", good.token!])
        let bad = EngineEvent.Confirm(id: "plan", text: "B", token: good.token)
        #expect(throws: ConfirmationLedger.Refusal.tokenMismatch(id: "plan")) { try l.accept(bad) }
    }

    @Test func licenceFirstAndAnsweredOnesDropped() throws {
        var l = ConfirmationLedger()
        let plan = EngineEvent.Confirm(id: "plan", text: "P", token: ConfirmationLedger.token(id: "plan", text: "P"))
        let lic = EngineEvent.Confirm(id: "d3dmetal_license", text: "L", token: "x", licensePath: "/l")
        let out = EngineProcess.Outcome(exitCode: 3, events: [.confirm(plan), .confirm(lic)])
        #expect(l.pending(in: out).map(\.id) == ["d3dmetal_license", "plan"])
        try l.accept(plan)
        #expect(l.pending(in: out).map(\.id) == ["d3dmetal_license"])
    }

    @Test func licenceHashIsTheShownFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sp-lic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appending(path: "License.rtf")
        try Data("{\\rtf1 licence}".utf8).write(to: f)
        let sha = try ConfirmationLedger.fileSHA256(f)
        var l = ConfirmationLedger()
        let c = EngineEvent.Confirm(id: "d3dmetal_license", text: "t", token: sha, licensePath: f.path)
        try l.acceptLicence(c, shownFile: f, shownSHA256: sha)
        #expect(l.environment == ["NP_D3DMETAL_LICENSE_TOKEN": sha])
        // Changed after it was shown: refused.
        var l2 = ConfirmationLedger()
        try Data("{\\rtf1 other}".utf8).write(to: f)
        #expect(throws: ConfirmationLedger.Refusal.licenceChanged) { try l2.acceptLicence(c, shownFile: f, shownSHA256: sha) }
    }
}

@Suite struct GlobalEnvEditing {
    @Test func keepsCommentsAndSetsValues() {
        var e = GlobalEnv(text: "# header\nWINEMSYNC=1\nROSETTA_ADVERTISE_AVX=1\n")
        e.set("WINEMSYNC", "0")
        e.set("MTL_HUD_ENABLED", "1")
        #expect(e.text == "# header\nWINEMSYNC=0\nROSETTA_ADVERTISE_AVX=1\nMTL_HUD_ENABLED=1\n")
        #expect(e.value("WINEMSYNC") == "0")
        e.set("MTL_HUD_ENABLED", nil)
        #expect(e.value("MTL_HUD_ENABLED") == nil)
    }

    @Test func duplicatesCollapse() {
        var e = GlobalEnv(text: "WINEMSYNC=1\nWINEMSYNC=0\n")
        #expect(e.value("WINEMSYNC") == "0")
        e.set("WINEMSYNC", "1")
        #expect(e.text == "WINEMSYNC=1\n")
    }

    @Test func allowList() {
        #expect(GlobalEnv.isAllowed("WINEMSYNC"))
        #expect(GlobalEnv.isAllowed("CX_GRAPHICS_BACKEND"))
        #expect(!GlobalEnv.isAllowed("PATH"))
        #expect(!GlobalEnv.isAllowed("X;rm"))
    }
}

@Suite struct LibraryParsing {
    @Test func manifestName() {
        let acf = "\"AppState\"\n{\n\t\"appid\"\t\t\"686060\"\n\t\"name\"\t\t\"Mewgenics\"\n}\n"
        #expect(GameStore.manifestName(acf) == "Mewgenics")
    }

    @Test func scansOnlySteamPlayPrefixes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sp-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["NP_HOME": root.path]
        let paths = Paths(environment: env)
        let fm = FileManager.default
        for id in ["686060", "22670", "0"] { try fm.createDirectory(at: paths.compatdata.appending(path: id), withIntermediateDirectories: true) }
        try Data().write(to: paths.compatdata.appending(path: "686060/notproton-run.log"))
        try fm.createDirectory(at: paths.steamSupport.appending(path: "steamapps"), withIntermediateDirectories: true)
        try Data("\t\"name\"\t\t\"Mewgenics\"\n".utf8).write(to: paths.steamSupport.appending(path: "steamapps/appmanifest_686060.acf"))
        try fm.createDirectory(at: paths.fixes, withIntermediateDirectories: true)
        try Data().write(to: paths.fixes.appending(path: "686060.sh"))
        let games = GameStore.scan(paths)
        #expect(games.map(\.appID) == [686060])
        #expect(games.first?.name == "Mewgenics" && games.first?.hasFix == true)
    }
}
