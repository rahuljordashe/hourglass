import Foundation

/// A rise in the weekly percentage between two readings: the weekly points used in between.
public struct UsageRise: Equatable, Sendable {
    /// The reading that showed the rise.
    public var time: Date
    /// The fresh reading before it (or the reset, if the week reset in between).
    public var from: Date
    public var points: Double
    /// The readings were more than 30 minutes apart, so when it was used isn't known.
    public var acrossGap: Bool

    public init(time: Date, from: Date, points: Double, acrossGap: Bool) {
        self.time = time
        self.from = from
        self.points = points
        self.acrossGap = acrossGap
    }
}

/// Daily use, derived from the raw readings and never stored: weekly points used per local day.
public enum DailyUsage {
    /// Every rise in weekly %, oldest first. After a weekly reset the count starts again from zero
    /// at the reset, so the new week's first reading counts in full. Drops are never counted.
    public static func rises(_ lines: [HistoryLine]) -> [UsageRise] {
        var result: [UsageRise] = []
        var previousLine: HistoryLine?
        var previousWeekly: (percent: Double, resetsAt: Date?)?
        for line in lines {
            defer { previousLine = line }
            guard let percent = line.weekly?.percent else { continue }
            let reset = line.weekly?.resetsAt
            defer { previousWeekly = (percent, reset) }
            guard let before = previousWeekly, let observed = HistoryGaps.observedFrom(line, after: previousLine) else { continue }

            var from = observed
            let points: Double
            if let reset, let oldReset = before.resetsAt, PlanUsageMerger.isNewWindow(reset, previous: oldReset) {
                // A new week: usage since the reset, which may have come after the last reading.
                points = percent
                if oldReset > from && oldReset < line.time { from = oldReset }
            } else if reset != nil, before.resetsAt == nil {
                // No week was open before ("ready"); this reading opened one.
                points = percent
            } else {
                points = percent - before.percent
            }
            guard points > 0 else { continue }
            result.append(UsageRise(time: line.time, from: from, points: points,
                                    acrossGap: line.time.timeIntervalSince(from) > HistoryGaps.threshold))
        }
        return result
    }

    /// One local day of use.
    public struct Day: Equatable, Sendable, Identifiable {
        public var start: Date
        /// Weekly points used in readings under 30 minutes apart.
        public var points: Double
        /// Weekly points that showed up after a gap: used by then, but not necessarily that day.
        public var gapPoints: Double
        /// The app took at least one reading that day. A day without any is a gap, not zero.
        public var hasReadings: Bool
        public var isToday: Bool

        public var id: Date { start }
        public var total: Double { points + gapPoints }

        public init(start: Date, points: Double, gapPoints: Double, hasReadings: Bool, isToday: Bool) {
            self.start = start
            self.points = points
            self.gapPoints = gapPoints
            self.hasReadings = hasReadings
            self.isToday = isToday
        }
    }

    /// The last `count` local days, oldest first, ending with today.
    public static func days(_ lines: [HistoryLine], count: Int, now: Date, calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(count - 1), to: today) else { return [] }
        let recent = lines.filter { $0.time >= first }
        var withReadings = Set<Date>()
        for line in recent { withReadings.insert(calendar.startOfDay(for: line.time)) }
        var points: [Date: Double] = [:], gapPoints: [Date: Double] = [:]
        // Rises need the reading before the first day too, so use every line.
        for rise in rises(lines) where rise.time >= first {
            let day = calendar.startOfDay(for: rise.time)
            if rise.acrossGap { gapPoints[day, default: 0] += rise.points } else { points[day, default: 0] += rise.points }
        }
        return (0..<count).reversed().compactMap { back -> Day? in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return Day(start: start, points: points[start] ?? 0, gapPoints: gapPoints[start] ?? 0,
                       hasReadings: withReadings.contains(start), isToday: back == 0)
        }
    }

    /// An even burn: the share of the weekly limit one day gets, about 14%.
    public static let dailyBudget = 100.0 / 7

    public static func isOverBudget(_ day: Day) -> Bool { day.total > dailyBudget + 0.05 }
}

// MARK: - The 7-day card's summary line

public enum LastSevenDays {
    /// "Monday used 22% of the week, over the daily budget." for the day that used the most.
    public static func summary(_ days: [DailyUsage.Day], now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard days.contains(where: \.hasReadings) else { return "Builds up as the app takes readings." }
        guard let top = days.max(by: { $0.total < $1.total }), top.total >= 0.5 else { return "No weekly use in the last 7 days." }
        let name = dayName(top, now: now, calendar: calendar, locale: locale)
        let used = top.isToday ? "has used" : "used"
        let verdict = DailyUsage.isOverBudget(top) ? "over the daily budget" : "within the daily budget"
        let so = top.isToday ? " so far" : ""
        return "\(name) \(used) \(percent(top.total)) of the week\(so), \(verdict)."
    }

    public static func dayName(_ day: DailyUsage.Day, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if day.isToday { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day.start, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: day.start)
    }

    public static func percent(_ value: Double) -> String {
        value > 0 && value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
}

// MARK: - When you use it

/// Average weekly points used per weekday and two-hour slot, from readings under 30 minutes apart.
public struct UsageHeatMap: Equatable, Sendable {
    /// Days with readings needed before the map means anything.
    public static let minimumDays = 14
    public static let slots = 12

    /// `cells[weekday - 1][slot]`, weekday as `Calendar` counts it (1 is Sunday). Nil where that
    /// weekday has no readings yet.
    public var cells: [[Double?]]
    /// Local days with at least one reading.
    public var daysWithReadings: Int

    public var isReady: Bool { daysWithReadings >= Self.minimumDays }
    public var highest: Double { cells.flatMap { $0.compactMap { $0 } }.max() ?? 0 }

    public static func make(_ lines: [HistoryLine], calendar: Calendar = .current) -> UsageHeatMap {
        var observedDays: [Int: Set<Date>] = [:]
        for line in lines {
            observedDays[calendar.component(.weekday, from: line.time), default: []].insert(calendar.startOfDay(for: line.time))
        }
        var totals = Array(repeating: Array(repeating: 0.0, count: slots), count: 7)
        for rise in DailyUsage.rises(lines) where !rise.acrossGap {
            let weekday = calendar.component(.weekday, from: rise.time)
            let slot = min(calendar.component(.hour, from: rise.time) / 2, slots - 1)
            totals[weekday - 1][slot] += rise.points
        }
        let cells = (1...7).map { weekday -> [Double?] in
            let days = observedDays[weekday]?.count ?? 0
            return totals[weekday - 1].map { days > 0 ? $0 / Double(days) : nil }
        }
        return UsageHeatMap(cells: cells, daysWithReadings: Set(observedDays.values.flatMap { $0 }).count)
    }
}
