import Foundation
import Observation
import UsageCore

/// The History window's optional explanation of spikes from Claude Code's own session logs. Off by
/// default. While on, it reads `~/.claude/projects` read-only when the History window opens and at
/// most once an hour, and keeps only tokens per hour, project and model (see `ClaudeCodeLogScanner`).
@MainActor
@Observable
final class ClaudeCodeLogLayer {
    private(set) var isEnabled: Bool
    private(set) var rows: [HourlyTokens] = []
    private(set) var lastScan: Date?
    /// The last read didn't recognise the logs, so the layer switched itself off.
    private(set) var formatChanged = false
    private(set) var isReading = false

    @ObservationIgnored private let files: HistoryFiles
    @ObservationIgnored private let scanner: ClaudeCodeLogScanner
    @ObservationIgnored private var timer: Timer?

    static let enabledKey = "historyClaudeCodeLogs"
    static let interval: TimeInterval = 3600
    /// Opening the History window reads again unless a read finished this recently.
    static let reopenGrace: TimeInterval = 5 * 60

    init(paths: NotchPaths, files: HistoryFiles) {
        self.files = files
        scanner = ClaudeCodeLogScanner(
            root: paths.claudeProjects, home: paths.home,
            excludedMarkers: ClaudeCodeLogScanner.appMarkers(workFolderPrefix: HardenedLaunch.workFolderPrefix,
                                                             supportDirectory: paths.supportDirectory))
        isEnabled = AppEnvironment.defaults.bool(forKey: Self.enabledKey)
    }

    /// At launch: if it's on, load the totals and keep the hourly schedule.
    func start() {
        let state = files.loadScanState()
        lastScan = state.lastScan
        formatChanged = state.formatChanged
        guard isEnabled else { return }
        rows = files.loadHourlyTokens()
        scheduleHourly()
    }

    /// Loads the saved totals without reading any logs. For drawing stills.
    func loadNow() {
        let state = files.loadScanState()
        lastScan = state.lastScan
        formatChanged = state.formatChanged
        if isEnabled { rows = files.loadHourlyTokens() }
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        AppEnvironment.defaults.set(on, forKey: Self.enabledKey)
        if on {
            formatChanged = false
            rows = files.loadHourlyTokens()
            read()
            scheduleHourly()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func windowOpened() {
        guard isEnabled else { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < Self.reopenGrace { return }
        read()
    }

    // MARK: Reading

    private func scheduleHourly() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if lastScan.map({ Date().timeIntervalSince($0) >= Self.interval }) ?? true { read() }
    }

    private func read() {
        guard isEnabled, !isReading else { return }
        isReading = true
        let files = self.files, scanner = self.scanner
        Task.detached(priority: .utility) {
            let now = Date()
            let result = scanner.scan(state: files.loadScanState(), now: now)
            var rows = files.loadHourlyTokens()
            if case .read = result.outcome {
                rows = HourlyTokens.merge(rows, result.added, now: now)
                try? files.writeHourlyTokens(rows)
            }
            try? files.writeScanState(result.state)
            await MainActor.run { self.finish(result, rows: rows) }
        }
    }

    private func finish(_ result: ClaudeCodeLogScanner.Result, rows: [HourlyTokens]) {
        isReading = false
        lastScan = result.state.lastScan
        self.rows = rows
        switch result.outcome {
        case .read(let messages):
            Log.data.info("Claude Code logs: \(messages, privacy: .public) new messages")
        case .noLogs:
            Log.data.info("Claude Code logs: none found")
        case .formatChanged:
            Log.data.error("Claude Code logs: format not recognised; switching the log layer off")
            formatChanged = true
            setEnabled(false)
        }
    }
}
