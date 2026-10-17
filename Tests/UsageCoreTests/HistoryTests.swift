import Foundation
import Testing
@testable import UsageCore

// Fake history only: made-up times and percentages, never real readings.

let utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.firstWeekday = 2
    return c
}()

/// Monday 5 October 2026, 00:00 UTC.
let monday = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!

func at(day: Double = 0, hour: Double = 0, minute: Double = 0) -> Date {
    monday.addingTimeInterval(day * 86400 + hour * 3600 + minute * 60)
}

func line(_ time: Date, five: Double? = nil, fiveReset: Date? = nil, week: Double? = nil, weekReset: Date? = nil,
          prev: Date? = nil, credits: Double? = nil, models: [HistoryLine.ModelRow] = []) -> HistoryLine {
    HistoryLine(time: time, previousReadAt: prev,
                fiveHour: five.map { .init(percent: $0, resetsAt: fiveReset) },
                weekly: week.map { .init(percent: $0, resetsAt: weekReset) },
                models: models, creditsUsed: credits, creditsLimit: credits == nil ? nil : 50, currency: credits == nil ? nil : "USD")
}

func plan(_ time: Date, five: Double = 10, fiveReset: Date? = nil, week: Double = 20, weekReset: Date? = nil, seeded: Bool = false) -> PlanUsage {
    PlanUsage(fiveHour: .init(percent: five, resetsAt: fiveReset ?? time.addingTimeInterval(3 * 3600)),
              sevenDay: .init(percent: week, resetsAt: weekReset ?? at(day: 7)),
              fetchedAt: time, isSeeded: seeded)
}

func temporaryHistory() throws -> HistoryFiles {
    let dir = FileManager.default.temporaryDirectory.appending(path: "hourglass-history-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return HistoryFiles(directory: dir)
}

@Suite("Recording readings")
struct RecordingTests {
    let fiveReset = at(hour: 4)

    @Test func firstReadingIsWritten() throws {
        let written = try #require(HistoryRecording.line(for: plan(at(hour: 1), fiveReset: fiveReset), lastWritten: nil, lastReadAt: nil))
        #expect(written.time == at(hour: 1))
        #expect(written.fiveHour?.percent == 10)
        #expect(written.weekly?.percent == 20)
        #expect(written.unchanged == false)
        #expect(written.previousReadAt == nil)
    }

    @Test func seededReadingsAreSkipped() {
        #expect(HistoryRecording.line(for: plan(at(hour: 1), seeded: true), lastWritten: nil, lastReadAt: nil) == nil)
    }

    @Test func identicalReadingIsSkippedUntilTheHourlyHeartbeat() throws {
        let first = try #require(HistoryRecording.line(for: plan(at(hour: 1), fiveReset: fiveReset), lastWritten: nil, lastReadAt: nil))
        #expect(HistoryRecording.line(for: plan(at(hour: 1, minute: 15), fiveReset: fiveReset), lastWritten: first, lastReadAt: at(hour: 1)) == nil)
        #expect(HistoryRecording.line(for: plan(at(hour: 1, minute: 59), fiveReset: fiveReset), lastWritten: first, lastReadAt: at(hour: 1, minute: 45)) == nil)
        let beat = try #require(HistoryRecording.line(for: plan(at(hour: 2), fiveReset: fiveReset), lastWritten: first, lastReadAt: at(hour: 1, minute: 45)))
        #expect(beat.unchanged)
        #expect(beat.previousReadAt == at(hour: 1, minute: 45))
    }

    @Test func changedReadingRemembersTheReadBeforeIt() throws {
        let first = try #require(HistoryRecording.line(for: plan(at(hour: 1), fiveReset: fiveReset), lastWritten: nil, lastReadAt: nil))
        let next = try #require(HistoryRecording.line(for: plan(at(hour: 1, minute: 30), five: 14, fiveReset: fiveReset),
                                                      lastWritten: first, lastReadAt: at(hour: 1, minute: 15)))
        #expect(!next.unchanged)
        #expect(next.previousReadAt == at(hour: 1, minute: 15))
    }

    @Test func olderOrRepeatedReadingIsSkipped() throws {
        let first = try #require(HistoryRecording.line(for: plan(at(hour: 2)), lastWritten: nil, lastReadAt: nil))
        #expect(HistoryRecording.line(for: plan(at(hour: 2), five: 50), lastWritten: first, lastReadAt: at(hour: 2)) == nil)
        #expect(HistoryRecording.line(for: plan(at(hour: 1), five: 50), lastWritten: first, lastReadAt: at(hour: 2)) == nil)
    }

    @Test func lineCarriesEveryField() {
        let usage = PlanUsage(
            limits: [
                .init(kind: "session", percent: 31, resetsAt: at(hour: 3)),
                .init(kind: "weekly_all", percent: 44, resetsAt: at(day: 6)),
                .init(kind: "weekly_scoped", percent: 12, resetsAt: at(day: 6), modelName: "Fable")
            ],
            credits: .init(isEnabled: true, monthlyLimit: 50, used: 7.25, currency: "GBP"),
            promos: [.init(key: "spring_bonus", limitDollars: 20, usedDollars: 5, remainingDollars: 15, expiresAt: at(day: 20))],
            subscriptionType: "max", source: .getUsage, fetchedAt: at(hour: 1))
        let line = HistoryLine(usage, previousReadAt: nil)
        #expect(line.fiveHour == .init(percent: 31, resetsAt: at(hour: 3)))
        #expect(line.weekly == .init(percent: 44, resetsAt: at(day: 6)))
        #expect(line.models == [.init(name: "Fable", percent: 12, resetsAt: at(day: 6))])
        #expect(line.creditsUsed == 7.25)
        #expect(line.creditsLimit == 50)
        #expect(line.currency == "GBP")
        #expect(line.promos.first?.remaining == 15)
        #expect(line.plan == "max")
        #expect(line.source == "get_usage")
    }
}

@Suite("History files")
struct HistoryFilesTests {
    @Test func appendsOneLinePerReadingIntoMonthlyFiles() throws {
        let files = try temporaryHistory()
        let september = utcCalendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 23))!
        try files.append(line(september, five: 5, fiveReset: september.addingTimeInterval(3600)))
        try files.append(line(at(hour: 1), five: 6, fiveReset: at(hour: 3)))
        try files.append(line(at(hour: 2), five: 7, fiveReset: at(hour: 3)))
        #expect(files.readingsFiles().map(\.lastPathComponent) == ["readings-2026-09.jsonl", "readings-2026-10.jsonl"])
        let october = try String(contentsOf: files.readingsFile(for: at()), encoding: .utf8)
        #expect(october.split(separator: "\n").count == 2)
        #expect(files.loadReadings().map { $0.fiveHour?.percent } == [5, 6, 7])
        #expect(files.lastReading()?.time == at(hour: 2))
    }

    @Test func corruptAndPartialLinesAreSkipped() throws {
        let files = try temporaryHistory()
        try files.append(line(at(hour: 1), five: 6, fiveReset: at(hour: 3)))
        let url = files.readingsFile(for: at())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // Garbage, then a line cut off mid-write with no newline.
        try handle.write(contentsOf: Data("not json\n{\"time\":\"2026-10-05T01:30:00Z\",\"fiveHour\":{\"perc".utf8))
        try handle.close()
        try files.append(line(at(hour: 2), five: 8, fiveReset: at(hour: 3)))
        #expect(files.loadReadings().map { $0.fiveHour?.percent } == [6, 8])
    }

    @Test func unknownFieldsAndMissingListsStillRead() throws {
        let json = #"{"time":"2026-10-05T01:00:00Z","weekly":{"percent":12},"futureField":true}"#
        let lines = HistoryCoding.decodeLines(HistoryLine.self, from: Data(json.utf8))
        #expect(lines.count == 1)
        #expect(lines.first?.weekly?.percent == 12)
        #expect(lines.first?.models == [])
        #expect(lines.first?.unchanged == false)
    }

    @Test func retentionDeletesWholeMonthsPastNinetyDays() throws {
        let files = try temporaryHistory()
        let now = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 17))!
        for month in [6, 7, 8, 9, 10] {
            let time = utcCalendar.date(from: DateComponents(year: 2026, month: month, day: 15))!
            try files.append(line(time, week: Double(month)))
        }
        // 90 days before 17 October is 19 July: June has ended before then, July hasn't.
        let deleted = files.pruneReadings(now: now)
        #expect(deleted.map(\.lastPathComponent) == ["readings-2026-06.jsonl"])
        #expect(files.readingsFiles().map(\.lastPathComponent) == ["readings-2026-07.jsonl", "readings-2026-08.jsonl",
                                                                  "readings-2026-09.jsonl", "readings-2026-10.jsonl"])
    }
}

@Suite("Summaries of closed windows and weeks")
struct SummaryTests {
    /// Two 5-hour windows on Monday, the second reaching 100%, and a gap in the first.
    var day: [HistoryLine] {
        let r1 = at(hour: 5), r2 = at(hour: 12)
        return [
            line(at(hour: 0, minute: 10), five: 5, fiveReset: r1, week: 2, weekReset: at(day: 7)),
            line(at(hour: 0, minute: 25), five: 12, fiveReset: r1.addingTimeInterval(2), week: 3, weekReset: at(day: 7)), // jitter
            line(at(hour: 2, minute: 25), five: 40, fiveReset: r1, week: 6, weekReset: at(day: 7), prev: at(hour: 0, minute: 25)), // 2 h gap
            line(at(hour: 2, minute: 40), five: 38, fiveReset: r1, week: 6, weekReset: at(day: 7)),
            line(at(hour: 7, minute: 30), five: 30, fiveReset: r2, week: 10, weekReset: at(day: 7)),
            line(at(hour: 9), five: 100, fiveReset: r2, week: 18, weekReset: at(day: 7)),
            line(at(hour: 9, minute: 15), five: 100, fiveReset: r2, week: 18, weekReset: at(day: 7))
        ]
    }

    @Test func closedFiveHourWindows() throws {
        let built = HistorySummaries.build(from: day, now: at(hour: 13))
        #expect(built.windows.count == 2)
        let first = try #require(built.windows.first)
        #expect(first.start == at(hour: 0))
        #expect(first.end == at(hour: 5))
        #expect(first.peakPercent == 40)
        #expect(first.reachedLimitAt == nil)
        #expect(first.readings == 4)
        // 10 min before the first reading, the 2 h gap, and 2 h 20 min after the last.
        #expect(first.gapMinutes == 10 + 120 + 140)
        let second = try #require(built.windows.last)
        #expect(second.reachedLimitAt == at(hour: 9))
        #expect(second.peakPercent == 100)
    }

    @Test func openWindowIsNotSummarised() {
        let built = HistorySummaries.build(from: day, now: at(hour: 11))
        #expect(built.windows.count == 1)
        #expect(built.weeks.isEmpty)
    }

    @Test func closedWeek() throws {
        let fable = { (p: Double) in [HistoryLine.ModelRow(name: "Fable", percent: p, resetsAt: at(day: 7))] }
        let lines = [
            line(at(hour: 1), five: 10, fiveReset: at(hour: 5), week: 10, weekReset: at(day: 7), credits: 40, models: fable(5)),
            line(at(hour: 3), five: 100, fiveReset: at(hour: 5), week: 40, weekReset: at(day: 7), credits: 45, models: fable(30)),
            // A new month: credits used drops back.
            line(at(day: 3), five: 20, fiveReset: at(day: 3, hour: 4), week: 80, weekReset: at(day: 7), credits: 2, models: fable(25)),
            line(at(day: 6), five: 50, fiveReset: at(day: 6, hour: 4), week: 100, weekReset: at(day: 7), credits: 6),
            line(at(day: 6, hour: 2), five: 50, fiveReset: at(day: 6, hour: 4), week: 99, weekReset: at(day: 7), credits: 6),
            line(at(day: 7, hour: 1), five: 3, fiveReset: at(day: 7, hour: 5), week: 1, weekReset: at(day: 14), credits: 6)
        ]
        let built = HistorySummaries.build(from: lines, now: at(day: 7, hour: 2))
        let week = try #require(built.weeks.first)
        #expect(built.weeks.count == 1)
        #expect(week.start == at())
        #expect(week.end == at(day: 7))
        #expect(week.finalPercent == 99)
        #expect(week.peakPercent == 100)
        #expect(week.modelPeaks == ["Fable": 30])
        #expect(week.creditsSpent == Double(5 + 2 + 4))
        #expect(week.currency == "USD")
        #expect(week.limitReachedAt == at(day: 6))
        #expect(week.windowsAtLimit == 1)
        #expect(week.readings == 5)
    }

    @Test func rebuildingIsIdempotentAndKeepsWhatRawNoLongerCovers() throws {
        let files = try temporaryHistory()
        let first = try files.rebuildSummaries(from: day, now: at(hour: 13))
        let bytes = try Data(contentsOf: files.windowsFile)
        let second = try files.rebuildSummaries(from: day, now: at(hour: 13))
        #expect(first.windows == second.windows)
        #expect(try Data(contentsOf: files.windowsFile) == bytes)

        // Raw readings for the first window pruned: its summary stays as it was.
        let later = try files.rebuildSummaries(from: Array(day.suffix(3)), now: at(hour: 13))
        #expect(later.windows.count == 2)
        #expect(later.windows.first == first.windows.first)
    }

    @Test func missedResetHealsOnRebuild() throws {
        let files = try temporaryHistory()
        // Nothing summarised yet (the app crashed before the reset was seen).
        #expect(files.loadWindows().isEmpty)
        try files.rebuildSummaries(from: day, now: at(hour: 13))
        #expect(files.loadWindows().count == 2)
    }
}

@Suite("Daily use")
struct DailyUseTests {
    @Test func risesAcrossAGapAreMarked() {
        let lines = [
            line(at(hour: 9), week: 10, weekReset: at(day: 7)),
            line(at(hour: 9, minute: 15), week: 12, weekReset: at(day: 7)),
            // Two hours with no reading at all.
            line(at(hour: 11, minute: 15), week: 20, weekReset: at(day: 7), prev: at(hour: 9, minute: 15)),
            // Flat for an hour (identical readings skipped), then a rise 15 minutes after the last one.
            line(at(hour: 12, minute: 30), week: 21, weekReset: at(day: 7), prev: at(hour: 12, minute: 15))
        ]
        let rises = DailyUsage.rises(lines)
        #expect(rises.map(\.points) == [2, 8, 1])
        #expect(rises.map(\.acrossGap) == [false, true, false])
    }

    @Test func dailyUseAcrossAWeeklyReset() {
        let lines = [
            line(at(day: 0, hour: 20), week: 80, weekReset: at(day: 1, hour: 12)),
            line(at(day: 0, hour: 20, minute: 20), week: 85, weekReset: at(day: 1, hour: 12)),
            line(at(day: 1, hour: 11, minute: 50), week: 90, weekReset: at(day: 1, hour: 12), prev: at(day: 1, hour: 11, minute: 35)),
            // Reset at 12:00; the next reading shows the new week at 3%.
            line(at(day: 1, hour: 12, minute: 10), week: 3, weekReset: at(day: 8, hour: 12), prev: at(day: 1, hour: 11, minute: 50)),
            line(at(day: 1, hour: 12, minute: 25), week: 5, weekReset: at(day: 8, hour: 12))
        ]
        let days = DailyUsage.days(lines, count: 2, now: at(day: 1, hour: 13), calendar: utcCalendar)
        #expect(days.map(\.points) == [5, 5 + 3 + 2])
        #expect(days.map(\.gapPoints) == [0, 0])
        #expect(days.last?.isToday == true)
    }

    @Test func daysWithoutReadingsAreGapsNotZero() {
        let lines = [
            line(at(day: 0, hour: 10), week: 10, weekReset: at(day: 7)),
            line(at(day: 3, hour: 9), week: 40, weekReset: at(day: 7), prev: at(day: 0, hour: 10))
        ]
        let days = DailyUsage.days(lines, count: 4, now: at(day: 3, hour: 12), calendar: utcCalendar)
        #expect(days.map(\.hasReadings) == [true, false, false, true])
        #expect(days[3].points == 0)
        #expect(days[3].gapPoints == 30)
    }

    @Test func sevenDaySummaryLine() {
        let days = (0..<7).map { i in
            DailyUsage.Day(start: at(day: Double(i)), points: i == 0 ? 22 : 3, gapPoints: 0, hasReadings: true, isToday: i == 6)
        }
        #expect(LastSevenDays.summary(days, now: at(day: 6, hour: 12), calendar: utcCalendar, locale: Locale(identifier: "en_GB"))
                == "Monday used 22% of the week, over the daily budget.")
        let quiet = days.map { var d = $0; d.points = $0.isToday ? 9 : 1; return d }
        #expect(LastSevenDays.summary(quiet, now: at(day: 6, hour: 12), calendar: utcCalendar)
                == "Today has used 9% of the week so far, within the daily budget.")
        let empty = days.map { var d = $0; d.hasReadings = false; d.points = 0; return d }
        #expect(LastSevenDays.summary(empty, now: at(day: 6), calendar: utcCalendar) == "Builds up as the app takes readings.")
    }

    @Test func heatMapWaitsForFourteenDays() {
        var lines: [HistoryLine] = []
        for d in 0..<13 {
            lines.append(line(at(day: Double(d), hour: 9), week: Double(d * 4), weekReset: at(day: 20)))
            lines.append(line(at(day: Double(d), hour: 9, minute: 20), week: Double(d * 4 + 2), weekReset: at(day: 20)))
        }
        #expect(!UsageHeatMap.make(lines, calendar: utcCalendar).isReady)
        lines.append(line(at(day: 13, hour: 9), week: 60, weekReset: at(day: 20)))
        let map = UsageHeatMap.make(lines, calendar: utcCalendar)
        #expect(map.isReady)
        // Mondays (weekday 2) 08:00 to 10:00: 2 points on each of two Mondays.
        #expect(map.cells[1][4] == 2)
        #expect(map.cells[1][0] == 0)
    }
}

@Suite("History CSV")
struct HistoryCSVTests {
    @Test func readingsExport() {
        let csv = HistoryCSV.readings([line(at(hour: 1), five: 12.5, fiveReset: at(hour: 3), week: 40, weekReset: at(day: 7), credits: 4,
                                            models: [.init(name: "Fable", percent: 10, resetsAt: at(day: 7))])])
        let rows = csv.split(separator: "\n")
        #expect(rows.count == 2)
        #expect(rows[0].hasPrefix("time,heartbeat,five_hour_percent"))
        #expect(rows[1].hasPrefix("2026-10-05T01:00:00Z,no,12.50,2026-10-05T03:00:00Z,40,"))
    }

    @Test func fieldsWithCommasAreQuoted() {
        #expect(HistoryCSV.field("a, b") == "\"a, b\"")
        #expect(HistoryCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryCSV.field("plain") == "plain")
    }
}
