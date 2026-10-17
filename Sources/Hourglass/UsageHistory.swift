import Foundation
import Observation
import UsageCore

/// The usage history: every fresh reading the app takes, kept on this Mac only (see `HistoryFiles`).
/// Publishes the raw lines and summaries for the 7-day card and the History window.
@MainActor
@Observable
final class UsageHistory {
    private(set) var lines: [HistoryLine] = []
    private(set) var windows: [WindowSummary] = []
    private(set) var weeks: [WeekSummary] = []

    /// The optional Claude Code log layer, off by default.
    let logs: ClaudeCodeLogLayer

    @ObservationIgnored private let archive: HistoryArchive
    @ObservationIgnored let files: HistoryFiles

    init(paths: NotchPaths) {
        files = HistoryFiles(directory: paths.historyDirectory)
        archive = HistoryArchive(files: files)
        logs = ClaudeCodeLogLayer(paths: paths, files: files)
    }

    /// Loads what's on disk, deletes raw readings past 90 days and rebuilds the summaries, so a
    /// reset missed while the app was closed (or a crash) heals now.
    func start() {
        logs.start()
        Task {
            let snapshot = await archive.load(now: Date())
            publish(snapshot)
        }
    }

    /// Reads what's on disk straight away and summarises it without writing anything. For drawing stills.
    func loadNow() {
        logs.loadNow()
        lines = files.loadReadings()
        let built = HistorySummaries.build(from: lines, now: Date())
        windows = HistorySummaries.merge(existing: files.loadWindows(), rebuilt: built.windows)
        weeks = HistorySummaries.merge(existing: files.loadWeeks(), rebuilt: built.weeks)
    }

    /// Records a fresh reading (the caller skips last-known ones). Identical readings are skipped
    /// apart from an hourly heartbeat.
    func record(_ usage: PlanUsage) {
        Task {
            guard let snapshot = await archive.record(usage, now: Date()) else { return }
            publish(snapshot)
        }
    }

    private func publish(_ snapshot: HistoryArchive.Snapshot) {
        lines = snapshot.lines
        if let summaries = snapshot.summaries {
            windows = summaries.windows
            weeks = summaries.weeks
        }
    }
}

/// Owns the history files, one change at a time, off the main thread.
actor HistoryArchive {
    struct Snapshot: Sendable {
        var lines: [HistoryLine]
        /// Only when they were rebuilt.
        var summaries: (windows: [WindowSummary], weeks: [WeekSummary])?
    }

    private let files: HistoryFiles
    private var lines: [HistoryLine] = []
    private var isLoaded = false
    private var lastReadAt: Date?
    private var lastPrune: Date?

    init(files: HistoryFiles) {
        self.files = files
    }

    func load(now: Date) -> Snapshot {
        prune(now: now)
        lines = files.loadReadings()
        lastReadAt = lines.last?.time
        isLoaded = true
        return Snapshot(lines: lines, summaries: rebuild(now: now))
    }

    func record(_ usage: PlanUsage, now: Date) -> Snapshot? {
        if !isLoaded { _ = load(now: now) }
        guard !usage.isSeeded else { return nil }
        defer { lastReadAt = max(lastReadAt ?? usage.fetchedAt, usage.fetchedAt) }
        let previous = lines.last
        guard let line = HistoryRecording.line(for: usage, lastWritten: previous, lastReadAt: lastReadAt) else { return nil }
        do { try files.append(line) } catch {
            Log.data.error("Couldn't record the reading: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        lines.append(line)

        // A reset closes a window: summarise it now (rebuilding is idempotent).
        var summaries: (windows: [WindowSummary], weeks: [WeekSummary])?
        if let previous, Self.isReset(line, after: previous) { summaries = rebuild(now: now) }
        if lastPrune.map({ now.timeIntervalSince($0) >= 86400 }) ?? true, prune(now: now) {
            lines = files.loadReadings()
        }
        return Snapshot(lines: lines, summaries: summaries)
    }

    static func isReset(_ line: HistoryLine, after previous: HistoryLine) -> Bool {
        PlanUsageMerger.isNewWindow(line.fiveHour?.resetsAt, previous: previous.fiveHour?.resetsAt)
            || PlanUsageMerger.isNewWindow(line.weekly?.resetsAt, previous: previous.weekly?.resetsAt)
            || (previous.fiveHour?.resetsAt != nil && line.fiveHour?.resetsAt == nil)
            || (previous.weekly?.resetsAt != nil && line.weekly?.resetsAt == nil)
    }

    private func rebuild(now: Date) -> (windows: [WindowSummary], weeks: [WeekSummary])? {
        do { return try files.rebuildSummaries(from: lines, now: now) } catch {
            Log.data.error("Couldn't write the history summaries: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// True when a monthly file was deleted.
    @discardableResult
    private func prune(now: Date) -> Bool {
        lastPrune = now
        let deleted = files.pruneReadings(now: now)
        if !deleted.isEmpty { Log.data.info("History: deleted \(deleted.count, privacy: .public) month(s) of raw readings past 90 days") }
        return !deleted.isEmpty
    }
}
