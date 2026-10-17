import Foundation

/// The history as CSV, for Export CSV in the History window. Times are ISO 8601 in UTC.
public enum HistoryCSV {
    public static func readings(_ lines: [HistoryLine]) -> String {
        var rows = [["time", "heartbeat", "five_hour_percent", "five_hour_resets_at", "weekly_percent", "weekly_resets_at",
                     "models", "credits_used", "credits_monthly_limit", "currency", "promos", "plan", "source"]]
        for line in lines {
            rows.append([
                date(line.time), line.unchanged ? "yes" : "no",
                number(line.fiveHour?.percent), date(line.fiveHour?.resetsAt),
                number(line.weekly?.percent), date(line.weekly?.resetsAt),
                line.models.map { "\($0.name) \(number($0.percent))% until \(date($0.resetsAt))" }.joined(separator: "; "),
                number(line.creditsUsed), number(line.creditsLimit), line.currency ?? "",
                line.promos.map { "\($0.key) \(number($0.remaining)) of \(number($0.limit)) left" }.joined(separator: "; "),
                line.plan ?? "", line.source ?? ""
            ])
        }
        return csv(rows)
    }

    public static func windows(_ windows: [WindowSummary]) -> String {
        var rows = [["start", "end", "peak_percent", "reached_limit_at", "readings", "gap_minutes"]]
        for w in windows {
            rows.append([date(w.start), date(w.end), number(w.peakPercent), date(w.reachedLimitAt), "\(w.readings)", "\(w.gapMinutes)"])
        }
        return csv(rows)
    }

    public static func weeks(_ weeks: [WeekSummary]) -> String {
        var rows = [["start", "end", "final_percent", "peak_percent", "model_peaks", "credits_spent", "currency",
                     "limit_reached_at", "five_hour_windows_at_limit", "readings", "gap_minutes"]]
        for w in weeks {
            rows.append([
                date(w.start), date(w.end), number(w.finalPercent), number(w.peakPercent),
                w.modelPeaks.sorted { $0.key < $1.key }.map { "\($0.key) \(number($0.value))%" }.joined(separator: "; "),
                number(w.creditsSpent), w.currency ?? "", date(w.limitReachedAt), "\(w.windowsAtLimit)", "\(w.readings)", "\(w.gapMinutes)"
            ])
        }
        return csv(rows)
    }

    public static func hourlyTokens(_ rows: [HourlyTokens]) -> String {
        var out = [["hour", "project", "model", "input_tokens", "output_tokens", "cache_write_tokens", "cache_read_tokens", "messages"]]
        for r in rows {
            out.append([date(r.hour), r.project, r.model, "\(r.input)", "\(r.output)", "\(r.cacheCreation)", "\(r.cacheRead)", "\(r.messages)"])
        }
        return csv(out)
    }

    // MARK: Helpers

    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// Quotes a field when it holds a comma, quote or line break.
    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "" }
        return value.formatted(.iso8601)
    }

    static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}
