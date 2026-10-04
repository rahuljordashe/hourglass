import Foundation

/// Small Codable files the app owns (latest usage, read ledger). Written atomically, so a crash
/// mid-write never leaves half a file; a missing or unreadable file reads as nil.
public enum JSONFile {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? PlanUsageCoding.decoder().decode(type, from: data)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PlanUsageCoding.encoder().encode(value).write(to: url, options: .atomic)
    }
}
