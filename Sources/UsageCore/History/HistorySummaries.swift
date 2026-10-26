import Foundation

/// One closed 5-hour window: a line of `windows.jsonl`.
public struct WindowSummary: Codable, Equatable, Sendable, HistorySummary {
    public var start: Date
    public var end: Date
    public var peakPercent: Double
    /// When a reading first showed 100%, if one did.
    public var reachedLimitAt: Date?
    public var readings: Int
    /// Minutes of the window the app wasn't reading (Mac asleep, app closed).
    public var gapMinutes: Int

    public init(start: Date, end: Date, peakPercent: Double, reachedLimitAt: Date?, readings: Int, gapMinutes: Int) {
        self.start = start
        self.end = end
        self.peakPercent = peakPercent
        self.reachedLimitAt = reachedLimitAt
        self.readings = readings
        self.gapMinutes = gapMinutes
    }
}

/// One closed week: a line of `weeks.jsonl`.
public struct WeekSummary: Codable, Equatable, Sendable, HistorySummary {
    public var start: Date
    public var end: Date
    public var finalPercent: Double
    public var peakPercent: Double
    /// The highest each per-model weekly limit reached, such as `["Fable": 64]`.
    public var modelPeaks: [String: Double]
    /// Usage credits spent during the week, when any reading carried them.
    public var creditsSpent: Double?
    public var currency: String?
    /// When a reading first showed the weekly limit at 100%, if one did.
    public var limitReachedAt: Date?
    /// 5-hour windows in the week that reached 100%.
    public var windowsAtLimit: Int
    public var readings: Int
    public var gapMinutes: Int

    public init(start: Date, end: Date, finalPercent: Double, peakPercent: Double, modelPeaks: [String: Double] = [:],
                creditsSpent: Double? = nil, currency: String? = nil, limitReachedAt: Date? = nil, windowsAtLimit: Int = 0,
                readings: Int, gapMinutes: Int = 0) {
        self.start = start
        self.end = end
        self.finalPercent = finalPercent
        self.peakPercent = peakPercent
        self.modelPeaks = modelPeaks
        self.creditsSpent = creditsSpent
        self.currency = currency
        self.limitReachedAt = limitReachedAt
        self.windowsAtLimit = windowsAtLimit
        self.readings = readings
        self.gapMinutes = gapMinutes
    }
}

public protocol HistorySummary {
    var start: Date { get }
    var end: Date { get }
    var readings: Int { get }
}

// MARK: - Gaps

/// When the app wasn't reading. A line's `previousReadAt` is the last fresh reading before it, so
/// the time between the two is either covered by skipped identical readings or, when it's long, a gap.
public enum HistoryGaps {
    /// Longer than this without a fresh reading counts as a gap.
    public static let threshold: TimeInterval = 30 * 60
    /// After the newest line: identical readings only write a heartbeat hourly, so allow for that.
    public static let trailingThreshold: TimeInterval = HistoryRecording.heartbeatInterval + threshold

    /// The fresh reading just before `line`: its own record of it, else the line before.
    public static func observedFrom(_ line: HistoryLine, after previous: HistoryLine?) -> Date? {
        guard let previous else { return line.previousReadAt }
        let from = max(line.previousReadAt ?? previous.time, previous.time)
        return min(from, line.time)
    }

    /// The stretches the app wasn't reading, oldest first. Everything before the first line counts.
    public static func unobserved(_ lines: [HistoryLine], now: Date) -> [DateInterval] {
        guard let first = lines.first else { return [DateInterval(start: .distantPast, end: max(now, .distantPast))] }
        var result = [DateInterval(start: .distantPast, end: first.time)]
        for (previous, line) in zip(lines, lines.dropFirst()) {
            guard let from = observedFrom(line, after: previous), line.time.timeIntervalSince(from) > threshold else { continue }
            result.append(DateInterval(start: from, end: line.time))
        }
        if let last = lines.last, now.timeIntervalSince(last.time) > trailingThreshold {
            result.append(DateInterval(start: last.time, end: now))
        }
        return result
    }

    /// Whole minutes of `interval` inside the unobserved stretches.
    public static func minutes(in interval: DateInterval, unobserved: [DateInterval]) -> Int {
        let seconds = unobserved.reduce(0.0) { total, gap in
            total + (gap.intersection(with: interval)?.duration ?? 0)
        }
        return Int((seconds / 60).rounded())
    }
}

// MARK: - Building summaries

public enum HistorySummaries {
    /// A run of lines in one window, keyed by the window's (first) reset time.
    struct Group {
        var resetsAt: Date
        var lines: [HistoryLine]
    }

    /// Splits lines into windows, using the same 60 s tolerance as the merge, so reset jitter never
    /// starts a new window. Lines with no open window ("ready") belong to none.
    static func groups(_ lines: [HistoryLine], _ window: (HistoryLine) -> HistoryLine.Window?) -> [Group] {
        var result: [Group] = []
        for line in lines {
            guard let w = window(line), w.percent != nil, let reset = w.resetsAt else { continue }
            if let current = result.last, !PlanUsageMerger.isNewWindow(reset, previous: current.resetsAt) {
                result[result.count - 1].lines.append(line)
            } else {
                result.append(Group(resetsAt: reset, lines: [line]))
            }
        }
        return result
    }

    /// Summaries of every closed 5-hour window and week in `lines` (sorted oldest first).
    public static func build(from lines: [HistoryLine], now: Date) -> (windows: [WindowSummary], weeks: [WeekSummary]) {
        let lines = lines.sorted { $0.time < $1.time }
        let unobserved = HistoryGaps.unobserved(lines, now: now)

        let fiveGroups = groups(lines, \.fiveHour)
        let windows = fiveGroups.filter { $0.resetsAt <= now }.map { group -> WindowSummary in
            let interval = DateInterval(start: group.resetsAt.addingTimeInterval(-UsageWindowKind.fiveHour.duration), end: group.resetsAt)
            let percents = group.lines.compactMap { $0.fiveHour?.percent }
            return WindowSummary(
                start: interval.start,
                end: interval.end,
                peakPercent: percents.max() ?? 0,
                reachedLimitAt: group.lines.first { ($0.fiveHour?.percent ?? 0) >= 100 }?.time,
                readings: group.lines.count,
                gapMinutes: HistoryGaps.minutes(in: interval, unobserved: unobserved)
            )
        }
        // Every window that reached 100%, open or closed, for the weekly count.
        let limitTimes = fiveGroups.compactMap { group in group.lines.first { ($0.fiveHour?.percent ?? 0) >= 100 }?.time }

        let spend = creditDeltas(lines)
        let weeks = groups(lines, \.weekly).filter { $0.resetsAt <= now }.map { group -> WeekSummary in
            let interval = DateInterval(start: group.resetsAt.addingTimeInterval(-UsageWindowKind.sevenDay.duration), end: group.resetsAt)
            let percents = group.lines.compactMap { $0.weekly?.percent }
            var peaks: [String: Double] = [:]
            for row in group.lines.flatMap(\.models) {
                guard let p = row.percent else { continue }
                peaks[row.name] = max(peaks[row.name] ?? p, p)
            }
            let spent = group.lines.compactMap { spend[$0.time] }
            return WeekSummary(
                start: interval.start,
                end: interval.end,
                finalPercent: group.lines.last?.weekly?.percent ?? 0,
                peakPercent: percents.max() ?? 0,
                modelPeaks: peaks,
                creditsSpent: spent.isEmpty ? nil : (spent.reduce(0, +) * 100).rounded() / 100,
                currency: group.lines.last { $0.currency != nil }?.currency,
                limitReachedAt: group.lines.first { ($0.weekly?.percent ?? 0) >= 100 }?.time,
                windowsAtLimit: limitTimes.filter { interval.start <= $0 && $0 < interval.end }.count,
                readings: group.lines.count,
                gapMinutes: HistoryGaps.minutes(in: interval, unobserved: unobserved)
            )
        }
        return (windows, weeks)
    }

    /// Credits spent since the previous reading that carried them, keyed by line time. A drop is a
    /// new month starting, so the new figure is all spend since then.
    static func creditDeltas(_ lines: [HistoryLine]) -> [Date: Double] {
        var result: [Date: Double] = [:]
        var last: Double?
        for line in lines {
            guard let used = line.creditsUsed else { continue }
            if let last { result[line.time] = used >= last ? used - last : used } else { result[line.time] = 0 }
            last = used
        }
        return result
    }

    /// Two summaries describe the same window when their ends are this close.
    static let sameWindow: TimeInterval = 5 * 60

    /// Existing summaries plus rebuilt ones, one per window, oldest first. Where both have a window,
    /// the one built from more readings wins (raw readings get pruned, summaries don't), and a tie
    /// goes to the rebuilt one, so rebuilding twice changes nothing.
    public static func merge<S: HistorySummary>(existing: [S], rebuilt: [S]) -> [S] {
        var result = existing
        for summary in rebuilt {
            if let i = result.firstIndex(where: { abs($0.end.timeIntervalSince(summary.end)) < sameWindow }) {
                if summary.readings >= result[i].readings { result[i] = summary }
            } else {
                result.append(summary)
            }
        }
        return result.sorted { $0.end < $1.end }
    }
}
