import Foundation

/// notproton's global.env: defaults for every game, one NAME=value per line (a game's launch
/// options still win). Edits keep comments and unknown lines exactly as they were.
public struct GlobalEnv: Sendable, Equatable {
    public private(set) var lines: [String]

    public init(text: String) {
        var l = text.components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        lines = l
    }

    public static func load(_ url: URL) -> GlobalEnv {
        GlobalEnv(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// The prefixes compat_run.sh accepts from global.env (doctor warns about anything else).
    public static func isAllowed(_ name: String) -> Bool {
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { return false }
        if name == "CX_FWD_COMPAT_GL_CTX" { return true }
        return ["CX_GRAPHICS", "D3DM_", "DXMT_", "DXVK_", "MTL_", "NOTPROTON_", "ROSETTA_", "WINE"].contains { name.hasPrefix($0) }
    }

    private static func name(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return String(t[..<eq])
    }

    public func value(_ name: String) -> String? {
        for line in lines.reversed() where Self.name(of: line) == name {
            let t = line.trimmingCharacters(in: .whitespaces)
            return String(t[t.index(after: t.firstIndex(of: "=")!)...])
        }
        return nil
    }

    /// nil removes the setting.
    public mutating func set(_ name: String, _ value: String?) {
        precondition(Self.isAllowed(name), "global.env name \(name) is not allowed")
        if let v = value { precondition(!v.contains("\n"), "global.env values are one line") }
        var replaced = false
        lines = lines.compactMap { line in
            guard Self.name(of: line) == name else { return line }
            if replaced || value == nil { return nil }
            replaced = true
            return "\(name)=\(value!)"
        }
        if !replaced, let v = value { lines.append("\(name)=\(v)") }
    }

    public var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// The switches the app shows. Off writes NAME=0 rather than removing the line: the run script
/// reads 1/0 (like Steam's Compatibility panel), and `install.sh all` re-adds its defaults
/// (WINEMSYNC=1, ROSETTA_ADVERTISE_AVX=1) only when no line for the name exists.
public struct GlobalSwitch: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var title: String
    public var help: String
    public var on: String = "1"
    public var off: String = "0"

    public func isOn(in env: GlobalEnv) -> Bool { env.value(name) == on }

    public static let all: [GlobalSwitch] = [
        GlobalSwitch(name: "WINEMSYNC", title: "Faster synchronisation (MSync)",
                     help: "Uses Mach semaphores instead of the wineserver for waits. Most games run smoother."),
        GlobalSwitch(name: "ROSETTA_ADVERTISE_AVX", title: "Tell games the CPU has AVX",
                     help: "Rosetta 2 can run AVX code; some newer games refuse to start without it."),
        GlobalSwitch(name: "MTL_HUD_ENABLED", title: "Metal performance HUD",
                     help: "Apple's frame-rate and memory overlay in every game."),
        GlobalSwitch(name: "NOTPROTON_HIDE_LAUNCHER_TILE", title: "Hide the launcher tile",
                     help: "Hides the small window that appears while a game starts."),
    ]
}
