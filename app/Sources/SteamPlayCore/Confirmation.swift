import CryptoKit
import Foundation

/// Answers collected for one operation. The engine exits 3 with a confirm event whenever it needs
/// an answer; the app shows that exact text, and on "yes" runs the command again with every token
/// given so far. A token only confirms the text it was made from, so if anything in the plan
/// changed between runs the engine asks again.
public struct ConfirmationLedger: Sendable, Equatable {
    public private(set) var tokens: [String] = []
    public private(set) var licenceToken: String?
    public private(set) var licenceFile: String?

    public init() {}

    /// sha256("<id>\n<text>"), as np_confirm computes it.
    public static func token(id: String, text: String) -> String {
        let digest = SHA256.hash(data: Data("\(id)\n\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func fileSHA256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case tokenMismatch(id: String)
        case licenceChanged
        case noLicenceText
        public var description: String {
            switch self {
            case .tokenMismatch(let id): "The installer's confirmation for \"\(id)\" does not match its text. Nothing was confirmed."
            case .licenceChanged: "The licence file changed after it was shown. Nothing was accepted."
            case .noLicenceText: "The installer did not provide the licence text."
            }
        }
    }

    /// The user agreed to a prompt shown with exactly `confirm.text`.
    public mutating func accept(_ confirm: EngineEvent.Confirm) throws {
        let mine = Self.token(id: confirm.id, text: confirm.text)
        guard confirm.token == nil || confirm.token == mine else { throw Refusal.tokenMismatch(id: confirm.id) }
        if !tokens.contains(mine) { tokens.append(mine) }
    }

    /// The user accepted the licence whose text was read from `shownFile` and hashed to `shownSHA256`
    /// when it was displayed. The engine checks the same hash again before installing.
    public mutating func acceptLicence(_ confirm: EngineEvent.Confirm, shownFile: URL, shownSHA256: String) throws {
        guard confirm.licensePath != nil else { throw Refusal.noLicenceText }
        guard (try? Self.fileSHA256(shownFile)) == shownSHA256, confirm.token == nil || confirm.token == shownSHA256 else {
            throw Refusal.licenceChanged
        }
        licenceToken = shownSHA256
        licenceFile = shownFile.path
    }

    public var arguments: [String] { tokens.flatMap { ["--confirmed-plan", $0] } }

    public var environment: [String: String] {
        var env: [String: String] = [:]
        if let t = licenceToken { env["NP_D3DMETAL_LICENSE_TOKEN"] = t }
        return env
    }

    /// Prompts in the order the user should see them: the licence before the plan it feeds into,
    /// and only prompts not answered yet.
    public func pending(in outcome: EngineProcess.Outcome) -> [EngineEvent.Confirm] {
        var seen = Set<String>()
        return outcome.confirms
            .filter { c in
                if c.isLicence { return licenceToken == nil || licenceToken != c.token }
                return !tokens.contains(Self.token(id: c.id, text: c.text))
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { a, b in a.isLicence && !b.isLicence }
    }
}
