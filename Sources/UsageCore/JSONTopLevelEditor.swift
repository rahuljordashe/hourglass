import Foundation

/// Edits one top-level key of a JSON object *in place*, leaving every other byte of the file
/// untouched (key order, formatting, other settings). Used so that changing Claude Code's
/// `statusLine` produces a one-entry diff rather than a reformatted file.
public enum JSONTopLevelEditor {
    public enum EditError: Error, Equatable {
        case notAnObject
        case malformed(String)
        case resultInvalid
    }

    struct Entry {
        var key: String
        var keyStart: String.Index
        var valueStart: String.Index
        var valueEnd: String.Index
    }

    struct Parsed {
        var entries: [Entry]
        var openBrace: String.Index
        var closeBrace: String.Index
    }

    /// The raw JSON text of a top-level value, or nil if the key is absent.
    public static func rawValue(forKey key: String, in text: String) throws -> String? {
        let parsed = try parse(text)
        guard let entry = parsed.entries.last(where: { $0.key == key }) else { return nil }
        return String(text[entry.valueStart..<entry.valueEnd])
    }

    /// Sets `key` to `rawJSON` (already-serialised JSON), replacing the existing value or appending a new entry.
    public static func setValue(_ rawJSON: String, forKey key: String, in text: String) throws -> String {
        let parsed = try parse(text)
        var result = text
        if let entry = parsed.entries.last(where: { $0.key == key }) {
            result.replaceSubrange(entry.valueStart..<entry.valueEnd, with: rawJSON)
        } else {
            let indent = detectIndent(text, parsed: parsed)
            let quotedKey = try quote(key)
            if let last = parsed.entries.last {
                result.insert(contentsOf: ",\n\(indent)\(quotedKey): \(rawJSON)", at: last.valueEnd)
            } else {
                result.replaceSubrange(parsed.openBrace...parsed.closeBrace, with: "{\n\(indent)\(quotedKey): \(rawJSON)\n}")
            }
        }
        try validate(result)
        return result
    }

    /// Removes `key` and its value, fixing up the surrounding comma. A no-op if the key is absent.
    public static func removeKey(_ key: String, in text: String) throws -> String {
        let parsed = try parse(text)
        guard let index = parsed.entries.lastIndex(where: { $0.key == key }) else { return text }
        var result = text
        let entry = parsed.entries[index]
        if index + 1 < parsed.entries.count {
            // Not last: remove from this key up to the next key.
            result.removeSubrange(entry.keyStart..<parsed.entries[index + 1].keyStart)
        } else if index > 0 {
            // Last of several: remove from the end of the previous value (taking its comma with it).
            result.removeSubrange(parsed.entries[index - 1].valueEnd..<entry.valueEnd)
        } else {
            // The only entry.
            result.replaceSubrange(parsed.openBrace...parsed.closeBrace, with: "{}")
        }
        try validate(result)
        return result
    }

    /// Serialises a JSON-compatible value as pretty JSON nested one level inside a top-level object,
    /// in the same `"key": value` style Claude Code writes (two-space indent, no space before colons).
    public static func serialise(_ value: Any, indent: String = "  ") throws -> String {
        try serialise(value, level: 1, indent: indent)
    }

    static func serialise(_ value: Any, level: Int, indent: String) throws -> String {
        let pad = String(repeating: indent, count: level + 1)
        let closePad = String(repeating: indent, count: level)
        switch value {
        case let dict as [String: Any]:
            if dict.isEmpty { return "{}" }
            let order = ["type", "command", "padding", "refreshInterval"]
            let keys = dict.keys.sorted { a, b in
                let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
                return ia != ib ? ia < ib : a < b
            }
            let body = try keys.map { "\(pad)\(try quote($0)): \(try serialise(dict[$0]!, level: level + 1, indent: indent))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(closePad)}"
        case let array as [Any]:
            if array.isEmpty { return "[]" }
            let body = try array.map { "\(pad)\(try serialise($0, level: level + 1, indent: indent))" }
            return "[\n" + body.joined(separator: ",\n") + "\n\(closePad)]"
        case let string as String:
            return try quote(string)
        case is NSNull:
            return "null"
        default:
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - Internals

    static func quote(_ s: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    static func validate(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else { throw EditError.resultInvalid }
    }

    static func detectIndent(_ text: String, parsed: Parsed) -> String {
        guard let first = parsed.entries.first else { return "  " }
        var i = first.keyStart
        var indent = ""
        while i > text.startIndex {
            let prev = text.index(before: i)
            let c = text[prev]
            if c == " " || c == "\t" { indent.insert(c, at: indent.startIndex); i = prev } else { break }
        }
        return indent.isEmpty ? "  " : indent
    }

    static func parse(_ text: String) throws -> Parsed {
        var scanner = Scanner(text: text)
        scanner.skipWhitespace()
        guard scanner.peek() == "{" else { throw EditError.notAnObject }
        let open = scanner.index
        scanner.advance()
        var entries: [Entry] = []
        scanner.skipWhitespace()
        if scanner.peek() == "}" {
            let close = scanner.index
            return Parsed(entries: [], openBrace: open, closeBrace: close)
        }
        while true {
            scanner.skipWhitespace()
            let keyStart = scanner.index
            let key = try scanner.readString()
            scanner.skipWhitespace()
            guard scanner.peek() == ":" else { throw EditError.malformed("expected ':' after key \(key)") }
            scanner.advance()
            scanner.skipWhitespace()
            let valueStart = scanner.index
            try scanner.skipValue()
            let valueEnd = scanner.index
            entries.append(Entry(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))
            scanner.skipWhitespace()
            switch scanner.peek() {
            case ",": scanner.advance()
            case "}": return Parsed(entries: entries, openBrace: open, closeBrace: scanner.index)
            default: throw EditError.malformed("expected ',' or '}'")
            }
        }
    }

    struct Scanner {
        let text: String
        var index: String.Index

        init(text: String) {
            self.text = text
            self.index = text.startIndex
        }

        func peek() -> Character? { index < text.endIndex ? text[index] : nil }
        mutating func advance() { index = text.index(after: index) }

        mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace { advance() }
        }

        mutating func readString() throws -> String {
            guard peek() == "\"" else { throw EditError.malformed("expected string") }
            let start = index
            try skipString()
            let raw = String(text[start..<index])
            guard let data = "[\(raw)]".data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
                  let s = arr.first
            else { throw EditError.malformed("bad string") }
            return s
        }

        mutating func skipString() throws {
            advance() // opening quote
            while let c = peek() {
                advance()
                if c == "\\" {
                    guard peek() != nil else { break }
                    advance()
                } else if c == "\"" {
                    return
                }
            }
            throw EditError.malformed("unterminated string")
        }

        mutating func skipValue() throws {
            guard let c = peek() else { throw EditError.malformed("unexpected end") }
            switch c {
            case "\"":
                try skipString()
            case "{", "[":
                var depth = 0
                while let ch = peek() {
                    if ch == "\"" { try skipString(); continue }
                    if ch == "{" || ch == "[" { depth += 1 }
                    if ch == "}" || ch == "]" {
                        depth -= 1
                        if depth == 0 { advance(); return }
                    }
                    advance()
                }
                throw EditError.malformed("unterminated container")
            default:
                // number, true, false, null
                while let ch = peek(), !(ch == "," || ch == "}" || ch == "]" || ch.isWhitespace) { advance() }
            }
        }
    }
}
