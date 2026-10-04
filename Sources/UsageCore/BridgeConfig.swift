import Foundation

/// Written by the app at setup, read by the bridge on every run.
public struct BridgeConfig: Codable, Equatable, Sendable {
    /// The status line command the user had before, run by the bridge so their status line looks unchanged.
    public var chainedCommand: String?
    /// The exact JSON text of the original `statusLine` value, restored verbatim on disconnect.
    /// Nil means there was no `statusLine` entry at all.
    public var originalStatusLineJSON: String?
    public var installedAt: Date?
    public var settingsPath: String?

    public init(chainedCommand: String? = nil, originalStatusLineJSON: String? = nil, installedAt: Date? = nil, settingsPath: String? = nil) {
        self.chainedCommand = chainedCommand
        self.originalStatusLineJSON = originalStatusLineJSON
        self.installedAt = installedAt
        self.settingsPath = settingsPath
    }

    enum CodingKeys: String, CodingKey {
        case chainedCommand = "chained_command"
        case originalStatusLineJSON = "original_status_line_json"
        case installedAt = "installed_at"
        case settingsPath = "settings_path"
    }

    public static func load(from url: URL) -> BridgeConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SnapshotCoding.decoder().decode(BridgeConfig.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SnapshotCoding.encoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Reads and writes `usage.json` safely when several Claude Code sessions run the bridge at once.
public enum SnapshotFile {
    public static func read(_ url: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? SnapshotCoding.decode(data)
    }

    /// Runs `body` while holding an exclusive lock, then writes the result atomically
    /// (write to a temporary file, then rename), so readers never see a half-written file.
    @discardableResult
    public static func update(
        _ paths: NotchPaths,
        _ body: (UsageSnapshot) -> UsageSnapshot
    ) throws -> UsageSnapshot {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)

        let fd = open(paths.lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        let current = read(paths.usageFile) ?? .empty
        let next = body(current)
        if next != current {
            try SnapshotCoding.encode(next).write(to: paths.usageFile, options: .atomic)
        }
        return next
    }
}
