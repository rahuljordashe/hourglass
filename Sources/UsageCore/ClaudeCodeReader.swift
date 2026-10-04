import Foundation

/// How a usage read launches Claude Code. Every launch is hardened the same way:
/// - flags that turn off hooks, MCP servers, session saving, Remote Control and session upload;
/// - an environment built from scratch (nothing inherited, no `CLAUDE_CODE_*` variables);
/// - an empty temporary working folder, so no project settings, hooks or MCP config apply.
///
/// Never `--bare` (it doesn't read the login) and never `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
/// (it blocks the usage fetch). Claude Code makes the network call; this code never sees a token.
public enum HardenedLaunch {
    public enum Mode: String, Sendable {
        /// `get_usage` control request over stream-json stdin.
        case getUsage
        /// `claude -p "/usage"` and its `usage_report`.
        case slashUsage
    }

    public static let settings = #"{"disableAllHooks":true,"remoteControlAtStartup":false,"autoUploadSessions":false}"#

    public static let hardeningFlags = [
        "--safe-mode",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--settings", settings
    ]

    public static func arguments(_ mode: Mode) -> [String] {
        switch mode {
        case .getUsage:
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"] + hardeningFlags
        case .slashUsage:
            ["-p", "/usage", "--output-format", "stream-json", "--verbose"] + hardeningFlags
        }
    }

    public static func environment(home: URL, user: String, tempDirectory: URL, executable: URL) -> [String: String] {
        let dirs = [executable.deletingLastPathComponent().path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return [
            "HOME": home.path,
            "USER": user,
            "LOGNAME": user,
            "PATH": dirs.filter { seen.insert($0).inserted }.joined(separator: ":"),
            "TMPDIR": tempDirectory.path.hasSuffix("/") ? tempDirectory.path : tempDirectory.path + "/",
            "LANG": "en_US.UTF-8",
            "DISABLE_AUTOUPDATER": "1"
        ]
    }

    /// The single stdin line for `get_usage`. `skip_behaviors` skips a scan of every local transcript.
    public static func getUsageRequest(id: String) -> String {
        #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"get_usage","skip_behaviors":true}}"#
    }

    /// Claude Code's token refresh lock. A read is skipped while it exists, so a launch never
    /// races (or gets killed during) a refresh.
    public static func refreshLock(home: URL) -> URL {
        home.appending(path: ".claude/.oauth_refresh.lock")
    }

    /// Where `claude` usually lives. Apps launched from Finder get a minimal PATH, so look explicitly.
    public static func candidateExecutables(home: URL) -> [URL] {
        [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appending(path: ".npm-global/bin/claude"),
            home.appending(path: ".bun/bin/claude")
        ]
    }
}

/// Runs one usage read through the installed Claude Code: `get_usage` first, `-p "/usage"` if
/// this Claude Code doesn't answer `get_usage`. Blocking; call it off the main thread.
///
/// Only one read runs at a time. A launch gets SIGTERM after `terminateAfter` seconds and is never
/// SIGKILLed: killing Claude Code mid token refresh can log it out. If it still hasn't exited after
/// the grace period, `isBusy` stays true until it does, so no second copy is started.
public final class ClaudeCodeReader: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executable: URL
        public var home: URL
        public var user: String
        /// Parent folder for each read's empty working folder.
        public var tempDirectory: URL
        public var terminateAfter: TimeInterval
        public var graceAfterTerminate: TimeInterval

        public init(executable: URL, home: URL, user: String, tempDirectory: URL,
                    terminateAfter: TimeInterval = 40, graceAfterTerminate: TimeInterval = 15) {
            self.executable = executable
            self.home = home
            self.user = user
            self.tempDirectory = tempDirectory
            self.terminateAfter = terminateAfter
            self.graceAfterTerminate = graceAfterTerminate
        }
    }

    public enum Outcome: Equatable, Sendable {
        case usage(PlanUsage)
        case unavailable(String)
        case error(String, rateLimited: Bool)
        /// Claude Code is refreshing its login; nothing was launched.
        case refreshLockHeld
        /// A previous launch is still running; nothing was launched.
        case busy
        case timedOut
        case launchFailed(String)
    }

    public struct Report: Sendable {
        public var outcome: Outcome
        /// Launches made (0, 1, or 2 when the fallback ran). Each counts against the budget.
        public var launches: Int
        public var mode: HardenedLaunch.Mode?
        public var duration: TimeInterval
    }

    private let config: Configuration
    private let lock = NSLock()
    private var running: Process?

    public init(_ config: Configuration) {
        self.config = config
        // Writing to a child that has already exited must be an error, not a crash.
        signal(SIGPIPE, SIG_IGN)
    }

    public var configuration: Configuration { config }

    /// True while a launch (or one that ignored SIGTERM) is still alive.
    public var isBusy: Bool {
        lock.withLock { running?.isRunning ?? false }
    }

    public func read(now: @escaping @Sendable () -> Date = Date.init) -> Report {
        let started = Date()
        func report(_ outcome: Outcome, _ launches: Int, _ mode: HardenedLaunch.Mode?) -> Report {
            Report(outcome: outcome, launches: launches, mode: mode, duration: Date().timeIntervalSince(started))
        }
        if isBusy { return report(.busy, 0, nil) }
        if FileManager.default.fileExists(atPath: HardenedLaunch.refreshLock(home: config.home).path) {
            return report(.refreshLockHeld, 0, nil)
        }

        let first = run(.getUsage, now: now)
        switch first {
        case .answered(let outcome):
            if case .error(let message, _) = outcome, Self.isUnsupported(message) { break }
            return report(outcome, 1, .getUsage)
        case .noAnswer:
            break
        case .failed(let outcome):
            return report(outcome, 1, .getUsage)
        }

        if isBusy { return report(.busy, 1, .getUsage) }
        switch run(.slashUsage, now: now) {
        case .answered(let outcome), .failed(let outcome):
            return report(outcome, 2, .slashUsage)
        case .noAnswer:
            return report(.error("Claude Code gave no usage answer", rateLimited: false), 2, .slashUsage)
        }
    }

    /// `get_usage` answered with "not supported" or an unknown-request error: worth the fallback.
    static func isUnsupported(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("not supported") || m.contains("unsupported") || m.contains("unknown") || m.contains("invalid")
    }

    // MARK: One launch

    enum LaunchResult {
        case answered(Outcome)
        /// Exited without an answer (for example an older Claude Code that ignores the request).
        case noAnswer
        case failed(Outcome)
    }

    private func run(_ mode: HardenedLaunch.Mode, now: @escaping @Sendable () -> Date) -> LaunchResult {
        let fm = FileManager.default
        let workDir = config.tempDirectory.appending(path: "hourglass-read-\(UUID().uuidString)", directoryHint: .isDirectory)
        do { try fm.createDirectory(at: workDir, withIntermediateDirectories: true) } catch {
            return .failed(.launchFailed("Couldn't create a working folder"))
        }

        let requestId = "notch-\(UUID().uuidString.prefix(12).lowercased())"
        let process = Process()
        process.executableURL = config.executable
        process.arguments = HardenedLaunch.arguments(mode)
        process.environment = HardenedLaunch.environment(home: config.home, user: config.user,
                                                         tempDirectory: config.tempDirectory, executable: config.executable)
        process.currentDirectoryURL = workDir
        process.qualityOfService = .utility

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = mode == .getUsage ? stdin : FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let input = OnceClosable(stdin.fileHandleForWriting)
        let collector = LineCollector(requestId: mode == .getUsage ? requestId : nil, now: now) {
            // Answer in hand: close stdin so Claude Code finishes and exits on its own.
            input.close()
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                collector.append(data)
            }
        }

        do { try process.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            try? fm.removeItem(at: workDir)
            return .failed(.launchFailed("Couldn't start Claude Code"))
        }
        lock.withLock { running = process }

        if mode == .getUsage {
            let line = HardenedLaunch.getUsageRequest(id: requestId) + "\n"
            input.write(Data(line.utf8))
        }

        var timedOut = false
        if exited.wait(timeout: .now() + config.terminateAfter) == .timedOut {
            timedOut = true
            process.terminate() // SIGTERM only, never SIGKILL
            if exited.wait(timeout: .now() + config.graceAfterTerminate) == .timedOut {
                // Leave it running; `isBusy` blocks new reads until it exits.
                input.close()
                return .failed(.timedOut)
            }
        }
        _ = drained.wait(timeout: .now() + 2)
        stdout.fileHandleForReading.readabilityHandler = nil
        input.close()
        lock.withLock { if running === process { running = nil } }
        try? fm.removeItem(at: workDir)

        if let outcome = collector.outcome {
            switch outcome {
            case .usage(let u): return .answered(.usage(u))
            case .unavailable(let m): return .answered(.unavailable(m))
            case .error(let m): return .answered(.error(m, rateLimited: outcome.isRateLimited))
            }
        }
        return timedOut ? .failed(.timedOut) : .noAnswer
    }
}

/// The write end of the child's stdin, closed exactly once from whichever thread gets there first.
private final class OnceClosable: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ data: Data) {
        lock.withLock { try? handle?.write(contentsOf: data) }
    }

    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
}

/// Splits stdout into lines and keeps the first usage answer.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var answer: UsageResponseParser.Outcome?
    private let requestId: String?
    private let now: @Sendable () -> Date
    private let onAnswer: () -> Void
    /// Lines longer than this are dropped rather than buffered (the init line lists every tool).
    private static let maxLine = 4 * 1024 * 1024

    init(requestId: String?, now: @escaping @Sendable () -> Date, onAnswer: @escaping () -> Void) {
        self.requestId = requestId
        self.now = now
        self.onAnswer = onAnswer
    }

    var outcome: UsageResponseParser.Outcome? { lock.withLock { answer } }

    func append(_ data: Data) {
        var found = false
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard answer == nil, let text = String(data: line, encoding: .utf8) else { continue }
                if let parsed = UsageResponseParser.parse(line: text, requestId: requestId, now: now()) {
                    answer = parsed
                    found = true
                }
            }
            if buffer.count > Self.maxLine { buffer.removeAll() }
        }
        if found { onAnswer() }
    }
}
