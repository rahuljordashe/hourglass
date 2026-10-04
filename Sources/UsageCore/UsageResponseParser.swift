import Foundation

/// Reads the two answers Claude Code gives about plan usage:
/// - the `control_response` to a `get_usage` control request (primary), and
/// - the `usage_report` on the synthetic assistant message `claude -p "/usage"` prints (fallback).
///
/// Both carry the same `rate_limits` object (the plain usage endpoint's body). Every field is
/// treated as optional, and anything unexpected is skipped rather than failing the whole answer.
public enum UsageResponseParser {
    public enum Outcome: Equatable, Sendable {
        case usage(PlanUsage)
        /// Plan limits don't apply to this login (API key, third-party provider, missing scope).
        case unavailable(String)
        /// Claude Code answered with an error.
        case error(String)

        /// The error text looks like the usage endpoint's rate limit.
        public var isRateLimited: Bool {
            guard case .error(let message) = self else { return false }
            let m = message.lowercased()
            return m.contains("429") || m.contains("rate limit") || m.contains("rate_limit") || m.contains("too many requests")
        }
    }

    /// Percentages outside this range are treated as nonsense and dropped.
    public static let percentRange: ClosedRange<Double> = 0...1000

    // MARK: Entry points

    /// One line of `stream-json` output. Returns nil for lines that aren't an answer.
    public static func parse(line: some StringProtocol, requestId: String?, now: Date) -> Outcome? {
        guard line.contains("control_response") || line.contains("usage_report"),
              let data = String(line).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return parseControlResponse(object, requestId: requestId, now: now)
            ?? parseUsageReport(object, now: now)
    }

    /// The `control_response` matching `requestId` (any `get_usage` answer when nil).
    public static func parseControlResponse(_ object: [String: Any], requestId: String?, now: Date) -> Outcome? {
        guard object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any]
        else { return nil }
        if let requestId, let id = response["request_id"] as? String, id != requestId { return nil }

        if response["subtype"] as? String == "error" {
            return .error((response["error"] as? String) ?? "Claude Code returned an error")
        }
        guard let body = response["response"] as? [String: Any] else {
            return .error("Claude Code's answer had no body")
        }
        if body["rate_limits_available"] as? Bool == false {
            return .unavailable("Plan limits aren't available for this Claude Code login")
        }
        guard let rateLimits = body["rate_limits"] as? [String: Any] else {
            return .error("Claude Code's answer had no usage data")
        }
        return .usage(planUsage(rateLimits: rateLimits, source: .getUsage, subscriptionType: body["subscription_type"] as? String, now: now))
    }

    /// The assistant message carrying `usage_report` from `claude -p "/usage"`.
    public static func parseUsageReport(_ object: [String: Any], now: Date) -> Outcome? {
        guard object["type"] as? String == "assistant",
              let report = object["usage_report"] as? [String: Any]
        else { return nil }
        guard let rateLimits = report["rate_limits"] as? [String: Any] else {
            return .unavailable("Claude Code's usage report had no plan limits")
        }
        return .usage(planUsage(rateLimits: rateLimits, source: .usageReport, subscriptionType: nil, now: now))
    }

    // MARK: The rate_limits object

    static let windowKeys: Set<String> = ["five_hour", "seven_day"]

    public static func planUsage(rateLimits rl: [String: Any], source: PlanUsage.Source, subscriptionType: String?, now: Date) -> PlanUsage {
        let limits = (rl["limits"] as? [Any]).map { $0.compactMap { limitRow($0) } }
        let modelScoped = (rl["model_scoped"] as? [Any]).map { rows in
            rows.compactMap { row -> PlanUsage.Limit? in
                guard let row = row as? [String: Any] else { return nil }
                return PlanUsage.Limit(
                    kind: "weekly_scoped",
                    group: "weekly",
                    percent: percent(row["utilization"]),
                    resetsAt: date(row["resets_at"]),
                    modelName: row["display_name"] as? String
                )
            }
        }

        var promos: [PlanUsage.Promo] = []
        for (key, value) in rl where !windowKeys.contains(key) {
            guard let bucket = value as? [String: Any], let limit = number(bucket["limit_dollars"]) else { continue }
            promos.append(PlanUsage.Promo(
                key: key,
                limitDollars: limit,
                usedDollars: number(bucket["used_dollars"]),
                remainingDollars: number(bucket["remaining_dollars"]),
                expiresAt: date(bucket["resets_at"])
            ))
        }
        promos.sort { $0.key < $1.key }

        // Last-known data comes back with `limits` stripped (and, from get_usage, without
        // `model_scoped`). A fresh answer always has the key, even when the list is empty.
        let isSeeded = !(rl["limits"] is [Any]) && !(rl["model_scoped"] is [Any])

        return PlanUsage(
            fiveHour: window(rl["five_hour"]),
            sevenDay: window(rl["seven_day"]),
            limits: limits,
            modelScoped: modelScoped,
            credits: credits(extra: rl["extra_usage"], spend: rl["spend"]),
            promos: promos,
            subscriptionType: subscriptionType,
            source: source,
            fetchedAt: now,
            isSeeded: isSeeded
        )
    }

    static func window(_ value: Any?) -> PlanUsage.Window? {
        guard let w = value as? [String: Any] else { return nil }
        let p = percent(w["utilization"])
        let r = date(w["resets_at"])
        if p == nil && r == nil { return nil }
        return PlanUsage.Window(percent: p, resetsAt: r)
    }

    static func limitRow(_ value: Any) -> PlanUsage.Limit? {
        guard let row = value as? [String: Any], let kind = row["kind"] as? String else { return nil }
        let scope = row["scope"] as? [String: Any]
        let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
        let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
        return PlanUsage.Limit(
            kind: kind,
            group: row["group"] as? String,
            percent: percent(row["percent"]),
            severity: row["severity"] as? String,
            resetsAt: date(row["resets_at"]),
            isActive: row["is_active"] as? Bool,
            modelName: model,
            surfaceName: surface
        )
    }

    static func credits(extra: Any?, spend: Any?) -> PlanUsage.Credits? {
        let e = extra as? [String: Any]
        let s = spend as? [String: Any]
        if e == nil && s == nil { return nil }

        let spendUsed = s?["used"] as? [String: Any]
        let spendLimit = s?["limit"] as? [String: Any]
        let exponent = number(e?["decimal_places"]) ?? number(spendUsed?["exponent"]) ?? 2
        let scale = pow(10, max(0, min(exponent, 6)))

        let used = number(e?["used_credits"]).map { $0 / scale } ?? minorAmount(spendUsed)
        let limit = number(e?["monthly_limit"]).map { $0 / scale } ?? minorAmount(spendLimit)

        return PlanUsage.Credits(
            isEnabled: (e?["is_enabled"] as? Bool) ?? (s?["enabled"] as? Bool),
            userDisabled: e?["user_disabled"] as? Bool,
            disabledReason: (e?["disabled_reason"] as? String) ?? (s?["disabled_reason"] as? String),
            monthlyLimit: limit,
            used: used,
            utilization: percent(e?["utilization"]),
            currency: (e?["currency"] as? String) ?? (spendUsed?["currency"] as? String),
            spendLimitReached: e?["spend_limit_reached"] as? Bool
        )
    }

    /// `{amount_minor, exponent}` to major units.
    static func minorAmount(_ value: [String: Any]?) -> Double? {
        guard let value, let minor = number(value["amount_minor"]) else { return nil }
        let exponent = number(value["exponent"]) ?? 2
        return minor / pow(10, max(0, min(exponent, 6)))
    }

    // MARK: Scalars

    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func percent(_ value: Any?) -> Double? {
        guard let d = number(value), percentRange.contains(d) else { return nil }
        return d
    }

    static func date(_ value: Any?) -> Date? {
        if let s = value as? String { return ISODate.parse(s) }
        return nil
    }
}

/// ISO 8601 with or without fractional seconds (any number of digits) and with `Z` or `±hh:mm`.
public enum ISODate {
    public static func parse(_ string: String) -> Date? {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            let digitsEnd = s[s.index(after: dot)...].firstIndex { !$0.isNumber } ?? s.endIndex
            let digits = s[s.index(after: dot)..<digitsEnd]
            fraction = Double("0." + digits) ?? 0
            s = s[..<dot] + s[digitsEnd...]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let base = formatter.date(from: String(s)) else { return nil }
        return base.addingTimeInterval(fraction)
    }
}
