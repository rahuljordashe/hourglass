import Foundation

/// What asked for fresh numbers.
public enum RefreshTrigger: String, Codable, Sendable {
    /// Pointer over the notch. Never reads: shows cached numbers and their age.
    case hover
    /// The notch opened to its full view.
    case expand
    /// The ↻ button.
    case manual
    /// The app's own timer.
    case background
}

/// How a read ended.
public enum ReadResult: String, Codable, Sendable {
    case success
    /// Claude Code answered with last-known data instead of a fresh read.
    case seeded
    /// The usage endpoint's rate limit (HTTP 429).
    case rateLimited
    /// Plan limits don't apply to this login.
    case unavailable
    /// Timed out, couldn't start, or an answer we couldn't use.
    case failed
}

/// The persisted record of reads, shared by every trigger: one budget for all of them.
public struct ReadLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var startedAt: Date
        public var trigger: RefreshTrigger

        public init(startedAt: Date, trigger: RefreshTrigger) {
            self.startedAt = startedAt
            self.trigger = trigger
        }
    }

    /// One 5-hour reading, for spotting fast-rising usage.
    public struct Sample: Codable, Equatable, Sendable {
        public var at: Date
        public var percent: Double
        public var resetsAt: Date?

        public init(at: Date, percent: Double, resetsAt: Date?) {
            self.at = at
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    /// Reads started in the last hour (older ones are pruned).
    public var reads: [Entry] = []
    public var lastFinishedAt: Date?
    public var lastSuccessAt: Date?
    public var lastResult: ReadResult?
    public var backoffUntil: Date?
    /// Consecutive unsuccessful reads; picks the step on the backoff ladder.
    public var backoffLevel = 0
    /// No reads until then, after a limit was hit.
    public var quietUntil: Date?
    /// Highest percentage seen at the last successful read, to notice the moment a limit is hit.
    public var lastHighestPercent: Double?
    /// The last two successful 5-hour readings, oldest first.
    public var samples: [Sample] = []
    /// Added to the next background interval so reads aren't on a fixed beat.
    public var jitter: TimeInterval = 0

    public init() {}
}

/// Decides whether a trigger may read now, under one budget for all triggers.
///
/// Pure: the clock, activity and current usage are passed in, so every rule is testable.
public struct RefreshScheduler: Sendable {
    public enum WaitReason: Equatable, Sendable {
        case budget, backoff, limitQuiet
    }

    public enum Skip: Equatable, Sendable {
        case hoverNeverReads
        case readInProgress
        /// Asleep, locked or idle. Background only.
        case inactive
        /// Expand with numbers newer than `expandStaleAfter`.
        case fresh(age: TimeInterval)
        /// ↻ within `manualMinInterval` of the last read: "Up to date · checked Ns ago".
        case upToDate(checkedAgo: TimeInterval)
        /// Background read not due yet.
        case notDue(next: Date)
        /// Budget, backoff or the post-limit quiet period: "Next refresh in N min".
        case wait(until: Date, reason: WaitReason)
    }

    public enum Decision: Equatable, Sendable {
        case read
        case skip(Skip)
    }

    public var hourlyCap = 10
    /// Six, so the 10-minute busy cadence holds instead of four quick reads and a half-hour gap.
    public var backgroundHourlyCap = 6
    public var expandStaleAfter: TimeInterval = 120
    public var manualMinInterval: TimeInterval = 60
    public var backgroundInterval: TimeInterval = 15 * 60
    public var busyBackgroundInterval: TimeInterval = 10 * 60
    /// At or above this percentage (any window), background reads use the busy interval.
    public var busyPercent = 70.0
    /// 5-hour usage rising at least this many points per minute counts as rising fast.
    public var risingFastPointsPerMinute = 0.5
    public var limitQuiet: TimeInterval = 3 * 60
    public var maxJitter: TimeInterval = 60
    public var rateLimitBackoff: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]
    public var seededBackoff: [TimeInterval] = [5 * 60, 10 * 60, 20 * 60, 40 * 60, 60 * 60]
    public var failureBackoff: [TimeInterval] = [2 * 60, 5 * 60, 10 * 60, 20 * 60, 30 * 60]
    public var unavailableBackoff: [TimeInterval] = [60 * 60]

    static let hour: TimeInterval = 3600

    public init() {}

    // MARK: Deciding

    public func decide(
        _ trigger: RefreshTrigger,
        now: Date,
        ledger: ReadLedger,
        usage: PlanUsage?,
        isReading: Bool,
        isActive: Bool
    ) -> Decision {
        switch trigger {
        case .hover:
            return .skip(.hoverNeverReads)
        case .expand, .manual, .background:
            break
        }
        if isReading { return .skip(.readInProgress) }

        switch trigger {
        case .expand:
            if let age = dataAge(now: now, ledger: ledger, usage: usage), age < expandStaleAfter {
                return .skip(.fresh(age: age))
            }
            if let finished = ledger.lastFinishedAt, now.timeIntervalSince(finished) < manualMinInterval {
                return .skip(.fresh(age: now.timeIntervalSince(finished)))
            }
        case .manual:
            if let finished = ledger.lastFinishedAt, now.timeIntervalSince(finished) < manualMinInterval {
                return .skip(.upToDate(checkedAgo: max(0, now.timeIntervalSince(finished))))
            }
        case .background:
            guard isActive else { return .skip(.inactive) }
            let due = backgroundDue(ledger: ledger, usage: usage)
            if now < due { return .skip(.notDue(next: due)) }
        case .hover:
            break
        }

        if let wait = gate(trigger, now: now, ledger: ledger) {
            return .skip(.wait(until: wait.until, reason: wait.reason))
        }
        return .read
    }

    /// When the next background read may happen, counting every gate. For scheduling the timer
    /// and for "Next refresh in N min".
    public func nextBackgroundRead(now: Date, ledger: ReadLedger, usage: PlanUsage?) -> Date {
        var next = max(now, backgroundDue(ledger: ledger, usage: usage))
        // Gates can open in sequence (budget frees up, then backoff ends), so settle them.
        for _ in 0..<4 {
            guard let wait = gate(.background, now: next, ledger: ledger) else { break }
            next = max(next, wait.until)
        }
        return next
    }

    /// The earliest moment any read is allowed, or nil if one is allowed now.
    public func blockedUntil(now: Date, ledger: ReadLedger) -> (until: Date, reason: WaitReason)? {
        gate(.manual, now: now, ledger: ledger)
    }

    /// Whether usage is high or rising fast enough for the busy cadence.
    public func isBusy(ledger: ReadLedger, usage: PlanUsage?) -> Bool {
        if let highest = usage?.highestPercent, highest >= busyPercent { return true }
        return isRisingFast(ledger)
    }

    func isRisingFast(_ ledger: ReadLedger) -> Bool {
        guard ledger.samples.count >= 2 else { return false }
        let a = ledger.samples[ledger.samples.count - 2]
        let b = ledger.samples[ledger.samples.count - 1]
        let minutes = b.at.timeIntervalSince(a.at) / 60
        guard minutes >= 1, minutes <= 45, !PlanUsageMerger.isNewWindow(b.resetsAt, previous: a.resetsAt) else { return false }
        return (b.percent - a.percent) / minutes >= risingFastPointsPerMinute
    }

    func backgroundDue(ledger: ReadLedger, usage: PlanUsage?) -> Date {
        guard let finished = ledger.lastFinishedAt else { return .distantPast }
        let interval = isBusy(ledger: ledger, usage: usage) ? busyBackgroundInterval : backgroundInterval
        return finished.addingTimeInterval(max(60, interval + ledger.jitter))
    }

    func dataAge(now: Date, ledger: ReadLedger, usage: PlanUsage?) -> TimeInterval? {
        guard let fetched = ledger.lastSuccessAt ?? usage.flatMap({ $0.isSeeded ? nil : $0.fetchedAt }) else { return nil }
        return max(0, now.timeIntervalSince(fetched))
    }

    /// The first gate that blocks a read at `now`: quiet period, backoff, then budget.
    func gate(_ trigger: RefreshTrigger, now: Date, ledger: ReadLedger) -> (until: Date, reason: WaitReason)? {
        if let quiet = ledger.quietUntil, now < quiet { return (quiet, .limitQuiet) }
        if let backoff = ledger.backoffUntil, now < backoff { return (backoff, .backoff) }

        let recent = ledger.reads.filter { now.timeIntervalSince($0.startedAt) < Self.hour }
        if recent.count >= hourlyCap, let oldest = recent.map(\.startedAt).min() {
            return (oldest.addingTimeInterval(Self.hour), .budget)
        }
        if trigger == .background {
            let background = recent.filter { $0.trigger == .background }
            if background.count >= backgroundHourlyCap, let oldest = background.map(\.startedAt).min() {
                return (oldest.addingTimeInterval(Self.hour), .budget)
            }
        }
        return nil
    }

    // MARK: Recording

    /// Call when a read starts, so it counts against the budget while it runs.
    public func recordStart(_ trigger: RefreshTrigger, at now: Date, in ledger: inout ReadLedger) {
        ledger.reads.removeAll { now.timeIntervalSince($0.startedAt) >= Self.hour }
        ledger.reads.append(.init(startedAt: now, trigger: trigger))
    }

    /// Call when a read ends. `jitterUnit` is a random number in 0...1 (injected for tests).
    public func recordFinish(
        _ result: ReadResult,
        at now: Date,
        usage: PlanUsage?,
        jitterUnit: Double,
        in ledger: inout ReadLedger
    ) {
        ledger.lastFinishedAt = now
        ledger.lastResult = result
        ledger.jitter = (min(max(jitterUnit, 0), 1) * 2 - 1) * maxJitter

        switch result {
        case .success:
            ledger.lastSuccessAt = now
            ledger.backoffLevel = 0
            ledger.backoffUntil = nil
            if let usage {
                if let session = usage.session, let percent = session.percent {
                    ledger.samples.append(.init(at: now, percent: percent, resetsAt: session.resetsAt))
                    ledger.samples = Array(ledger.samples.suffix(2))
                }
                let highest = usage.highestPercent
                if let highest, highest >= 100, (ledger.lastHighestPercent ?? 0) < 100 {
                    ledger.quietUntil = now.addingTimeInterval(limitQuiet)
                }
                ledger.lastHighestPercent = highest
            }
        case .seeded:
            backOff(seededBackoff, at: now, in: &ledger)
        case .rateLimited:
            backOff(rateLimitBackoff, at: now, in: &ledger)
        case .unavailable:
            backOff(unavailableBackoff, at: now, in: &ledger)
        case .failed:
            backOff(failureBackoff, at: now, in: &ledger)
        }
        ledger.reads.removeAll { now.timeIntervalSince($0.startedAt) >= Self.hour }
    }

    private func backOff(_ ladder: [TimeInterval], at now: Date, in ledger: inout ReadLedger) {
        ledger.backoffLevel += 1
        let step = ladder[min(ledger.backoffLevel - 1, ladder.count - 1)]
        ledger.backoffUntil = now.addingTimeInterval(step)
    }
}
