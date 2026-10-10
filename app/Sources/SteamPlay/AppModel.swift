import AppKit
import Observation
import SteamPlayCore
import SwiftUI

/// One engine operation in progress or just finished, shown in the run sheet.
struct RunState: Identifiable {
    struct StepRow: Identifiable {
        var id: String
        var title: String
        var status: EngineEvent.Step.Status
        var detail: String
    }
    enum Phase: Equatable { case running, waiting, finished(EngineEvent.Result.Status?, Int32), cancelled(String) }

    let id = UUID()
    var title: String
    var steps: [StepRow] = []
    var log: [String] = []
    var notices: [String] = []
    var phase: Phase = .running
    var resultDetail: String = ""

    var current: StepRow? { steps.last { $0.status == .start } }

    mutating func apply(_ e: EngineEvent) {
        switch e {
        case .step(let s):
            let row = StepRow(id: s.id, title: s.title, status: s.status, detail: s.detail)
            if let i = steps.lastIndex(where: { $0.id == s.id }) { steps[i] = row } else { steps.append(row) }
        case .notify(let t): notices.append(t)
        case .result(let r): resultDetail = r.detail
        default: break
        }
    }
}

/// A question the engine asked; the sheet answers it.
struct PendingQuestion: Identifiable {
    let id = UUID()
    var confirm: EngineEvent.Confirm
    /// d3dmetal_license: the text as displayed and the hash of the file it came from.
    var licenceText: AttributedString?
    var licenceFile: URL?
    var licenceSHA256: String?
    var answer: CheckedContinuation<Bool, Never>
}

enum Operation {
    case install(gptkDMG: URL?)
    case uninstall(removeRunners: Bool, removeGlobalEnv: Bool, removePrefixes: Bool)
    case reapply
    case journalClear

    var title: String {
        switch self {
        case .install: "Installing Steam Play"
        case .uninstall: "Uninstalling Steam Play"
        case .reapply: "Re-applying after a Steam update"
        case .journalClear: "Clearing the interrupted run"
        }
    }

    var arguments: [String] {
        switch self {
        case .install(let dmg): ["all"] + (dmg.map { ["--gptk-dmg", $0.path] } ?? [])
        case .uninstall(let r, let g, let p):
            ["uninstall"] + (r ? ["--remove-runners"] : []) + (g ? ["--remove-global-env"] : []) + (p ? ["--remove-prefixes"] : [])
        case .reapply: ["reapply"]
        case .journalClear: ["journal-clear"]
        }
    }
}

@MainActor @Observable
final class AppModel {
    var engine: Engine?
    let paths = Paths()
    var doctor: DoctorReport?
    var doctorError: String?
    var checking = false
    var state: InstallState?
    var games: [Game] = []
    var backups: [SteamBackup] = []
    var globalEnv = GlobalEnv(text: "")
    var run: RunState?
    var question: PendingQuestion?
    private var runTask: Task<Void, Never>?
    /// Live updates from one engine run; hops from an earlier run are dropped.
    private var generation = 0
    private var logBefore: [String] = []

    static let enginePathKey = "enginePath"

    init() {
        engine = Engine.locate(saved: UserDefaults.standard.string(forKey: Self.enginePathKey))
    }

    var isBusy: Bool { run.map { if case .finished = $0.phase { false } else if case .cancelled = $0.phase { false } else { true } } ?? false }

    func chooseEngine(_ url: URL) {
        let e = Engine(root: url)
        guard e.isValid else { return }
        engine = e
        UserDefaults.standard.set(url.path, forKey: Self.enginePathKey)
        Task { await refresh() }
    }

    // MARK: reading

    func refresh() async {
        reloadLocal()
        guard let engine else { doctor = nil; return }
        checking = true
        defer { checking = false }
        do {
            let out = try await EngineProcess.run(engine: engine, arguments: ["doctor"])
            doctor = out.doctor
            doctorError = out.doctor == nil ? "The installer's check gave no result (exit \(out.exitCode))." : nil
        } catch {
            doctorError = error.localizedDescription
        }
        reloadLocal()
    }

    func reloadLocal() {
        state = InstallState.load(paths.stateFile)
        games = GameStore.scan(paths)
        backups = BackupStore.scan(paths, state: state)
        globalEnv = GlobalEnv.load(paths.globalEnv)
    }

    func setSwitch(_ s: GlobalSwitch, on: Bool) {
        var env = GlobalEnv.load(paths.globalEnv)
        env.set(s.name, on ? s.on : s.off)
        do { try env.write(to: paths.globalEnv); globalEnv = env } catch { NSSound.beep() }
    }

    // MARK: operations

    func start(_ op: Operation) {
        guard let engine, !isBusy else { return }
        run = RunState(title: op.title)
        runTask = Task { await perform(op, engine: engine) }
    }

    func stop() { runTask?.cancel() }

    func dismissRun() {
        guard !isBusy else { return }
        run = nil
        doctor = nil // the old report no longer describes this Mac
        Task { await refresh() }
    }

    /// Drives the command through the engine's questions (Driver); questions show in the run sheet.
    private func perform(_ op: Operation, engine: Engine) async {
        let end = await Driver.run(
            engine: engine, arguments: op.arguments,
            onRound: { round in
                await MainActor.run {
                    self.generation = round * 2 + 1
                    self.run?.steps = []
                    self.run?.phase = .running
                }
            },
            onEvent: { round, e in Task { @MainActor in if self.generation == round * 2 + 1 { self.run?.apply(e) } } },
            onLog: { round, l in Task { @MainActor in if self.generation == round * 2 + 1 { self.run?.log.append(l) } } },
            onOutcome: { round, outcome in
                await MainActor.run {
                    // The complete, ordered record replaces whatever the live hops managed to show.
                    self.generation = round * 2 + 2
                    self.run?.steps = []
                    self.run?.log = self.logBefore + outcome.log
                    self.logBefore = self.run?.log ?? []
                    for e in outcome.events { self.run?.apply(e) }
                    self.run?.phase = .waiting
                }
            },
            answer: { c in await self.ask(c) })
        logBefore = []
        switch end {
        case .finished(let o): run?.phase = .finished(o.result?.status, o.exitCode)
        case .declined(let c):
            run?.phase = .cancelled(c.isLicence
                ? (c.licensePath == nil
                   ? "D3DMetal needs Apple's licence, which is not in the GPTK 3.0 archive. Run Install again and choose Apple's Game Porting Toolkit disk image. Nothing was changed."
                   : "D3DMetal's licence was not accepted. Nothing was changed.")
                : "Not confirmed. Nothing was changed.")
        case .refused(let why): run?.phase = .cancelled(why)
        case .tooManyRounds: run?.phase = .cancelled("The installer kept asking for confirmation, so it was stopped. Nothing more was changed.")
        case .couldNotStart(let why): run?.phase = .cancelled("The installer could not start: \(why)")
        }
    }

    private func ask(_ c: EngineEvent.Confirm) async -> Driver.Answer {
        var text: AttributedString?
        var file: URL?
        var sha: String?
        if c.isLicence {
            guard let p = c.licensePath else { return .no }
            let url = URL(fileURLWithPath: p)
            guard let data = try? Data(contentsOf: url), let h = try? ConfirmationLedger.fileSHA256(url) else { return .no }
            let ns = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
                ?? NSAttributedString(string: String(decoding: data, as: UTF8.self))
            text = AttributedString(ns.string)
            file = url
            sha = h
        }
        let yes = await withCheckedContinuation { cont in
            question = PendingQuestion(confirm: c, licenceText: text, licenceFile: file, licenceSHA256: sha, answer: cont)
        }
        question = nil
        guard yes else { return .no }
        if let file, let sha { return .licence(file: file, sha256: sha) }
        return .yes
    }

    func answer(_ yes: Bool) {
        question?.answer.resume(returning: yes)
        question = nil
    }

    // MARK: Steam

    func openSteam() { NSWorkspace.shared.openApplication(at: paths.steamApp, configuration: .init()) }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
