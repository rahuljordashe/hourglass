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
