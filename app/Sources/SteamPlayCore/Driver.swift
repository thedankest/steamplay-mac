import Foundation

/// Runs one engine command to the end: each time the engine stops for a question (exit 3 with
/// confirm events), asks `answer` for each new one and, while every answer is yes, runs the same
/// command again with all answers so far. A no ends it with nothing changed.
public enum Driver {
    public enum Answer: Sendable {
        case no
        case yes
        /// d3dmetal_license: the file whose text was shown and its SHA-256 at display time.
        case licence(file: URL, sha256: String)
    }

    public enum End: Sendable, Equatable {
        case finished(EngineProcess.Outcome)
        case declined(EngineEvent.Confirm)
        case refused(String)
        case tooManyRounds
        case couldNotStart(String)
    }

    public static func run(engine: Engine, arguments: [String], maxRounds: Int = 8,
                           onRound: @escaping @Sendable (Int) async -> Void = { _ in },
                           onEvent: @escaping @Sendable (Int, EngineEvent) -> Void = { _, _ in },
                           onLog: @escaping @Sendable (Int, String) -> Void = { _, _ in },
                           onOutcome: @escaping @Sendable (Int, EngineProcess.Outcome) async -> Void = { _, _ in },
                           answer: @escaping @Sendable (EngineEvent.Confirm) async -> Answer) async -> End {
        var ledger = ConfirmationLedger()
        for round in 0..<maxRounds {
            await onRound(round)
            let outcome: EngineProcess.Outcome
            do {
                outcome = try await EngineProcess.run(engine: engine, arguments: arguments + ledger.arguments,
                                                      environment: ledger.environment,
                                                      onEvent: { onEvent(round, $0) }, onLog: { onLog(round, $0) })
            } catch {
                return .couldNotStart(error.localizedDescription)
            }
            await onOutcome(round, outcome)
            let pending = ledger.pending(in: outcome)
            guard outcome.exitCode == 3, !pending.isEmpty, !Task.isCancelled else { return .finished(outcome) }
            for c in pending {
                do {
                    switch await answer(c) {
                    case .no: return .declined(c)
                    case .yes: try ledger.accept(c)
                    case .licence(let file, let sha): try ledger.acceptLicence(c, shownFile: file, shownSHA256: sha)
                    }
                } catch {
                    return .refused("\(error)")
                }
            }
        }
        return .tooManyRounds
    }
}
