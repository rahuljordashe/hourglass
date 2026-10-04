import Foundation

/// One rate-limit window as last seen by the bridge.
public struct WindowReading: Codable, Equatable, Sendable {
    /// Percentage of the window used, as reported by Claude Code (0 to 100, occasionally above).
    public var usedPercentage: Double
    /// When the window resets.
    public var resetsAt: Date
    /// When the bridge last recorded a fresh value for this window.
    public var observedAt: Date

    public init(usedPercentage: Double, resetsAt: Date, observedAt: Date) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
        case observedAt = "observed_at"
    }
}

/// Where the most recent fresh reading came from. Used for the "last reading" line and diagnostics.
public struct ReadingSource: Codable, Equatable, Sendable {
    public var claudeCodeVersion: String?
    /// The value of `CLAUDE_CODE_ENTRYPOINT` in the bridge's environment, such as `cli` or `claude-desktop`.
    public var entrypoint: String?

    public init(claudeCodeVersion: String? = nil, entrypoint: String? = nil) {
        self.claudeCodeVersion = claudeCodeVersion
        self.entrypoint = entrypoint
    }

    enum CodingKeys: String, CodingKey {
        case claudeCodeVersion = "claude_code_version"
        case entrypoint
    }
}

/// Per-session bookkeeping that lets the bridge tell a genuinely new reading from a re-run of an old one.
public struct SessionMark: Codable, Equatable, Sendable {
    /// `cost.total_api_duration_ms` the last time this session ran the status line.
    public var apiDurationMs: Double?
    public var seenAt: Date

    public init(apiDurationMs: Double?, seenAt: Date) {
        self.apiDurationMs = apiDurationMs
        self.seenAt = seenAt
    }

    enum CodingKeys: String, CodingKey {
        case apiDurationMs = "api_ms"
        case seenAt = "seen_at"
    }
}

/// The file the bridge writes and the app watches.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var fiveHour: WindowReading?
    public var sevenDay: WindowReading?
    public var source: ReadingSource?
    /// Last time the bridge ran with rate-limit data, fresh or not.
    public var lastRunAt: Date?
    public var sessions: [String: SessionMark]

    public init(
        fiveHour: WindowReading? = nil,
        sevenDay: WindowReading? = nil,
        source: ReadingSource? = nil,
        lastRunAt: Date? = nil,
        sessions: [String: SessionMark] = [:]
    ) {
        self.schema = Self.currentSchema
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.source = source
        self.lastRunAt = lastRunAt
        self.sessions = sessions
    }

    public static let empty = UsageSnapshot()

    public func reading(for kind: UsageWindowKind) -> WindowReading? {
        switch kind {
        case .fiveHour: fiveHour
        case .sevenDay: sevenDay
        }
    }

    /// The newest moment any window was confirmed.
    public var lastUpdated: Date? {
        [fiveHour?.observedAt, sevenDay?.observedAt].compactMap { $0 }.max()
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case source
        case lastRunAt = "last_run_at"
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        fiveHour = try? c.decodeIfPresent(WindowReading.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(WindowReading.self, forKey: .sevenDay)
        source = try? c.decodeIfPresent(ReadingSource.self, forKey: .source)
        lastRunAt = try? c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        sessions = (try? c.decodeIfPresent([String: SessionMark].self, forKey: .sessions)) ?? [:]
    }
}

public enum UsageWindowKind: String, CaseIterable, Sendable, Codable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    public var duration: TimeInterval {
        switch self {
        case .fiveHour: 5 * 3600
        case .sevenDay: 7 * 24 * 3600
        }
    }

    public var title: String {
        switch self {
        case .fiveHour: "5-hour"
        case .sevenDay: "Weekly"
        }
    }

    public var spokenTitle: String {
        switch self {
        case .fiveHour: "five hour"
        case .sevenDay: "weekly"
        }
    }
}

// MARK: - Coding

public enum SnapshotCoding {
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

    public static func decode(_ data: Data) throws -> UsageSnapshot {
        try decoder().decode(UsageSnapshot.self, from: data)
    }

    public static func encode(_ snapshot: UsageSnapshot) throws -> Data {
        try encoder().encode(snapshot)
    }
}
