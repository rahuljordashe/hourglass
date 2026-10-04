import Foundation
import Testing
@testable import UsageCore

private let start = Date(timeIntervalSince1970: 1_791_000_000)
private let min: TimeInterval = 60

/// Drives a scheduler and ledger through reads, like the app does.
private struct Harness {
    var scheduler = RefreshScheduler()
    var ledger = ReadLedger()
    var usage: PlanUsage?

    func decide(_ trigger: RefreshTrigger, at now: Date, reading: Bool = false, active: Bool = true) -> RefreshScheduler.Decision {
        scheduler.decide(trigger, now: now, ledger: ledger, usage: usage, isReading: reading, isActive: active)
    }

    mutating func read(_ trigger: RefreshTrigger, at now: Date, result: ReadResult = .success, session: Double? = 10, duration: TimeInterval = 2) {
        scheduler.recordStart(trigger, at: now, in: &ledger)
        let finished = now.addingTimeInterval(duration)
        let fresh = result == .success ? usageFor(session: session, at: finished) : nil
        if let fresh { usage = fresh }
        scheduler.recordFinish(result, at: finished, usage: fresh, jitterUnit: 0.5, in: &ledger)
    }
}

func usageFor(session: Double?, at: Date) -> PlanUsage {
    PlanUsage(
        limits: [PlanUsage.Limit(kind: "session", percent: session, resetsAt: Date(timeIntervalSince1970: 1_791_000_000 + 3 * 3600)),
                 PlanUsage.Limit(kind: "weekly_all", percent: 10, resetsAt: Date(timeIntervalSince1970: 1_791_000_000 + 4 * 86400))],
        fetchedAt: at
    )
}

@Suite("Refresh scheduler")
struct SchedulerTests {
    @Test func hoverNeverReads() {
        let h = Harness()
        #expect(h.decide(.hover, at: start) == .skip(.hoverNeverReads))
    }

    @Test func onlyOneReadAtATime() {
        let h = Harness()
        for trigger in [RefreshTrigger.expand, .manual, .background] {
            #expect(h.decide(trigger, at: start, reading: true) == .skip(.readInProgress))
        }
    }

    @Test func expandReadsOnlyWhenOlderThanTwoMinutes() {
        var h = Harness()
        #expect(h.decide(.expand, at: start) == .read) // nothing cached yet
        h.read(.expand, at: start)
        let finished = start.addingTimeInterval(2)
        #expect(h.decide(.expand, at: finished.addingTimeInterval(90)) == .skip(.fresh(age: 90)))
        #expect(h.decide(.expand, at: finished.addingTimeInterval(121)) == .read)
    }

    @Test func manualWithinAMinuteIsUpToDate() {
        var h = Harness()
        h.read(.background, at: start)
        let finished = start.addingTimeInterval(2)
        #expect(h.decide(.manual, at: finished.addingTimeInterval(25)) == .skip(.upToDate(checkedAgo: 25)))
        #expect(h.decide(.manual, at: finished.addingTimeInterval(61)) == .read)
    }

    @Test func backgroundEveryFifteenMinutesWhileActive() {
        var h = Harness()
        #expect(h.decide(.background, at: start) == .read)
        #expect(h.decide(.background, at: start, active: false) == .skip(.inactive))
        h.read(.background, at: start, session: 20)
        let finished = start.addingTimeInterval(2)
        // jitterUnit 0.5 means no jitter.
        #expect(h.decide(.background, at: finished.addingTimeInterval(14 * min)) == .skip(.notDue(next: finished.addingTimeInterval(15 * min))))
        #expect(h.decide(.background, at: finished.addingTimeInterval(15 * min)) == .read)
        #expect(h.decide(.background, at: finished.addingTimeInterval(15 * min), active: false) == .skip(.inactive))
    }

    @Test func anyReadResetsTheBackgroundClock() {
        var h = Harness()
        h.read(.background, at: start)
        h.read(.expand, at: start.addingTimeInterval(10 * min))
        let expandFinished = start.addingTimeInterval(10 * min + 2)
        #expect(h.decide(.background, at: start.addingTimeInterval(16 * min)) == .skip(.notDue(next: expandFinished.addingTimeInterval(15 * min))))
    }

    @Test func tenMinutesAtSeventyPercent() {
        var h = Harness()
        h.read(.background, at: start, session: 72)
        let finished = start.addingTimeInterval(2)
        #expect(h.decide(.background, at: finished.addingTimeInterval(10 * min)) == .read)
    }

    @Test func tenMinutesWhenRisingFast() {
        var h = Harness()
        h.read(.background, at: start, session: 10)
        h.read(.background, at: start.addingTimeInterval(15 * min), session: 25) // +15 points in 15 min
        #expect(h.scheduler.isRisingFast(h.ledger))
        let finished = start.addingTimeInterval(15 * min + 2)
        #expect(h.decide(.background, at: finished.addingTimeInterval(10 * min)) == .read)

        var slow = Harness()
        slow.read(.background, at: start, session: 10)
        slow.read(.background, at: start.addingTimeInterval(15 * min), session: 12)
        #expect(!slow.scheduler.isRisingFast(slow.ledger))
    }

    @Test func jitterShiftsTheBackgroundInterval() {
        var h = Harness()
        h.scheduler.recordStart(.background, at: start, in: &h.ledger)
        h.scheduler.recordFinish(.success, at: start, usage: usageFor(session: 5, at: start), jitterUnit: 1, in: &h.ledger)
        #expect(h.ledger.jitter == 60)
        #expect(h.scheduler.nextBackgroundRead(now: start, ledger: h.ledger, usage: nil) == start.addingTimeInterval(16 * min))
    }

    @Test func hardCapOfTenReadsAnHour() {
        var h = Harness()
        for i in 0..<10 { h.read(.manual, at: start.addingTimeInterval(Double(i) * 2 * min)) }
        let now = start.addingTimeInterval(21 * min)
        #expect(h.decide(.manual, at: now) == .skip(.wait(until: start.addingTimeInterval(3600), reason: .budget)))
        #expect(h.decide(.expand, at: now) == .skip(.wait(until: start.addingTimeInterval(3600), reason: .budget)))
        #expect(h.decide(.manual, at: start.addingTimeInterval(3600)) == .read)
    }

    @Test func busyCadenceHoldsEveryTenMinutes() {
        var h = Harness()
        var t = start
        for i in 0..<8 {
            #expect(h.decide(.background, at: t) == .read, "read \(i + 1) should be allowed")
            h.read(.background, at: t, session: 80)
            t = t.addingTimeInterval(10 * min + 2)
        }
    }

    @Test func backgroundUsesAtMostSixAnHour() {
        var h = Harness()
        h.scheduler.busyBackgroundInterval = 5 * min // faster than the cap allows
        var t = start
        for _ in 0..<6 {
            h.read(.background, at: t, session: 80)
            t = t.addingTimeInterval(5 * min + 2)
        }
        // Busy cadence says due, but the background share of the budget is spent.
        #expect(h.decide(.background, at: t) == .skip(.wait(until: start.addingTimeInterval(3600), reason: .budget)))
        // Other triggers still have budget left.
        #expect(h.decide(.manual, at: t) == .read)
        #expect(h.scheduler.nextBackgroundRead(now: t, ledger: h.ledger, usage: h.usage) == start.addingTimeInterval(3600))
    }

    @Test func seededAndRateLimitedBackOffAndPersist() throws {
        var h = Harness()
        h.read(.background, at: start, result: .seeded)
        let finished = start.addingTimeInterval(2)
        #expect(h.ledger.backoffUntil == finished.addingTimeInterval(5 * min))
        #expect(h.decide(.manual, at: finished.addingTimeInterval(2 * min)) == .skip(.wait(until: finished.addingTimeInterval(5 * min), reason: .backoff)))

        h.read(.manual, at: finished.addingTimeInterval(6 * min), result: .rateLimited)
        let second = finished.addingTimeInterval(6 * min + 2)
        #expect(h.ledger.backoffLevel == 2)
        #expect(h.ledger.backoffUntil == second.addingTimeInterval(30 * min))

        // Survives a relaunch.
        let data = try PlanUsageCoding.encoder().encode(h.ledger)
        let restored = try PlanUsageCoding.decoder().decode(ReadLedger.self, from: data)
        #expect(restored == h.ledger)
        #expect(h.scheduler.blockedUntil(now: second, ledger: restored)?.reason == .backoff)

        // A success clears it.
        h.read(.manual, at: second.addingTimeInterval(31 * min))
        #expect(h.ledger.backoffUntil == nil)
        #expect(h.ledger.backoffLevel == 0)
    }

    @Test func backoffLadderTopsOut() {
        var h = Harness()
        var t = start
        for _ in 0..<8 {
            h.read(.manual, at: t, result: .failed)
            t = (h.ledger.backoffUntil ?? t).addingTimeInterval(1)
        }
        let last = h.ledger.backoffUntil!.timeIntervalSince(h.ledger.lastFinishedAt!)
        #expect(last == 30 * min)
    }

    @Test func quietForThreeMinutesAfterHittingALimit() {
        var h = Harness()
        h.read(.manual, at: start, session: 95)
        #expect(h.ledger.quietUntil == nil)
        h.read(.manual, at: start.addingTimeInterval(2 * min), session: 100)
        let hit = start.addingTimeInterval(2 * min + 2)
        #expect(h.ledger.quietUntil == hit.addingTimeInterval(3 * min))
        #expect(h.decide(.manual, at: hit.addingTimeInterval(90)) == .skip(.wait(until: hit.addingTimeInterval(3 * min), reason: .limitQuiet)))
        #expect(h.decide(.manual, at: hit.addingTimeInterval(3 * min)) == .read)

        // Staying at the limit doesn't restart the quiet period.
        h.read(.manual, at: hit.addingTimeInterval(4 * min), session: 100)
        #expect(h.ledger.quietUntil == hit.addingTimeInterval(3 * min))
    }

    @Test func ledgerPrunesReadsOlderThanAnHour() {
        var h = Harness()
        h.read(.manual, at: start)
        h.read(.manual, at: start.addingTimeInterval(2 * 3600))
        #expect(h.ledger.reads.count == 1)
    }

    @Test func persistsThroughTheFileHelper() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "notch-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "read-ledger.json")
        var h = Harness()
        h.read(.background, at: start, result: .seeded)
        try JSONFile.write(h.ledger, to: url)
        #expect(JSONFile.read(ReadLedger.self, from: url) == h.ledger)
        #expect(JSONFile.read(ReadLedger.self, from: dir.appending(path: "missing.json")) == nil)
    }
}
