import Foundation

/// One local day, summarised: a line of `days.jsonl`, kept for good so weeks older than the 90 days
/// of raw readings keep their tiles and comparison curves. Rebuildable from raw readings.
public struct DaySummary: Codable, Equatable, Sendable, Identifiable {
    /// One 5-hour window that overlapped the day.
    public struct FiveHourWindow: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var peakPercent: Double
        public var reachedLimitAt: Date?

        public init(start: Date, end: Date, peakPercent: Double, reachedLimitAt: Date? = nil) {
            self.start = start
            self.end = end
            self.peakPercent = peakPercent
            self.reachedLimitAt = reachedLimitAt
        }
    }

    /// The local date, "2026-10-14".
    public var date: String
    /// Local midnight at the start of the day.
    public var start: Date
    /// Weekly points used that day (including any seen after a gap).
    public var share: Double
    /// The part of `share` that only showed up after a gap in readings.
    public var gapShare: Double
    /// There was a gap of more than 30 minutes in the day's readings.
    public var hadGap: Bool
    /// The weekly percentage at the day's last reading.
    public var weekTotalAtEnd: Double?
    /// The reset of the limit week the day's last reading belonged to.
    public var weekEnd: Date?
    /// When the weekly limit was reached, if it was that day.
    public var limitReachedAt: Date?
    public var fiveHourWindows: [FiveHourWindow]
    public var readings: Int

    public var id: String { date }
    /// A 5-hour window reached 100% during the day.
    public var fiveHourLimitHit: Bool { fiveHourWindows.contains { $0.reachedLimitAt.map { start <= $0 && $0 < end } ?? false } }

    public init(date: String, start: Date, share: Double, gapShare: Double = 0, hadGap: Bool = false, weekTotalAtEnd: Double? = nil,
                weekEnd: Date? = nil, limitReachedAt: Date? = nil, fiveHourWindows: [FiveHourWindow] = [], readings: Int) {
        self.date = date
        self.start = start
        self.share = share
        self.gapShare = gapShare
        self.hadGap = hadGap
        self.weekTotalAtEnd = weekTotalAtEnd
        self.weekEnd = weekEnd
        self.limitReachedAt = limitReachedAt
        self.fiveHourWindows = fiveHourWindows
        self.readings = readings
    }
}

extension DaySummary: HistorySummary {
    public var end: Date { start.addingTimeInterval(86400) }
}

public enum DaySummaries {
    /// "2026-10-14" in `calendar`'s time zone.
    public static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// One summary per local day that has readings, oldest first.
    public static func build(from lines: [HistoryLine], calendar: Calendar = .current) -> [DaySummary] {
        let lines = lines.sorted { $0.time < $1.time }
        guard !lines.isEmpty else { return [] }
        let rises = DailyUsage.rises(lines)
        let unobserved = HistoryGaps.unobserved(lines, now: lines.last!.time)

        var points: [Date: (all: Double, gap: Double)] = [:]
        for rise in rises {
            let day = calendar.startOfDay(for: rise.time)
            var p = points[day] ?? (0, 0)
            p.all += rise.points
            if rise.acrossGap { p.gap += rise.points }
            points[day] = p
        }

        // Weekly limit reached: the first reading at 100% in each limit week.
        var limitTimes: [Date] = []
        for group in HistorySummaries.groups(lines, \.weekly) {
            if let hit = group.lines.first(where: { ($0.weekly?.percent ?? 0) >= 100 }) { limitTimes.append(hit.time) }
        }
        let windows = HistorySummaries.groups(lines, \.fiveHour).map { group in
            DaySummary.FiveHourWindow(
                start: group.resetsAt.addingTimeInterval(-UsageWindowKind.fiveHour.duration), end: group.resetsAt,
                peakPercent: group.lines.compactMap { $0.fiveHour?.percent }.max() ?? 0,
                reachedLimitAt: group.lines.first { ($0.fiveHour?.percent ?? 0) >= 100 }?.time)
        }

        let byDay = Dictionary(grouping: lines) { calendar.startOfDay(for: $0.time) }
        return byDay.keys.sorted().map { start in
            let dayLines = byDay[start]!
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
            let day = DateInterval(start: start, end: end)
            let last = dayLines.last { $0.weekly?.percent != nil }
            // A gap inside the day itself (the stretch before the first reading of the day counts too,
            // unless it started before the day: that's the night, already covered by `gapShare`).
            let gap = unobserved.contains { stretch in
                guard let overlap = stretch.intersection(with: day) else { return false }
                return overlap.duration > HistoryGaps.threshold && stretch.start >= start
            }
            return DaySummary(
                date: key(start, calendar: calendar),
                start: start,
                share: round2(points[start]?.all ?? 0),
                gapShare: round2(points[start]?.gap ?? 0),
                hadGap: gap || (points[start]?.gap ?? 0) > 0,
                weekTotalAtEnd: last?.weekly?.percent,
                weekEnd: last?.weekly?.resetsAt,
                limitReachedAt: limitTimes.first { day.contains($0) && $0 < end },
                fiveHourWindows: windows.filter { $0.start < end && $0.end > start },
                readings: dayLines.count
            )
        }
    }

    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// Existing summaries plus rebuilt ones, one per date. The one built from more readings wins.
    public static func merge(existing: [DaySummary], rebuilt: [DaySummary]) -> [DaySummary] {
        var byDate: [String: DaySummary] = [:]
        for day in existing { byDate[day.date] = day }
        for day in rebuilt where day.readings >= (byDate[day.date]?.readings ?? 0) { byDate[day.date] = day }
        return byDate.values.sorted { $0.start < $1.start }
    }
}
