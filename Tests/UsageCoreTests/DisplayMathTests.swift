import Foundation
import Testing
@testable import UsageCore

@Suite("Countdown, time tick and weekly budget")
struct DisplayMathTests {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 5 * 3600 + 1800)! // a half-hour offset, no daylight saving
        return c
    }()

    @Test func countdown() {
        #expect(UsageFormat.countdown(nil) == "–")
        #expect(UsageFormat.countdown(30) == "<1m")
        #expect(UsageFormat.countdown(50 * 60 + 40) == "50m")
        #expect(UsageFormat.countdown(59 * 60 + 59) == "59m")
        #expect(UsageFormat.countdown(3600) == "1h00")
        #expect(UsageFormat.countdown(3600 + 52 * 60) == "1h52")
        #expect(UsageFormat.countdown(4 * 3600 + 5 * 60) == "4h05")
    }

    @Test func longDuration() {
        #expect(UsageFormat.longDuration((5 * 24 + 15) * 3600 + 120) == "5 days 15 hours")
        #expect(UsageFormat.longDuration((24 + 1) * 3600) == "1 day 1 hour")
        #expect(UsageFormat.longDuration(2 * 86400) == "2 days")
        #expect(UsageFormat.longDuration(9 * 3600 + 59 * 60) == "9 hours")
        #expect(UsageFormat.longDuration(40 * 60) == "40 minutes")
    }

    /// The tick is the share of the window already passed: 1 − time left ÷ window length.
    @Test func timeTick() {
        let now = Date(timeIntervalSince1970: 1_791_100_000)
        let five = UsageEvaluator.status(.fiveHour, WindowReading(usedPercentage: 40, resetsAt: now.addingTimeInterval(50 * 60), observedAt: now), now: now)
        #expect(abs(five.elapsedFraction - (1 - 50.0 / 300)) < 0.0001)
        let week = UsageEvaluator.status(.sevenDay, WindowReading(usedPercentage: 19, resetsAt: now.addingTimeInterval(5.5 * 86400), observedAt: now), now: now)
        #expect(abs(week.elapsedFraction - (1 - 5.5 / 7)) < 0.0001)
    }

    private func weekly(_ percent: Double, resetIn: TimeInterval, now: Date) -> WindowStatus {
        UsageEvaluator.status(.sevenDay, WindowReading(usedPercentage: percent, resetsAt: now.addingTimeInterval(resetIn), observedAt: now), now: now)
    }

    @Test func perDayBudget() throws {
        // 4 October 2026, 14:00 at UTC+05:30; reset 9 October 09:30 (4 days 19.5 hours).
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 14)))
        let reset = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 30)))
        let b = try #require(WeeklyBudget.make(weekly: weekly(19, resetIn: reset.timeIntervalSince(now), now: now), now: now, calendar: cal))
        #expect(b.percentLeft == 81)
        #expect(b.line == .perDay(Int((81 / (reset.timeIntervalSince(now) / 86400)).rounded()))) // 14
        #expect(b.line == .perDay(17)) // 81 ÷ 4.81 days
        // Today (10 h left), 5 to 8 October in full, the reset day (9.5 h).
        #expect(b.days.map(\.hours) == [10, 24, 24, 24, 24, 9.5])
        #expect(b.days.map(\.isToday) == [true, false, false, false, false, false])
        #expect(abs(b.days.map(\.hours).reduce(0, +) * 3600 - b.timeLeft) < 1)
    }

    @Test func lastDayAndExhausted() throws {
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 20)))
        let last = try #require(WeeklyBudget.make(weekly: weekly(94, resetIn: 13.5 * 3600, now: now), now: now, calendar: cal))
        #expect(last.line == .leftUntilReset(6))
        #expect(last.days.count == 2) // tonight and the reset morning
        let spent = try #require(WeeklyBudget.make(weekly: weekly(100, resetIn: 3 * 86400, now: now), now: now, calendar: cal))
        #expect(spent.line == .exhausted)
        #expect(WeeklyBudget.make(weekly: nil, now: now) == nil)
    }
}
