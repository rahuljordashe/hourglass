import Foundation

/// The plan usage Claude Code reports for the logged-in account, as one normalised value.
///
/// Every field is optional: Claude Code's answer changes shape between versions and plans, and a
/// missing value means "unknown", never 0. Percentages are 0 to 100 and can go above 100.
public struct PlanUsage: Codable, Equatable, Sendable {
    public static let currentSchema = 2

    public enum Source: String, Codable, Sendable {
        /// The `get_usage` control request.
        case getUsage = "get_usage"
        /// The `usage_report` on `claude -p "/usage"`'s output.
        case usageReport = "usage_report"
    }

    /// A 5-hour or weekly window. `resetsAt == nil` with a known percentage means no window is open
    /// ("ready"), not 0%.
    public struct Window: Codable, Equatable, Sendable {
        public var percent: Double?
        public var resetsAt: Date?

        public init(percent: Double?, resetsAt: Date?) {
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    /// One row of the server's `limits[]`, classified on `kind`.
    public struct Limit: Codable, Equatable, Sendable {
        public enum Category: Equatable, Sendable {
            case session, weeklyAll, weeklyScoped, other
        }

        public var kind: String
        public var group: String?
        public var percent: Double?
        public var severity: String?
        public var resetsAt: Date?
        public var isActive: Bool?
        public var modelName: String?
        public var surfaceName: String?

        public init(kind: String, group: String? = nil, percent: Double?, severity: String? = nil, resetsAt: Date?,
                    isActive: Bool? = nil, modelName: String? = nil, surfaceName: String? = nil) {
            self.kind = kind
            self.group = group
            self.percent = percent
            self.severity = severity
            self.resetsAt = resetsAt
            self.isActive = isActive
            self.modelName = modelName
            self.surfaceName = surfaceName
        }

        public var category: Category {
            switch kind {
            case "session": .session
            case "weekly_all": .weeklyAll
            case "weekly_scoped": .weeklyScoped
            default: .other
            }
        }

        /// "Fable", or the surface name for surface-scoped rows.
        public var scopeName: String? { modelName ?? surfaceName }

        public var window: Window { Window(percent: percent, resetsAt: resetsAt) }
    }

    /// Usage credits (formerly "extra usage"). Money is in major units (dollars, not cents).
    public struct Credits: Codable, Equatable, Sendable {
        public var isEnabled: Bool?
        public var userDisabled: Bool?
        public var disabledReason: String?
        public var monthlyLimit: Double?
        public var used: Double?
        public var utilization: Double?
        public var currency: String?
        public var spendLimitReached: Bool?

        public init(isEnabled: Bool? = nil, userDisabled: Bool? = nil, disabledReason: String? = nil, monthlyLimit: Double? = nil,
                    used: Double? = nil, utilization: Double? = nil, currency: String? = nil, spendLimitReached: Bool? = nil) {
            self.isEnabled = isEnabled
            self.userDisabled = userDisabled
            self.disabledReason = disabledReason
            self.monthlyLimit = monthlyLimit
            self.used = used
            self.utilization = utilization
            self.currency = currency
            self.spendLimitReached = spendLimitReached
        }
    }

    /// A promotional dollar bucket (any top-level object with a `limit_dollars`). Whole dollars.
    public struct Promo: Codable, Equatable, Sendable {
        public var key: String
        public var limitDollars: Double?
        public var usedDollars: Double?
        public var remainingDollars: Double?
        public var expiresAt: Date?

        public init(key: String, limitDollars: Double?, usedDollars: Double?, remainingDollars: Double?, expiresAt: Date?) {
            self.key = key
            self.limitDollars = limitDollars
            self.usedDollars = usedDollars
            self.remainingDollars = remainingDollars
            self.expiresAt = expiresAt
        }
    }

    public var schema: Int
    public var fiveHour: Window?
    public var sevenDay: Window?
    /// `nil` when the answer had no `limits` key at all (for example, last-known data).
    public var limits: [Limit]?
    /// Per-model weekly windows from `get_usage`'s `model_scoped`, used when `limits` is missing.
    public var modelScoped: [Limit]?
    public var credits: Credits?
    public var promos: [Promo]
    public var subscriptionType: String?
    public var source: Source
    public var fetchedAt: Date
    /// Claude Code answered with last-known data instead of a fresh read.
    public var isSeeded: Bool

    public init(
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        limits: [Limit]? = nil,
        modelScoped: [Limit]? = nil,
        credits: Credits? = nil,
        promos: [Promo] = [],
        subscriptionType: String? = nil,
        source: Source = .getUsage,
        fetchedAt: Date,
        isSeeded: Bool = false
    ) {
        self.schema = Self.currentSchema
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
        self.modelScoped = modelScoped
        self.credits = credits
        self.promos = promos
        self.subscriptionType = subscriptionType
        self.source = source
        self.fetchedAt = fetchedAt
        self.isSeeded = isSeeded
    }

    // MARK: Derived

    /// The 5-hour window: the `session` row, else the legacy `five_hour` object.
    public var session: Window? {
        limits?.first { $0.category == .session }?.window ?? fiveHour
    }

    /// The weekly (all models) window: the `weekly_all` row, else the legacy `seven_day` object.
    public var weekly: Window? {
        limits?.first { $0.category == .weeklyAll }?.window ?? sevenDay
    }

    /// Per-model (or per-surface) weekly windows.
    public var scopedWeekly: [Limit] {
        if let limits { return limits.filter { $0.category == .weeklyScoped } }
        return modelScoped ?? []
    }

    public func window(_ kind: UsageWindowKind) -> Window? {
        switch kind {
        case .fiveHour: session
        case .sevenDay: weekly
        }
    }

    /// Highest known percentage across all windows, for cadence and alert decisions.
    public var highestPercent: Double? {
        ([session?.percent, weekly?.percent] + scopedWeekly.map(\.percent)).compactMap { $0 }.max()
    }
}

// MARK: - Folding a new reading into the last one

public enum PlanUsageMerger {
    /// `resets_at` jitters by a second or two between reads. A reset only counts as real (a new
    /// window) when it moves forward by at least this much.
    public static let resetTolerance: TimeInterval = 60

    /// Folds `incoming` into `previous`.
    /// - Reset times that moved less than a minute keep their previous value, so alert ids and
    ///   countdowns stay stable.
    /// - Last-known (seeded) data never replaces a fresh reading.
    public static func merge(_ incoming: PlanUsage, into previous: PlanUsage?) -> PlanUsage {
        guard let previous else { return incoming }
        if incoming.isSeeded && !previous.isSeeded { return previous }

        var next = incoming
        next.fiveHour = stabilise(next.fiveHour, previous: previous.fiveHour)
        next.sevenDay = stabilise(next.sevenDay, previous: previous.sevenDay)
        next.limits = next.limits?.map { row in
            var row = row
            let match = previous.limits?.first { $0.kind == row.kind && $0.scopeName == row.scopeName }
            row.resetsAt = stableReset(row.resetsAt, previous: match?.resetsAt)
            return row
        }
        next.modelScoped = next.modelScoped?.map { row in
            var row = row
            let match = previous.modelScoped?.first { $0.scopeName == row.scopeName }
            row.resetsAt = stableReset(row.resetsAt, previous: match?.resetsAt)
            return row
        }
        return next
    }

    static func stabilise(_ window: PlanUsage.Window?, previous: PlanUsage.Window?) -> PlanUsage.Window? {
        guard var window else { return nil }
        window.resetsAt = stableReset(window.resetsAt, previous: previous?.resetsAt)
        return window
    }

    /// Keeps the previous reset time unless the new one moved forward by a minute or more.
    /// A reset time moving backwards a little is jitter too.
    public static func stableReset(_ incoming: Date?, previous: Date?) -> Date? {
        guard let incoming, let previous else { return incoming }
        let delta = incoming.timeIntervalSince(previous)
        return abs(delta) < resetTolerance ? previous : incoming
    }

    /// True when `incoming` starts a genuinely new window compared with `previous`.
    public static func isNewWindow(_ incoming: Date?, previous: Date?) -> Bool {
        guard let incoming, let previous else { return false }
        return incoming.timeIntervalSince(previous) >= resetTolerance
    }
}

// MARK: - Coding

public enum PlanUsageCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
