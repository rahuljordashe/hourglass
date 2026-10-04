import Foundation

/// How much of the weekly limit is left per remaining day, for the open panel's budget card.
public struct WeeklyBudget: Equatable, Sendable {
    public enum Line: Equatable, Sendable {
        /// "about 14% a day"
        case perDay(Int)
        /// Under a day to the reset: "6% left until reset".
        case leftUntilReset(Int)
        /// "No weekly budget left"
        case exhausted
    }

    /// One remaining day, from now (today) to the reset (the reset day).
    public struct Day: Equatable, Sendable {
        public var start: Date
        public var hours: Double
        public var isToday: Bool
    }

    public var percentLeft: Double
    public var timeLeft: TimeInterval
    public var resetsAt: Date
    public var line: Line
    public var days: [Day]

    public static func make(weekly: WindowStatus?, now: Date, calendar: Calendar = .current) -> WeeklyBudget? {
        guard let weekly, !weekly.isReset, weekly.resetsAt > now else { return nil }
        let left = max(0, 100 - weekly.reportedPercentage)
        let timeLeft = weekly.resetsAt.timeIntervalSince(now)
        let line: Line
        if left <= 0 {
            line = .exhausted
        } else if timeLeft < 86400 {
            line = .leftUntilReset(Int(left.rounded()))
        } else {
            line = .perDay(Int((left / (timeLeft / 86400)).rounded()))
        }
        return WeeklyBudget(percentLeft: left, timeLeft: timeLeft, resetsAt: weekly.resetsAt, line: line,
                            days: days(from: now, to: weekly.resetsAt, calendar: calendar))
    }

    /// Today through the reset day, each with the hours of it still to come.
    static func days(from now: Date, to end: Date, calendar: Calendar) -> [Day] {
        var result: [Day] = []
        var cursor = now
        while cursor < end, result.count < 9 {
            let nextMidnight = calendar.startOfDay(for: cursor).addingTimeInterval(86400 * 1.5)
            let dayEnd = min(calendar.startOfDay(for: nextMidnight), end)
            result.append(Day(start: cursor, hours: dayEnd.timeIntervalSince(cursor) / 3600, isToday: result.isEmpty))
            cursor = dayEnd
        }
        return result
    }
}
