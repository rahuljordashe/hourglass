import Foundation
import Testing
@testable import UsageCore

@Suite("Editing one top-level JSON key in place")
struct JSONEditorTests {
    let sample = """
    {
      "model": "opus",
      "statusLine": {
        "type": "command",
        "command": "npx ccstatusline@latest"
      },
      "tui": "fullscreen",
      "note": "braces } and \\"quotes\\" in strings"
    }

    """

    @Test func readsRawValue() throws {
        let raw = try #require(try JSONTopLevelEditor.rawValue(forKey: "statusLine", in: sample))
        #expect(raw.hasPrefix("{"))
        #expect(raw.contains("ccstatusline"))
        #expect(try JSONTopLevelEditor.rawValue(forKey: "missing", in: sample) == nil)
    }

    @Test func replacesOnlyThatValue() throws {
        let out = try JSONTopLevelEditor.setValue(#"{"type":"command","command":"x"}"#, forKey: "statusLine", in: sample)
        let expected = sample.replacingOccurrences(of: """
        {
            "type": "command",
            "command": "npx ccstatusline@latest"
          }
        """, with: #"{"type":"command","command":"x"}"#)
        #expect(out == expected)
    }

    @Test func appendsWhenMissing() throws {
        let out = try JSONTopLevelEditor.setValue("1", forKey: "newKey", in: sample)
        #expect(out.contains(#""note": "braces } and \"quotes\" in strings","#))
        #expect(out.contains("\n  \"newKey\": 1"))
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        #expect(obj["newKey"] as? Int == 1)
        #expect(obj["model"] as? String == "opus")
    }

    @Test func emptyObject() throws {
        let out = try JSONTopLevelEditor.setValue("true", forKey: "a", in: "{ }")
        #expect(out == "{\n  \"a\": true\n}")
        #expect(try JSONTopLevelEditor.removeKey("a", in: out) == "{}")
    }

    @Test func removesMiddleAndLastKeys() throws {
        let noStatus = try JSONTopLevelEditor.removeKey("statusLine", in: sample)
        let obj = try JSONSerialization.jsonObject(with: Data(noStatus.utf8)) as! [String: Any]
        #expect(obj["statusLine"] == nil)
        #expect(obj.count == 3)
        let noNote = try JSONTopLevelEditor.removeKey("note", in: sample)
        #expect(noNote.contains(#""tui": "fullscreen""# + "\n}"))
    }

    @Test func rejectsNonObjects() {
        #expect(throws: JSONTopLevelEditor.EditError.notAnObject) { try JSONTopLevelEditor.setValue("1", forKey: "a", in: "[1,2]") }
        #expect(throws: (any Error).self) { try JSONTopLevelEditor.setValue("1", forKey: "a", in: "{\"a\": ") }
    }
}

@Suite("Connecting to Claude Code's settings")
struct InstallerTests {
    let original = """
    {
      "model": "opus",
      "statusLine": {
        "type": "command",
        "command": "npx ccstatusline@latest",
        "padding": 1
      },
      "tui": "fullscreen"
    }

    """

    func makeHome(settings: String?) throws -> (NotchPaths, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "notch-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        if let settings {
            try settings.write(to: home.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)
        }
        let bridge = home.appending(path: "fake-bridge")
        try "#!/bin/sh\n".write(to: bridge, atomically: true, encoding: .utf8)
        return (NotchPaths(home: home), bridge)
    }

    @Test func connectChainsExistingCommandAndBacksUp() throws {
        let (paths, bridge) = try makeHome(settings: original)
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = StatusLineInstaller(paths: paths)
        #expect(installer.status() == .disconnected(currentCommand: "npx ccstatusline@latest"))

        let report = try installer.connect(bridgeSource: bridge, now: t0)
        #expect(report.previousCommand == "npx ccstatusline@latest")
        #expect(installer.status() == .connected)

        // Backup is byte-identical to the original.
        let backup = try #require(report.backupURL)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)

        // Only statusLine changed; padding kept; other keys and their order untouched.
        let updated = try String(contentsOf: paths.claudeSettings, encoding: .utf8)
        #expect(updated.hasPrefix("{\n  \"model\": \"opus\",\n  \"statusLine\": {"))
        #expect(updated.hasSuffix("},\n  \"tui\": \"fullscreen\"\n}\n"))
        #expect(updated.contains("  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": "))
        #expect(updated.contains("hourglass-bridge'\",\n    \"padding\": 1\n  },"))
        let obj = try JSONSerialization.jsonObject(with: Data(updated.utf8)) as! [String: Any]
        let status = obj["statusLine"] as! [String: Any]
        #expect(status["padding"] as? Int == 1)
        #expect(status["type"] as? String == "command")
        #expect((status["command"] as? String)?.contains("hourglass-bridge") == true)

        // The chained command is recorded for the bridge.
        let config = try #require(BridgeConfig.load(from: paths.configFile))
        #expect(config.chainedCommand == "npx ccstatusline@latest")
        #expect(FileManager.default.isExecutableFile(atPath: paths.installedBridge.path))

        // Connecting again is a no-op.
        let again = try installer.connect(bridgeSource: bridge, now: t0.addingTimeInterval(5))
        #expect(again.backupURL == nil)
        #expect(BridgeConfig.load(from: paths.configFile)?.chainedCommand == "npx ccstatusline@latest")
    }

    @Test func disconnectRestoresOriginalExactly() throws {
        let (paths, bridge) = try makeHome(settings: original)
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = StatusLineInstaller(paths: paths)
        try installer.connect(bridgeSource: bridge, now: t0)
        try installer.disconnect(now: t0.addingTimeInterval(1))
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == original)
        #expect(installer.status() == .disconnected(currentCommand: "npx ccstatusline@latest"))
    }

    @Test func noPreviousStatusLine() throws {
        let plain = "{\n  \"model\": \"opus\"\n}\n"
        let (paths, bridge) = try makeHome(settings: plain)
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = StatusLineInstaller(paths: paths)
        try installer.connect(bridgeSource: bridge, now: t0)
        #expect(BridgeConfig.load(from: paths.configFile)?.chainedCommand == nil)
        #expect(installer.status() == .connected)
        try installer.disconnect(now: t0.addingTimeInterval(1))
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == plain)
    }

    @Test func missingSettingsFileIsCreated() throws {
        let (paths, bridge) = try makeHome(settings: nil)
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = StatusLineInstaller(paths: paths)
        let report = try installer.connect(bridgeSource: bridge, now: t0)
        #expect(report.backupURL == nil)
        #expect(installer.status() == .connected)
    }

    @Test func unreadableSettingsAreNeverTouched() throws {
        let broken = "{ \"model\": \"opus\", oops }"
        let (paths, bridge) = try makeHome(settings: broken)
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = StatusLineInstaller(paths: paths)
        if case .unreadable = installer.status() {} else { Issue.record("expected unreadable") }
        #expect(throws: (any Error).self) { try installer.connect(bridgeSource: bridge, now: t0) }
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == broken)
    }

    @Test func disconnectLeavesSomeoneElsesChangeAlone() throws {
        let (paths, bridge) = try makeHome(settings: original)
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = StatusLineInstaller(paths: paths)
        try installer.connect(bridgeSource: bridge, now: t0)
        let theirs = "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"my-own\"}\n}\n"
        try theirs.write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
        try installer.disconnect(now: t0.addingTimeInterval(1))
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == theirs)
    }
}
