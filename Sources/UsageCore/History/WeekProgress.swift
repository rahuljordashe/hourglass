import Foundation

/// A point on a week's running total: how far into the limit week, and the weekly % then.
public struct CurvePoint: Equatable, Sendable {
    public var offset: TimeInterval
    public var percent: Double

    public init(offset: TimeInterval, percent: Double) {
        self.offset = offset
        self.percent = percent
    }
}

/// One limit week, from reset to reset.
public struct LimitWeek: Equatable, Sendable, Identifiable {
    public var start: Date
    /// The reset that ends it.
    public var end: Date
    /// The running total: 0 at the reset, then one point per recorded reading (or per day for weeks
    /// older than the raw readings). Gaps are straight joins between readings, never made-up points.
    public var curve: [CurvePoint]
    public var finalPercent: Double?
    public var limitReachedAt: Date?
    public var windowsAtLimit: Int
    public var isCurrent: Bool

    public var id: Date { end }

    public init(start: Date, end: Date, curve: [CurvePoint], finalPercent: Double?, limitReachedAt: Date? = nil,
                windowsAtLimit: Int = 0, isCurrent: Bool = false) {
        self.start = start
        self.end = end
        self.curve = curve
        self.finalPercent = finalPercent
        self.limitReachedAt = limitReachedAt
        self.windowsAtLimit = windowsAtLimit
        self.isCurrent = isCurrent
    }
}

/// How the current week compares: the open panel's "This week" card and the History window's chart.
public enum WeekProgress {
    public static let length = UsageWindowKind.sevenDay.duration
    /// Two week ends this close are the same week (reset times jitter).
    static let sameWeek: TimeInterval = 5 * 60
    /// More than this many points over an even pace draws the line amber.
    public static let aheadThreshold = 10.0

    // MARK: Curves

    /// The running total of the week ending `weekEnd`, from raw readings.
    public static func curve(_ lines: [HistoryLine], weekEnd: Date) -> [CurvePoint] {
        let start = weekEnd.addingTimeInterval(-length)
        let group = HistorySummaries.groups(lines, \.weekly).first { abs($0.resetsAt.timeIntervalSince(weekEnd)) < sameWeek }
        guard let group else { return [] }
        return [CurvePoint(offset: 0, percent: 0)] + group.lines.compactMap { line in
            line.weekly?.percent.map { CurvePoint(offset: line.time.timeIntervalSince(start), percent: $0) }
        }
    }

    /// The same from daily summaries, one point at the end of each day, for weeks past the raw readings.
    public static func curve(days: [DaySummary], weekEnd: Date) -> [CurvePoint] {
        let start = weekEnd.addingTimeInterval(-length)
        let points = days
            .filter { day in day.weekEnd.map { abs($0.timeIntervalSince(weekEnd)) < sameWeek } ?? false }
            .compactMap { day in
                day.weekTotalAtEnd.map { CurvePoint(offset: min(day.end, weekEnd).timeIntervalSince(start), percent: $0) }
            }
        return points.isEmpty ? [] : [CurvePoint(offset: 0, percent: 0)] + points
    }

    /// The running total `offset` into the week: straight between points, flat after the last.
    public static func value(_ curve: [CurvePoint], at offset: TimeInterval) -> Double? {
        guard let first = curve.first, offset >= first.offset else { return nil }
        for (a, b) in zip(curve, curve.dropFirst()) where offset <= b.offset {
            let span = b.offset - a.offset
            return span <= 0 ? b.percent : a.percent + (b.percent - a.percent) * (offset - a.offset) / span
        }
        return curve.last?.percent
    }

    // MARK: Weeks

    /// Every known limit week, newest first: from raw readings where there are any, else from the
    /// weekly and daily summaries. `current` is the weekly window as now known, if one is open.
    public static func weeks(lines: [HistoryLine], summaries: [WeekSummary], days: [DaySummary],
                             current: (percent: Double, resetsAt: Date)?, now: Date) -> [LimitWeek] {
        let groups = HistorySummaries.groups(lines, \.weekly)
        var ends = groups.map(\.resetsAt) + summaries.map(\.end) + days.compactMap(\.weekEnd)
        if let current { ends.append(current.resetsAt) }
        var unique: [Date] = []
        for end in ends.sorted(by: >) where !unique.contains(where: { abs($0.timeIntervalSince(end)) < sameWeek }) {
            unique.append(end)
        }
        return unique.map { end in
            let start = end.addingTimeInterval(-length)
            var curve = curve(lines, weekEnd: end)
            if curve.count < 2 { curve = self.curve(days: days, weekEnd: end) }
            let summary = summaries.first { abs($0.end.timeIntervalSince(end)) < sameWeek }
            let group = groups.first { abs($0.resetsAt.timeIntervalSince(end)) < sameWeek }
            let inWeek = { (date: Date) in start <= date && date < end }
            let isCurrent = end > now
            if isCurrent, let current {
                curve.append(CurvePoint(offset: min(now, end).timeIntervalSince(start), percent: current.percent))
            }
            return LimitWeek(
                start: start, end: end, curve: curve,
                finalPercent: isCurrent ? (current?.percent ?? curve.last?.percent) : (summary?.finalPercent ?? curve.last?.percent),
                limitReachedAt: summary?.limitReachedAt
                    ?? group?.lines.first { ($0.weekly?.percent ?? 0) >= 100 }?.time
                    ?? days.compactMap(\.limitReachedAt).filter(inWeek).min(),
                windowsAtLimit: summary?.windowsAtLimit
                    ?? Set(days.flatMap(\.fiveHourWindows).compactMap(\.reachedLimitAt).filter(inWeek)).count,
                isCurrent: isCurrent)
        }
    }

    /// The seven local days drawn for a week: each day belongs to the week that holds its midday,
    /// so a reset partway through a day puts the day in whichever week has most of it.
    public static func dayStarts(_ week: LimitWeek, calendar: Calendar = .current) -> [Date] {
        var day = calendar.startOfDay(for: week.start.addingTimeInterval(-86400))
        var result: [Date] = []
        while result.count < 7, day < week.end {
            let midday = day.addingTimeInterval(12 * 3600)
            if week.start <= midday && midday < week.end { result.append(day) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// One local day's stretch of a week's chart, from a midnight (or the reset) to the next.
    public struct ChartDay: Equatable, Sendable {
        /// Seconds from the week's start, clipped to the week.
        public var from: TimeInterval
        public var to: TimeInterval
        /// 1 is Sunday, as `Calendar` counts.
        public var weekday: Int
        public var isToday: Bool
        /// Labelled when at least half a day of it is in the week, or when it's today.
        public var isLabelled: Bool
    }

    /// The chart's x axis split at local midnights, so each day's initial sits on that calendar day and
    /// today follows the clock, not the reset time. A reset partway through a day leaves a short day at each end.
    public static func chartDays(_ week: LimitWeek, now: Date, calendar: Calendar = .current) -> [ChartDay] {
        let end = week.start.addingTimeInterval(length)
        var cursor = week.start
        var result: [ChartDay] = []
        while cursor < end, result.count < 9 {
            let day = calendar.startOfDay(for: cursor)
            let next = min(calendar.date(byAdding: .day, value: 1, to: day) ?? end, end)
            guard next > cursor else { break }
            let isToday = cursor <= now && now < next
            result.append(ChartDay(from: cursor.timeIntervalSince(week.start), to: next.timeIntervalSince(week.start),
                                   weekday: calendar.component(.weekday, from: day), isToday: isToday,
                                   isLabelled: isToday || next.timeIntervalSince(cursor) >= 12 * 3600))
            cursor = next
        }
        return result
    }

    // MARK: Comparisons

    public enum Comparison: String, CaseIterable, Sendable {
        case lastWeek, fourWeeks, threeMonths

        public var title: String {
            switch self {
            case .lastWeek: "Last week"
            case .fourWeeks: "4 weeks"
            case .threeMonths: "3 months"
            }
        }

        /// Full past weeks needed before the choice is offered, and the most it uses.
        public var minimumWeeks: Int {
            switch self {
            case .lastWeek: 1
            case .fourWeeks: 4
            case .threeMonths: 8
            }
        }

        public var maximumWeeks: Int {
            switch self {
            case .lastWeek: 1
            case .fourWeeks: 4
            case .threeMonths: 12
            }
        }
    }

    /// Past weeks recorded from (about) their start, newest first: only those make a fair comparison.
    public static func fullPastWeeks(_ weeks: [LimitWeek], historyStart: Date?) -> [LimitWeek] {
        guard let historyStart else { return [] }
        return weeks.filter { !$0.isCurrent && $0.curve.count >= 2 && historyStart <= $0.start.addingTimeInterval(12 * 3600) }
    }

    /// The comparison band, sampled every hour of the week. Last week: its own line. 4 weeks: the
    /// lowest to the highest, with the average. 3 months: the middle half (25th to 75th
    /// percentile) of up to 12 weeks, with the median.
    public struct Band: Equatable, Sendable {
        public var offsets: [TimeInterval]
        public var lower: [Double]
        public var upper: [Double]
        public var middle: [Double]
        public var weeks: Int

        public func at(_ offset: TimeInterval) -> (lower: Double, upper: Double, middle: Double)? {
            guard let i = offsets.lastIndex(where: { $0 <= offset }) else { return nil }
            guard i + 1 < offsets.count else { return (lower[i], upper[i], middle[i]) }
            let f = (offset - offsets[i]) / (offsets[i + 1] - offsets[i])
            func mix(_ a: [Double]) -> Double { a[i] + (a[i + 1] - a[i]) * f }
            return (mix(lower), mix(upper), mix(middle))
        }
    }

    public static func band(_ comparison: Comparison, fullPastWeeks: [LimitWeek]) -> Band? {
        let weeks = Array(fullPastWeeks.prefix(comparison.maximumWeeks))
        guard weeks.count >= comparison.minimumWeeks else { return nil }
        let offsets = stride(from: 0.0, through: length, by: 3600).map { $0 }
        var lower: [Double] = [], upper: [Double] = [], middle: [Double] = []
        for offset in offsets {
            let values = weeks.compactMap { value($0.curve, at: offset) }.sorted()
            guard !values.isEmpty else { lower.append(0); upper.append(0); middle.append(0); continue }
            switch comparison {
            case .lastWeek:
                lower.append(values[0]); upper.append(values[0]); middle.append(values[0])
            case .fourWeeks:
                lower.append(values.first!); upper.append(values.last!); middle.append(values.reduce(0, +) / Double(values.count))
            case .threeMonths:
                lower.append(percentile(values, 0.25)); upper.append(percentile(values, 0.75)); middle.append(percentile(values, 0.5))
            }
        }
        return Band(offsets: offsets, lower: lower, upper: upper, middle: middle, weeks: weeks.count)
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = p * Double(sorted.count - 1)
        let i = Int(position.rounded(.down)), f = position - Double(i)
        return i + 1 < sorted.count ? sorted[i] + (sorted[i + 1] - sorted[i]) * f : sorted[i]
    }

    // MARK: Words

    /// Points above (positive) or below an even pace from the reset.
    public static func paceDelta(percent: Double, now: Date, weekEnd: Date) -> Double {
        let elapsed = min(max(now.timeIntervalSince(weekEnd.addingTimeInterval(-length)) / length, 0), 1)
        return percent - elapsed * 100
    }

    /// "70% · 9 points under pace", "· ahead of pace", "· on pace" or "· limit reached".
    public static func header(percent: Double, now: Date, weekEnd: Date) -> String {
        let shown = UsageFormat.percent(percent)
        if percent >= 100 { return "\(shown) · limit reached" }
        let delta = paceDelta(percent: percent, now: now, weekEnd: weekEnd)
        let points = Int(abs(delta).rounded())
        if points < 1 { return "\(shown) · on pace" }
        let unit = points == 1 ? "point" : "points"
        return "\(shown) · \(points) \(unit) \(delta > 0 ? "ahead of" : "under") pace"
    }

    public enum LineStyle: Equatable, Sendable { case normal, ahead, limit }

    public static func lineStyle(percent: Double, now: Date, weekEnd: Date) -> LineStyle {
        if percent >= 100 { return .limit }
        return paceDelta(percent: percent, now: now, weekEnd: weekEnd) > aheadThreshold ? .ahead : .normal
    }

    /// The line under the card: "Last week you were at 59% by now.", led by "Limit reached Friday
    /// 15:40. Back Monday 09:00." once the limit is reached. Nil when there's nothing to say.
    public static func sentence(limitReachedAt: Date?, weekEnd: Date, lastWeekByNow: Double?,
                                calendar: Calendar = .current, locale: Locale = .current) -> String? {
        var parts: [String] = []
        if let hit = limitReachedAt {
            parts.append("Limit reached \(dayAndTime(hit, calendar: calendar, locale: locale)). Back \(dayAndTime(weekEnd, calendar: calendar, locale: locale)).")
        }
        if let last = lastWeekByNow {
            parts.append("Last week you were at \(UsageFormat.percent(last)) by now.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "Friday 15:40"
    public static func dayAndTime(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE HH:mm")
        return formatter.string(from: date).replacingOccurrences(of: ",", with: "")
    }
}
