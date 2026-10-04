import Foundation

/// Short, human strings for the notch. Clock times follow the system locale (24-hour on a UK Mac).
public enum UsageFormat {
    public static func percent(_ value: Double) -> String {
        let clamped = max(0, value)
        if clamped > 0, clamped < 1 { return "<1%" }
        return "\(Int(clamped.rounded()))%"
    }

    /// "2h 14m", "45m", "3d 4h", "<1m".
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let minutes = total / 60
        if minutes < 1 { return "<1m" }
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    /// Spoken form for VoiceOver: "2 hours 14 minutes".
    public static func spokenDuration(_ interval: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = interval >= 86400 ? [.day, .hour] : [.hour, .minute]
        f.maximumUnitCount = 2
        return f.string(from: max(60, interval)) ?? duration(interval)
    }

    /// "updated just now", "updated 12 min ago", "updated 3 h ago", "updated 2 days ago".
    public static func age(_ age: TimeInterval) -> String {
        let minutes = Int(max(0, age) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h ago" }
        return "\(hours / 24) days ago"
    }

    /// "14:30" today, "tomorrow 09:00", or "Thu 09:00" further out.
    public static func clock(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        // Within the coming week the weekday is enough; further out, use the date.
        if date.timeIntervalSince(now) > 6 * 86400 {
            let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
            return "\(day) \(time)"
        }
        let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
        return "\(day) \(time)"
    }

    public static func paceDescription(_ pace: Pace) -> String {
        switch pace {
        case .ahead(let d): "\(Int(d.rounded()))% ahead of pace"
        case .onPace: "On pace"
        case .behind(let d): "\(Int(d.rounded()))% under pace"
        }
    }

    /// "$12.34", in the given currency.
    public static func money(_ amount: Double, currency: String, locale: Locale = .current) -> String {
        // Narrow symbols: "$12.34", not "US$12.34" on a UK Mac.
        amount.formatted(.currency(code: currency).locale(locale).presentation(.narrow).precision(.fractionLength(2)))
    }

    /// Plain names for the promotional buckets whose meaning is known; anything new gets a generic name.
    public static func promoTitle(_ key: String) -> String {
        switch key {
        case "iguana_necktie": "Cloud sessions credit"
        case "harbor_lantern": "One-time credit"
        case "cinder_cove": "Claude Code & Cowork credit"
        default: "Promotional credit"
        }
    }

    /// The status line under the numbers: "Checked just now", "Checked 4 min ago", "Checked 2 h ago".
    public static func checked(_ age: TimeInterval) -> String {
        let seconds = Int(max(0, age))
        if seconds < 45 { return "Checked just now" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "Checked \(max(1, minutes)) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "Checked \(hours) h ago" }
        return "Checked \(hours / 24) days ago"
    }

    /// The resting countdown to the 5-hour reset: "50m" under an hour, "1h52" from an hour up,
    /// "<1m" in the last minute, "–" with no reading.
    public static func countdown(_ interval: TimeInterval?) -> String {
        guard let interval else { return "–" }
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h" + String(format: "%02d", minutes % 60)
    }

    /// "5 days 15 hours", "1 day 2 hours", "9 hours", "40 minutes".
    public static func longDuration(_ interval: TimeInterval) -> String {
        let hours = Int(max(0, interval) / 3600)
        let days = hours / 24, rest = hours % 24
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if days > 0 { return rest > 0 ? "\(unit(days, "day")) \(unit(rest, "hour"))" : unit(days, "day") }
        if hours > 0 { return unit(hours, "hour") }
        return unit(max(1, Int(max(0, interval) / 60)), "minute")
    }
}
