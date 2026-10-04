import Foundation

/// The subset of Claude Code's status line JSON that Hourglass reads.
/// Reference: https://code.claude.com/docs/en/statusline
public struct StatusLineInput: Decodable, Sendable {
    public struct RateWindow: Decodable, Sendable {
        public var usedPercentage: Double?
        public var resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        public init(usedPercentage: Double?, resetsAt: Double?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercentage = c.lenientDouble(.usedPercentage)
            resetsAt = c.lenientDouble(.resetsAt)
        }
    }

    public struct RateLimits: Decodable, Sendable {
        public var fiveHour: RateWindow?
        public var sevenDay: RateWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }

        public init(fiveHour: RateWindow?, sevenDay: RateWindow?) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? c.decodeIfPresent(RateWindow.self, forKey: .fiveHour)
            sevenDay = try? c.decodeIfPresent(RateWindow.self, forKey: .sevenDay)
        }

        public func window(_ kind: UsageWindowKind) -> RateWindow? {
            switch kind {
            case .fiveHour: fiveHour
            case .sevenDay: sevenDay
            }
        }
    }

    public struct Cost: Decodable, Sendable {
        public var totalApiDurationMs: Double?

        enum CodingKeys: String, CodingKey {
            case totalApiDurationMs = "total_api_duration_ms"
        }

        public init(totalApiDurationMs: Double?) {
            self.totalApiDurationMs = totalApiDurationMs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalApiDurationMs = c.lenientDouble(.totalApiDurationMs)
        }
    }

    public var sessionId: String?
    public var version: String?
    public var cost: Cost?
    public var rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case version
        case cost
        case rateLimits = "rate_limits"
    }

    public init(sessionId: String?, version: String?, cost: Cost?, rateLimits: RateLimits?) {
        self.sessionId = sessionId
        self.version = version
        self.cost = cost
        self.rateLimits = rateLimits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        cost = try? c.decodeIfPresent(Cost.self, forKey: .cost)
        rateLimits = try? c.decodeIfPresent(RateLimits.self, forKey: .rateLimits)
    }

    public static func parse(_ data: Data) throws -> StatusLineInput {
        try JSONDecoder().decode(StatusLineInput.self, from: data)
    }
}

extension KeyedDecodingContainer {
    /// Reads a number that may arrive as an integer, a float, a numeric string, or null.
    func lenientDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d.isFinite ? d : nil }
        if let s = try? decodeIfPresent(String.self, forKey: key), let d = Double(s) { return d.isFinite ? d : nil }
        return nil
    }
}
