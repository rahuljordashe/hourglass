import Foundation
import Testing
@testable import UsageCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func input(session: String = "s1", apiMs: Double?, five: (Double, Double)? = nil, week: (Double, Double)? = nil) -> StatusLineInput {
    StatusLineInput(
        sessionId: session,
        version: "2.1.287",
        cost: apiMs.map { .init(totalApiDurationMs: $0) },
        rateLimits: (five == nil && week == nil) ? nil : .init(
            fiveHour: five.map { .init(usedPercentage: $0.0, resetsAt: $0.1) },
            sevenDay: week.map { .init(usedPercentage: $0.0, resetsAt: $0.1) }
        )
    )
}

let t0 = Date(timeIntervalSince1970: 1_790_970_000)
let fiveReset: Double = 1_790_985_600
let weekReset: Double = 1_791_417_600

@Suite("Parsing Claude Code's status line input")
struct ParsingTests {
    @Test func fullInput() throws {
        let parsed = try StatusLineInput.parse(fixture("full-input"))
        #expect(parsed.sessionId == "11111111-2222-3333-4444-555555555555")
        #expect(parsed.version == "2.1.287")
        #expect(parsed.cost?.totalApiDurationMs == 5400)
        #expect(parsed.rateLimits?.fiveHour?.usedPercentage == 23.5)
        #expect(parsed.rateLimits?.fiveHour?.resetsAt == fiveReset)
        #expect(parsed.rateLimits?.sevenDay?.usedPercentage == 41.2)
    }

    @Test func missingRateLimits() throws {
        let parsed = try StatusLineInput.parse(fixture("no-rate-limits"))
        #expect(parsed.rateLimits == nil)
    }

    @Test func lenientNumbersAndNulls() throws {
        let parsed = try StatusLineInput.parse(fixture("odd-types"))
        #expect(parsed.cost?.totalApiDurationMs == 1200)
        #expect(parsed.rateLimits?.fiveHour?.resetsAt == fiveReset)
        #expect(parsed.rateLimits?.sevenDay?.usedPercentage == nil)
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try StatusLineInput.parse(Data("not json".utf8)) }
    }
}

@Suite("Merging readings")
struct MergeTests {
    @Test func firstReadingIsStored() throws {
        let parsed = try StatusLineInput.parse(fixture("full-input"))
        let (snap, outcome) = UsageMerger.merge(.empty, with: parsed, now: t0, entrypoint: "cli")
        #expect(outcome.fresh)
        #expect(snap.fiveHour == WindowReading(usedPercentage: 23.5, resetsAt: Date(timeIntervalSince1970: fiveReset), observedAt: t0))
        #expect(snap.sevenDay?.usedPercentage == 41.2)
        #expect(snap.source == ReadingSource(claudeCodeVersion: "2.1.287", entrypoint: "cli"))
        #expect(snap.lastUpdated == t0)
    }

    @Test func noRateLimitsChangesNothingButRemembersSession() throws {
        let (first, _) = UsageMerger.merge(.empty, with: input(apiMs: 100, five: (10, fiveReset)), now: t0, entrypoint: nil)
        let parsed = try StatusLineInput.parse(fixture("no-rate-limits"))
        let (snap, outcome) = UsageMerger.merge(first, with: parsed, now: t0.addingTimeInterval(60), entrypoint: nil)
        #expect(!outcome.hadRateLimits)
        #expect(outcome.changedWindows.isEmpty)
        #expect(snap.fiveHour == first.fiveHour)
        #expect(snap.sessions["11111111-2222-3333-4444-555555555555"] != nil)
    }

    @Test func missingWindowKeepsLastKnownValue() throws {
        let (first, _) = UsageMerger.merge(.empty, with: input(apiMs: 100, five: (10, fiveReset), week: (40, weekReset)), now: t0, entrypoint: nil)
        let (snap, outcome) = UsageMerger.merge(first, with: input(apiMs: 200, five: (12, fiveReset)), now: t0.addingTimeInterval(60), entrypoint: nil)
        #expect(outcome.changedWindows == [.fiveHour])
        #expect(snap.fiveHour?.usedPercentage == 12)
        #expect(snap.sevenDay == first.sevenDay)
    }

    @Test func rerunWithoutNewResponseDoesNotRefreshAge() {
        let (first, _) = UsageMerger.merge(.empty, with: input(apiMs: 100, five: (10, fiveReset)), now: t0, entrypoint: nil)
        let (snap, outcome) = UsageMerger.merge(first, with: input(apiMs: 100, five: (10, fiveReset)), now: t0.addingTimeInterval(600), entrypoint: nil)
        #expect(!outcome.fresh)
        #expect(snap.fiveHour?.observedAt == t0)
    }

    @Test func idleSessionCannotOverwriteNewerReadingFromAnotherSession() {
        // Session A reads 10%, then session B reads 30%, then idle A re-runs (vim toggle) with its old 10%.
        var (snap, _) = UsageMerger.merge(.empty, with: input(session: "A", apiMs: 100, five: (10, fiveReset)), now: t0, entrypoint: nil)
        (snap, _) = UsageMerger.merge(snap, with: input(session: "B", apiMs: 50, five: (30, fiveReset)), now: t0.addingTimeInterval(60), entrypoint: nil)
        let (after, outcome) = UsageMerger.merge(snap, with: input(session: "A", apiMs: 100, five: (10, fiveReset)), now: t0.addingTimeInterval(120), entrypoint: nil)
        #expect(!outcome.fresh)
        #expect(after.fiveHour?.usedPercentage == 30)
        #expect(after.fiveHour?.observedAt == t0.addingTimeInterval(60))
    }

    @Test func idleSessionWithOlderWindowIsIgnored() {
        var (snap, _) = UsageMerger.merge(.empty, with: input(session: "A", apiMs: 100, five: (80, fiveReset - 18000)), now: t0, entrypoint: nil)
        (snap, _) = UsageMerger.merge(snap, with: input(session: "B", apiMs: 10, five: (5, fiveReset)), now: t0.addingTimeInterval(60), entrypoint: nil)
        let (after, _) = UsageMerger.merge(snap, with: input(session: "A", apiMs: 100, five: (80, fiveReset - 18000)), now: t0.addingTimeInterval(120), entrypoint: nil)
        #expect(after.fiveHour?.usedPercentage == 5)
        #expect(after.fiveHour?.resetsAt == Date(timeIntervalSince1970: fiveReset))
    }

    @Test func nonFreshRunCanStillMoveForward() {
        var (snap, _) = UsageMerger.merge(.empty, with: input(session: "A", apiMs: 100, five: (10, fiveReset)), now: t0, entrypoint: nil)
        // A higher value in the same window is always newer.
        (snap, _) = UsageMerger.merge(snap, with: input(session: "A", apiMs: 100, five: (15, fiveReset)), now: t0.addingTimeInterval(30), entrypoint: nil)
        #expect(snap.fiveHour?.usedPercentage == 15)
        // A later window is always newer.
        (snap, _) = UsageMerger.merge(snap, with: input(session: "A", apiMs: 100, five: (1, fiveReset + 18000)), now: t0.addingTimeInterval(60), entrypoint: nil)
        #expect(snap.fiveHour?.usedPercentage == 1)
    }

    @Test func freshReadingIsTrustedEvenIfLower() {
        var (snap, _) = UsageMerger.merge(.empty, with: input(apiMs: 100, five: (40, fiveReset)), now: t0, entrypoint: nil)
        (snap, _) = UsageMerger.merge(snap, with: input(apiMs: 300, five: (38, fiveReset)), now: t0.addingTimeInterval(60), entrypoint: nil)
        #expect(snap.fiveHour?.usedPercentage == 38)
    }

    @Test func resetJitterCountsAsSameWindow() {
        var (snap, _) = UsageMerger.merge(.empty, with: input(session: "A", apiMs: 100, five: (40, fiveReset)), now: t0, entrypoint: nil)
        (snap, _) = UsageMerger.merge(snap, with: input(session: "B", apiMs: 100, five: (20, fiveReset + 60)), now: t0.addingTimeInterval(60), entrypoint: nil)
        // B is a new session, so fresh: trusted.
        #expect(snap.fiveHour?.usedPercentage == 20)
        let (after, _) = UsageMerger.merge(snap, with: input(session: "A", apiMs: 100, five: (19, fiveReset - 30)), now: t0.addingTimeInterval(90), entrypoint: nil)
        #expect(after.fiveHour?.usedPercentage == 20)
    }

    @Test func oldSessionsArePruned() {
        var snap = UsageSnapshot.empty
        for i in 0..<80 {
            (snap, _) = UsageMerger.merge(snap, with: input(session: "s\(i)", apiMs: 1), now: t0.addingTimeInterval(Double(i)), entrypoint: nil)
        }
        #expect(snap.sessions.count == UsageMerger.maxSessions)
        #expect(snap.sessions["s79"] != nil)
        #expect(snap.sessions["s0"] == nil)

        let later = t0.addingTimeInterval(9 * 24 * 3600)
        (snap, _) = UsageMerger.merge(snap, with: input(session: "new", apiMs: 1), now: later, entrypoint: nil)
        #expect(snap.sessions.keys.sorted() == ["new"])
    }

    @Test func snapshotRoundTrips() throws {
        let (snap, _) = UsageMerger.merge(.empty, with: input(apiMs: 100, five: (10, fiveReset), week: (40, weekReset)), now: t0, entrypoint: "cli")
        let decoded = try SnapshotCoding.decode(SnapshotCoding.encode(snap))
        #expect(decoded == snap)
    }

    @Test func corruptWindowInFileIsDroppedNotFatal() throws {
        let json = #"{"schema":1,"five_hour":{"used_percentage":"x"},"seven_day":{"used_percentage":5,"resets_at":1791417600,"observed_at":1790970000},"sessions":{}}"#
        let snap = try SnapshotCoding.decode(Data(json.utf8))
        #expect(snap.fiveHour == nil)
        #expect(snap.sevenDay?.usedPercentage == 5)
    }
}

@Suite("Concurrent bridge runs")
struct SnapshotFileTests {
    @Test func parallelWritersNeverCorruptTheFile() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "notch-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = NotchPaths(home: home)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    _ = try? SnapshotFile.update(paths) { current in
                        UsageMerger.merge(current, with: input(session: "s\(i % 4)", apiMs: Double(i), five: (Double(i), fiveReset)), now: Date(), entrypoint: nil).0
                    }
                }
            }
        }
        let final = try #require(SnapshotFile.read(paths.usageFile))
        #expect(final.fiveHour != nil)
        #expect(final.sessions.count == 4)
    }
}
