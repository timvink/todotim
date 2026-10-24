import Foundation

/// Minimal TOML reader for `~/.todotim.toml`: `[table]` headers, `key = value` pairs with
/// basic/literal strings, booleans, integers and floats, and `#` comments. Arrays, inline
/// tables and multi-line strings are not supported (the config does not need them).
public enum TOML {
    public enum Value: Equatable, Sendable {
        case string(String), bool(Bool), int(Int), double(Double)
    }

    public struct ParseError: Error, LocalizedError, Equatable {
        public var line: Int
        public var message: String
        public var errorDescription: String? { "Line \(line): \(message)" }
    }

    /// Returns values keyed by dotted path, e.g. `["sync.username": .string("tim")]`.
    public static func parse(_ text: String) throws -> [String: Value] {
        var result: [String: Value] = [:]
        var table = ""
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            let n = i + 1
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    throw ParseError(line: n, message: "Unsupported table header")
                }
                table = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                guard isValidKey(table) else { throw ParseError(line: n, message: "Invalid table name") }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw ParseError(line: n, message: "Expected key = value") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else { throw ParseError(line: n, message: "Invalid key '\(key)'") }
            let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let value = parseValue(rawValue) else {
                throw ParseError(line: n, message: "Unsupported value for '\(key)'")
            }
            let path = table.isEmpty ? key : "\(table).\(key)"
            guard result[path] == nil else { throw ParseError(line: n, message: "Duplicate key '\(path)'") }
            result[path] = value
        }
        return result
    }

    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    /// Removes a trailing `# comment`, ignoring `#` inside strings.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for (offset, c) in line.enumerated() {
            if escaped { escaped = false; continue }
            if quote == "\"" && c == "\\" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "#" { return String(line.prefix(offset)) }
        }
        return line
    }

    private static func parseValue(_ s: String) -> Value? {
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            let inner = String(s.dropFirst().dropLast())
            return inner.contains("'") ? nil : .string(inner)
        }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return unescape(String(s.dropFirst().dropLast())).map(Value.string)
        }
        let digits = s.replacingOccurrences(of: "_", with: "")
        if let i = Int(digits) { return .int(i) }
        if let d = Double(digits) { return .double(d) }
        return nil
    }

    private static func unescape(_ s: String) -> String? {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\"" { return nil }
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            default: return nil
            }
        }
        return out
    }
}
