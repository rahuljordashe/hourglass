import Foundation

/// Connects Hourglass to Claude Code by pointing Claude Code's `statusLine` at the bridge,
/// and disconnects it by restoring whatever was there before.
///
/// Safety rules:
/// - Claude Code's settings file is copied to a timestamped backup before every change.
/// - Only the `statusLine` entry is edited; every other byte of the file stays as it was.
/// - An existing status line command is recorded and chained, so the terminal status line looks unchanged.
public struct StatusLineInstaller: Sendable {
    public static let bridgeMarker = "hourglass-bridge"

    public enum Status: Equatable, Sendable {
        /// The bridge is Claude Code's status line.
        case connected
        /// Something else (or nothing) is the status line. `currentCommand` is what's there now.
        case disconnected(currentCommand: String?)
        /// Claude Code's settings file can't be read as JSON. Nothing will be touched.
        case unreadable(String)
    }

    public struct Report: Equatable, Sendable {
        public var backupURL: URL?
        public var previousCommand: String?
        public var newCommand: String?
    }

    public var paths: NotchPaths

    public init(paths: NotchPaths = NotchPaths()) {
        self.paths = paths
    }

    public func status() -> Status {
        let url = paths.claudeSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return .disconnected(currentCommand: nil) }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let command = try currentCommand(in: text)
            if let command, command.contains(Self.bridgeMarker) { return .connected }
            return .disconnected(currentCommand: command)
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// Copies the bridge to its stable location and points Claude Code at it.
    /// `bridgeSource` is the bridge binary inside the app bundle.
    @discardableResult
    public func connect(bridgeSource: URL, now: Date = Date()) throws -> Report {
        try installBridge(from: bridgeSource)

        let fm = FileManager.default
        let settingsURL = paths.claudeSettings
        let exists = fm.fileExists(atPath: settingsURL.path)
        let text = exists ? try String(contentsOf: settingsURL, encoding: .utf8) : "{}\n"

        let originalRaw = try JSONTopLevelEditor.rawValue(forKey: "statusLine", in: text)
        let originalObject = originalRaw.flatMap { raw in
            (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? [String: Any]
        }
        let previousCommand = originalObject?["command"] as? String

        if let previousCommand, previousCommand.contains(Self.bridgeMarker) {
            return Report(backupURL: nil, previousCommand: previousCommand, newCommand: previousCommand)
        }

        // Record what to chain and how to restore, before touching anything.
        let config = BridgeConfig(
            chainedCommand: previousCommand.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
            originalStatusLineJSON: originalRaw,
            installedAt: now,
            settingsPath: settingsURL.path
        )
        try config.save(to: paths.configFile)

        let backup = exists ? try backupSettings(now: now) : nil

        // Keep the user's own status line options (padding, refreshInterval and so on); swap only the command.
        var newObject = originalObject ?? [:]
        newObject["type"] = "command"
        let command = shellQuoted(paths.installedBridge.path)
        newObject["command"] = command

        let indent = "  "
        let raw = try JSONTopLevelEditor.serialise(newObject, indent: indent)
        let updated = try JSONTopLevelEditor.setValue(raw, forKey: "statusLine", in: text)
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePreservingAttributes(updated, to: settingsURL)

        return Report(backupURL: backup, previousCommand: previousCommand, newCommand: command)
    }

    /// Restores the original `statusLine` entry (or removes it if there was none).
    @discardableResult
    public func disconnect(now: Date = Date()) throws -> Report {
        let settingsURL = paths.claudeSettings
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return Report() }
        let text = try String(contentsOf: settingsURL, encoding: .utf8)
        let current = try currentCommand(in: text)
        guard let current, current.contains(Self.bridgeMarker) else {
            // Someone already changed it; leave their choice alone.
            return Report(backupURL: nil, previousCommand: current, newCommand: current)
        }

        let config = BridgeConfig.load(from: paths.configFile)
        let backup = try backupSettings(now: now)
        let updated: String
        if let original = config?.originalStatusLineJSON {
            updated = try JSONTopLevelEditor.setValue(original, forKey: "statusLine", in: text)
        } else {
            updated = try JSONTopLevelEditor.removeKey("statusLine", in: text)
        }
        try writePreservingAttributes(updated, to: settingsURL)
        let restored = try currentCommand(in: updated)
        return Report(backupURL: backup, previousCommand: current, newCommand: restored)
    }

    // MARK: - Helpers

    func currentCommand(in text: String) throws -> String? {
        guard let raw = try JSONTopLevelEditor.rawValue(forKey: "statusLine", in: text),
              let object = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as? [String: Any]
        else { return nil }
        return object["command"] as? String
    }

    public func installBridge(from source: URL) throws {
        let fm = FileManager.default
        let dest = paths.installedBridge
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.contentsEqual(atPath: source.path, andPath: dest.path) { return }
        let staging = dest.deletingLastPathComponent().appending(path: ".bridge-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
    }

    func backupSettings(now: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.backupDirectory, withIntermediateDirectories: true)
        let stamp = Self.stamp(now)
        var dest = paths.backupDirectory.appending(path: "settings-\(stamp).json")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            n += 1
            dest = paths.backupDirectory.appending(path: "settings-\(stamp)-\(n).json")
        }
        try fm.copyItem(at: paths.claudeSettings, to: dest)
        return dest
    }

    /// Atomic write that keeps the file's permissions.
    func writePreservingAttributes(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        try Data(text.utf8).write(to: url, options: .atomic)
        if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
    }

    func shellQuoted(_ path: String) -> String {
        if path.allSatisfy({ $0.isLetter || $0.isNumber || "/._-".contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
