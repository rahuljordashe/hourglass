import CoreGraphics
import Foundation
import Testing
@testable import UsageCore

@Suite("Notch layout")
struct NotchLayoutTests {
    @Test func defaultIsTheOriginalLayout() {
        let layout = NotchLayout.default
        #expect(layout.left == .ringPair)
        #expect(layout.right == .countdown)
        #expect(layout.face == .rings)
        #expect(layout.hover == HoverOptions(timeTick: true, budgetLine: false, resetTimes: false))
        #expect(layout.open.visible == [.budget, .byModel, .credits])
        #expect(layout.leftWidth == 36)
        #expect(layout.rightWidth == 36)
    }

    @Test func facesSetBothEarsAndKeepTheRest() {
        var start = NotchLayout.default
        start.hover.budgetLine = true
        start.open.setShown(.credits, false)
        let expected: [Face: (EarItem, EarItem)] = [
            .rings: (.ringPair, .countdown),
            .numbers: (.fiveHourPercent, .weeklyPercent),
            .timeFirst: (.fiveHourPercent, .countdown),
            .bars: (.miniBars, .fiveHourPercent),
            .clock: (.fiveHourRing, .resetClock),
            .quiet: (.warningDot, .nothing)
        ]
        for face in Face.allCases {
            let layout = start.with(face)
            #expect(layout.left == expected[face]?.0)
            #expect(layout.right == expected[face]?.1)
            #expect(layout.face == face)
            #expect(layout.hover == start.hover)
            #expect(layout.open == start.open)
        }
    }

    @Test func singleEarChangesLeaveTheFaceWhenTheyNoLongerMatch() {
        let custom = NotchLayout.default.with(.miniBars, on: .right)
        #expect(custom.left == .ringPair)
        #expect(custom.right == .miniBars)
        #expect(custom.face == nil)
        #expect(custom.with(.countdown, on: .right).face == .rings)
    }

    @Test func onlyTheClockTimeWidensItsEar() {
        for item in EarItem.allCases {
            #expect(item.earWidth == (item == .resetClock ? 46 : 36))
        }
        let clock = NotchLayout.default.with(.clock)
        #expect(clock.leftWidth == 36)
        #expect(clock.rightWidth == 46)
        #expect(NotchLayout.default.with(.resetClock, on: .left).leftWidth == 46)
    }

    @Test func savesAndReadsBack() throws {
        var layout = NotchLayout.default.with(.bars)
        layout.hover = HoverOptions(timeTick: false, budgetLine: true, resetTimes: true)
        layout.open.move(.credits, by: -1)
        layout.open.setShown(.budget, false)
        let data = try #require(layout.encoded())
        #expect(NotchLayout.decode(data) == layout)
    }

    @Test func unreadableOrUnknownValuesFallBackPerField() {
        #expect(NotchLayout.decode(nil) == .default)
        #expect(NotchLayout.decode(Data("not json".utf8)) == .default)
        // A later version's item in one ear doesn't wipe the other ear or the panels.
        let json = #"{"left":"sparkline","right":"resetClock","hover":{"budgetLine":true},"open":{"order":["credits","weather"],"hidden":["byModel","weather"]}}"#
        let layout = NotchLayout.decode(Data(json.utf8))
        #expect(layout.left == .ringPair)
        #expect(layout.right == .resetClock)
        #expect(layout.hover == HoverOptions(timeTick: true, budgetLine: true, resetTimes: false))
        #expect(layout.open.order == [.credits, .budget, .byModel])
        #expect(layout.open.hidden == [.byModel])
    }

    @Test func openSectionsMoveAndHide() {
        var open = OpenLayout()
        #expect(!open.canMove(.budget, by: -1))
        #expect(open.canMove(.budget, by: 1))
        open.move(.budget, by: -1) // already first: nothing happens
        #expect(open.order == [.budget, .byModel, .credits])
        open.move(.credits, by: -1)
        #expect(open.order == [.budget, .credits, .byModel])
        open.move(.byModel, by: 1) // already last
        #expect(open.order == [.budget, .credits, .byModel])
        open.setShown(.credits, false)
        #expect(open.visible == [.budget, .byModel])
        #expect(!open.isShown(.credits))
        open.setShown(.credits, true)
        #expect(open.visible == [.budget, .credits, .byModel])
    }

    @Test func itemsSayWhichFigureTheyCarry() {
        #expect(EarItem.ringPair.carries(.fiveHour) && EarItem.ringPair.carries(.sevenDay))
        #expect(EarItem.fiveHourPercent.carries(.fiveHour) && !EarItem.fiveHourPercent.carries(.sevenDay))
        #expect(EarItem.weeklyPercent.carries(.sevenDay) && !EarItem.weeklyPercent.carries(.fiveHour))
        #expect(!EarItem.countdown.carries(.fiveHour) && !EarItem.nothing.carries(.sevenDay))
    }
}

@Suite("Ear items with readings")
struct EarItemReadingTests {
    let now = Date(timeIntervalSince1970: 1_791_100_000)
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func state(five: Double, weekly: Double) -> UsageState {
        let f = UsageEvaluator.status(.fiveHour, WindowReading(usedPercentage: five, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60), observedAt: now), now: now)
        let w = UsageEvaluator.status(.sevenDay, WindowReading(usedPercentage: weekly, resetsAt: now.addingTimeInterval(3 * 86400), observedAt: now), now: now)
        return UsageState(fiveHour: f, sevenDay: w, lastUpdated: now, age: 0, freshness: .fresh, source: nil)
    }

    @Test func warningDotOnlyFromSeventyPercent() {
        #expect(EarItem.warningDotLevel(state(five: 69, weekly: 40)) == nil)
        #expect(EarItem.warningDotLevel(state(five: 70, weekly: 40)) == .normal)
        // Colours keep their usual thresholds: amber from 75, red from 90, whichever limit is higher.
        #expect(EarItem.warningDotLevel(state(five: 20, weekly: 80)) == .warning)
        #expect(EarItem.warningDotLevel(state(five: 92, weekly: 80)) == .critical)
        #expect(EarItem.warningDotLevel(.empty) == nil)
    }

    @Test func voiceOverDescribesWhatEachEarShows() {
        let s = state(five: 42, weekly: 19)
        let locale = Locale(identifier: "en_GB")
        #expect(EarItem.ringPair.spoken(s, now: now) == "five hour 42 percent used, weekly 19 percent used")
        #expect(EarItem.fiveHourPercent.spoken(s, now: now) == "five hour 42 percent used")
        #expect(EarItem.weeklyPercent.spoken(s, now: now) == "weekly 19 percent used")
        #expect(EarItem.countdown.spoken(s, now: now) == "five hour limit resets in 2 hours, 14 minutes")
        let clock = UsageFormat.clock(now.addingTimeInterval(2 * 3600 + 14 * 60), now: now, calendar: cal, locale: locale)
        #expect(EarItem.resetClock.spoken(s, now: now, calendar: cal, locale: locale) == "five hour limit resets at \(clock)")
        #expect(EarItem.warningDot.spoken(s, now: now) == nil)
        #expect(EarItem.warningDot.spoken(state(five: 95, weekly: 10), now: now) == "Warning: close to a limit")
        #expect(EarItem.nothing.spoken(s, now: now) == nil)
        #expect(EarItem.ringPair.spoken(.empty, now: now) == nil)
    }
}

@Suite("Ear widths in the window")
struct EarWidthGeometryTests {
    private let g = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                  notchWidth: 185, notchHeight: 32, notchMidX: 864)

    @Test func aWideEarGrowsOnlyItsOwnSide() {
        let even = g.restingWindowFrame(earsHidden: false)
        let wideRight = g.restingWindowFrame(earsHidden: false, left: 36, right: 46)
        #expect(wideRight.minX == even.minX)
        #expect(wideRight.maxX == even.maxX + 10)
        let wideLeft = g.restingRect(left: 46, right: 36)
        #expect(wideLeft.minX == g.notchRect.minX - 46)
        #expect(wideLeft.maxX == g.notchRect.maxX + 36)
        // Never below the notch, and hidden ears still shrink to the notch.
        #expect(wideRight.minY == 1085)
        #expect(g.restingWindowFrame(earsHidden: true, left: 46, right: 46) == g.restingWindowFrame(earsHidden: true))
        #expect(g.canvasScreenFrame(in: wideRight).contains(wideRight))
    }
}
