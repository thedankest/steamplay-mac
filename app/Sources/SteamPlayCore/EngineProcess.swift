import Foundation

/// Runs `scripts/install.sh <args> --json` and streams its events (stdout) and human text
/// (stderr). Cancelling the calling task sends SIGINT, which the engine handles: it rolls
/// Steam.app back if a patch was in flight and exits 130.
public enum EngineProcess {
    public struct Outcome: Sendable, Equatable {
        public var exitCode: Int32
        public var events: [EngineEvent]
        /// stderr: the engine's human-readable progress.
        public var log: [String] = []
        public var result: EngineEvent.Result? {
            for case .result(let r) in events.reversed() { return r }
            return nil
        }
        public var confirms: [EngineEvent.Confirm] {
            events.compactMap { if case .confirm(let c) = $0 { c } else { nil } }
        }
        public var doctor: DoctorReport? {
            for case .doctor(let d) in events.reversed() { return d }
            return nil
        }
    }

    /// A GUI app gets launchd's short PATH; the engine needs Homebrew's zstd and git.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment,
                                   extra: [String: String]) -> [String: String] {
        var env = base
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var parts = path.split(separator: ":").map(String.init)
        for p in ["/usr/local/bin", "/opt/homebrew/bin"] where !parts.contains(p) { parts.insert(p, at: 0) }
        env["PATH"] = parts.joined(separator: ":")
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // The app answers prompts with tokens; never with a stale token from the parent shell.
        env["NP_CONFIRM_TOKEN"] = nil
        env["NP_PROGRESS_FD"] = nil
        env["NP_D3DMETAL_LICENSE_TOKEN"] = nil
        env["NP_D3DMETAL_LICENSE_FILE"] = nil
        for (k, v) in extra { env[k] = v }
        return env
    }

    public static func run(engine: Engine, arguments: [String], environment extra: [String: String] = [:],
                           onEvent: @escaping @Sendable (EngineEvent) -> Void = { _ in },
                           onLog: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [engine.script.path] + arguments + ["--json"]
        process.currentDirectoryURL = engine.root
        process.environment = environment(extra: extra)
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collected = EventBox()
        let logLines = LineBox()
        let group = DispatchGroup()
        func pump(_ handle: FileHandle, _ line: @escaping @Sendable (String) -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        line(String(decoding: lineData, as: UTF8.self))
                    }
                }
                if !buffer.isEmpty { line(String(decoding: buffer, as: UTF8.self)) }
                group.leave()
            }
        }
        pump(out.fileHandleForReading) { line in
            guard let ev = EngineEvent.parse(line) else { return }
            collected.append(ev)
            onEvent(ev)
        }
        pump(err.fileHandleForReading) { l in
            logLines.append(l)
            onLog(l)
        }

        // Not waitUntilExit: on a GCD thread it can miss the exit and block for good (seen in the
        // tests). The termination handler always fires.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // The write ends belong to the child now; EOF arrives when it (and its children) exit.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        let code: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    exited.wait()
                    group.wait()
                    cont.resume(returning: process.terminationStatus)
                }
            }
        } onCancel: {
            if process.isRunning { process.interrupt() }
        }
        return Outcome(exitCode: code, events: collected.events, log: logLines.lines)
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EngineEvent] = []
    func append(_ e: EngineEvent) { lock.withLock { storage.append(e) } }
    var events: [EngineEvent] { lock.withLock { storage } }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ l: String) { lock.withLock { storage.append(l) } }
    var lines: [String] { lock.withLock { storage } }
}
