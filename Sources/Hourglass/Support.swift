import AppKit
import os
import ServiceManagement
import SwiftUI
import UsageCore

enum Log {
    static let subsystem = "io.github.rahuljordashe.hourglass"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let data = Logger(subsystem: subsystem, category: "data")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// Sandbox mode: when `HOURGLASS_HOME` is set, every path, preference and the login item are
/// redirected or skipped, so the app can be exercised without touching the real setup.
enum AppEnvironment {
    static let isSandboxed = ProcessInfo.processInfo.environment["HOURGLASS_HOME"].map { !$0.isEmpty } ?? false

    nonisolated(unsafe) static let defaults: UserDefaults = isSandboxed
        ? (UserDefaults(suiteName: "io.github.rahuljordashe.hourglass.sandbox") ?? .standard)
        : .standard
}

/// The notch layout, kept in the app's own defaults on this Mac and nowhere else.
enum LayoutDefaults {
    static let layoutKey = "notchLayout"
    static let hintKey = "didShowCustomiseHint"

    static func load() -> NotchLayout {
        NotchLayout.decode(AppEnvironment.defaults.data(forKey: layoutKey))
    }

    static func save(_ layout: NotchLayout) {
        if layout == .default {
            AppEnvironment.defaults.removeObject(forKey: layoutKey)
        } else if let data = layout.encoded() {
            AppEnvironment.defaults.set(data, forKey: layoutKey)
        }
    }

    /// The one-time customise hint: true the first time it's asked, then never again.
    static func takeHint() -> Bool {
        guard !AppEnvironment.defaults.bool(forKey: hintKey) else { return false }
        AppEnvironment.defaults.set(true, forKey: hintKey)
        return true
    }
}

enum Links {
    static let usageSettings = URL(string: "https://claude.ai/settings/usage")!
}

// MARK: - Theme

enum Theme {
    static let normal = Color(white: 0.95)                             // #F2F2F2
    static let ready = Color(red: 0.486, green: 0.839, blue: 0.604)    // #7CD69A, only for "ready"
    static let stale = Color.white.opacity(0.42)
    static let warning = Color(red: 0.961, green: 0.722, blue: 0.239)  // #F5B83D
    static let critical = Color(red: 1.0, green: 0.353, blue: 0.306)   // #FF5A4E
    static let track = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)
    static let card = Color.white.opacity(0.06)
    /// The editor's selection and Done button: macOS's dark-mode blue.
    static let accent = Color(red: 0.039, green: 0.518, blue: 1.0)    // #0A84FF

    static func color(for level: UsageLevel) -> Color {
        switch level {
        case .normal: normal
        case .warning: warning
        case .critical, .exhausted: critical
        }
    }
}

// MARK: - Launch at login

@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = false
    private(set) var needsApproval = false

    private static let didOfferKey = "didEnableLaunchAtLoginOnFirstRun"

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    /// Turns launch at login on the first time the app runs; after that it's the user's choice.
    func enableOnFirstRun() {
        guard !AppEnvironment.defaults.bool(forKey: Self.didOfferKey) else { return }
        AppEnvironment.defaults.set(true, forKey: Self.didOfferKey)
        set(true)
    }

    func set(_ enabled: Bool) {
        guard !AppEnvironment.isSandboxed else {
            Log.app.info("Sandbox mode: not changing launch at login")
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}

// MARK: - Connection to Claude Code

@MainActor
@Observable
final class ConnectionManager {
    private(set) var status: StatusLineInstaller.Status = .disconnected(currentCommand: nil)
    private(set) var lastError: String?

    @ObservationIgnored private let installer: StatusLineInstaller
    @ObservationIgnored private let paths: NotchPaths

    var isConnected: Bool { status == .connected }

    init(paths: NotchPaths) {
        self.paths = paths
        self.installer = StatusLineInstaller(paths: paths)
        refresh()
    }

    func refresh() {
        status = installer.status()
    }

    /// The bridge binary shipped inside the app bundle.
    var bundledBridge: URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "hourglass-bridge") { return url }
        // Running unbundled (swift run): the bridge sits next to the app executable.
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "hourglass-bridge")
        return sibling.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// Readings no longer come from the status line, so launch never connects it. If it is still
    /// connected from an earlier version, keep its installed bridge copy current until it's removed.
    func setUpOnLaunch() {
        refresh()
        if isConnected, let bridge = bundledBridge {
            do { try installer.installBridge(from: bridge) } catch {
                Log.app.error("Couldn't refresh bridge: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func connect() {
        guard let bridge = bundledBridge else {
            lastError = "The bridge is missing from the app bundle."
            return
        }
        do {
            let report = try installer.connect(bridgeSource: bridge)
            lastError = nil
            Log.app.info("Connected. Previous status line: \(report.previousCommand ?? "none", privacy: .public). Backup: \(report.backupURL?.path ?? "none", privacy: .public)")
        } catch {
            lastError = "Couldn't update Claude Code settings: \(error.localizedDescription)"
            Log.app.error("Connect failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func disconnect() {
        do {
            let report = try installer.disconnect()
            lastError = nil
            Log.app.info("Disconnected. Restored: \(report.newCommand ?? "none", privacy: .public)")
        } catch {
            lastError = "Couldn't restore Claude Code settings: \(error.localizedDescription)"
        }
        refresh()
    }

    func revealLog() {
        let log = paths.bridgeLog
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(paths.supportDirectory)
        }
    }
}
