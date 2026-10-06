import CoreGraphics
import Foundation
import Testing
@testable import UsageCore

/// This Mac: 1728×1117 pt, notch 185×32 at x 771.5 to 956.5 (from the research, measured on 27.0.1).
private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let left = CGRect(x: 0, y: 1085, width: 771.5, height: 32)
private let right = CGRect(x: 956.5, y: 1085, width: 771.5, height: 32)

@Suite("Notch geometry")
struct NotchGeometryTests {
    @Test func measuresTheHousingFromTheAuxiliaryAreas() throws {
        let g = try #require(NotchGeometry(screenFrame: screen, auxiliaryTopLeft: left, auxiliaryTopRight: right, safeAreaTop: 32))
        #expect(g.notchWidth == 185)
        #expect(g.notchHeight == 32)
        #expect(g.notchMidX == 864)
        #expect(g.notchRect == CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    }

    @Test func noHousingNoGeometry() {
        #expect(NotchGeometry(screenFrame: screen, auxiliaryTopLeft: nil, auxiliaryTopRight: right, safeAreaTop: 32) == nil)
        #expect(NotchGeometry(screenFrame: screen, auxiliaryTopLeft: left, auxiliaryTopRight: right, safeAreaTop: 0) == nil)
    }

    @Test func restingIndicatorsOnlyBesideTheNotch() throws {
        let g = try #require(NotchGeometry(screenFrame: screen, auxiliaryTopLeft: left, auxiliaryTopRight: right, safeAreaTop: 32))
        let rest = g.restingWindowFrame(earsHidden: false)
        // Never below the notch: the window is exactly the menu bar band's height.
        #expect(rest.minY == 1085)
        #expect(rest.maxY == 1117)
        // 36 pt ears either side, plus the 8 pt corner flares.
        #expect(rest.minX == 727) // 771.5 - 36 - 8, snapped outwards
        #expect(rest.maxX == 1001) // 956.5 + 36 + 8, snapped outwards
        // Watching video: shrinks back to the notch.
        let hidden = g.restingWindowFrame(earsHidden: true)
        #expect(hidden.minX == 763)
        #expect(hidden.maxX == 965)
        #expect(hidden.minY == 1085)
    }

    /// Regression: on hover the window grows from the resting frame to the open one. The drawing
    /// canvas must stay exactly where it was on screen, or the resting line jumps sideways.
    @Test func canvasNeverMovesWhenTheWindowResizes() throws {
        let g = try #require(NotchGeometry(screenFrame: screen, auxiliaryTopLeft: left, auxiliaryTopRight: right, safeAreaTop: 32))
        let frames = [g.restingWindowFrame(earsHidden: false), g.restingWindowFrame(earsHidden: true), g.openWindowFrame]
        let canvases = frames.map { g.canvasScreenFrame(in: $0) }
        #expect(Set(canvases.map { "\($0)" }).count == 1)
        let canvas = try #require(canvases.first)
        #expect(canvas.midX == g.notchMidX)
        #expect(canvas.maxY == screen.maxY)
        // Each window is fully covered by the canvas, so nothing is ever drawn outside it.
        for frame in frames { #expect(canvas.contains(frame)) }
    }

    @Test func openWindowIsTopCentred() throws {
        let g = try #require(NotchGeometry(screenFrame: screen, auxiliaryTopLeft: left, auxiliaryTopRight: right, safeAreaTop: 32))
        let open = g.openWindowFrame
        #expect(open.maxY == 1117)
        #expect(abs(open.midX - 864) <= 0.5)
        #expect(open.height == NotchGeometry.openSize.height)
    }
}

@Suite("Hiding while watching video")
struct VideoSignalTests {
    private func assertion(_ type: String, level: Int = 255, name: String = "Video Wake Lock") -> [String: Any] {
        ["AssertType": type, "AssertLevel": NSNumber(value: level), "AssertName": name]
    }

    @Test func displayAwakeRequestsCountExceptKeepAwakeTools() {
        let names: [Int32: String] = [10: "Google Chrome Helper", 11: "caffeinate", 12: "Stremio", 13: "sharingd", 14: "Hourglass", 15: "Safari"]
        let byProcess: [Int32: [[String: Any]]] = [
            10: [assertion("PreventUserIdleDisplaySleep")],
            11: [assertion("PreventUserIdleDisplaySleep")],
            12: [assertion("NoDisplaySleepAssertion")],
            13: [assertion("PreventUserIdleSystemSleep")], // system sleep only: not video
            14: [assertion("PreventUserIdleDisplaySleep")], // ourselves
            15: [assertion("PreventUserIdleDisplaySleep", level: 0)] // switched off
        ]
        let holders = VideoSignal.holders(byProcess, ownPid: 14) { names[$0] }
        #expect(holders == ["Google Chrome Helper", "Stremio"])
        #expect(VideoSignal.holders([:], ownPid: 1) { _ in nil }.isEmpty)
    }

    @Test func callsAndNoteTakersAreNotVideo() {
        let names: [Int32: String] = [20: "Microsoft Teams", 21: "Wispr Flow", 22: "Some Call App", 23: "zoom.us", 24: "Google Chrome", 25: "Recallr"]
        let byProcess: [Int32: [[String: Any]]] = [
            20: [assertion("NoDisplaySleepAssertion", name: "Microsoft Teams Call in progress")],
            21: [assertion("NoDisplaySleepAssertion", name: "Electron")],
            22: [assertion("PreventUserIdleDisplaySleep", name: "Meeting in progress")],
            23: [assertion("PreventUserIdleDisplaySleep")],
            24: [assertion("PreventUserIdleDisplaySleep", name: "Video Wake Lock")],
            25: [assertion("PreventUserIdleDisplaySleep", name: "Recalling playback")] // "call" inside a word isn't a call
        ]
        #expect(VideoSignal.holders(byProcess, ownPid: 1) { names[$0] } == ["Google Chrome", "Recallr"])
    }

    @Test func hidesAtOnceAndReturnsThreeSecondsAfterStopping() {
        let t = Date(timeIntervalSince1970: 1_791_000_000)
        var state = VideoHideState()
        func feed(_ playing: Bool, _ seconds: TimeInterval) -> Bool {
            state.update(playing: playing, now: t.addingTimeInterval(seconds))
        }
        #expect(feed(true, 0))
        #expect(state.isWatching)
        // A short pause doesn't bring the indicators back.
        #expect(!feed(false, 10))
        #expect(state.nextCheck(now: t) == t.addingTimeInterval(13))
        #expect(!feed(true, 12))
        #expect(state.isWatching)
        // Stopped for 3 s: back.
        #expect(!feed(false, 20))
        #expect(!feed(false, 22))
        #expect(feed(false, 23))
        #expect(!state.isWatching)
    }
}

@Suite("Status line wording")
struct StatusWordingTests {
    @Test func checkedAgo() {
        #expect(UsageFormat.checked(10) == "Checked just now")
        #expect(UsageFormat.checked(50) == "Checked 1 min ago")
        #expect(UsageFormat.checked(4 * 60 + 10) == "Checked 4 min ago")
        #expect(UsageFormat.checked(2 * 3600) == "Checked 2 h ago")
        #expect(UsageFormat.checked(3 * 86400) == "Checked 3 days ago")
    }
}
