import Foundation

/// One raw reading as kept in the usage history: a line of `readings-YYYY-MM.jsonl`.
///
/// Only the numbers Claude Code reported, never anything about the account beyond the plan type.
/// Every value but `time` is optional, so a line written by a later version still reads.
public struct HistoryLine: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var percent: Double?
        public var resetsAt: Date?

        public init(percent: Double?, resetsAt: Date?) {
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    /// A per-model (or per-surface) weekly limit, such as Fable.
    public struct ModelRow: Codable, Equatable, Sendable {
        public var name: String
        public var percent: Double?
        public var resetsAt: Date?

        public init(name: String, percent: Double?, resetsAt: Date?) {
            self.name = name
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    public struct Promo: Codable, Equatable, Sendable {
        public var key: String
        public var limit: Double?
        public var used: Double?
        public var remaining: Double?
        public var expiresAt: Date?

        public init(key: String, limit: Double?, used: Double?, remaining: Double?, expiresAt: Date?) {
            self.key = key
            self.limit = limit
            self.used = used
            self.remaining = remaining
            self.expiresAt = expiresAt
        }
    }

    /// When Claude Code answered.
    public var time: Date
    /// The fresh reading the app took before this one, written or not. Readings identical to the
    /// last line aren't written, so this is what tells a flat stretch from a gap.
    public var previousReadAt: Date?
    /// A heartbeat: the same numbers as the line before, written at most once an hour.
    public var unchanged: Bool
    public var fiveHour: Window?
    public var weekly: Window?
    public var models: [ModelRow]
    /// Usage credits spent this month, in major units (dollars, not cents).
    public var creditsUsed: Double?
    public var creditsLimit: Double?
    public var currency: String?
    public var promos: [Promo]
    public var plan: String?
    public var source: String?

    public init(time: Date, previousReadAt: Date? = nil, unchanged: Bool = false, fiveHour: Window? = nil, weekly: Window? = nil,
                models: [ModelRow] = [], creditsUsed: Double? = nil, creditsLimit: Double? = nil, currency: String? = nil,
                promos: [Promo] = [], plan: String? = nil, source: String? = nil) {
        self.time = time
        self.previousReadAt = previousReadAt
        self.unchanged = unchanged
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.models = models
        self.creditsUsed = creditsUsed
        self.creditsLimit = creditsLimit
        self.currency = currency
        self.promos = promos
        self.plan = plan
        self.source = source
    }

    /// The history line for a reading.
    public init(_ usage: PlanUsage, previousReadAt: Date?) {
        self.init(
            time: usage.fetchedAt,
            previousReadAt: previousReadAt,
            fiveHour: usage.session.map { Window(percent: $0.percent, resetsAt: $0.resetsAt) },
            weekly: usage.weekly.map { Window(percent: $0.percent, resetsAt: $0.resetsAt) },
            models: usage.scopedWeekly.compactMap { row in
                row.scopeName.map { ModelRow(name: $0, percent: row.percent, resetsAt: row.resetsAt) }
            },
            creditsUsed: usage.credits?.used,
            creditsLimit: usage.credits?.monthlyLimit,
            currency: usage.credits?.currency,
            promos: usage.promos.map {
                Promo(key: $0.key, limit: $0.limitDollars, used: $0.usedDollars, remaining: $0.remainingDollars, expiresAt: $0.expiresAt)
            },
            plan: usage.subscriptionType,
            source: usage.source.rawValue
        )
    }

    /// The same numbers, ignoring when they were read.
    public func sameReading(as other: HistoryLine) -> Bool {
        var a = self, b = other
        a.time = .distantPast; b.time = .distantPast
        a.previousReadAt = nil; b.previousReadAt = nil
        a.unchanged = false; b.unchanged = false
        return a == b
    }

    // Missing lists read as empty and a missing flag as false, so older or newer lines still decode.
    enum CodingKeys: String, CodingKey {
        case time, previousReadAt = "prev", unchanged, fiveHour, weekly, models, creditsUsed, creditsLimit, currency, promos, plan, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        previousReadAt = try? c.decodeIfPresent(Date.self, forKey: .previousReadAt)
        unchanged = (try? c.decodeIfPresent(Bool.self, forKey: .unchanged)) ?? false
        fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
        weekly = try? c.decodeIfPresent(Window.self, forKey: .weekly)
        models = (try? c.decodeIfPresent([ModelRow].self, forKey: .models)) ?? []
        creditsUsed = try? c.decodeIfPresent(Double.self, forKey: .creditsUsed)
        creditsLimit = try? c.decodeIfPresent(Double.self, forKey: .creditsLimit)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        promos = (try? c.decodeIfPresent([Promo].self, forKey: .promos)) ?? []
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encodeIfPresent(previousReadAt, forKey: .previousReadAt)
        if unchanged { try c.encode(true, forKey: .unchanged) }
        try c.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(weekly, forKey: .weekly)
        if !models.isEmpty { try c.encode(models, forKey: .models) }
        try c.encodeIfPresent(creditsUsed, forKey: .creditsUsed)
        try c.encodeIfPresent(creditsLimit, forKey: .creditsLimit)
        try c.encodeIfPresent(currency, forKey: .currency)
        if !promos.isEmpty { try c.encode(promos, forKey: .promos) }
        try c.encodeIfPresent(plan, forKey: .plan)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

// MARK: - What gets written

/// Which fresh readings become history lines.
public enum HistoryRecording {
    /// A run of identical readings still writes one line this often, so a flat stretch can be told
    /// apart from a gap (the Mac asleep, the app closed).
    public static let heartbeatInterval: TimeInterval = 3600

    /// The line to write for `usage`, or nil to write nothing.
    /// - Last-known (seeded) readings are never written.
    /// - A reading identical to the last line is skipped, except for an hourly heartbeat.
    /// - `lastReadAt` is the previous fresh reading, written or skipped.
    public static func line(for usage: PlanUsage, lastWritten: HistoryLine?, lastReadAt: Date?) -> HistoryLine? {
        guard !usage.isSeeded else { return nil }
        var line = HistoryLine(usage, previousReadAt: lastReadAt)
        guard let last = lastWritten else { return line }
        guard line.time > last.time else { return nil }
        if line.sameReading(as: last) {
            guard line.time.timeIntervalSince(last.time) >= heartbeatInterval else { return nil }
            line.unchanged = true
        }
        return line
    }
}

// MARK: - Coding

public enum HistoryCoding {
    /// One compact line per value, keys sorted, dates as ISO 8601 so the files read on their own.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Decodes each line of a JSON Lines file, skipping blank, partial or corrupt lines.
    public static func decodeLines<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        let decoder = decoder()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { line in
            try? decoder.decode(T.self, from: Data(line))
        }
    }

    public static func encodeLines<T: Encodable>(_ values: [T]) throws -> Data {
        let encoder = encoder()
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0A)
        }
        return data
    }
}
