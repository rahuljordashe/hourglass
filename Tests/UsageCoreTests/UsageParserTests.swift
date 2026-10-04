import Foundation
import Testing
@testable import UsageCore

private func fixtureText(_ name: String, ext: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private func usage(_ outcome: UsageResponseParser.Outcome?) throws -> PlanUsage {
    guard case .usage(let u) = outcome else {
        Issue.record("Expected usage, got \(String(describing: outcome))")
        throw CancellationError()
    }
    return u
}

private let now = Date(timeIntervalSince1970: 1_791_018_260)

/// Wraps a `rate_limits` object in a get_usage control_response.
private func controlResponse(_ rateLimits: String, id: String = "r1", available: Bool = true) -> String {
    """
    {"type":"control_response","response":{"subtype":"success","request_id":"\(id)","response":{"subscription_type":"max","rate_limits_available":\(available),"rate_limits":\(rateLimits),"behaviors":null}}}
    """
}

@Suite("Parsing Claude Code's usage answers")
struct UsageParserTests {
    @Test func getUsageFromTheSpike() throws {
        let line = try fixtureText("get-usage-success", ext: "json").replacingOccurrences(of: "\n", with: "")
        let u = try usage(UsageResponseParser.parse(line: line, requestId: "notch-test-1", now: now))

        #expect(u.source == .getUsage)
        #expect(u.subscriptionType == "max")
        #expect(!u.isSeeded)
        #expect(u.limits?.count == 3)
        #expect(u.session?.percent == 12)
        #expect(u.weekly?.percent == 34)
        #expect(u.session?.resetsAt == ISODate.parse("2026-01-14T15:00:00+00:00"))

        let fable = try #require(u.scopedWeekly.first)
        #expect(u.scopedWeekly.count == 1)
        #expect(fable.scopeName == "Fable")
        #expect(fable.percent == 6)

        let credits = try #require(u.credits)
        #expect(credits.isEnabled == false)
        #expect(credits.userDisabled == true)
        #expect(credits.used == 0) // from spend.used: 0 minor units
        #expect(credits.currency == "USD")

        #expect(u.promos.map(\.key) == ["harbor_lantern", "iguana_necktie"])
        let cloud = try #require(u.promos.first { $0.key == "iguana_necktie" })
        #expect(cloud.limitDollars == 100) // whole dollars, never divided by 100
        #expect(cloud.remainingDollars == 100)
    }

    @Test func usageReportFallbackFromTheSpike() throws {
        let stream = try fixtureText("usage-report-stream", ext: "jsonl")
        let outcomes = stream.split(separator: "\n").compactMap { UsageResponseParser.parse(line: $0, requestId: nil, now: now) }
        #expect(outcomes.count == 1)
        let u = try usage(outcomes.first)
        #expect(u.source == .usageReport)
        #expect(!u.isSeeded)
        #expect(u.limits?.map(\.category) == [.session, .weeklyAll, .weeklyScoped])
        #expect(u.scopedWeekly.first?.scopeName == "Fable")
        #expect(u.credits?.isEnabled == false)
    }

    @Test func seededAnswerIsFlagged() throws {
        let line = try fixtureText("get-usage-seeded", ext: "json").replacingOccurrences(of: "\n", with: "")
        let u = try usage(UsageResponseParser.parse(line: line, requestId: nil, now: now))
        #expect(u.isSeeded)
        #expect(u.limits == nil)
        // Legacy windows still give the numbers.
        #expect(u.session?.percent == 12)
        #expect(u.weekly?.percent == 34)
    }

    @Test func ignoresAnswersToOtherRequests() throws {
        let line = controlResponse(#"{"limits":[]}"#, id: "someone-else")
        #expect(UsageResponseParser.parse(line: line, requestId: "mine", now: now) == nil)
        #expect(UsageResponseParser.parse(line: #"{"type":"system","subtype":"init"}"#, requestId: nil, now: now) == nil)
        #expect(UsageResponseParser.parse(line: "not json control_response", requestId: nil, now: now) == nil)
    }

    @Test func errorsAndUnavailablePlans() throws {
        let error = #"{"type":"control_response","response":{"subtype":"error","request_id":"r1","error":"Request failed with status code 429"}}"#
        let outcome = UsageResponseParser.parse(line: error, requestId: "r1", now: now)
        #expect(outcome == .error("Request failed with status code 429"))
        #expect(outcome?.isRateLimited == true)
        #expect(UsageResponseParser.Outcome.error("socket hang up").isRateLimited == false)

        let apiKey = controlResponse("null", available: false)
        guard case .unavailable = UsageResponseParser.parse(line: apiKey, requestId: "r1", now: now) else {
            Issue.record("Expected unavailable"); return
        }
    }

    @Test func classifiesLimitsOnKindNotOrder() throws {
        let rl = """
        {"limits":[
          {"kind":"weekly_scoped","percent":40,"resets_at":"2026-10-09T04:00:00Z","scope":{"model":{"display_name":"Fable"}}},
          {"kind":"something_new","percent":3},
          {"kind":"weekly_all","percent":22.5,"resets_at":"2026-10-09T04:00:00Z"},
          {"kind":"session","percent":130,"resets_at":"2026-10-03T13:40:00Z"},
          {"percent":9}
        ]}
        """
        let u = try usage(UsageResponseParser.parse(line: controlResponse(rl), requestId: "r1", now: now))
        #expect(u.limits?.count == 4) // the row without a kind is dropped
        #expect(u.session?.percent == 130) // above 100 is allowed
        #expect(u.weekly?.percent == 22.5)
        #expect(u.scopedWeekly.map(\.scopeName) == ["Fable"])
        #expect(u.limits?.contains { $0.category == .other } == true)
        #expect(u.highestPercent == 130)
    }

    @Test func missingValuesAreUnknownNotZero() throws {
        let rl = """
        {"five_hour":{"utilization":null,"resets_at":null},
         "seven_day":{"utilization":"12","resets_at":"garbage"},
         "limits":[{"kind":"session","percent":-4,"resets_at":null},{"kind":"weekly_all","percent":true}]}
        """
        let u = try usage(UsageResponseParser.parse(line: controlResponse(rl), requestId: "r1", now: now))
        #expect(u.fiveHour == nil)
        #expect(u.sevenDay == nil)
        #expect(u.session?.percent == nil)
        #expect(u.weekly?.percent == nil) // a boolean is not a number
        #expect(u.highestPercent == nil)
        #expect(u.credits == nil)
        #expect(u.promos.isEmpty)
    }

    @Test func nullResetMeansReadyNotZero() throws {
        let rl = #"{"limits":[{"kind":"session","percent":0,"resets_at":null}]}"#
        let u = try usage(UsageResponseParser.parse(line: controlResponse(rl), requestId: "r1", now: now))
        #expect(u.session == PlanUsage.Window(percent: 0, resetsAt: nil))
    }

    @Test func creditsUseMinorUnitsAndDecimalPlaces() throws {
        let rl = """
        {"limits":[],
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1234,"utilization":24.68,"currency":"GBP","decimal_places":2},
         "spend":{"used":{"amount_minor":999,"currency":"USD","exponent":2},"enabled":true}}
        """
        let credits = try #require(try usage(UsageResponseParser.parse(line: controlResponse(rl), requestId: "r1", now: now)).credits)
        #expect(credits.isEnabled == true)
        #expect(credits.monthlyLimit == 50)
        #expect(credits.used == 12.34)
        #expect(credits.currency == "GBP")
        #expect(credits.utilization == 24.68)
    }

    @Test func promoBucketsAreFoundGenerically() throws {
        let rl = """
        {"limits":[],
         "five_hour":{"utilization":5,"resets_at":null,"limit_dollars":null},
         "brand_new_bucket":{"utilization":10,"resets_at":"2026-11-01T00:00:00Z","limit_dollars":20,"used_dollars":2,"remaining_dollars":18},
         "dormant":null}
        """
        let u = try usage(UsageResponseParser.parse(line: controlResponse(rl), requestId: "r1", now: now))
        #expect(u.promos == [PlanUsage.Promo(key: "brand_new_bucket", limitDollars: 20, usedDollars: 2, remainingDollars: 18,
                                             expiresAt: ISODate.parse("2026-11-01T00:00:00Z"))])
    }

    @Test func isoDates() {
        let base = Date(timeIntervalSince1970: 1_791_035_400) // 2026-10-03T13:50:00Z
        #expect(ISODate.parse("2026-10-03T13:50:00Z") == base)
        #expect(ISODate.parse("2026-10-03T13:50:00+00:00") == base)
        #expect(ISODate.parse("2026-10-03T19:20:00+05:30") == base)
        let micro = ISODate.parse("2026-10-03T13:50:00.466680+00:00")
        #expect(abs((micro?.timeIntervalSince(base) ?? 0) - 0.46668) < 0.0001)
        #expect(ISODate.parse("yesterday") == nil)
    }
}

@Suite("Folding a new usage reading into the last one")
struct PlanUsageMergeTests {
    let reset = Date(timeIntervalSince1970: 1_791_035_400)

    private func reading(_ percent: Double, reset: Date?, seeded: Bool = false, at: Date = now) -> PlanUsage {
        PlanUsage(
            limits: [PlanUsage.Limit(kind: "session", percent: percent, resetsAt: reset),
                     PlanUsage.Limit(kind: "weekly_scoped", percent: percent, resetsAt: reset, modelName: "Fable")],
            fetchedAt: at,
            isSeeded: seeded
        )
    }

    @Test func jitterKeepsThePreviousResetTime() {
        let merged = PlanUsageMerger.merge(reading(12, reset: reset.addingTimeInterval(1.9)), into: reading(10, reset: reset))
        #expect(merged.session?.resetsAt == reset)
        #expect(merged.session?.percent == 12)
        #expect(merged.scopedWeekly.first?.resetsAt == reset)
        let backwards = PlanUsageMerger.merge(reading(12, reset: reset.addingTimeInterval(-30)), into: reading(10, reset: reset))
        #expect(backwards.session?.resetsAt == reset)
    }

    @Test func aRealResetMovesForwardAMinuteOrMore() {
        let later = reset.addingTimeInterval(5 * 3600)
        let merged = PlanUsageMerger.merge(reading(0, reset: later), into: reading(80, reset: reset))
        #expect(merged.session?.resetsAt == later)
        #expect(PlanUsageMerger.isNewWindow(reset.addingTimeInterval(60), previous: reset))
        #expect(!PlanUsageMerger.isNewWindow(reset.addingTimeInterval(59), previous: reset))
        #expect(!PlanUsageMerger.isNewWindow(nil, previous: reset))
    }

    @Test func seededDataNeverReplacesAFreshReading() {
        let fresh = reading(40, reset: reset)
        let merged = PlanUsageMerger.merge(reading(20, reset: reset, seeded: true, at: now.addingTimeInterval(600)), into: fresh)
        #expect(merged == fresh)
        // With nothing better, last-known data is still worth showing.
        #expect(PlanUsageMerger.merge(reading(20, reset: reset, seeded: true), into: nil).isSeeded)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = reading(33.3, reset: reset)
        let data = try PlanUsageCoding.encoder().encode(original)
        #expect(try PlanUsageCoding.decoder().decode(PlanUsage.self, from: data) == original)
    }
}

@Suite("Evaluating a fetched reading")
struct PlanUsageEvaluatorTests {
    let now = Date(timeIntervalSince1970: 1_791_018_260)

    @Test func windowsScopedRowsAndCredits() throws {
        let reset = now.addingTimeInterval(3600)
        let usage = PlanUsage(
            limits: [PlanUsage.Limit(kind: "session", percent: 40, resetsAt: reset),
                     PlanUsage.Limit(kind: "weekly_all", percent: 18, resetsAt: now.addingTimeInterval(5 * 86400)),
                     PlanUsage.Limit(kind: "weekly_scoped", percent: 92, resetsAt: now.addingTimeInterval(5 * 86400), modelName: "Fable")],
            credits: .init(isEnabled: false),
            promos: [.init(key: "live", limitDollars: 100, usedDollars: 10, remainingDollars: 90, expiresAt: now.addingTimeInterval(60)),
                     .init(key: "expired", limitDollars: 100, usedDollars: 0, remainingDollars: 100, expiresAt: now.addingTimeInterval(-60))],
            fetchedAt: now.addingTimeInterval(-120)
        )
        let state = UsageEvaluator.evaluate(plan: usage, now: now)
        #expect(state.fiveHour?.percentage == 40)
        #expect(state.fiveHour?.resetsAt == reset)
        #expect(state.sevenDay?.percentage == 18)
        #expect(state.age == 120)
        #expect(state.freshness == .fresh)
        #expect(state.scoped.map(\.name) == ["Fable"])
        #expect(state.scoped.first?.level == .critical)
        #expect(state.credits?.isEnabled == false)
        #expect(state.promos.map(\.key) == ["live"]) // expired buckets are hidden
        #expect(UsageEvaluator.nextReset(after: now, in: usage) == now.addingTimeInterval(60))
    }

    @Test func nullResetIsReadyAndMissingIsUnknown() {
        let usage = PlanUsage(
            limits: [PlanUsage.Limit(kind: "session", percent: 0, resetsAt: nil),
                     PlanUsage.Limit(kind: "weekly_all", percent: nil, resetsAt: now.addingTimeInterval(86400))],
            fetchedAt: now
        )
        let state = UsageEvaluator.evaluate(plan: usage, now: now)
        #expect(state.fiveHour == nil)
        #expect(state.isReady(.fiveHour))
        #expect(state.sevenDay == nil) // unknown, not 0%
        #expect(!state.isReady(.sevenDay))
        #expect(state.hasData)
    }

    @Test func passedResetReadsAsReady() {
        let usage = PlanUsage(limits: [PlanUsage.Limit(kind: "session", percent: 70, resetsAt: now.addingTimeInterval(-10))], fetchedAt: now.addingTimeInterval(-600))
        let state = UsageEvaluator.evaluate(plan: usage, now: now)
        #expect(state.isReady(.fiveHour))
        #expect(state.fiveHour?.reportedPercentage == 70)
    }

    @Test func seededFlagCarriesThrough() {
        let usage = PlanUsage(sevenDay: .init(percent: 5, resetsAt: now.addingTimeInterval(86400)), fetchedAt: now, isSeeded: true)
        #expect(UsageEvaluator.evaluate(plan: usage, now: now).isSeeded)
    }
}
