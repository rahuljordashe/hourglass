import Foundation
import Testing
@testable import UsageCore

@Suite("Evaluating state for display")
struct EvaluatorTests {
    let resetsAt = Date(timeIntervalSince1970: 1_790_985_600)
    var windowStart: Date { resetsAt.addingTimeInterval(-UsageWindowKind.fiveHour.duration) }

    func snapshot(five: Double, observedAt: Date) -> UsageSnapshot {
        UsageSnapshot(fiveHour: WindowReading(usedPercentage: five, resetsAt: resetsAt, observedAt: observedAt))
    }

    @Test func noData() {
        let state = UsageEvaluator.evaluate(nil, now: t0)
        #expect(!state.hasData)
        #expect(state.freshness == .none)
    }

    static let bands: [(TimeInterval, Freshness)] = [
        (0, .fresh),
        (540, .fresh),
        (600, .aging),
        (1740, .aging),
        (1800, .stale),
        (18000, .stale)
    ]

    @Test(arguments: EvaluatorTests.bands)
    func freshnessBands(age: TimeInterval, expected: Freshness) {
        let now = windowStart.addingTimeInterval(4 * 3600)
        let state = UsageEvaluator.evaluate(snapshot(five: 20, observedAt: now.addingTimeInterval(-age)), now: now)
        #expect(state.freshness == expected)
    }

    @Test func pastResetShowsZeroAndFlagsIt() {
        let state = UsageEvaluator.evaluate(snapshot(five: 88, observedAt: resetsAt.addingTimeInterval(-600)), now: resetsAt.addingTimeInterval(60))
        let five = try! #require(state.fiveHour)
        #expect(five.isReset)
        #expect(five.percentage == 0)
        #expect(five.reportedPercentage == 88)
        #expect(five.level == .normal)
        #expect(five.pace == nil)
        #expect(five.projectedLimitAt == nil)
    }

    @Test func paceAheadAndBehind() {
        // Halfway through the window.
        let now = windowStart.addingTimeInterval(2.5 * 3600)
        let ahead = UsageEvaluator.status(.fiveHour, WindowReading(usedPercentage: 70, resetsAt: resetsAt, observedAt: now), now: now)
        #expect(ahead.elapsedFraction == 0.5)
        #expect(ahead.pace == .ahead(20))
        let behind = UsageEvaluator.status(.fiveHour, WindowReading(usedPercentage: 30, resetsAt: resetsAt, observedAt: now), now: now)
        #expect(behind.pace == .behind(20))
        let even = UsageEvaluator.status(.fiveHour, WindowReading(usedPercentage: 52, resetsAt: resetsAt, observedAt: now), now: now)
        #expect(even.pace == .onPace)
    }

    @Test func projectionWhenBurningFast() throws {
        // 60% used one hour in: 1% per minute, so 100% at 1h40m, well before the 5h reset.
        let now = windowStart.addingTimeInterval(3600)
        let status = UsageEvaluator.status(.fiveHour, WindowReading(usedPercentage: 60, resetsAt: resetsAt, observedAt: now), now: now)
        let hit = try #require(status.projectedLimitAt)
        #expect(abs(hit.timeIntervalSince(windowStart.addingTimeInterval(6000))) < 1)
    }

    @Test func noProjectionWhenRoughlyOnPace() {
        // 9% used 8.2% of the way through a week: technically heading past 100%, but on pace.
        let weekReset = Date(timeIntervalSince1970: 1_791_518_400)
        let now = weekReset.addingTimeInterval(-(6 * 86400 + 10 * 3600))
        let status = UsageEvaluator.status(.sevenDay, WindowReading(usedPercentage: 9, resetsAt: weekReset, observedAt: now), now: now)
        #expect(status.pace == .onPace)
        #expect(status.projectedLimitAt == nil)
    }

    @Test func noProjectionWhenOnTrackOrTooEarly() {
        let later = windowStart.addingTimeInterval(4 * 3600)
        let slow = UsageEvaluator.status(.fiveHour, WindowReading(usedPercentage: 50, resetsAt: resetsAt, observedAt: later), now: later)
        #expect(slow.projectedLimitAt == nil)
        let early = windowStart.addingTimeInterval(60)
        let tooEarly = UsageEvaluator.status(.fiveHour, WindowReading(usedPercentage: 5, resetsAt: resetsAt, observedAt: early), now: early)
        #expect(tooEarly.projectedLimitAt == nil)
    }

    @Test func levels() {
        #expect(UsageLevel(percentage: 74.9) == .normal)
        #expect(UsageLevel(percentage: 75) == .warning)
        #expect(UsageLevel(percentage: 90) == .critical)
        #expect(UsageLevel(percentage: 100) == .exhausted)
    }

    @Test func nextResetPicksSoonestFuture() {
        let snap = UsageSnapshot(
            fiveHour: WindowReading(usedPercentage: 1, resetsAt: resetsAt, observedAt: t0),
            sevenDay: WindowReading(usedPercentage: 1, resetsAt: resetsAt.addingTimeInterval(86400), observedAt: t0)
        )
        #expect(UsageEvaluator.nextReset(after: t0, in: snap) == resetsAt)
        #expect(UsageEvaluator.nextReset(after: resetsAt.addingTimeInterval(1), in: snap) == resetsAt.addingTimeInterval(86400))
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test func durations() {
        #expect(UsageFormat.duration(20) == "<1m")
        #expect(UsageFormat.duration(45 * 60) == "45m")
        #expect(UsageFormat.duration(2 * 3600 + 14 * 60 + 30) == "2h 14m")
        #expect(UsageFormat.duration(3 * 3600) == "3h")
        #expect(UsageFormat.duration(3 * 86400 + 4 * 3600) == "3d 4h")
    }

    @Test func percents() {
        #expect(UsageFormat.percent(0) == "0%")
        #expect(UsageFormat.percent(0.4) == "<1%")
        #expect(UsageFormat.percent(23.5) == "24%")
        #expect(UsageFormat.percent(100.2) == "100%")
    }

    @Test func ages() {
        #expect(UsageFormat.age(20) == "just now")
        #expect(UsageFormat.age(12 * 60) == "12 min ago")
        #expect(UsageFormat.age(3 * 3600) == "3 h ago")
        #expect(UsageFormat.age(3 * 86400) == "3 days ago")
    }

    @Test func clockUses24HourOnUKLocale() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let locale = Locale(identifier: "en_GB")
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!
        let later = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 30))!
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9))!
        let thursday = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9))!
        #expect(UsageFormat.clock(later, now: now, calendar: cal, locale: locale) == "14:30")
        #expect(UsageFormat.clock(tomorrow, now: now, calendar: cal, locale: locale) == "tomorrow 09:00")
        #expect(UsageFormat.clock(thursday, now: now, calendar: cal, locale: locale) == "Thu 09:00")
        let nextMonth = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 7, minute: 59))!
        #expect(UsageFormat.clock(nextMonth, now: now, calendar: cal, locale: locale) == "5 Nov 07:59")
    }

    @Test func moneyUsesNarrowSymbols() {
        let uk = Locale(identifier: "en_GB")
        #expect(UsageFormat.money(54.46, currency: "USD", locale: uk) == "$54.46")
        #expect(UsageFormat.money(250, currency: "USD", locale: uk) == "$250.00")
        #expect(UsageFormat.money(12.3, currency: "GBP", locale: uk) == "£12.30")
    }
}

@Suite("Alerts")
struct AlertTests {
    let resetsAt = Date(timeIntervalSince1970: 1_790_985_600)

    func state(_ five: Double, now: Date, observed: Date? = nil) -> UsageState {
        UsageEvaluator.evaluate(UsageSnapshot(fiveHour: WindowReading(usedPercentage: five, resetsAt: resetsAt, observedAt: observed ?? now)), now: now)
    }

    @Test func existingCrossingsAtLaunchAreSilent() {
        var tracker = AlertTracker()
        let now = resetsAt.addingTimeInterval(-3600)
        #expect(tracker.process(state(92, now: now), now: now) == nil)
        #expect(tracker.process(state(93, now: now), now: now) == nil)
    }

    @Test func crossingFiresOnceAndJumpsShowHighest() {
        var tracker = AlertTracker()
        let now = resetsAt.addingTimeInterval(-3600)
        _ = tracker.process(state(50, now: now), now: now)
        let a = tracker.process(state(76, now: now), now: now)
        #expect(a?.kind == .threshold(75))
        #expect(tracker.process(state(77, now: now), now: now) == nil)
        let b = tracker.process(state(100, now: now), now: now)
        #expect(b?.kind == .threshold(100))
        #expect(b?.title == "5-hour limit reached")
        #expect(tracker.process(state(100, now: now), now: now) == nil)
    }

    @Test func resetAlertsOnlyWhenNoticedPromptly() {
        var tracker = AlertTracker()
        let before = resetsAt.addingTimeInterval(-60)
        _ = tracker.process(state(60, now: before), now: before)
        let justAfter = resetsAt.addingTimeInterval(30)
        let alert = tracker.process(state(60, now: justAfter, observed: before), now: justAfter)
        #expect(alert?.kind == .reset)
        #expect(tracker.process(state(60, now: justAfter, observed: before), now: justAfter) == nil)

        var late = AlertTracker()
        _ = late.process(state(60, now: before), now: before)
        let hoursLater = resetsAt.addingTimeInterval(3 * 3600)
        #expect(late.process(state(60, now: hoursLater, observed: before), now: hoursLater) == nil)
    }

    @Test func persistedFiredSetPreventsRepeatsAfterRelaunch() {
        var first = AlertTracker()
        let now = resetsAt.addingTimeInterval(-3600)
        _ = first.process(state(10, now: now), now: now)
        _ = first.process(state(80, now: now), now: now)
        var relaunched = AlertTracker(fired: first.fired)
        _ = relaunched.process(state(10, now: now), now: now)
        #expect(relaunched.process(state(81, now: now), now: now) == nil)
    }
}
