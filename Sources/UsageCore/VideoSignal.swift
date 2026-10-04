import Foundation

/// Decides whether something on screen is probably a video, from macOS power assertions.
///
/// Video players and browsers ask macOS to keep the display awake while a video plays
/// (`PreventUserIdleDisplaySleep`). Reading who holds that needs no permission. Keep-awake
/// utilities ask too, so they're ignored by name.
public enum VideoSignal {
    public static let displaySleepTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Processes whose display-awake requests aren't video.
    public static let ignoredProcesses: Set<String> = [
        "caffeinate", "Amphetamine", "KeepingYouAwake", "Lungo", "Theine", "Caffeine",
        "powerd", "WindowServer", "loginwindow", "Hourglass"
    ]

    /// Names of processes holding a display-awake assertion, from `IOPMCopyAssertionsByProcess`'s
    /// dictionary (pid to a list of assertion dictionaries).
    public static func holders(
        _ byProcess: [Int32: [[String: Any]]],
        ownPid: Int32,
        name: (Int32) -> String?
    ) -> [String] {
        var result: [String] = []
        for (pid, assertions) in byProcess where pid != ownPid {
            let holds = assertions.contains { assertion in
                guard let type = assertion["AssertType"] as? String, displaySleepTypes.contains(type) else { return false }
                // Level 0 means the assertion is switched off.
                if let level = (assertion["AssertLevel"] as? NSNumber)?.intValue, level == 0 { return false }
                return true
            }
            guard holds else { continue }
            let processName = name(pid) ?? (assertions.first?["Process Name"] as? String) ?? "pid \(pid)"
            if ignoredProcesses.contains(processName) { continue }
            result.append(processName)
        }
        return result.sorted()
    }
}

/// Smooths the raw signal: hides almost at once when video starts, but only shows again once it
/// has stopped for a few seconds, so pausing to skip doesn't make the indicators flicker.
public struct VideoHideState: Equatable, Sendable {
    public static let returnDelay: TimeInterval = 3

    public private(set) var isWatching = false
    private var stoppedAt: Date?

    public init() {}

    /// Feed every sample. Returns true when `isWatching` changed.
    @discardableResult
    public mutating func update(playing: Bool, now: Date) -> Bool {
        if playing {
            stoppedAt = nil
            guard !isWatching else { return false }
            isWatching = true
            return true
        }
        guard isWatching else { return false }
        if let stoppedAt {
            if now.timeIntervalSince(stoppedAt) >= Self.returnDelay {
                isWatching = false
                self.stoppedAt = nil
                return true
            }
        } else {
            stoppedAt = now
        }
        return false
    }

    /// When to sample again to notice the return delay passing.
    public func nextCheck(now: Date) -> Date? {
        stoppedAt.map { $0.addingTimeInterval(Self.returnDelay) }
    }
}
