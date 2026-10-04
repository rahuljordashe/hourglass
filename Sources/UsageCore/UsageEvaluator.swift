import Foundation

public enum UsageLevel: Int, Comparable, Sendable {
    case normal, warning, critical, exhausted

    public static let warningThreshold = 75.0
    public static let criticalThreshold = 90.0

    public init(percentage: Double) {
        switch percentage {
        case 100...: self = .exhausted
        case Self.criticalThreshold...: self = .critical
        case Self.warningThreshold...: self = .warning
        default: self = .normal
        }
    }

    public static func < (lhs: UsageLevel, rhs: UsageLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum Freshness: Sendable, Equatable {
    /// No reading has ever arrived.
    case none
    /// Updated within the last ten minutes.
    case fresh
    /// Ten to thirty minutes old.
    case aging
    /// Over thirty minutes old: the notch greys out.
    case stale

    public static let agingAfter: TimeInterval = 10 * 60
    public static let staleAfter: TimeInterval = 30 * 60

    public init(age: TimeInterval?) {
        guard let age else { self = .none; return }
        switch age {
        case ..<Self.agingAfter: self = .fresh
        case ..<Self.staleAfter: self = .aging
        default: self = .stale
        }
    }
}

public enum Pace: Sendable, Equatable {
    /// Using faster than an even burn would for the time elapsed.
    case ahead(Double)
    case onPace
    /// Using slower than an even burn.
    case behind(Double)

    /// Within this many percentage points counts as on pace.
    public static let tolerance = 5.0

    public init(delta: Double) {
        if delta > Self.tolerance { self = .ahead(delta) }
        else if delta < -Self.tolerance { self = .behind(-delta) }
        else { self = .onPace }
    }
}

/// Everything the UI needs about one window at a given moment.
public struct WindowStatus: Sendable, Equatable {
    public var kind: UsageWindowKind
    /// What to display: the reported percentage, or 0 once the window has reset.
    public var percentage: Double
    /// The last reported percentage, even after reset.
    public var reportedPercentage: Double
    public var resetsAt: Date
    public var observedAt: Date
    /// The reset time has passed since the last reading. Usage since then is unknown.
    public var isReset: Bool
    public var timeUntilReset: TimeInterval
    /// Fraction of the window that has elapsed now, 0 to 1.
    public var elapsedFraction: Double
    /// Percentage points above (positive) or below an even burn rate. Nil once reset.
    public var paceDelta: Double?
    /// When the limit will be reached at the average rate so far, if that is before the reset.
    public var projectedLimitAt: Date?

    public var level: UsageLevel { isReset ? .normal : UsageLevel(percentage: percentage) }
    public var pace: Pace? { paceDelta.map(Pace.init(delta:)) }
    /// Clamped 0 to 1 for drawing.
    public var fraction: Double { min(max(percentage / 100, 0), 1) }
}

/// A per-model (or per-surface) weekly window, such as "Fable".
public struct ScopedWindowStatus: Sendable, Equatable, Identifiable {
    public var name: String
    public var percent: Double?
    public var resetsAt: Date?
    /// No window open, or its reset time has passed since the reading.
    public var isReady: Bool

    public var id: String { name }
    public var level: UsageLevel { isReady ? .normal : UsageLevel(percentage: percent ?? 0) }
    public var fraction: Double { isReady ? 0 : min(max((percent ?? 0) / 100, 0), 1) }
}

public struct UsageState: Sendable, Equatable {
    public var fiveHour: WindowStatus?
    public var sevenDay: WindowStatus?
    public var lastUpdated: Date?
    public var age: TimeInterval?
    public var freshness: Freshness
    public var source: ReadingSource?
    /// Windows with a known percentage but no open window (`resets_at: null`): "ready", not 0%.
    public var ready: Set<UsageWindowKind> = []
    public var scoped: [ScopedWindowStatus] = []
    public var credits: PlanUsage.Credits?
    public var promos: [PlanUsage.Promo] = []
    /// The numbers are Claude Code's last-known data, not a fresh read.
    public var isSeeded = false

    public var hasData: Bool { fiveHour != nil || sevenDay != nil || !ready.isEmpty }

    /// Ready: no window open, or the reset time passed since the reading.
    public func isReady(_ kind: UsageWindowKind) -> Bool {
        ready.contains(kind) || (window(kind)?.isReset ?? false)
    }

    public func window(_ kind: UsageWindowKind) -> WindowStatus? {
        switch kind {
        case .fiveHour: fiveHour
        case .sevenDay: sevenDay
        }
    }

    public static let empty = UsageState(fiveHour: nil, sevenDay: nil, lastUpdated: nil, age: nil, freshness: .none, source: nil)
}

public enum UsageEvaluator {
    /// Projections need this much of the window to have elapsed before they mean anything.
    public static let minimumElapsedForProjection = 0.08

    public static func evaluate(_ snapshot: UsageSnapshot?, now: Date) -> UsageState {
        guard let snapshot else { return .empty }
        let lastUpdated = snapshot.lastUpdated
        let age = lastUpdated.map { max(0, now.timeIntervalSince($0)) }
        return UsageState(
            fiveHour: snapshot.fiveHour.map { status(.fiveHour, $0, now: now) },
            sevenDay: snapshot.sevenDay.map { status(.sevenDay, $0, now: now) },
            lastUpdated: lastUpdated,
            age: age,
            freshness: Freshness(age: age),
            source: snapshot.source
        )
    }

    /// The same evaluation for a reading the app fetched from Claude Code itself.
    public static func evaluate(plan usage: PlanUsage?, now: Date) -> UsageState {
        guard let usage else { return .empty }
        var ready = Set<UsageWindowKind>()
        func windowStatus(_ kind: UsageWindowKind) -> WindowStatus? {
            guard let window = usage.window(kind), let percent = window.percent else { return nil }
            guard let resetsAt = window.resetsAt else {
                ready.insert(kind)
                return nil
            }
            return status(kind, WindowReading(usedPercentage: max(0, percent), resetsAt: resetsAt, observedAt: usage.fetchedAt), now: now)
        }
        let five = windowStatus(.fiveHour)
        let week = windowStatus(.sevenDay)
        let scoped = usage.scopedWeekly.compactMap { row -> ScopedWindowStatus? in
            guard let name = row.scopeName else { return nil }
            let passed = row.resetsAt.map { now >= $0 } ?? false
            return ScopedWindowStatus(name: name, percent: row.percent, resetsAt: row.resetsAt,
                                      isReady: (row.percent != nil && row.resetsAt == nil) || passed)
        }
        let age = max(0, now.timeIntervalSince(usage.fetchedAt))
        return UsageState(
            fiveHour: five,
            sevenDay: week,
            lastUpdated: usage.fetchedAt,
            age: age,
            freshness: Freshness(age: age),
            source: nil,
            ready: ready,
            scoped: scoped,
            credits: usage.credits,
            promos: usage.promos.filter { promo in
                guard let expires = promo.expiresAt else { return true }
                return expires > now
            },
            isSeeded: usage.isSeeded
        )
    }

    /// The next moment the displayed state changes on its own, for a fetched reading.
    public static func nextReset(after now: Date, in usage: PlanUsage?) -> Date? {
        guard let usage else { return nil }
        let resets = [usage.session?.resetsAt, usage.weekly?.resetsAt] + usage.scopedWeekly.map(\.resetsAt) + usage.promos.map(\.expiresAt)
        return resets.compactMap { $0 }.filter { $0 > now }.min()
    }

    public static func status(_ kind: UsageWindowKind, _ reading: WindowReading, now: Date) -> WindowStatus {
        let duration = kind.duration
        let isReset = now >= reading.resetsAt
        let windowStart = reading.resetsAt.addingTimeInterval(-duration)
        let elapsedNow = min(max(now.timeIntervalSince(windowStart) / duration, 0), 1)
        let percentage = isReset ? 0 : reading.usedPercentage

        var paceDelta: Double?
        var projected: Date?
        if !isReset {
            paceDelta = reading.usedPercentage - elapsedNow * 100

            // Average burn rate from the window's start to the moment of the reading.
            let elapsedAtReading = reading.observedAt.timeIntervalSince(windowStart)
            // Only warn when clearly ahead of pace, so the label and the warning never disagree.
            if let delta = paceDelta, delta > Pace.tolerance,
               elapsedAtReading / duration >= minimumElapsedForProjection,
               reading.usedPercentage > 0,
               reading.usedPercentage < 100 {
                let ratePerSecond = reading.usedPercentage / elapsedAtReading
                let secondsToLimit = (100 - reading.usedPercentage) / ratePerSecond
                let hitAt = reading.observedAt.addingTimeInterval(secondsToLimit)
                if hitAt < reading.resetsAt { projected = hitAt }
            }
        }

        return WindowStatus(
            kind: kind,
            percentage: percentage,
            reportedPercentage: reading.usedPercentage,
            resetsAt: reading.resetsAt,
            observedAt: reading.observedAt,
            isReset: isReset,
            timeUntilReset: max(0, reading.resetsAt.timeIntervalSince(now)),
            elapsedFraction: elapsedNow,
            paceDelta: paceDelta,
            projectedLimitAt: projected
        )
    }

    /// The next moment the displayed state changes on its own (a window resets). Lets the app
    /// schedule one precise wake-up instead of polling.
    public static func nextReset(after now: Date, in snapshot: UsageSnapshot?) -> Date? {
        [snapshot?.fiveHour?.resetsAt, snapshot?.sevenDay?.resetsAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
    }
}
