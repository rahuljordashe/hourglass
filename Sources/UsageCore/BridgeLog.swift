import Foundation

/// A small, self-rotating local log for the bridge. Kept under ~512 KB across two files.
public enum BridgeLog {
    public static let maxBytes = 256 * 1024

    public static func append(_ line: String, paths: NotchPaths, now: Date = Date()) {
        let fm = FileManager.default
        let url = paths.bridgeLog
        try? fm.createDirectory(at: paths.logDirectory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withInternetDateTime])
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
