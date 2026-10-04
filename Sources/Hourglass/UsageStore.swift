import AppKit
import Observation
import UsageCore

/// Holds the latest plan usage read from Claude Code and keeps a local clock, publishing a
/// ready-to-draw `UsageState`. The reading is saved to disk so the notch shows the last known
/// numbers (with their age) straight after launch, before the first read.
///
/// No polling: the clock wakes once a minute (aligned to the minute), at the exact moment a window
/// resets, and on wake from sleep.
@MainActor
@Observable
final class UsageStore {
    private(set) var usage: PlanUsage?
    private(set) var now = Date()

    var state: UsageState { UsageEvaluator.evaluate(plan: usage, now: now) }

    @ObservationIgnored var onChange: ((UsageState) -> Void)?
    @ObservationIgnored private let paths: NotchPaths
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(paths: NotchPaths) {
        self.paths = paths
    }

    func start() {
        usage = JSONFile.read(PlanUsage.self, from: paths.planUsageFile)
        scheduleTick()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Folds a new reading in (reset jitter ignored, last-known data never replaces fresh data)
    /// and saves it.
    func apply(_ incoming: PlanUsage) {
        let merged = PlanUsageMerger.merge(incoming, into: usage)
        now = Date()
        guard merged != usage else { return }
        usage = merged
        do { try JSONFile.write(merged, to: paths.planUsageFile) } catch {
            Log.data.error("Couldn't save the reading: \(error.localizedDescription, privacy: .public)")
        }
        Log.data.info("Reading: 5h=\(merged.session?.percent ?? -1, privacy: .public) 7d=\(merged.weekly?.percent ?? -1, privacy: .public) seeded=\(merged.isSeeded, privacy: .public)")
        scheduleTick()
        onChange?(state)
    }

    // MARK: Clock

    private func scheduleTick() {
        tickTimer?.invalidate()
        let current = Date()
        let nextMinute = (current.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60.5
        var fireAt = Date(timeIntervalSince1970: nextMinute)
        if let reset = UsageEvaluator.nextReset(after: current, in: usage), reset < fireAt {
            fireAt = reset.addingTimeInterval(0.5)
        }
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        now = Date()
        scheduleTick()
        onChange?(state)
    }
}
