// hourglass-bridge
//
// Claude Code runs this as its status line command, passing session JSON on stdin.
// 1. Saves the two rate-limit windows to ~/Library/Application Support/Hourglass/usage.json.
// 2. Runs the user's previous status line command with the same input and prints its output,
//    so the terminal status line looks exactly as before.
//
// It never touches the network, the Keychain, or Claude Code's credentials, and it never fails
// in a way that blanks the status line: recording errors are logged and chaining still happens.

import Foundation
import UsageCore

nonisolated(unsafe) var childPID: pid_t = 0

let paths = NotchPaths()

// MARK: Management commands (for people, not for Claude Code)

let arguments = CommandLine.arguments.dropFirst()
if let command = arguments.first, command.hasPrefix("--") {
    let installer = StatusLineInstaller(paths: paths)
    do {
        switch command {
        case "--status":
            switch installer.status() {
            case .connected:
                print("Connected: Claude Code's status line runs the Hourglass bridge.")
                if let chained = BridgeConfig.load(from: paths.configFile)?.chainedCommand { print("Chained status line: \(chained)") }
            case .disconnected(let current):
                print("Not connected. Current status line: \(current ?? "none")")
            case .unreadable(let why):
                print("Claude Code settings could not be read: \(why)")
            }
            if let snapshot = SnapshotFile.read(paths.usageFile) {
                let state = UsageEvaluator.evaluate(snapshot, now: Date())
                for kind in UsageWindowKind.allCases {
                    if let w = state.window(kind) {
                        print("\(kind.title): \(UsageFormat.percent(w.percentage)) used, resets in \(UsageFormat.duration(w.timeUntilReset))\(w.isReset ? " (reset, awaiting reading)" : "")")
                    }
                }
                if let age = state.age { print("Updated \(UsageFormat.age(age))") }
            }
        case "--connect":
            let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let report = try installer.connect(bridgeSource: me)
            print("Connected. Previous status line: \(report.previousCommand ?? "none"). Backup: \(report.backupURL?.path ?? "not needed")")
        case "--disconnect":
            let report = try installer.disconnect()
            print("Disconnected. Status line is now: \(report.newCommand ?? "none"). Backup: \(report.backupURL?.path ?? "not needed")")
        default:
            print("Usage: hourglass-bridge [--status | --connect | --disconnect]")
            print("With no arguments it reads Claude Code status line JSON on stdin.")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
}
let started = Date()
let env = ProcessInfo.processInfo.environment
let input = FileHandle.standardInput.readDataToEndOfFile()

// MARK: Record

var logLine = ""
do {
    let parsed = try StatusLineInput.parse(input)
    var outcome: UsageMerger.Outcome?
    try SnapshotFile.update(paths) { current in
        let (next, result) = UsageMerger.merge(current, with: parsed, now: started, entrypoint: env["CLAUDE_CODE_ENTRYPOINT"])
        outcome = result
        return next
    }
    let five = parsed.rateLimits?.fiveHour?.usedPercentage.map { String(format: "%.1f", $0) } ?? "-"
    let week = parsed.rateLimits?.sevenDay?.usedPercentage.map { String(format: "%.1f", $0) } ?? "-"
    let changed = outcome?.changedWindows.map(\.rawValue).sorted().joined(separator: ",") ?? ""
    logLine = "session=\(parsed.sessionId?.prefix(8) ?? "?") entry=\(env["CLAUDE_CODE_ENTRYPOINT"] ?? "?") v=\(parsed.version ?? "?") fresh=\(outcome?.fresh ?? false) 5h=\(five) 7d=\(week) changed=[\(changed)]"
} catch {
    logLine = "record-error=\(error)"
}

// MARK: Chain

let depthKey = "HOURGLASS_BRIDGE_DEPTH"
let config = BridgeConfig.load(from: paths.configFile)
var exitCode: Int32 = 0

if let command = config?.chainedCommand,
   !command.contains(StatusLineInstaller.bridgeMarker),
   env[depthKey] == nil {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    var childEnv = env
    childEnv[depthKey] = "1"
    process.environment = childEnv
    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    // If Claude Code cancels us (a newer update arrived), take the child down too.
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig) { received in
            if childPID > 0 { kill(childPID, received) }
            _exit(128 + received)
        }
    }

    do {
        try process.run()
        childPID = process.processIdentifier
        stdinPipe.fileHandleForWriting.write(input)
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        exitCode = process.terminationStatus
    } catch {
        logLine += " chain-error=\(error)"
    }
} else if config?.chainedCommand == nil {
    // No previous status line: show a minimal one of our own.
    if let snapshot = SnapshotFile.read(paths.usageFile) {
        let state = UsageEvaluator.evaluate(snapshot, now: Date())
        var parts: [String] = []
        if let f = state.fiveHour { parts.append("5h \(UsageFormat.percent(f.percentage))") }
        if let w = state.sevenDay { parts.append("week \(UsageFormat.percent(w.percentage))") }
        if !parts.isEmpty { print(parts.joined(separator: " · ")) }
    }
}

// MARK: Log

BridgeLog.append(logLine + String(format: " took=%.0fms exit=%d", Date().timeIntervalSince(started) * 1000, exitCode), paths: paths)
exit(exitCode)
