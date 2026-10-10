import Foundation

/// The places the engine works on. Same defaults and NP_* overrides as scripts/install.sh, so an
/// app started with the installer tests' environment looks at the same fake world as the engine.
public struct Paths: Sendable, Equatable {
    public var home: URL
    public var steamApp: URL
    public var steamSupport: URL
    public var support: URL
    public var backups: URL

    public init(environment env: [String: String] = ProcessInfo.processInfo.environment) {
        func dir(_ key: String, _ fallback: @autoclosure () -> URL) -> URL {
            if let v = env[key], !v.isEmpty { return URL(fileURLWithPath: v, isDirectory: true) }
            return fallback()
        }
        let home = dir("NP_HOME", FileManager.default.homeDirectoryForCurrentUser)
        self.home = home
        steamApp = dir("NP_STEAM_APP", URL(fileURLWithPath: "/Applications/Steam.app", isDirectory: true))
        steamSupport = dir("NP_STEAM_SUPPORT", home.appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory))
        support = dir("NP_SUPPORT", home.appending(path: "Library/Application Support/notproton", directoryHint: .isDirectory))
        backups = dir("NP_BACKUP_DIR", home.appending(path: "SteamPlayBackup", directoryHint: .isDirectory))
    }

    public var globalEnv: URL { support.appending(path: "global.env") }
    public var stateFile: URL { support.appending(path: "install-state.json") }
    public var logs: URL { support.appending(path: "logs", directoryHint: .isDirectory) }
    public var fixes: URL { support.appending(path: "fixes", directoryHint: .isDirectory) }
    public var compatdata: URL { steamSupport.appending(path: "steamapps/compatdata", directoryHint: .isDirectory) }
}

/// Where scripts/install.sh lives: a steamplay-mac checkout (or, later, a copy inside the app).
public struct Engine: Sendable, Equatable {
    public var root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    public var script: URL { root.appending(path: "scripts/install.sh") }
    public var isValid: Bool { FileManager.default.isReadableFile(atPath: script.path) }

    /// First match: STEAMPLAY_ENGINE, the saved choice, an engine inside the app bundle,
    /// ~/steamplay-mac.
    public static func locate(saved: String?, bundle: Bundle = .main,
                              environment env: [String: String] = ProcessInfo.processInfo.environment) -> Engine? {
        var candidates: [URL] = []
        if let e = env["STEAMPLAY_ENGINE"], !e.isEmpty { candidates.append(URL(fileURLWithPath: e)) }
        if let s = saved, !s.isEmpty { candidates.append(URL(fileURLWithPath: s)) }
        if let r = bundle.resourceURL { candidates.append(r.appending(path: "engine")) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: "steamplay-mac"))
        return candidates.map(Engine.init(root:)).first { $0.isValid }
    }
}
