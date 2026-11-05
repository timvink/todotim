import Foundation

/// A JSON value for the engine's line protocol. Built with literals, read with the typed
/// accessors, and serialized compactly with sorted keys (one value per line, never a raw newline).
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? {
        guard case .number(let n) = self, n.rounded() == n, abs(n) < 9.0e15 else { return nil }
        return Int(n)
    }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }

    /// `.string(s)`, or `.null` for nil.
    public static func string(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }
    public static func int(_ n: Int) -> JSON { .number(Double(n)) }

    // MARK: Serialization

    public func serialized() -> String {
        var out = ""
        out.reserveCapacity(256)
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += Self.format(n)
        case .string(let s): Self.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, key) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                o[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    private static func format(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n.rounded() == n, abs(n) < 9.0e15 { return String(Int64(n)) }
        return String(n)
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Parsing

    public struct ParseError: Error, LocalizedError {
        public var errorDescription: String? { "Invalid JSON" }
    }

    public static func parse(_ text: String) throws -> JSON {
        guard let data = text.data(using: .utf8) else { throw ParseError() }
        do {
            return try JSONDecoder().decode(JSON.self, from: data)
        } catch {
            throw ParseError()
        }
    }
}

extension JSON: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
