import Foundation
import XCTest

/// A parsed JSON value from the shared golden files in `fixtures/` (format: fixtures/README.md).
enum FixtureJSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FixtureJSON])
    case object([String: FixtureJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([FixtureJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: FixtureJSON].self)) }
    }

    subscript(key: String) -> FixtureJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var isNull: Bool { self == .null }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var int: Int? { number.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [FixtureJSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: FixtureJSON] { if case .object(let o) = self { return o }; return [:] }
    var strings: [String] { array.compactMap(\.string) }

    /// The string at `key`, or nil when missing or JSON null.
    func str(_ key: String) -> String? { self[key]?.string }
}

/// Locates and reads `fixtures/` relative to this source file, so it works under `swift test` on
/// macOS and Linux without SwiftPM resources.
enum Fixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TodoCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("fixtures", isDirectory: true)

    static func url(_ path: String) -> URL { directory.appendingPathComponent(path) }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    static func json(_ path: String) throws -> FixtureJSON {
        try JSONDecoder().decode(FixtureJSON.self, from: Data(contentsOf: url(path)))
    }

    /// File names in `fixtures/<sub>` ending in `suffix`, sorted.
    static func files(_ sub: String, suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(sub).path).filter { $0.hasSuffix(suffix) }.sorted()
    }

    /// A gregorian calendar in `zone` with `locale`.
    static func calendar(zone: String = "Europe/Amsterdam", locale: String = "en_US") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        cal.locale = Locale(identifier: locale)
        return cal
    }

    /// Noon of a `yyyy-MM-dd` day in `calendar` (the fixed "now" of the parser fixtures).
    static func noon(_ day: String, _ calendar: Calendar) -> Date {
        let p = day.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    /// `2026-11-01T12:00:00Z`.
    static func time(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: s) else { fatalError("bad fixture time \(s)") }
        return d
    }

    static func timeString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
