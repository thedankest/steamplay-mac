import Foundation

/// One line of `install.sh --json` output (GUI interface schema 1, documented at the top of
/// scripts/install.sh). Unknown events are kept, not dropped, so a newer engine still shows up.
public enum EngineEvent: Sendable, Equatable {
    case step(Step)
    case confirm(Confirm)
    case plan(Plan)
    case notify(String)
    case result(Result)
    case doctor(DoctorReport)
    case unknown(String)

    public struct Step: Sendable, Equatable, Decodable {
        public enum Status: String, Sendable, Decodable { case start, ok, warn, fail, skip }
        public var id: String
        public var title: String
        public var status: Status
        public var detail: String
    }

    public struct Confirm: Sendable, Equatable, Decodable {
        public var id: String
        public var text: String
        /// sha256("<id>\n<text>") for prompts; the licence file's SHA-256 for d3dmetal_license.
        public var token: String?
        /// d3dmetal_license only.
        public var licensePath: String?
        public var url: String?
        /// The environment variable that carries the answer (d3dmetal_license only).
        public var env: String?

        enum CodingKeys: String, CodingKey {
            case id, text, token, url, env
            case licensePath = "license_path"
        }

        public init(id: String, text: String, token: String?, licensePath: String? = nil, url: String? = nil, env: String? = nil) {
            self.id = id
            self.text = text
            self.token = token
            self.licensePath = licensePath
            self.url = url
            self.env = env
        }

        public var isLicence: Bool { id == "d3dmetal_license" }
    }

    public struct Plan: Sendable, Equatable, Decodable {
        public var op: String
        public var text: String
        public var token: String
    }

    public struct Result: Sendable, Equatable, Decodable {
        public enum Status: String, Sendable, Decodable {
            case ok, fail, plan, pending, interrupted
            case needsConfirmation = "needs_confirmation"
        }
        public var op: String
        public var status: Status
        public var exit: Int
        public var detail: String
    }

    private struct Kind: Decodable { var event: String }
    private struct Notify: Decodable { var text: String }

    /// Parses one stdout line. Returns nil for blank lines.
    public static func parse(_ line: some StringProtocol) -> EngineEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let data = Data(trimmed.utf8)
        let dec = JSONDecoder()
        guard let kind = try? dec.decode(Kind.self, from: data) else { return .unknown(trimmed) }
        do {
            switch kind.event {
            case "step": return .step(try dec.decode(Step.self, from: data))
            case "confirm": return .confirm(try dec.decode(Confirm.self, from: data))
            case "plan": return .plan(try dec.decode(Plan.self, from: data))
            case "notify": return .notify(try dec.decode(Notify.self, from: data).text)
            case "result": return .result(try dec.decode(Result.self, from: data))
            case "doctor": return .doctor(try dec.decode(DoctorReport.self, from: data))
            default: return .unknown(trimmed)
            }
        } catch {
            return .unknown(trimmed)
        }
    }
}

/// `install.sh doctor --json`.
public struct DoctorReport: Sendable, Equatable, Decodable {
    public enum Verdict: String, Sendable, Decodable, Comparable {
        case ok, warn, fail, skip
        private var rank: Int { switch self { case .skip: 0; case .ok: 1; case .warn: 2; case .fail: 3 } }
        public static func < (a: Verdict, b: Verdict) -> Bool { a.rank < b.rank }
    }
    public struct Check: Sendable, Equatable, Decodable, Identifiable {
        public var id: String
        public var verdict: Verdict
        public var detail: String
        public init(id: String, verdict: Verdict, detail: String) {
            self.id = id
            self.verdict = verdict
            self.detail = detail
        }
    }
    public var schema: Int
    public var verdict: Verdict
    public var exit: Int
    public var quick: Bool
    public var checks: [Check]

    public init(schema: Int = 1, verdict: Verdict, exit: Int, quick: Bool = false, checks: [Check]) {
        self.schema = schema
        self.verdict = verdict
        self.exit = exit
        self.quick = quick
        self.checks = checks
    }

    public func check(_ id: String) -> Check? { checks.first { $0.id == id } }

    /// No install-state.json: the engine has never installed on this Mac (doctor's `state` check).
    public var isInstalled: Bool {
        guard let s = check("state") else { return false }
        return !(s.verdict == .warn && s.detail.hasPrefix("no install-state.json"))
    }

    /// A run was cut off (`journal` check fails): only uninstall or journal-clear help.
    public var hasInterruptedRun: Bool { check("journal")?.verdict == .fail }
}
