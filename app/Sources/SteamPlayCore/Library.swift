import Foundation

/// A Windows game that has run through Steam Play: its compatdata prefix holds notproton's run log.
public struct Game: Sendable, Identifiable, Equatable, Hashable {
    public var id: Int { appID }
    public var appID: Int
    public var name: String
    public var prefix: URL
    public var runLog: URL?
    public var lastRun: Date?
    public var hasFix: Bool
}

public enum GameStore {
    /// `"name"  "Mewgenics"` from appmanifest_<id>.acf in any Steam library folder.
    public static func manifestName(_ acf: String) -> String? {
        for line in acf.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            // \t"name"\t\t"Value" -> ["\t", "name", "\t\t", "Value", ""]
            if parts.count >= 4, parts[1] == "name" { return String(parts[3]) }
        }
        return nil
    }

    /// Library folders from libraryfolders.vdf ("path" entries), the default one first.
    public static func libraryFolders(steamSupport: URL) -> [URL] {
        var out = [steamSupport]
        let vdf = steamSupport.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                if parts.count >= 4, parts[1] == "path" {
                    let u = URL(fileURLWithPath: String(parts[3]), isDirectory: true)
                    if !out.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { out.append(u) }
                }
            }
        }
        return out
    }

    public static func scan(_ paths: Paths) -> [Game] {
        let fm = FileManager.default
        let libraries = libraryFolders(steamSupport: paths.steamSupport)
        guard let ids = try? fm.contentsOfDirectory(atPath: paths.compatdata.path) else { return [] }
        var games: [Game] = []
        for entry in ids {
            guard let appID = Int(entry), appID > 0 else { continue }
            let prefix = paths.compatdata.appending(path: entry, directoryHint: .isDirectory)
            let log = prefix.appending(path: "notproton-run.log")
            let ran = fm.fileExists(atPath: log.path)
            guard ran || fm.fileExists(atPath: prefix.appending(path: "notproton-msync").path) else { continue }
            var name = "App \(appID)"
            for lib in libraries {
                let acf = lib.appending(path: "steamapps/appmanifest_\(appID).acf")
                if let text = try? String(contentsOf: acf, encoding: .utf8), let n = manifestName(text) { name = n; break }
            }
            let date = ran ? (try? fm.attributesOfItem(atPath: log.path)[.modificationDate]) as? Date : nil
            games.append(Game(appID: appID, name: name, prefix: prefix, runLog: ran ? log : nil, lastRun: date,
                              hasFix: fm.fileExists(atPath: paths.fixes.appending(path: "\(appID).sh").path)))
        }
        return games.sorted { ($0.lastRun ?? .distantPast) > ($1.lastRun ?? .distantPast) }
    }
}

/// A copy of Steam.app in ~/SteamPlayBackup. The app never deletes these (PLAN.md rule 1).
public struct SteamBackup: Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: String, Sendable { case original, snapshot, patched, other }
    public var id: String { url.path }
    public var url: URL
    public var kind: Kind
    public var isActive: Bool
    public var recorded: Bool
    public var created: Date?
}

/// The parts of install-state.json the app shows. Read-only: only the engine writes the state.
public struct InstallState: Sendable, Equatable {
    public var currentRunner: String?
    public var dylibVersion: String?
    public var patchedAt: String?
    public var clientBuild: Int?
    public var gate: String?
    public var activeBackup: String?
    public var recordedBackups: [String: String] // path -> kind

    public static func load(_ url: URL) -> InstallState? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let steam = obj["steam"] as? [String: Any]
        let client = obj["client"] as? [String: Any]
        let gate = client?["gate"] as? [String: Any]
        var recorded: [String: String] = [:]
        for b in steam?["backups"] as? [[String: Any]] ?? [] {
            if let p = b["path"] as? String { recorded[p] = b["kind"] as? String ?? "" }
        }
        var gateText: String?
        if let g = gate, let r = g["resolved"] as? Int, let n = g["required"] as? Int {
            gateText = "\(g["result"] as? String ?? "?") (\(r)/\(n))"
        }
        return InstallState(currentRunner: obj["current"] as? String,
                            dylibVersion: obj["dylib_version"] as? String,
                            patchedAt: (steam?["patched"] as? [String: Any])?["at"] as? String,
                            clientBuild: client?["binary_build"] as? Int,
                            gate: gateText,
                            activeBackup: steam?["active_backup"] as? String,
                            recordedBackups: recorded)
    }
}

public enum BackupStore {
    public static func scan(_ paths: Paths, state: InstallState?) -> [SteamBackup] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.backups.path) else { return [] }
        return names.filter { $0.hasPrefix("Steam.app.") }.map { name in
            let url = paths.backups.appending(path: name, directoryHint: .isDirectory)
            let rec = state?.recordedBackups[url.path]
            let kind: SteamBackup.Kind
            switch rec {
            case "original": kind = .original
            case "snapshot": kind = .snapshot
            default:
                if name.contains("prepatch") { kind = .snapshot }
                else if name.contains("patched") { kind = .patched }
                else { kind = rec == nil ? .other : .original }
            }
            let created = (try? fm.attributesOfItem(atPath: url.path)[.creationDate]) as? Date
            return SteamBackup(url: url, kind: kind, isActive: state?.activeBackup == url.path,
                               recorded: rec != nil, created: created)
        }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }
}
