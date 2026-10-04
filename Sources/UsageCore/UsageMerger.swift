import Foundation

/// Folds one status line run into the stored snapshot.
///
/// Every Claude Code session reports the same account-wide pool, so the newest genuine reading wins.
/// The tricky part is telling a genuine reading from a re-run: Claude Code also re-runs the status line
/// on things like vim mode changes or a window reaching its reset time, and an idle session then
/// resends whatever it heard last, which may be older than what another session reported since.
///
/// Rules:
/// - A run is *fresh* when its session's `total_api_duration_ms` has grown since that session last
///   ran (or the session is new). A fresh run reflects a brand-new API response, so it is trusted.
/// - A non-fresh run can only move a window forwards: a later reset time (new window), or a higher
///   percentage within the same window. Usage within one window never goes down, so a lower value
///   from a non-fresh run is an old reading and is ignored.
/// - A window missing from the input keeps its last known value (each window can be absent on its own,
///   and Claude Code drops a window once its reset time passes).
public enum UsageMerger {
    /// Reset times within this distance are treated as the same window.
    public static let sameWindowTolerance: TimeInterval = 300
    /// Session bookkeeping older than this is pruned.
    public static let sessionRetention: TimeInterval = 8 * 24 * 3600
    public static let maxSessions = 64

    public struct Outcome: Equatable, Sendable {
        public var fresh: Bool
        public var hadRateLimits: Bool
        public var changedWindows: Set<UsageWindowKind>
    }

    public static func merge(
        _ snapshot: UsageSnapshot,
        with input: StatusLineInput,
        now: Date,
        entrypoint: String?
    ) -> (UsageSnapshot, Outcome) {
        var next = snapshot
        let sessionKey = input.sessionId ?? "unknown"
        let apiMs = input.cost?.totalApiDurationMs
        let previous = snapshot.sessions[sessionKey]

        let fresh: Bool = {
            guard let apiMs, let previous, let previousMs = previous.apiDurationMs else { return true }
            return apiMs > previousMs
        }()

        var changed = Set<UsageWindowKind>()
        let limits = input.rateLimits
        let hadRateLimits = limits?.fiveHour != nil || limits?.sevenDay != nil

        for kind in UsageWindowKind.allCases {
            let stored = snapshot.reading(for: kind)
            let merged = mergeWindow(stored: stored, incoming: limits?.window(kind), fresh: fresh, now: now)
            if merged != stored {
                changed.insert(kind)
                switch kind {
                case .fiveHour: next.fiveHour = merged
                case .sevenDay: next.sevenDay = merged
                }
            }
        }

        if hadRateLimits {
            next.lastRunAt = now
        }
        if !changed.isEmpty {
            next.source = ReadingSource(claudeCodeVersion: input.version, entrypoint: entrypoint)
        }

        let bestMs = [apiMs, previous?.apiDurationMs].compactMap { $0 }.max()
        next.sessions[sessionKey] = SessionMark(apiDurationMs: bestMs, seenAt: now)
        next.sessions = prune(next.sessions, now: now)
        next.schema = UsageSnapshot.currentSchema

        return (next, Outcome(fresh: fresh, hadRateLimits: hadRateLimits, changedWindows: changed))
    }

    static func mergeWindow(
        stored: WindowReading?,
        incoming: StatusLineInput.RateWindow?,
        fresh: Bool,
        now: Date
    ) -> WindowReading? {
        guard let incoming,
              let percentage = incoming.usedPercentage,
              let resetsAtSeconds = incoming.resetsAt,
              resetsAtSeconds > 0
        else { return stored }

        let reading = WindowReading(
            usedPercentage: max(0, percentage),
            resetsAt: Date(timeIntervalSince1970: resetsAtSeconds),
            observedAt: now
        )
        guard let stored else { return reading }
        if fresh { return reading }

        let resetDelta = reading.resetsAt.timeIntervalSince(stored.resetsAt)
        if resetDelta > sameWindowTolerance { return reading } // a newer window
        if resetDelta < -sameWindowTolerance { return stored } // an older window from an idle session
        if reading.usedPercentage > stored.usedPercentage + 0.0001 { return reading }
        return stored
    }

    static func prune(_ sessions: [String: SessionMark], now: Date) -> [String: SessionMark] {
        let recent = sessions.filter { now.timeIntervalSince($0.value.seenAt) < sessionRetention }
        guard recent.count > maxSessions else { return recent }
        let kept = recent.sorted { $0.value.seenAt > $1.value.seenAt }.prefix(maxSessions)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
