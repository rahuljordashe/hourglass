import Foundation
import Testing
@testable import UsageCore

/// A throwaway home folder with a fake `claude` shell script standing in for Claude Code.
private struct FakeClaude {
    let root: URL
    var home: URL { root.appending(path: "home") }
    var temp: URL { root.appending(path: "tmp") }
    var executable: URL { root.appending(path: "bin/claude") }
    var argsLog: URL { root.appending(path: "args.txt") }
    var envLog: URL { root.appending(path: "env.txt") }
    var cwdLog: URL { root.appending(path: "cwd.txt") }
    var countLog: URL { root.appending(path: "launches.txt") }

    /// `body` runs after the script has logged its arguments, environment and folder.
    init(_ body: String) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "notch-reader-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in [home, temp, executable.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsLog.path)'
        /usr/bin/env > '\(envLog.path)'
        pwd -P > '\(cwdLog.path)'
        ls -A >> '\(cwdLog.path)'
        echo x >> '\(countLog.path)'
        \(body)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func reader(terminateAfter: TimeInterval = 10, grace: TimeInterval = 5) -> ClaudeCodeReader {
        ClaudeCodeReader(.init(executable: executable, home: home, user: "tester", tempDirectory: temp,
                               terminateAfter: terminateAfter, graceAfterTerminate: grace))
    }

    var launches: Int {
        ((try? String(contentsOf: countLog, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// Reads the request line, then answers it with `rateLimits` and waits for stdin to close.
private func answering(_ rateLimits: String) -> String {
    """
    read line
    id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
    printf '%s\\n' '{"type":"system","subtype":"init"}'
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":%s}}}\\n' "$id" '\(rateLimits)'
    cat > /dev/null
    """
}

private let sessionRow = #"{"limits":[{"kind":"session","percent":42,"resets_at":"2026-10-03T13:40:00Z"}]}"#

@Suite("Hardened Claude Code reader", .serialized)
struct ReaderTests {
    @Test func getUsageAnswerAndHardening() throws {
        let fake = try FakeClaude(answering(sessionRow))
        defer { fake.cleanUp() }
        let report = fake.reader().read()

        guard case .usage(let usage) = report.outcome else {
            Issue.record("Expected usage, got \(report.outcome)"); return
        }
        #expect(usage.session?.percent == 42)
        #expect(report.launches == 1)
        #expect(report.mode == .getUsage)

        let args = try String(contentsOf: fake.argsLog, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == HardenedLaunch.arguments(.getUsage))
        for flag in ["--safe-mode", "--strict-mcp-config", "--no-session-persistence", "--settings"] {
            #expect(args.contains(flag))
        }
        #expect(!args.contains("--bare"))

        let env = try String(contentsOf: fake.envLog, encoding: .utf8)
        let keys = Set(env.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        // sh adds PWD, SHLVL and _ itself; everything else is exactly what we built.
        #expect(keys.subtracting(["PWD", "SHLVL", "_", "OLDPWD"]) == ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "DISABLE_AUTOUPDATER"])
        #expect(env.contains("DISABLE_AUTOUPDATER=1"))
        #expect(env.contains("HOME=\(fake.home.path)"))
        #expect(!env.contains("CLAUDE"))

        // Ran in a fresh, empty folder under the temp directory, removed afterwards.
        let cwd = try String(contentsOf: fake.cwdLog, encoding: .utf8).split(separator: "\n")
        #expect(cwd.count == 1)
        #expect(cwd.first?.contains("hourglass-read-") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fake.temp.path).isEmpty)
    }

    @Test func fallsBackToSlashUsageWhenGetUsageGoesUnanswered() throws {
        let fake = try FakeClaude("""
        if [ "$2" = "/usage" ]; then
          printf '%s\\n' '{"type":"assistant","usage_report":{"rate_limits":{"limits":[{"kind":"weekly_all","percent":18}]}}}'
          printf '%s\\n' '{"type":"result","subtype":"success","num_turns":0}'
        fi
        """)
        defer { fake.cleanUp() }
        let report = fake.reader().read()
        guard case .usage(let usage) = report.outcome else {
            Issue.record("Expected usage, got \(report.outcome)"); return
        }
        #expect(usage.source == .usageReport)
        #expect(usage.weekly?.percent == 18)
        #expect(report.launches == 2)
        #expect(report.mode == .slashUsage)
        #expect(fake.launches == 2)
        let args = try String(contentsOf: fake.argsLog, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == HardenedLaunch.arguments(.slashUsage))
    }

    @Test func rateLimitedErrorIsReportedWithoutFallback() throws {
        let fake = try FakeClaude("""
        read line
        id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
        printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"Request failed with status code 429"}}\\n' "$id"
        cat > /dev/null
        """)
        defer { fake.cleanUp() }
        let report = fake.reader().read()
        #expect(report.outcome == .error("Request failed with status code 429", rateLimited: true))
        #expect(report.launches == 1)
    }

    @Test func skipsWhileClaudeCodeIsRefreshingItsLogin() throws {
        let fake = try FakeClaude(answering(sessionRow))
        defer { fake.cleanUp() }
        let lock = HardenedLaunch.refreshLock(home: fake.home)
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lock)

        let report = fake.reader().read()
        #expect(report.outcome == .refreshLockHeld)
        #expect(report.launches == 0)
        #expect(fake.launches == 0)
    }

    @Test func sendsSigtermAfterTheDeadline() throws {
        let fake = try FakeClaude("exec /bin/sleep 30")
        defer { fake.cleanUp() }
        let reader = fake.reader(terminateAfter: 0.5, grace: 5)
        let report = reader.read()
        #expect(report.outcome == .timedOut)
        #expect(report.launches == 1)
        #expect(report.duration < 5)
        #expect(!reader.isBusy)
    }

    @Test func neverKillsAndStaysBusyWhileAProcessIgnoresSigterm() async throws {
        let fake = try FakeClaude("""
        trap '' TERM
        /bin/sleep 3
        """)
        defer { fake.cleanUp() }
        // Long enough for the script to set its trap before SIGTERM arrives.
        let reader = fake.reader(terminateAfter: 1, grace: 0.3)
        let report = reader.read()
        #expect(report.outcome == .timedOut)
        #expect(reader.isBusy) // still running: not killed
        #expect(reader.read().outcome == .busy)
        #expect(fake.launches == 1)

        try await Task.sleep(for: .seconds(3.5))
        #expect(!reader.isBusy)
    }

    @Test func missingExecutableFailsCleanly() throws {
        let fake = try FakeClaude("")
        defer { fake.cleanUp() }
        try FileManager.default.removeItem(at: fake.executable)
        let report = fake.reader().read()
        #expect(report.outcome == .launchFailed("Couldn't start Claude Code"))
    }

    @Test func requestLineShape() throws {
        let line = HardenedLaunch.getUsageRequest(id: "abc")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "control_request")
        #expect(object["request_id"] as? String == "abc")
        let request = try #require(object["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "get_usage")
        #expect(request["skip_behaviors"] as? Bool == true)
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(HardenedLaunch.settings.utf8)) as? [String: Bool])
        #expect(settings == ["disableAllHooks": true, "remoteControlAtStartup": false, "autoUploadSessions": false])
    }
}
