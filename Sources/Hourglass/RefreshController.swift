import AppKit
import CoreGraphics
import Observation
import UsageCore

/// Fetches usage by asking the installed Claude Code (see `ClaudeCodeReader`), on four triggers
/// that share one budget (see `RefreshScheduler`): hover (never reads), expand, ↻ and a background
/// timer that pauses while the Mac is asleep, locked or idle.
@MainActor
@Observable
final class RefreshController {
    private(set) var isReading = false
    /// A short-lived answer to ↻ when no read was made ("Up to date · checked 25s ago").
    private(set) var notice: String?
    /// Why the last read didn't produce numbers, if it didn't.
    private(set) var problem: String?
    private(set) var ledger: ReadLedger

    @ObservationIgnored private let paths: NotchPaths
    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private let scheduler = RefreshScheduler()
    @ObservationIgnored private var reader: ClaudeCodeReader?
    @ObservationIgnored private var backgroundTimer: Timer?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var isLocked = false

    /// No input for this long counts as idle.
    static let idleAfter: TimeInterval = 5 * 60
    /// While idle, asleep or locked, check again this often.
    static let inactiveRecheck: TimeInterval = 60
    /// Claude Code is refreshing its login: try again shortly.
    static let refreshLockRetry: TimeInterval = 30

    init(paths: NotchPaths, store: UsageStore) {
        self.paths = paths
        self.store = store
        self.ledger = JSONFile.read(ReadLedger.self, from: paths.readLedgerFile) ?? ReadLedger()
    }

    func start() {
        observeActivity()
        request(.background)
    }

    // MARK: Triggers

    func request(_ trigger: RefreshTrigger) {
        let now = Date()
        let decision = scheduler.decide(trigger, now: now, ledger: ledger, usage: store.usage,
                                        isReading: isReading || (reader?.isBusy ?? false), isActive: isActive)
        switch decision {
        case .read:
            read(trigger)
        case .skip(let skip):
            if trigger == .manual { showNotice(for: skip, now: now) }
            if trigger == .background { scheduleBackground(after: skip, now: now) }
        }
    }

    /// "Next refresh in N min" when reads are paused by the budget, backoff or the post-limit quiet.
    func waitDescription(now: Date) -> String? {
        guard !isReading, let blocked = scheduler.blockedUntil(now: now, ledger: ledger) else { return nil }
        return "Next refresh in \(Self.minutes(blocked.until.timeIntervalSince(now)))"
    }

    /// The most reads allowed in any hour, all triggers together.
    var hourlyCap: Int { scheduler.hourlyCap }

    /// Reads used in the trailing hour, for the expanded view's footer.
    func readsInLastHour(now: Date) -> Int {
        ledger.reads.filter { now.timeIntervalSince($0.startedAt) < 3600 }.count
    }

    // MARK: Reading

    private func read(_ trigger: RefreshTrigger) {
        guard let executable = locateClaude() else {
            problem = "Couldn't find Claude Code. Install it and log in with claude."
            scheduleBackground(at: Date().addingTimeInterval(15 * 60))
            return
        }
        let reader = readerFor(executable)
        isReading = true
        notice = nil
        let started = Date()
        Log.data.info("Read (\(trigger.rawValue, privacy: .public)) starting")

        Task.detached(priority: .utility) {
            let report = reader.read()
            await MainActor.run { self.finish(report, trigger: trigger, started: started) }
        }
    }

    private func finish(_ report: ClaudeCodeReader.Report, trigger: RefreshTrigger, started: Date) {
        isReading = false
        let now = Date()
        Log.data.info("Read (\(trigger.rawValue, privacy: .public)) finished in \(report.duration, format: .fixed(precision: 1), privacy: .public)s via \(report.mode?.rawValue ?? "none", privacy: .public): \(String(describing: report.outcome), privacy: .public)")

        for _ in 0..<report.launches { scheduler.recordStart(trigger, at: started, in: &ledger) }

        let result: ReadResult?
        switch report.outcome {
        case .usage(let usage):
            store.apply(usage)
            result = usage.isSeeded ? .seeded : .success
            problem = usage.isSeeded ? "Claude Code gave its last known numbers" : nil
        case .unavailable(let message):
            result = .unavailable
            problem = message
        case .error(let message, let rateLimited):
            result = rateLimited ? .rateLimited : .failed
            problem = rateLimited ? "Usage server is busy" : "Claude Code: \(message)"
        case .timedOut:
            result = .failed
            problem = "Claude Code took too long to answer"
        case .launchFailed(let message):
            result = .failed
            problem = message
        case .refreshLockHeld:
            result = nil
            if trigger == .manual { flash("Claude Code is signing in, try again shortly") }
            scheduleBackground(at: now.addingTimeInterval(Self.refreshLockRetry))
        case .busy:
            result = nil
        }

        if let result, report.launches > 0 {
            scheduler.recordFinish(result, at: now, usage: result == .success ? store.usage : nil,
                                   jitterUnit: Double.random(in: 0...1), in: &ledger)
        }
        saveLedger()
        if result != nil { scheduleBackground(at: scheduler.nextBackgroundRead(now: now, ledger: ledger, usage: store.usage)) }
    }

    private func readerFor(_ executable: URL) -> ClaudeCodeReader {
        // Keep the reader that may still own a running launch, so "one at a time" holds.
        if let reader, reader.isBusy || reader.configuration.executable == executable { return reader }
        let reader = ClaudeCodeReader(.init(
            executable: executable,
            home: paths.home,
            user: NSUserName(),
            tempDirectory: FileManager.default.temporaryDirectory
        ))
        self.reader = reader
        return reader
    }

    private func saveLedger() {
        do { try JSONFile.write(ledger, to: paths.readLedgerFile) } catch {
            Log.data.error("Couldn't save the read ledger: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Messages

    private func showNotice(for skip: RefreshScheduler.Skip, now: Date) {
        switch skip {
        case .upToDate(let ago):
            flash("Up to date · checked \(Int(ago.rounded()))s ago")
        case .wait(let until, let reason):
            let wait = "Next refresh in \(Self.minutes(until.timeIntervalSince(now)))"
            switch reason {
            case .budget: flash("Hourly read limit reached. \(wait)")
            case .backoff: flash(wait)
            case .limitQuiet: flash("Limit just reached. \(wait)")
            }
        case .readInProgress, .fresh, .notDue, .inactive, .hoverNeverReads:
            break
        }
    }

    private func flash(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    static func minutes(_ interval: TimeInterval) -> String {
        let m = Int((max(0, interval) / 60).rounded(.up))
        return m <= 1 ? "1 min" : "\(m) min"
    }

    // MARK: Background timer

    private func scheduleBackground(after skip: RefreshScheduler.Skip, now: Date) {
        switch skip {
        case .notDue(let next), .wait(let next, _):
            scheduleBackground(at: next)
        case .inactive:
            scheduleBackground(at: now.addingTimeInterval(Self.inactiveRecheck))
        case .readInProgress:
            break // finishing the read schedules the next one
        case .fresh, .upToDate, .hoverNeverReads:
            scheduleBackground(at: scheduler.nextBackgroundRead(now: now, ledger: ledger, usage: store.usage))
        }
    }

    private func scheduleBackground(at date: Date) {
        backgroundTimer?.invalidate()
        guard !isAsleep else { return }
        let fireAt = max(date, Date().addingTimeInterval(1))
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.request(.background) }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    // MARK: Activity

    private var isActive: Bool {
        !isAsleep && !isLocked && Self.idleSeconds < Self.idleAfter
    }

    /// Seconds since the last keyboard, mouse or trackpad input. Needs no permission.
    private static var idleSeconds: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private func observeActivity() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (RefreshController) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            }
            observers.append((center, token))
        }
        on(workspace, NSWorkspace.willSleepNotification) { $0.isAsleep = true; $0.backgroundTimer?.invalidate() }
        on(workspace, NSWorkspace.didWakeNotification) { $0.isAsleep = false; $0.request(.background) }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.isLocked = true }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.isLocked = false; $0.request(.background) }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false; $0.request(.background) }
    }

    // MARK: Finding Claude Code

    private func locateClaude() -> URL? {
        let fm = FileManager.default
        if let found = HardenedLaunch.candidateExecutables(home: paths.home).first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        return nil
    }
}
