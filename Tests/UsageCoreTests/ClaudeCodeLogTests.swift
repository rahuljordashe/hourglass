import Foundation
import Testing
@testable import UsageCore

// Fake Claude Code logs, written to a temporary folder. Never real logs.

struct FakeLogs {
    let home: URL
    var root: URL { home.appending(path: ".claude/projects", directoryHint: .isDirectory) }

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "hourglass-fake-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var scanner: ClaudeCodeLogScanner {
        ClaudeCodeLogScanner(root: root, home: home, excludedMarkers: ClaudeCodeLogScanner.appMarkers(
            workFolderPrefix: HardenedLaunch.workFolderPrefix,
            supportDirectory: NotchPaths(home: home).supportDirectory))
    }

    /// The folder name Claude Code would give a project at `~/<path>`.
    func folder(_ path: String) -> String { ClaudeCodeLogScanner.encode(home.path + "/" + path) }

    func append(_ lines: [String], project: String, file: String = "session.jsonl", newline: Bool = true) throws {
        let dir = root.appending(path: project, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: file)
        let text = lines.joined(separator: "\n") + (newline ? "\n" : "")
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }
}

func assistant(_ time: String, model: String = "claude-fable-5-1", id: String = UUID().uuidString, request: String = "req_1",
               input: Int = 100, output: Int = 50, cacheWrite: Int = 10, cacheRead: Int = 1000) -> String {
    #"{"type":"assistant","timestamp":"\#(time)","requestId":"\#(request)","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"SECRET-CONTENT"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead)}}}"#
}

let userLine = #"{"type":"user","timestamp":"2026-10-05T09:00:00.000Z","message":{"role":"user","content":"SECRET-CONTENT"}}"#
let scanNow = ISO8601DateFormatter().date(from: "2026-10-06T00:00:00Z")!

@Suite("Claude Code log layer")
struct ClaudeCodeLogTests {
    @Test func countsAssistantUsagePerHourProjectAndModel() throws {
        let logs = try FakeLogs()
        try logs.append([
            userLine,
            assistant("2026-10-05T09:05:00.120Z"),
            assistant("2026-10-05T09:40:00Z", input: 200),
            assistant("2026-10-05T10:10:00Z", model: "claude-opus-5-5")
        ], project: logs.folder("Developer/hourglass"))
        let result = logs.scanner.scan(state: LogScanState(), now: scanNow)
        #expect(result.outcome == .read(messages: 3))
        #expect(result.added.count == 2)
        let nine = try #require(result.added.first)
        #expect(nine.project == "hourglass")
        #expect(nine.model == "Fable")
        #expect(nine.input == 300)
        #expect(nine.output == 100)
        #expect(nine.cacheCreation == 20)
        #expect(nine.cacheRead == 2000)
        #expect(nine.messages == 2)
        #expect(result.added.last?.model == "Opus")
    }

    @Test func repeatedLinesForOneMessageCountOnce() throws {
        let logs = try FakeLogs()
        let line = assistant("2026-10-05T09:05:00Z", id: "msg_1", request: "req_9")
        try logs.append([line, line], project: logs.folder("Developer/a"))
        // A resumed session repeats it in another file.
        try logs.append([line], project: logs.folder("Developer/a"), file: "resumed.jsonl")
        let result = logs.scanner.scan(state: LogScanState(), now: scanNow)
        #expect(result.outcome == .read(messages: 1))
        #expect(result.added.first?.messages == 1)
    }

    @Test func readsIncrementallyAndWaitsForWholeLines() throws {
        let logs = try FakeLogs()
        let project = logs.folder("Developer/a")
        try logs.append([assistant("2026-10-05T09:05:00Z")], project: project)
        let first = logs.scanner.scan(state: LogScanState(), now: scanNow)
        #expect(first.outcome == .read(messages: 1))

        // Half a line, still being written.
        let next = assistant("2026-10-05T11:00:00Z")
        try logs.append([String(next.prefix(40))], project: project, newline: false)
        let second = logs.scanner.scan(state: first.state, now: scanNow)
        #expect(second.outcome == .read(messages: 0))

        try logs.append([String(next.dropFirst(40))], project: project)
        let third = logs.scanner.scan(state: second.state, now: scanNow)
        #expect(third.outcome == .read(messages: 1))
        #expect(third.added.first?.hour == ISO8601DateFormatter().date(from: "2026-10-05T11:00:00Z"))
    }

    @Test func leavesOutTheAppsOwnReads() throws {
        let logs = try FakeLogs()
        try logs.append([assistant("2026-10-05T09:05:00Z")], project: "-private-var-folders-xy-T-hourglass-read-1234ABCD")
        try logs.append([assistant("2026-10-05T09:06:00Z")], project: logs.folder("Library/Application Support/Hourglass/refresh"))
        try logs.append([assistant("2026-10-05T09:07:00Z")], project: logs.folder("Developer/real-project"))
        let result = logs.scanner.scan(state: LogScanState(), now: scanNow)
        #expect(result.outcome == .read(messages: 1))
        #expect(result.added.map(\.project) == ["real-project"])
    }

    @Test func unfamiliarFormatSwitchesOffWithoutCounting() throws {
        let logs = try FakeLogs()
        let changed = (0..<6).map { #"{"type":"assistant","timestamp":"2026-10-05T09:0\#($0):00Z","msg":{"tokens":5}}"# }
        try logs.append(changed + [assistant("2026-10-05T09:30:00Z")], project: logs.folder("Developer/a"))
        let result = logs.scanner.scan(state: LogScanState(), now: scanNow)
        #expect(result.outcome == .formatChanged)
        #expect(result.added.isEmpty)
        #expect(result.state.formatChanged)
        #expect(result.state.offsets.isEmpty)
    }

    @Test func manyLinesWithNoAssistantAtAllLooksChanged() throws {
        let logs = try FakeLogs()
        try logs.append(Array(repeating: #"{"kind":"turn","at":"2026-10-05T09:00:00Z"}"#, count: 210), project: logs.folder("Developer/a"))
        #expect(logs.scanner.scan(state: LogScanState(), now: scanNow).outcome == .formatChanged)
    }

    @Test func truncatedFileIsReadAgainWithoutDoubleCounting() throws {
        let logs = try FakeLogs()
        let project = logs.folder("Developer/a")
        let line = assistant("2026-10-05T09:05:00Z", id: "msg_1")
        try logs.append([line, assistant("2026-10-05T09:06:00Z", id: "msg_2")], project: project)
        let first = logs.scanner.scan(state: LogScanState(), now: scanNow)
        try Data((line + "\n").utf8).write(to: logs.root.appending(path: "\(project)/session.jsonl"))
        let second = logs.scanner.scan(state: first.state, now: scanNow)
        #expect(second.outcome == .read(messages: 0))
    }

    @Test func oldMessagesAreLeftOut() throws {
        let logs = try FakeLogs()
        try logs.append([assistant("2026-06-01T09:05:00Z"), assistant("2026-10-05T09:05:00Z")], project: logs.folder("Developer/a"))
        let result = logs.scanner.scan(state: LogScanState(), now: scanNow)
        #expect(result.added.count == 1)
    }

    @Test func storedAggregatesHoldNoMessageContent() throws {
        let logs = try FakeLogs()
        try logs.append([userLine, assistant("2026-10-05T09:05:00Z")], project: logs.folder("Developer/a"))
        let result = logs.scanner.scan(state: LogScanState(), now: scanNow)
        let files = HistoryFiles(directory: logs.home.appending(path: "history"))
        try files.writeHourlyTokens(result.added)
        try files.writeScanState(result.state)
        let stored = try String(contentsOf: files.hourlyTokensFile, encoding: .utf8) + String(contentsOf: files.logScanStateFile, encoding: .utf8)
        #expect(!stored.contains("SECRET-CONTENT"))
        #expect(files.loadHourlyTokens() == result.added)
        #expect(files.loadScanState() == result.state)
    }

    @Test func projectAndModelNames() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ClaudeCodeLogScanner.projectName("-Users-someone-Developer-hourglass", home: home) == "hourglass")
        #expect(ClaudeCodeLogScanner.projectName("-Users-someone-notes", home: home) == "notes")
        #expect(ClaudeCodeLogScanner.projectName("-Users-someone", home: home) == "~")
        #expect(ClaudeCodeLogScanner.projectName("-opt-build", home: home) == "opt-build")
        #expect(ClaudeCodeLogScanner.modelName("claude-fable-5-1") == "Fable")
        #expect(ClaudeCodeLogScanner.modelName("claude-sonnet-5-5") == "Sonnet")
        #expect(ClaudeCodeLogScanner.modelName("mystery-1") == "mystery-1")
    }

    @Test func mergingSumsHoursAndDropsOldOnes() {
        let hour = ISO8601DateFormatter().date(from: "2026-10-05T09:00:00Z")!
        let old = ISO8601DateFormatter().date(from: "2026-05-01T09:00:00Z")!
        let merged = HourlyTokens.merge(
            [HourlyTokens(hour: hour, project: "a", model: "Fable", input: 1, messages: 1),
             HourlyTokens(hour: old, project: "a", model: "Fable", input: 9, messages: 1)],
            [HourlyTokens(hour: hour, project: "a", model: "Fable", input: 2, messages: 1)], now: scanNow)
        #expect(merged == [HourlyTokens(hour: hour, project: "a", model: "Fable", input: 3, messages: 2)])
    }

    @Test func explainsADay() {
        let day = DateInterval(start: ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")!, duration: 86400)
        let rows = [
            HourlyTokens(hour: day.start.addingTimeInterval(9 * 3600), project: "hourglass", model: "Fable", input: 900),
            HourlyTokens(hour: day.start.addingTimeInterval(10 * 3600), project: "website", model: "Opus", input: 300),
            HourlyTokens(hour: day.start.addingTimeInterval(11 * 3600), project: "website", model: "Fable", input: 200)
        ]
        #expect(TokenBreakdown.mostly(rows, in: day) == "mostly hourglass, Fable")
        #expect(TokenBreakdown.top(rows, in: day).projects.map(\.name) == ["hourglass", "website"])
        #expect(TokenBreakdown.mostly(rows, in: DateInterval(start: day.end, duration: 86400)) == nil)
        #expect(TokenBreakdown.tokens(1_260_000) == "1.3M tokens")
        #expect(TokenBreakdown.tokens(840_400) == "840K tokens")
    }
}
