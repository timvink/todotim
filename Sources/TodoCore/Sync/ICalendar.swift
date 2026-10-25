import Foundation

/// One content line of an iCalendar object (RFC 5545 §3.1), e.g.
/// `DUE;VALUE=DATE:20261103`. `value` is kept as written (TEXT values stay escaped), so
/// properties TodoTim does not own round-trip byte for byte (apart from line folding).
struct ICalProperty: Equatable, Sendable {
    /// Upper-cased, e.g. "DUE" or "X-APPLE-SORT-ORDER".
    var name: String
    /// In order of appearance; names upper-cased, values unquoted and RFC 6868-decoded.
    var params: [(name: String, value: String)]
    var value: String

    init(_ name: String, params: [(name: String, value: String)] = [], value: String) {
        self.name = name; self.params = params; self.value = value
    }

    func param(_ name: String) -> String? { params.first { $0.name == name }?.value }

    static func == (a: ICalProperty, b: ICalProperty) -> Bool {
        a.name == b.name && a.value == b.value && a.params.count == b.params.count
            && zip(a.params, b.params).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
}

/// A component (`BEGIN:X` … `END:X`) with its properties and subcomponents, in order.
struct ICalComponent: Equatable, Sendable {
    var name: String
    var properties: [ICalProperty] = []
    var components: [ICalComponent] = []

    init(_ name: String, properties: [ICalProperty] = [], components: [ICalComponent] = []) {
        self.name = name; self.properties = properties; self.components = components
    }

    func first(_ name: String) -> ICalProperty? { properties.first { $0.name == name } }
    func all(_ name: String) -> [ICalProperty] { properties.filter { $0.name == name } }

    mutating func remove(_ name: String) { properties.removeAll { $0.name == name } }

    /// Replaces the first property called `property.name` (keeping its position) and removes
    /// any others with that name; appends it when there is none.
    mutating func set(_ property: ICalProperty) {
        if let i = properties.firstIndex(where: { $0.name == property.name }) {
            properties[i] = property
            var k = properties.count - 1
            while k > i {
                if properties[k].name == property.name { properties.remove(at: k) }
                k -= 1
            }
        } else {
            properties.append(property)
        }
    }
}

/// Bounded iCalendar parser and serializer. Calendar data comes from the server (and from any
/// client that writes to it), so it is treated as hostile: size, line count, nesting and
/// component count are capped, and anything malformed is rejected as a whole.
enum ICalendar {
    enum Failure: Error, Equatable {
        case tooLarge
        case malformed(String)
    }

    /// Largest accepted calendar object (one task) in bytes.
    static let maxBytes = 1 << 20
    static let maxLines = 20_000
    static let maxDepth = 8
    static let maxComponents = 1_000
    static let maxParams = 64

    /// Parses one iCalendar object; the result is the outermost component (normally VCALENDAR).
    static func parse(_ text: String) throws -> ICalComponent {
        guard text.utf8.count <= maxBytes else { throw Failure.tooLarge }
        // Unfold (RFC 5545 §3.1): a line starting with a space or tab continues the previous one.
        // Servers may deliver LF instead of CRLF (e.g. inside XML), so both are accepted.
        var lines: [Substring] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            var line = raw
            if line.hasSuffix("\r") { line = line.dropLast() }
            if let first = line.first, first == " " || first == "\t" {
                guard !lines.isEmpty else { throw Failure.malformed("continuation without a line") }
                lines[lines.count - 1] = Substring(lines[lines.count - 1] + line.dropFirst())
            } else if !line.isEmpty {
                lines.append(line)
                guard lines.count <= maxLines else { throw Failure.tooLarge }
            }
        }
        var stack: [ICalComponent] = []
        var root: ICalComponent?
        var componentCount = 0
        for line in lines {
            let p = try parseLine(line)
            if p.name == "BEGIN" {
                guard root == nil else { throw Failure.malformed("content after the end") }
                componentCount += 1
                guard stack.count < maxDepth, componentCount <= maxComponents else { throw Failure.tooLarge }
                stack.append(ICalComponent(p.value.uppercased()))
            } else if p.name == "END" {
                guard let done = stack.popLast(), done.name == p.value.uppercased() else {
                    throw Failure.malformed("unbalanced END:\(p.value)")
                }
                if stack.isEmpty { root = done } else { stack[stack.count - 1].components.append(done) }
            } else {
                guard !stack.isEmpty else { throw Failure.malformed("property outside a component") }
                stack[stack.count - 1].properties.append(p)
            }
        }
        guard stack.isEmpty, let root else { throw Failure.malformed("missing END") }
        return root
    }

    /// `NAME;P=V;P2="a:b":value`.
    static func parseLine(_ line: Substring) throws -> ICalProperty {
        var i = line.startIndex
        func isNameChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-") }
        while i < line.endIndex, isNameChar(line[i]) { i = line.index(after: i) }
        let name = line[line.startIndex..<i].uppercased()
        guard !name.isEmpty, i < line.endIndex else { throw Failure.malformed("bad content line") }
        var params: [(name: String, value: String)] = []
        while line[i] == ";" {
            i = line.index(after: i)
            let start = i
            while i < line.endIndex, isNameChar(line[i]) { i = line.index(after: i) }
            let pname = line[start..<i].uppercased()
            guard !pname.isEmpty, i < line.endIndex, line[i] == "=" else { throw Failure.malformed("bad parameter") }
            i = line.index(after: i)
            // A parameter may hold a comma-separated list; quoted parts may contain ; : ,
            var value = ""
            while i < line.endIndex, line[i] != ";", line[i] != ":" {
                if line[i] == "\"" {
                    i = line.index(after: i)
                    guard let close = line[i...].firstIndex(of: "\"") else { throw Failure.malformed("unterminated quote") }
                    value += line[i..<close]
                    i = line.index(after: close)
                } else {
                    value.append(line[i])
                    i = line.index(after: i)
                }
            }
            params.append((pname, decodeParam(value)))
            guard params.count <= maxParams, i < line.endIndex else { throw Failure.malformed("bad parameters") }
        }
        guard line[i] == ":" else { throw Failure.malformed("missing ':'") }
        return ICalProperty(name, params: params, value: String(line[line.index(after: i)...]))
    }

    static func serialize(_ c: ICalComponent) -> String {
        var out = ""
        func emit(_ c: ICalComponent) {
            out += fold("BEGIN:\(c.name)")
            for p in c.properties { out += fold(line(for: p)) }
            for sub in c.components { emit(sub) }
            out += fold("END:\(c.name)")
        }
        emit(c)
        return out
    }

    static func line(for p: ICalProperty) -> String {
        var s = p.name
        for (name, value) in p.params {
            let encoded = encodeParam(value)
            let needsQuotes = encoded.contains { $0 == ":" || $0 == ";" || $0 == "," } || encoded.isEmpty
            s += ";\(name)=" + (needsQuotes ? "\"\(encoded)\"" : encoded)
        }
        return s + ":" + p.value
    }

    /// Folds at 75 octets (RFC 5545 §3.1) without splitting a UTF-8 sequence; ends with CRLF.
    static func fold(_ line: String) -> String {
        var out = ""
        var count = 0
        for ch in line.unicodeScalars {
            let n = String(ch).utf8.count
            if count + n > 75 {
                out += "\r\n "
                count = 1
            }
            out.unicodeScalars.append(ch)
            count += n
        }
        return out + "\r\n"
    }

    // MARK: - Values

    /// TEXT escaping (RFC 5545 §3.3.11).
    static func escapeText(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case ";": out += "\\;"
            case ",": out += "\\,"
            case "\n", "\r\n": out += "\\n"
            case "\r": continue
            default: out.append(c)
            }
        }
        return out
    }

    static func unescapeText(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for c in s {
            if escaped {
                switch c {
                case "n", "N": out.append("\n")
                default: out.append(c)  // \\ \; \, and anything unexpected
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Splits a TEXT list (e.g. CATEGORIES) on unescaped commas and unescapes each item.
    static func splitTextList(_ s: String) -> [String] {
        var items: [String] = []
        var current = ""
        var escaped = false
        for c in s {
            if escaped { current.append("\\"); current.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "," { items.append(current); current = "" }
            else { current.append(c) }
        }
        items.append(current)
        return items.map(unescapeText)
    }

    /// RFC 6868 parameter encoding: ^n newline, ^' double quote, ^^ caret. (RFC 5545 itself
    /// cannot put a double quote in a parameter value.)
    static func encodeParam(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "^": out += "^^"
            case "\"": out += "^'"
            case "\n", "\r\n": out += "^n"
            case "\r": continue
            default: out.append(c)
            }
        }
        return out
    }

    static func decodeParam(_ s: String) -> String {
        guard s.contains("^") else { return s }
        var out = ""
        var caret = false
        for c in s {
            if caret {
                switch c {
                case "n": out.append("\n")
                case "'": out.append("\"")
                case "^": out.append("^")
                default: out.append("^"); out.append(c)
                }
                caret = false
            } else if c == "^" {
                caret = true
            } else {
                out.append(c)
            }
        }
        if caret { out.append("^") }
        return out
    }

    // MARK: - Dates

    /// A DATE or DATE-TIME value as written: `yyyyMMdd`, optionally `THHmmss` and `Z`, plus
    /// the TZID parameter.
    struct DateValue: Equatable, Sendable {
        var year: Int, month: Int, day: Int
        /// "THHmmss" or "THHmmssZ"; nil for a DATE.
        var timePart: String?
        var tzid: String?

        init?(_ p: ICalProperty) {
            let v = p.value.trimmingCharacters(in: .whitespaces)
            let chars = Array(v.utf8)
            guard chars.count >= 8, chars.prefix(8).allSatisfy({ (48...57).contains($0) }),
                  let y = Int(v.prefix(4)), let m = Int(v.dropFirst(4).prefix(2)), let d = Int(v.dropFirst(6).prefix(2)),
                  (1...12).contains(m), (1...31).contains(d) else { return nil }
            year = y; month = m; day = d
            if chars.count == 8 {
                timePart = nil
            } else {
                let t = String(v.dropFirst(8))
                let digits = t.dropFirst().prefix(6)
                guard t.hasPrefix("T"), digits.count == 6, digits.allSatisfy(\.isNumber),
                      t.count == 7 || (t.count == 8 && t.hasSuffix("Z")) else { return nil }
                timePart = t
            }
            tzid = p.param("TZID")
        }

        var isDate: Bool { timePart == nil }

        /// The date in `calendar`'s timezone: a DATE or floating time as written; a UTC or TZID
        /// time converted (an unknown TZID is read as floating).
        func localDate(calendar: Calendar) -> DueDate {
            guard let t = timePart else { return DueDate(date: String(format: "%04d-%02d-%02d", year, month, day)) }
            let digits = Array(t.dropFirst().prefix(6)).map { Int(String($0))! }
            let comps = DateComponents(year: year, month: month, day: day, hour: digits[0] * 10 + digits[1],
                                       minute: digits[2] * 10 + digits[3], second: digits[4] * 10 + digits[5])
            var zone: TimeZone?
            if t.hasSuffix("Z") { zone = TimeZone(identifier: "UTC") } else if let tzid { zone = TimeZone(identifier: tzid) }
            guard let zone else { return DueDate(date: String(format: "%04d-%02d-%02d", year, month, day)) }
            var source = Calendar(identifier: .gregorian)
            source.timeZone = zone
            guard let instant = source.date(from: comps) else {
                return DueDate(date: String(format: "%04d-%02d-%02d", year, month, day))
            }
            return DueDate(instant, calendar: calendar)
        }

        /// The same value moved by `days` calendar days (time of day and TZID unchanged).
        func shifted(days: Int) -> DateValue {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = TimeZone(identifier: "UTC")!
            var copy = self
            if let d = gregorian.date(from: DateComponents(year: year, month: month, day: day)),
               let moved = gregorian.date(byAdding: .day, value: days, to: d) {
                let c = gregorian.dateComponents([.year, .month, .day], from: moved)
                copy.year = c.year!; copy.month = c.month!; copy.day = c.day!
            }
            return copy
        }

        func property(_ name: String, keeping original: ICalProperty) -> ICalProperty {
            var p = original
            p.name = name
            p.value = String(format: "%04d%02d%02d", year, month, day) + (timePart ?? "")
            return p
        }
    }

    /// `DUE;VALUE=DATE:20261103`.
    static func dateProperty(_ name: String, _ due: DueDate) -> ICalProperty {
        ICalProperty(name, params: [("VALUE", "DATE")], value: due.date.replacingOccurrences(of: "-", with: ""))
    }

    /// UTC DATE-TIME `20261103T101500Z` (whole seconds).
    static func utcString(_ date: Date) -> String {
        let secs = Int64((date.timeIntervalSince1970).rounded(.down))
        var days = secs / 86400
        var rem = secs % 86400
        if rem < 0 { rem += 86400; days -= 1 }
        let (y, m, d) = MillisecondDate.civil(fromDays: days)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", Int(y), Int(m), Int(d), Int(rem / 3600), Int(rem / 60 % 60), Int(rem % 60))
    }

    /// Parses a DATE-TIME as an instant: UTC (`Z`), TZID (when known) or floating (read in
    /// `floating`). A DATE is midnight UTC. nil when invalid.
    static func instant(_ p: ICalProperty, floating: TimeZone = .current) -> Date? {
        guard let v = DateValue(p) else { return nil }
        var comps = DateComponents(year: v.year, month: v.month, day: v.day)
        var zone = TimeZone(identifier: "UTC")!
        if let t = v.timePart {
            let digits = Array(t.dropFirst().prefix(6)).map { Int(String($0))! }
            comps.hour = digits[0] * 10 + digits[1]
            comps.minute = digits[2] * 10 + digits[3]
            comps.second = digits[4] * 10 + digits[5]
            if !t.hasSuffix("Z") { zone = v.tzid.flatMap(TimeZone.init(identifier:)) ?? floating }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: comps)
    }
}
