import Foundation

/// Every location Hourglass reads or writes. Nothing lives outside these, apart from the one
/// `statusLine` entry in Claude Code's user settings.
public struct NotchPaths: Sendable {
    public var home: URL

    public init(home: URL = NotchPaths.defaultHome) {
        self.home = home
    }

    /// The real home folder, or `HOURGLASS_HOME` when set (used by tests and dry runs).
    public static var defaultHome: URL {
        if let override = ProcessInfo.processInfo.environment["HOURGLASS_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/Hourglass
    public var supportDirectory: URL {
        home.appending(path: "Library/Application Support/Hourglass", directoryHint: .isDirectory)
    }

    /// The latest reading, written by the bridge and watched by the app.
    public var usageFile: URL { supportDirectory.appending(path: "usage.json") }

    /// The latest plan usage read from Claude Code by the app itself.
    public var planUsageFile: URL { supportDirectory.appending(path: "plan-usage.json") }

    /// The read budget, backoff and quiet period, so they survive a relaunch.
    public var readLedgerFile: URL { supportDirectory.appending(path: "read-ledger.json") }

    /// Held briefly by the bridge while it reads, merges and writes `usage.json`.
    public var lockFile: URL { supportDirectory.appending(path: ".usage.lock") }

    /// The bridge's configuration: which status line command to chain to.
    public var configFile: URL { supportDirectory.appending(path: "config.json") }

    /// A stable copy of the bridge, so Claude Code keeps working even if the app is moved.
    public var installedBridge: URL { supportDirectory.appending(path: "bin/hourglass-bridge") }

    /// Copies of Claude Code's settings taken before each change.
    public var backupDirectory: URL { supportDirectory.appending(path: "backups", directoryHint: .isDirectory) }

    /// ~/Library/Logs/Hourglass
    public var logDirectory: URL {
        home.appending(path: "Library/Logs/Hourglass", directoryHint: .isDirectory)
    }

    public var bridgeLog: URL { logDirectory.appending(path: "bridge.log") }

    /// Claude Code's user settings.
    public var claudeSettings: URL { home.appending(path: ".claude/settings.json") }
}
