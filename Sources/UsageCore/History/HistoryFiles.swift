import Foundation

/// The usage history on disk, all under the app's support folder in `history/`:
/// - `readings-YYYY-MM.jsonl`: raw readings, one JSON line each, one file per month (UTC), append only;
/// - `windows.jsonl` and `weeks.jsonl`: summaries of closed 5-hour windows and weeks, kept for good;
/// - `claude-code-hourly.jsonl` and `claude-code-scan.json`: the optional Claude Code log layer.
///
/// A corrupt or partial line is skipped on read, never fatal. Nothing here leaves the Mac.
public struct HistoryFiles: Sendable {
    public var directory: URL

    /// Raw readings older than this are deleted; summaries are kept for good.
    public static let rawRetention: TimeInterval = 90 * 86400

    public init(directory: URL) {
        self.directory = directory
    }

    public var windowsFile: URL { directory.appending(path: "windows.jsonl") }
    public var weeksFile: URL { directory.appending(path: "weeks.jsonl") }
    public var daysFile: URL { directory.appending(path: "days.jsonl") }
    public var hourlyTokensFile: URL { directory.appending(path: "claude-code-hourly.jsonl") }
    public var logScanStateFile: URL { directory.appending(path: "claude-code-scan.json") }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public func readingsFile(for date: Date) -> URL {
        let parts = Self.utc.dateComponents([.year, .month], from: date)
        let name = String(format: "readings-%04d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0)
        return directory.appending(path: name)
    }

    /// Every monthly readings file, oldest first.
    public func readingsFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { Self.month(ofFileNamed: $0) != nil }.sorted().map { directory.appending(path: $0) }
    }

    /// The first moment of the month a `readings-YYYY-MM.jsonl` file covers.
    static func month(ofFileNamed name: String) -> Date? {
        guard name.hasPrefix("readings-"), name.hasSuffix(".jsonl") else { return nil }
        let middle = name.dropFirst("readings-".count).dropLast(".jsonl".count)
        let parts = middle.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return utc.date(from: DateComponents(year: year, month: month, day: 1))
    }

    // MARK: Raw readings

    /// Appends one reading to its month's file. If the file's last line was cut short (a crash
    /// mid-write), the new line starts on a line of its own, so only the partial one is lost.
    public func append(_ line: HistoryLine) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = readingsFile(for: line.time)
        var data = try HistoryCoding.encoder().encode(line)
        data.append(0x0A)
        guard fm.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { data.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: data)
    }

    /// Every readable raw reading, oldest first.
    public func loadReadings() -> [HistoryLine] {
        readingsFiles()
            .flatMap { url in (try? Data(contentsOf: url)).map { HistoryCoding.decodeLines(HistoryLine.self, from: $0) } ?? [] }
            .sorted { $0.time < $1.time }
    }

    /// The newest readable line, from the newest file that has one.
    public func lastReading() -> HistoryLine? {
        for url in readingsFiles().reversed() {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let last = HistoryCoding.decodeLines(HistoryLine.self, from: data).max(by: { $0.time < $1.time }) { return last }
        }
        return nil
    }

    /// Deletes each monthly file once every line it could hold is past the retention. Returns the
    /// files deleted.
    @discardableResult
    public func pruneReadings(now: Date) -> [URL] {
        let cutoff = now.addingTimeInterval(-Self.rawRetention)
        var deleted: [URL] = []
        for url in readingsFiles() {
            guard let start = Self.month(ofFileNamed: url.lastPathComponent),
                  let end = Self.utc.date(byAdding: .month, value: 1, to: start), end <= cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { deleted.append(url) }
        }
        return deleted
    }

    // MARK: Summaries

    public func loadWindows() -> [WindowSummary] { loadLines(WindowSummary.self, from: windowsFile) }
    public func loadWeeks() -> [WeekSummary] { loadLines(WeekSummary.self, from: weeksFile) }
    public func loadDays() -> [DaySummary] { loadLines(DaySummary.self, from: daysFile) }

    /// Rebuilds the summary files from the raw readings and what's already summarised, so a missed
    /// reset or a crash heals on the next run. Running it twice gives the same files.
    @discardableResult
    public func rebuildSummaries(from readings: [HistoryLine], now: Date, calendar: Calendar = .current) throws -> HistorySummarySet {
        let set = summaries(from: readings, now: now, calendar: calendar)
        try writeLines(set.windows, to: windowsFile)
        try writeLines(set.weeks, to: weeksFile)
        try writeLines(set.days, to: daysFile)
        return set
    }

    /// What `rebuildSummaries` would write, without writing it.
    public func summaries(from readings: [HistoryLine], now: Date, calendar: Calendar = .current) -> HistorySummarySet {
        let rebuilt = HistorySummaries.build(from: readings, now: now)
        return HistorySummarySet(
            windows: HistorySummaries.merge(existing: loadWindows(), rebuilt: rebuilt.windows),
            weeks: HistorySummaries.merge(existing: loadWeeks(), rebuilt: rebuilt.weeks),
            days: DaySummaries.merge(existing: loadDays(), rebuilt: DaySummaries.build(from: readings, calendar: calendar)))
    }

    // MARK: Claude Code log layer

    public func loadHourlyTokens() -> [HourlyTokens] { loadLines(HourlyTokens.self, from: hourlyTokensFile) }

    public func writeHourlyTokens(_ rows: [HourlyTokens]) throws { try writeLines(rows, to: hourlyTokensFile) }

    public func loadScanState() -> LogScanState {
        guard let data = try? Data(contentsOf: logScanStateFile),
              let state = try? HistoryCoding.decoder().decode(LogScanState.self, from: data) else { return LogScanState() }
        return state
    }

    public func writeScanState(_ state: LogScanState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try HistoryCoding.encoder().encode(state).write(to: logScanStateFile, options: .atomic)
    }

    // MARK: Helpers

    func loadLines<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return HistoryCoding.decodeLines(type, from: data)
    }

    /// Replaces a whole JSON Lines file atomically, and only when its contents change.
    func writeLines<T: Encodable>(_ values: [T], to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try HistoryCoding.encodeLines(values)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }
}

public struct HistorySummarySet: Equatable, Sendable {
    public var windows: [WindowSummary]
    public var weeks: [WeekSummary]
    public var days: [DaySummary]

    public init(windows: [WindowSummary] = [], weeks: [WeekSummary] = [], days: [DaySummary] = []) {
        self.windows = windows
        self.weeks = weeks
        self.days = days
    }
}
