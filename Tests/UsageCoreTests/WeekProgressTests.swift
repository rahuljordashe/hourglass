import Foundation
import Testing
@testable import UsageCore

// Made-up weeks only. The limit week in these tests runs Monday 00:00 to Monday 00:00 UTC.

@Suite("Daily summaries")
struct DaySummaryTests {
    var lines: [HistoryLine] {
        [
            line(at(hour: 9), five: 10, fiveReset: at(hour: 13), week: 10, weekReset: at(day: 7)),
            line(at(hour: 9, minute: 15), five: 40, fiveReset: at(hour: 13), week: 14, weekReset: at(day: 7)),
            line(at(hour: 9, minute: 30), five: 100, fiveReset: at(hour: 13), week: 18, weekReset: at(day: 7)),
            // Two hours unread, and use that only shows up after it.
            line(at(hour: 11, minute: 30), five: 100, fiveReset: at(hour: 13), week: 24, weekReset: at(day: 7), prev: at(hour: 9, minute: 30)),
            line(at(day: 1, hour: 10), five: 30, fiveReset: at(day: 1, hour: 14), week: 99, weekReset: at(day: 7), prev: at(hour: 11, minute: 30)),
            line(at(day: 1, hour: 10, minute: 15), five: 35, fiveReset: at(day: 1, hour: 14), week: 100, weekReset: at(day: 7))
        ]
    }

    @Test func onePerDayWithShareGapAndLimits() throws {
        let days = DaySummaries.build(from: lines, calendar: utcCalendar)
        #expect(days.map(\.date) == ["2026-10-05", "2026-10-06"])
        let monday = try #require(days.first)
        #expect(monday.share == 14) // 4 + 4 + 6 (after the gap)
        #expect(monday.gapShare == 6)
        #expect(monday.hadGap)
        #expect(monday.weekTotalAtEnd == 24)
        #expect(monday.weekEnd == at(day: 7))
        #expect(monday.limitReachedAt == nil)
        #expect(monday.fiveHourLimitHit)
        #expect(monday.fiveHourWindows == [.init(start: at(hour: 8), end: at(hour: 13), peakPercent: 100, reachedLimitAt: at(hour: 9, minute: 30))])
        let tuesday = try #require(days.last)
        #expect(tuesday.share == 76) // the overnight rise to 99% counts on the day it was seen, as after a gap
        #expect(tuesday.gapShare == 75)
        #expect(tuesday.limitReachedAt == at(day: 1, hour: 10, minute: 15))
        #expect(!tuesday.fiveHourLimitHit)
    }

    @Test func rebuildKeepsDaysWhoseReadingsWerePruned() throws {
        let files = try temporaryHistory()
        let first = try files.rebuildSummaries(from: lines, now: at(day: 2), calendar: utcCalendar)
        let again = try files.rebuildSummaries(from: lines, now: at(day: 2), calendar: utcCalendar)
        #expect(first.days == again.days)
        let later = try files.rebuildSummaries(from: Array(lines.suffix(2)), now: at(day: 2), calendar: utcCalendar)
        #expect(later.days.count == 2)
        #expect(later.days.first == first.days.first)
        #expect(files.loadDays() == later.days)
    }

    @Test func csvExport() {
        let csv = HistoryCSV.days(DaySummaries.build(from: lines, calendar: utcCalendar))
        let rows = csv.split(separator: "\n")
        #expect(rows.count == 3)
        #expect(rows[0] == "date,share_of_week,seen_after_gap,had_gap,week_total_at_end,week_resets_at,weekly_limit_reached_at,five_hour_limit_hit,five_hour_peaks,readings")
        #expect(rows[1].hasPrefix("2026-10-05,14,6,yes,24,2026-10-12T00:00:00Z,,yes,"))
    }
}

@Suite("This week against past weeks")
struct WeekProgressTests {
    func week(_ n: Int, _ percents: [(day: Double, percent: Double)]) -> [HistoryLine] {
        percents.map { line(at(day: Double(7 * n) + $0.day), week: $0.percent, weekReset: at(day: Double(7 * (n + 1)))) }
    }

    @Test func curvesStartAtZeroAndJoinReadingsStraight() {
        let lines = week(0, [(1, 10), (3, 40)])
        let curve = WeekProgress.curve(lines, weekEnd: at(day: 7))
        #expect(curve == [.init(offset: 0, percent: 0), .init(offset: 86400, percent: 10), .init(offset: 3 * 86400, percent: 40)])
        #expect(WeekProgress.value(curve, at: 2 * 86400) == 25)
        #expect(WeekProgress.value(curve, at: 6 * 86400) == 40)
        #expect(WeekProgress.value([], at: 10) == nil)
    }

    @Test func weeksFromRawAndFromDailySummariesOnly() throws {
        // Week 0 survives only as daily summaries; week 1 has raw readings; week 2 is current.
        let old = DaySummaries.build(from: week(0, [(0.5, 10), (2.5, 50), (6.5, 80)]), calendar: utcCalendar)
        let raw = week(1, [(1, 20), (5, 60)])
        let weeks = WeekProgress.weeks(lines: raw, summaries: [], days: old, current: (30, at(day: 21)), now: at(day: 16))
        #expect(weeks.map(\.end) == [at(day: 21), at(day: 14), at(day: 7)])
        #expect(weeks[0].isCurrent)
        #expect(weeks[0].finalPercent == 30)
        #expect(weeks[0].curve.last == .init(offset: 2 * 86400, percent: 30))
        #expect(weeks[1].curve.count == 3)
        #expect(weeks[2].curve.map(\.percent) == [0, 10, 50, 80])
        #expect(weeks[2].finalPercent == 80)
    }

    @Test func comparisonsNeedEnoughFullWeeks() throws {
        var lines: [HistoryLine] = []
        for n in 0..<5 { lines += week(n, [(0.1, 0), (3.5, Double(20 + n * 10)), (6.9, Double(50 + n * 10))]) }
        let weeks = WeekProgress.weeks(lines: lines, summaries: [], days: [], current: (10, at(day: 42)), now: at(day: 36))
        let full = WeekProgress.fullPastWeeks(weeks, historyStart: lines.first?.time)
        #expect(full.count == 5)
        let last = try #require(WeekProgress.band(.lastWeek, fullPastWeeks: full))
        #expect(last.at(3.5 * 86400)?.middle == 60)
        let four = try #require(WeekProgress.band(.fourWeeks, fullPastWeeks: full))
        #expect(four.weeks == 4)
        #expect(four.at(3.5 * 86400)?.lower == 30)
        #expect(four.at(3.5 * 86400)?.upper == 60)
        #expect(four.at(3.5 * 86400)?.middle == 45)
        #expect(WeekProgress.band(.threeMonths, fullPastWeeks: full) == nil)
        // A week the app only started recording halfway through isn't a fair comparison.
        #expect(WeekProgress.fullPastWeeks(weeks, historyStart: at(day: 3)).map(\.end) == Array(full.map(\.end).prefix(4)))
    }

    @Test func middleHalfAndMedian() {
        #expect(WeekProgress.percentile([10, 20, 30, 40, 50], 0.5) == 30)
        #expect(WeekProgress.percentile([10, 20, 30, 40, 50], 0.25) == 20)
        #expect(WeekProgress.percentile([10, 20], 0.75) == 17.5)
    }

    @Test func headerAndLineColour() {
        // Day 3.5 of 7: even pace is 50%.
        let now = at(day: 3, hour: 12), end = at(day: 7)
        #expect(WeekProgress.header(percent: 41, now: now, weekEnd: end) == "41% · 9 points under pace")
        #expect(WeekProgress.header(percent: 50.3, now: now, weekEnd: end) == "50% · on pace")
        #expect(WeekProgress.header(percent: 51, now: now, weekEnd: end) == "51% · 1 point ahead of pace")
        #expect(WeekProgress.header(percent: 100, now: now, weekEnd: end) == "100% · limit reached")
        #expect(WeekProgress.lineStyle(percent: 60, now: now, weekEnd: end) == .normal)
        #expect(WeekProgress.lineStyle(percent: 61, now: now, weekEnd: end) == .ahead)
        #expect(WeekProgress.lineStyle(percent: 100, now: now, weekEnd: end) == .limit)
    }

    @Test func sentenceUnderTheCard() {
        let gb = Locale(identifier: "en_GB")
        #expect(WeekProgress.sentence(limitReachedAt: nil, weekEnd: at(day: 7), lastWeekByNow: 59, calendar: utcCalendar, locale: gb)
                == "Last week you were at 59% by now.")
        #expect(WeekProgress.sentence(limitReachedAt: at(day: 4, hour: 15, minute: 40), weekEnd: at(day: 7, hour: 9),
                                      lastWeekByNow: 80, calendar: utcCalendar, locale: gb)
                == "Limit reached Friday 15:40. Back Monday 09:00. Last week you were at 80% by now.")
        #expect(WeekProgress.sentence(limitReachedAt: nil, weekEnd: at(day: 7), lastWeekByNow: nil) == nil)
    }

    @Test func daysBelongToTheWeekHoldingTheirMidday() {
        // A week from Thursday 18:00 to the next Thursday 18:00 draws Friday to Thursday.
        let start = at(day: 3, hour: 18)
        let week = LimitWeek(start: start, end: start.addingTimeInterval(WeekProgress.length), curve: [], finalPercent: nil)
        let days = WeekProgress.dayStarts(week, calendar: utcCalendar)
        #expect(days == (4...10).map { at(day: Double($0)) })
        // A reset at 06:00 keeps that day in the new week.
        let early = at(day: 3, hour: 6)
        let morning = LimitWeek(start: early, end: early.addingTimeInterval(WeekProgress.length), curve: [], finalPercent: nil)
        #expect(WeekProgress.dayStarts(morning, calendar: utcCalendar).first == at(day: 3))
    }

    @Test func chartDaysFollowTheClockNotTheReset() throws {
        // The reported case: a week resetting Friday 04:00 UTC (09:30 in Colombo), seen at 08:56 on Monday.
        var colombo = Calendar(identifier: .gregorian)
        colombo.timeZone = try #require(TimeZone(identifier: "Asia/Colombo"))
        let start = Date(timeIntervalSince1970: 1_792_728_000) // Friday 23 Oct 2026 04:00 UTC
        let week = LimitWeek(start: start, end: start.addingTimeInterval(WeekProgress.length), curve: [], finalPercent: nil)
        let monday = Date(timeIntervalSince1970: 1_792_985_160) // Monday 26 Oct 2026 08:56 Colombo
        let days = WeekProgress.chartDays(week, now: monday, calendar: colombo)
        // Friday 09:30 to midnight, six whole days, then Friday midnight to 09:30.
        #expect(days.map(\.weekday) == [6, 7, 1, 2, 3, 4, 5, 6])
        #expect(days.first?.from == 0)
        #expect(days.first?.to == 14.5 * 3600)
        #expect(days.last?.to == WeekProgress.length)
        #expect(days.filter(\.isToday).map(\.weekday) == [2])
        // The short last Friday goes unlabelled so Friday isn't drawn twice.
        #expect(days.map(\.isLabelled) == [true, true, true, true, true, true, true, false])
    }

    @Test func chartDaysForAMidnightReset() {
        let week = LimitWeek(start: at(), end: at(day: 7), curve: [], finalPercent: nil)
        let days = WeekProgress.chartDays(week, now: at(day: 6, hour: 23), calendar: utcCalendar)
        #expect(days.count == 7)
        #expect(days.map(\.from) == (0..<7).map { Double($0) * 86400 })
        #expect(days.map(\.isToday) == [false, false, false, false, false, false, true])
        #expect(days.allSatisfy { $0.isLabelled })
    }

    @Test func comparisonLabelSitsBelowItsLineUnlessCrowded() {
        func baseline(_ y: Double, _ others: [Double] = []) -> Double {
            WeekProgress.comparisonLabelBaseline(lineY: y, avoiding: others, plotTop: 5, plotBottom: 72, labelHeight: 10)
        }
        #expect(baseline(30) == 43)
        // Too near this week's line or the pace line below: above its own line instead.
        #expect(baseline(30, [50]) == 24)
        #expect(baseline(30, [36]) == 24)
        #expect(baseline(30, [60]) == 43)
        // Too near the foot of the plot.
        #expect(baseline(50) == 44)
        // Never above the top of the plot.
        #expect(baseline(64) == 58)
        #expect(baseline(8, [21]) == 15)
    }

    @Test func aLimitReachedBeforeTheResetBelongsToTheOldWeek() {
        // The old week ends Thursday 18:00 having hit 100% that morning; the new week starts at 2%.
        let old = (0..<4).map { line(at(day: Double($0), hour: 9), week: Double(40 + 20 * $0), weekReset: at(day: 3, hour: 18)) }
        let new = [line(at(day: 3, hour: 20), week: 2, weekReset: at(day: 10, hour: 18))]
        let days = DaySummaries.build(from: old + new, calendar: utcCalendar)
        // Only daily summaries left (raw pruned): the limit still lands in the old week.
        let weeks = WeekProgress.weeks(lines: [], summaries: [], days: days, current: (2, at(day: 10, hour: 18)), now: at(day: 3, hour: 21))
        #expect(weeks.map(\.end) == [at(day: 10, hour: 18), at(day: 3, hour: 18)])
        #expect(weeks[0].limitReachedAt == nil)
        #expect(weeks[1].limitReachedAt == at(day: 3, hour: 9))
    }
}
