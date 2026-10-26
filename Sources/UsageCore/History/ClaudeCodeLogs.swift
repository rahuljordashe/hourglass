import Foundation

/// Tokens Claude Code used in one hour, for one project and one model: a line of
/// `claude-code-hourly.jsonl`. Aggregates only; no message, prompt or file content is ever kept.
public struct HourlyTokens: Codable, Equatable, Sendable {
    public var hour: Date
    /// The project folder's short name, such as "hourglass".
    public var project: String
    /// The model's family name, such as "Fable".
    public var model: String
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var messages: Int

    public init(hour: Date, project: String, model: String, input: Int = 0, output: Int = 0, cacheCreation: Int = 0,
                cacheRead: Int = 0, messages: Int = 0) {
        self.hour = hour
        self.project = project
        self.model = model
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.messages = messages
    }

    /// Tokens for ranking: input, output and cache writes. Cache reads are left out; they're
    /// cheap and large enough to drown out everything else.
    public var weight: Int { input + output + cacheCreation }

    var key: String { "\(Int(hour.timeIntervalSince1970))|\(project)|\(model)" }

    /// `existing` plus `added`, one row per hour, project and model, dropping hours past the retention.
    public static func merge(_ existing: [HourlyTokens], _ added: [HourlyTokens], now: Date) -> [HourlyTokens] {
        let cutoff = now.addingTimeInterval(-HistoryFiles.rawRetention)
        var rows: [String: HourlyTokens] = [:]
        for row in existing + added where row.hour >= cutoff {
            if var current = rows[row.key] {
                current.input += row.input
                current.output += row.output
                current.cacheCreation += row.cacheCreation
                current.cacheRead += row.cacheRead
                current.messages += row.messages
                rows[row.key] = current
            } else {
                rows[row.key] = row
            }
        }
        return rows.values.sorted { ($0.hour, $0.project, $0.model) < ($1.hour, $1.project, $1.model) }
    }
}

/// Where the log reader got to: each file's read position and the messages already counted.
public struct LogScanState: Codable, Equatable, Sendable {
    /// Bytes read so far, by path under `~/.claude/projects`.
    public var offsets: [String: UInt64] = [:]
    /// Message and request ids already counted, with their time, so a repeated line counts once.
    public var seen: [String: Date] = [:]
    /// The last read found lines it didn't recognise and switched the layer off.
    public var formatChanged = false
    public var lastScan: Date?

    public init() {}
}

/// Reads Claude Code's session logs (`~/.claude/projects/**/*.jsonl`) read-only and incrementally,
/// keeping only each assistant message's time, model, token counts and project folder name.
public struct ClaudeCodeLogScanner: Sendable {
    public enum Outcome: Equatable, Sendable {
        case read(messages: Int)
        /// The lines didn't look like Claude Code's log format: nothing was counted.
        case formatChanged
        case noLogs
    }

    public struct Result: Sendable {
        public var added: [HourlyTokens]
        public var state: LogScanState
        public var outcome: Outcome
    }

    public var root: URL
    /// The home folder, to shorten project folder names.
    public var home: URL
    /// Project folders whose name contains any of these are the app's own hidden reads, never counted.
    public var excludedMarkers: [String]

    /// Ids are remembered this long; Claude Code deletes logs after 30 days by default.
    public static let seenRetention: TimeInterval = 40 * 86400
    static let chunkSize = 8 * 1024 * 1024

    public init(root: URL, home: URL, excludedMarkers: [String]) {
        self.root = root
        self.home = home
        self.excludedMarkers = excludedMarkers
    }

    /// The markers for an app whose hidden reads run in `<tmp>/<workFolderPrefix>…` and whose
    /// support folder is `supportDirectory`.
    public static func appMarkers(workFolderPrefix: String, supportDirectory: URL) -> [String] {
        let support = supportDirectory.pathComponents.suffix(2).joined(separator: "/")
        return [encode(workFolderPrefix), encode(support)]
    }

    /// Claude Code names a project folder after its path with every other character turned into "-".
    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    // MARK: Scanning

    public func scan(state: LogScanState, now: Date) -> Result {
        let files = logFiles()
        guard !files.isEmpty else { return Result(added: [], state: state, outcome: .noLogs) }

        var next = state
        var counter = Counter()
        var rows: [String: HourlyTokens] = [:]
        var live = Set<String>()
        let cutoff = now.addingTimeInterval(-HistoryFiles.rawRetention)

        for (url, path, project) in files {
            live.insert(path)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value else { continue }
            var offset = next.offsets[path] ?? 0
            if size < offset { offset = 0 } // replaced or truncated: start again (ids stop double counting)
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            do { try handle.seek(toOffset: offset) } catch { continue }

            var carry = Data()
            while true {
                let chunk = handle.readData(ofLength: Self.chunkSize)
                if chunk.isEmpty { break }
                carry.append(chunk)
                guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
                let complete = carry[carry.startIndex...lastNewline]
                for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard let entry = counter.entry(Data(line)) else { continue }
                    if let key = entry.dedupeKey {
                        if next.seen[key] != nil { continue }
                        next.seen[key] = entry.time
                    }
                    guard entry.time >= cutoff, entry.model != "<synthetic>" else { continue }
                    var hour = HourlyTokens(hour: Self.hour(of: entry.time), project: Self.projectName(project, home: home),
                                            model: Self.modelName(entry.model))
                    hour = rows[hour.key] ?? hour
                    hour.input += entry.input
                    hour.output += entry.output
                    hour.cacheCreation += entry.cacheCreation
                    hour.cacheRead += entry.cacheRead
                    hour.messages += 1
                    rows[hour.key] = hour
                    counter.counted += 1
                }
                offset += UInt64(complete.count)
                carry.removeSubrange(carry.startIndex...lastNewline)
            }
            next.offsets[path] = offset
        }

        if counter.looksChanged {
            var failed = state
            failed.formatChanged = true
            failed.lastScan = now
            return Result(added: [], state: failed, outcome: .formatChanged)
        }
        next.offsets = next.offsets.filter { live.contains($0.key) }
        next.seen = next.seen.filter { now.timeIntervalSince($0.value) < Self.seenRetention }
        next.formatChanged = false
        next.lastScan = now
        return Result(added: HourlyTokens.merge([], Array(rows.values), now: now), state: next, outcome: .read(messages: counter.counted))
    }

    /// Every log file, with its path under the root and its project folder, skipping the app's own.
    func logFiles() -> [(URL, String, String)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [(URL, String, String)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            let path = String(full.dropFirst(rootPath.count).drop { $0 == "/" })
            guard let project = path.split(separator: "/").first.map(String.init), path.contains("/") else { continue }
            if excludedMarkers.contains(where: { !$0.isEmpty && project.contains($0) }) { continue }
            result.append((url, path, project))
        }
        return result.sorted { $0.1 < $1.1 }
    }

    // MARK: One line

    struct Entry {
        var time: Date
        var model: String
        var input: Int
        var output: Int
        var cacheCreation: Int
        var cacheRead: Int
        var dedupeKey: String?
    }

    /// Counts what it sees, to tell a format change from a quiet week.
    struct Counter {
        var lines = 0
        var assistantLines = 0
        var recognised = 0
        var counted = 0

        var looksChanged: Bool {
            if assistantLines >= 5 && recognised * 2 < assistantLines { return true }
            return lines >= 200 && assistantLines == 0
        }

        /// The usage on an assistant line, or nil for any other line. Reads only the time, model,
        /// ids and token counts; the rest of the line (the message itself) is never kept.
        mutating func entry(_ line: Data) -> Entry? {
            lines += 1
            guard line.range(of: Data("assistant".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant" else { return nil }
            assistantLines += 1
            guard let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any],
                  let input = (usage["input_tokens"] as? NSNumber)?.intValue,
                  let output = (usage["output_tokens"] as? NSNumber)?.intValue,
                  let stamp = object["timestamp"] as? String,
                  let time = ClaudeCodeLogScanner.parseTime(stamp) else { return nil }
            recognised += 1
            let id = message["id"] as? String
            let request = object["requestId"] as? String
            return Entry(
                time: time, model: model, input: input, output: output,
                cacheCreation: (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0,
                cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
                dedupeKey: id.flatMap { id in request.map { "\(id):\($0)" } }
            )
        }
    }

    static func parseTime(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func hour(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    // MARK: Names

    /// "claude-fable-5-1" → "Fable"; anything unfamiliar keeps its id.
    public static func modelName(_ id: String) -> String {
        let lower = id.lowercased()
        for family in ["fable", "opus", "sonnet", "haiku"] where lower.contains(family) {
            return family.prefix(1).uppercased() + family.dropFirst()
        }
        return id
    }

    /// "-Users-name-Developer-hourglass" → "hourglass": the home folder and a usual code
    /// folder are dropped. Folder names can't be decoded exactly (Claude Code turns "/" and "-"
    /// alike into "-"), so this is a readable label, not a path.
    public static func projectName(_ folder: String, home: URL) -> String {
        var name = folder
        let encodedHome = encode(home.standardizedFileURL.path)
        if name.hasPrefix(encodedHome) {
            name = String(name.dropFirst(encodedHome.count))
            if name.isEmpty { return "~" }
        }
        name = String(name.drop { $0 == "-" })
        for parent in ["Developer", "Projects", "projects", "Code", "code", "dev", "src", "repos", "Repos", "GitHub", "git",
                       "Documents", "Desktop", "work", "Work"] where name.hasPrefix(parent + "-") {
            name = String(name.dropFirst(parent.count + 1))
            break
        }
        return name.isEmpty ? folder : name
    }
}

// MARK: - Explaining days and weeks

public enum TokenBreakdown {
    public struct Share: Equatable, Sendable {
        public var name: String
        public var tokens: Int
        public var fraction: Double
    }

    /// Projects and models in `interval`, biggest first.
    public static func top(_ rows: [HourlyTokens], in interval: DateInterval) -> (projects: [Share], models: [Share]) {
        let inside = rows.filter { interval.start <= $0.hour && $0.hour < interval.end }
        let total = max(inside.reduce(0) { $0 + $1.weight }, 1)
        func shares(_ name: (HourlyTokens) -> String) -> [Share] {
            Dictionary(grouping: inside, by: name)
                .map { Share(name: $0.key, tokens: $0.value.reduce(0) { $0 + $1.weight }, fraction: 0) }
                .filter { $0.tokens > 0 }
                .map { var s = $0; s.fraction = Double(s.tokens) / Double(total); return s }
                .sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
        }
        return (shares(\.project), shares(\.model))
    }

    /// "mostly hourglass, Fable", or nil when Claude Code wasn't used then.
    public static func mostly(_ rows: [HourlyTokens], in interval: DateInterval) -> String? {
        let top = top(rows, in: interval)
        guard let project = top.projects.first, let model = top.models.first else { return nil }
        return "mostly \(project.name), \(model.name)"
    }

    /// "1.2M tokens", "840K tokens", "312 tokens".
    public static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM tokens", Double(count) / 1_000_000)
        case 1_000...: "\(Int((Double(count) / 1000).rounded()))K tokens"
        default: "\(count) tokens"
        }
    }
}
