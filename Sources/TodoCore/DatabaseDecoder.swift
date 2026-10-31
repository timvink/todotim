import Foundation

/// Fast path for reading `db.json`: parses the UTF-8 bytes straight into a `Database`, several
/// times faster than `JSONDecoder` (which builds a keyed container per object and boxes every
/// value), so a large database loads sooner at launch.
///
/// It is strict and conservative: it returns nil for anything it does not decode exactly like
/// `JSONCoding.decoder` would — invalid JSON or UTF-8, a missing or mistyped field, a duplicate
/// key, a priority out of range, a date in a format other than the one `LocalPersistence.save`
/// writes, a number it cannot parse exactly. The caller then decodes with `JSONDecoder`, so
/// whether a file counts as corrupt is still decided by `JSONDecoder` alone. Unknown keys are
/// skipped, as the synthesized `Decodable` conformances do.
enum DatabaseDecoder {
    static func decode(_ data: Data) -> Database? {
        data.withUnsafeBytes { raw -> Database? in
            var reader = JSONBytes(UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                                       count: raw.count))
            guard let db = reader.database() else { return nil }
            reader.skipWhitespace()
            return reader.atEnd ? db : nil
        }
    }
}

/// A cursor over JSON text. Every parsing method returns nil (or false) on anything unexpected.
private struct JSONBytes {
    let bytes: UnsafeBufferPointer<UInt8>
    var i = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    var atEnd: Bool { i == bytes.count }

    // MARK: Structure

    mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    /// Skips whitespace and consumes `c` when it is next.
    mutating func consume(_ c: UInt8) -> Bool {
        skipWhitespace()
        guard i < bytes.count, bytes[i] == c else { return false }
        i += 1
        return true
    }

    /// Calls `field` for each key of an object; `field` must consume the value and return false
    /// on failure. Duplicate keys are left to `field` (entities reject them, see `Seen`).
    mutating func object(_ field: (inout JSONBytes, String) -> Bool) -> Bool {
        guard consume(UInt8(ascii: "{")) else { return false }
        if consume(UInt8(ascii: "}")) { return true }
        repeat {
            skipWhitespace()
            guard let key = string(), consume(UInt8(ascii: ":")) else { return false }
            skipWhitespace()
            guard field(&self, key) else { return false }
        } while consume(UInt8(ascii: ","))
        return consume(UInt8(ascii: "}"))
    }

    /// Like `object`, with the keys as `FieldKey`s (no string per key). A key with escapes is
    /// declined (it could spell a known field), and so is a non-ASCII one (it would have to be
    /// checked for valid UTF-8, which JSONDecoder requires; field names are ASCII).
    mutating func fields(_ field: (inout JSONBytes, FieldKey) -> Bool) -> Bool {
        guard consume(UInt8(ascii: "{")) else { return false }
        if consume(UInt8(ascii: "}")) { return true }
        repeat {
            skipWhitespace()
            guard let (start, end, simple, ascii) = scanString(), simple, ascii, consume(UInt8(ascii: ":")) else { return false }
            skipWhitespace()
            guard field(&self, FieldKey(UnsafeBufferPointer(rebasing: bytes[start..<end]))) else { return false }
        } while consume(UInt8(ascii: ","))
        return consume(UInt8(ascii: "}"))
    }

    /// `{ "<id>": <entity>, … }` into a dictionary; nil for a duplicate key.
    mutating func dictionary<T>(_ entity: (inout JSONBytes) -> T?) -> [EntityID: T]? {
        var out: [EntityID: T] = [:]
        let ok = object { r, key in
            guard let value = entity(&r), out.updateValue(value, forKey: key) == nil else { return false }
            return true
        }
        return ok ? out : nil
    }

    /// Consumes `null` when it is next.
    mutating func null() -> Bool {
        skipWhitespace()
        return literal("null")
    }

    private mutating func literal(_ word: StaticString) -> Bool {
        let n = word.utf8CodeUnitCount
        guard bytes.count - i >= n else { return false }
        let p = word.utf8Start
        for k in 0..<n where bytes[i + k] != p[k] { return false }
        i += n
        return true
    }

    // MARK: Values

    mutating func bool() -> Bool? {
        skipWhitespace()
        if literal("true") { return true }
        if literal("false") { return false }
        return nil
    }

    /// A JSON string. Escapes are decoded; invalid UTF-8, unescaped control characters and lone
    /// surrogates are rejected, as `JSONDecoder` rejects them.
    mutating func string() -> String? {
        guard let (start, end, simple, ascii) = scanString() else { return nil }
        let slice = UnsafeBufferPointer(rebasing: bytes[start..<end])
        if simple {
            return ascii ? String(decoding: slice, as: UTF8.self) : String(validating: slice, as: UTF8.self)
        }
        return unescape(slice)
    }

    /// The bytes of a string without escapes (for dates); nil when it has any.
    mutating func plainStringBytes() -> UnsafeBufferPointer<UInt8>? {
        guard let (start, end, simple, _) = scanString(), simple else { return nil }
        return UnsafeBufferPointer(rebasing: bytes[start..<end])
    }

    /// Finds the closing quote of a string starting at `i`. Returns the content range, whether it
    /// has no escapes, and whether it is all ASCII.
    private mutating func scanString() -> (Int, Int, Bool, Bool)? {
        guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { return nil }
        let start = i + 1
        var k = start
        var simple = true
        var high: UInt8 = 0
        while k < bytes.count {
            let c = bytes[k]
            if c == UInt8(ascii: "\"") {
                i = k + 1
                return (start, k, simple, high < 0x80)
            }
            if c == UInt8(ascii: "\\") {
                simple = false
                k += 2  // the escaped character is checked by `unescape`
                continue
            }
            if c < 0x20 { return nil }
            high |= c
            k += 1
        }
        return nil
    }

    private func unescape(_ s: UnsafeBufferPointer<UInt8>) -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var k = 0
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= s.count else { return nil }
            var v: UInt32 = 0
            for j in at..<(at + 4) {
                let c = s[j]
                let d: UInt8
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
                default: return nil
                }
                v = v << 4 | UInt32(d)
            }
            return v
        }
        while k < s.count {
            let c = s[k]
            guard c == UInt8(ascii: "\\") else {
                out.append(c)
                k += 1
                continue
            }
            guard k + 1 < s.count else { return nil }
            switch s[k + 1] {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                guard var scalar = hex4(k + 2) else { return nil }
                k += 6
                if (0xD800..<0xDC00).contains(scalar) {
                    // High surrogate: must be followed by an escaped low surrogate.
                    guard k + 1 < s.count, s[k] == UInt8(ascii: "\\"), s[k + 1] == UInt8(ascii: "u"),
                          let low = hex4(k + 2), (0xDC00..<0xE000).contains(low) else { return nil }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    k += 6
                } else if (0xDC00..<0xE000).contains(scalar) {
                    return nil
                }
                guard let u = Unicode.Scalar(scalar) else { return nil }
                out.append(contentsOf: UTF8.encode(u)!)
                continue
            default:
                return nil
            }
            k += 2
        }
        return out.withUnsafeBufferPointer { String(validating: $0, as: UTF8.self) }
    }

    /// A JSON number as a `Double`, parsed like `JSONDecoder` (correctly rounded); nil for
    /// anything that is not a valid JSON number or not finite.
    mutating func double() -> Double? {
        skipWhitespace()
        let start = i
        var k = i
        func digits() -> Int {
            let d0 = k
            while k < bytes.count, bytes[k] >= UInt8(ascii: "0"), bytes[k] <= UInt8(ascii: "9") { k += 1 }
            return k - d0
        }
        if k < bytes.count, bytes[k] == UInt8(ascii: "-") { k += 1 }
        let intStart = k
        let intDigits = digits()
        // JSON: at least one digit, and no leading zero unless the integer part is 0.
        guard intDigits > 0, intDigits == 1 || bytes[intStart] != UInt8(ascii: "0") else { return nil }
        var isInteger = true
        if k < bytes.count, bytes[k] == UInt8(ascii: ".") {
            k += 1
            guard digits() > 0 else { return nil }
            isInteger = false
        }
        if k < bytes.count, bytes[k] == UInt8(ascii: "e") || bytes[k] == UInt8(ascii: "E") {
            k += 1
            if k < bytes.count, bytes[k] == UInt8(ascii: "+") || bytes[k] == UInt8(ascii: "-") { k += 1 }
            guard digits() > 0 else { return nil }
            isInteger = false
        }
        i = k
        if isInteger, intDigits <= 15 {
            // Exact in a Double; also the common case (orders 1, 2, 3…).
            var v: Int64 = 0
            for j in intStart..<k { v = v * 10 + Int64(bytes[j] - UInt8(ascii: "0")) }
            return bytes[start] == UInt8(ascii: "-") ? -Double(v) : Double(v)
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<k]), as: UTF8.self)
        guard let v = Double(text), v.isFinite else { return nil }
        if v == 0 {
            // Underflow to zero (e.g. 1e-400): leave it to JSONDecoder.
            for j in start..<k {
                let c = bytes[j]
                if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { break }
                if c >= UInt8(ascii: "1"), c <= UInt8(ascii: "9") { return nil }
            }
        }
        return v
    }

    /// The priority field: exactly one of the digits 1–4 (anything else goes to `JSONDecoder`).
    mutating func priority() -> Priority? {
        skipWhitespace()
        guard i < bytes.count else { return nil }
        let c = bytes[i]
        guard c >= UInt8(ascii: "1"), c <= UInt8(ascii: "4") else { return nil }
        if i + 1 < bytes.count {
            switch bytes[i + 1] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"): return nil
            default: break
            }
        }
        i += 1
        return Priority(rawValue: Int(c - UInt8(ascii: "0")))
    }

    /// A date as `LocalPersistence.save` writes it (`yyyy-MM-ddTHH:mm:ss.SSS`, UTC).
    mutating func date() -> Date? {
        skipWhitespace()
        guard let b = plainStringBytes() else { return nil }
        return MillisecondDate.parse(utf8: b)
    }

    mutating func stringArray() -> [String]? {
        guard consume(UInt8(ascii: "[")) else { return nil }
        var out: [String] = []
        if consume(UInt8(ascii: "]")) { return out }
        repeat {
            skipWhitespace()
            guard let s = string() else { return nil }
            out.append(s)
        } while consume(UInt8(ascii: ","))
        return consume(UInt8(ascii: "]")) ? out : nil
    }

    /// Skips any valid JSON value (for unknown keys).
    mutating func skipValue(depth: Int = 0) -> Bool {
        guard depth < 64 else { return false }
        skipWhitespace()
        guard i < bytes.count else { return false }
        switch bytes[i] {
        case UInt8(ascii: "\""):
            return string() != nil
        case UInt8(ascii: "{"):
            return object { r, _ in r.skipValue(depth: depth + 1) }
        case UInt8(ascii: "["):
            i += 1
            if consume(UInt8(ascii: "]")) { return true }
            repeat {
                guard skipValue(depth: depth + 1) else { return false }
            } while consume(UInt8(ascii: ","))
            return consume(UInt8(ascii: "]"))
        case UInt8(ascii: "t"), UInt8(ascii: "f"):
            return bool() != nil
        case UInt8(ascii: "n"):
            return null()
        default:
            return double() != nil
        }
    }

    // MARK: Entities (field names and optionality as in the synthesized `Codable` conformances)

    mutating func database() -> Database? {
        var db = Database()
        var seen = Seen()
        let ok = fields { r, key in
            switch key {
            case .projects:
                guard seen.insert(0), let v = r.dictionary({ $0.project() }) else { return false }
                db.projects = v
            case .sections:
                guard seen.insert(1), let v = r.dictionary({ $0.section() }) else { return false }
                db.sections = v
            case .tasks:
                guard seen.insert(2), let v = r.dictionary({ $0.task() }) else { return false }
                db.tasks = v
            case .labels:
                guard seen.insert(3), let v = r.dictionary({ $0.label() }) else { return false }
                db.labels = v
            default:
                return r.skipValue()
            }
            return true
        }
        return ok && seen.has(0, 1, 2, 3) ? db : nil
    }

    mutating func project() -> Project? {
        var id: String?, name: String?, color: String?, order: Double?, isInbox: Bool?, updatedAt: Date?, deleted: Bool?
        var seen = Seen()
        let ok = fields { r, key in
            switch key {
            case .id: guard seen.insert(0) else { return false }; id = r.string(); return id != nil
            case .name: guard seen.insert(1) else { return false }; name = r.string(); return name != nil
            case .color: guard seen.insert(2) else { return false }; color = r.string(); return color != nil
            case .order: guard seen.insert(3) else { return false }; order = r.double(); return order != nil
            case .isInbox: guard seen.insert(4) else { return false }; isInbox = r.bool(); return isInbox != nil
            case .updatedAt: guard seen.insert(5) else { return false }; updatedAt = r.date(); return updatedAt != nil
            case .deleted: guard seen.insert(6) else { return false }; deleted = r.bool(); return deleted != nil
            default: return r.skipValue()
            }
        }
        guard ok, let id, let name, let color, let order, let isInbox, let updatedAt, let deleted else { return nil }
        return Project(id: id, name: name, color: color, order: order, isInbox: isInbox, updatedAt: updatedAt, deleted: deleted)
    }

    mutating func section() -> Section? {
        var id: String?, projectId: String?, name: String?, order: Double?, updatedAt: Date?, deleted: Bool?
        var seen = Seen()
        let ok = fields { r, key in
            switch key {
            case .id: guard seen.insert(0) else { return false }; id = r.string(); return id != nil
            case .projectId: guard seen.insert(1) else { return false }; projectId = r.string(); return projectId != nil
            case .name: guard seen.insert(2) else { return false }; name = r.string(); return name != nil
            case .order: guard seen.insert(3) else { return false }; order = r.double(); return order != nil
            case .updatedAt: guard seen.insert(4) else { return false }; updatedAt = r.date(); return updatedAt != nil
            case .deleted: guard seen.insert(5) else { return false }; deleted = r.bool(); return deleted != nil
            default: return r.skipValue()
            }
        }
        guard ok, let id, let projectId, let name, let order, let updatedAt, let deleted else { return nil }
        return Section(id: id, projectId: projectId, name: name, order: order, updatedAt: updatedAt, deleted: deleted)
    }

    mutating func label() -> Label? {
        var id: String?, name: String?, color: String?, order: Double?, updatedAt: Date?, deleted: Bool?
        var seen = Seen()
        let ok = fields { r, key in
            switch key {
            case .id: guard seen.insert(0) else { return false }; id = r.string(); return id != nil
            case .name: guard seen.insert(1) else { return false }; name = r.string(); return name != nil
            case .color: guard seen.insert(2) else { return false }; color = r.string(); return color != nil
            case .order: guard seen.insert(3) else { return false }; order = r.double(); return order != nil
            case .updatedAt: guard seen.insert(4) else { return false }; updatedAt = r.date(); return updatedAt != nil
            case .deleted: guard seen.insert(5) else { return false }; deleted = r.bool(); return deleted != nil
            default: return r.skipValue()
            }
        }
        guard ok, let id, let name, let color, let order, let updatedAt, let deleted else { return nil }
        return Label(id: id, name: name, color: color, order: order, updatedAt: updatedAt, deleted: deleted)
    }

    /// `DueDate` (`{"date": "yyyy-MM-dd"}`) or null.
    mutating func dueDate() -> DueDate?? {
        if null() { return .some(nil) }
        var date: String?
        var seen = Seen()
        let ok = fields { r, key in
            switch key {
            case .date: guard seen.insert(0) else { return false }; date = r.string(); return date != nil
            default: return r.skipValue()
            }
        }
        guard ok, let date else { return nil }
        return .some(DueDate(date: date))
    }

    /// An optional string field: a string, or null for nil.
    mutating func optionalString() -> String?? {
        if null() { return .some(nil) }
        guard let s = string() else { return nil }
        return .some(s)
    }

    mutating func optionalDate() -> Date?? {
        if null() { return .some(nil) }
        guard let d = date() else { return nil }
        return .some(d)
    }

    mutating func task() -> TodoTask? {
        var id: String?, projectId: String?, content: String?, description: String?
        var sectionId: String?, parentId: String?, recurrence: String?
        var priority: Priority?, due: DueDate?, labels: [String]?
        var isCompleted: Bool?, completedAt: Date?, order: Double?, collapsed: Bool?
        var createdAt: Date?, updatedAt: Date?, deleted: Bool?
        var seen = Seen()
        let ok = fields { r, key in
            switch key {
            case .id: guard seen.insert(0) else { return false }; id = r.string(); return id != nil
            case .projectId: guard seen.insert(1) else { return false }; projectId = r.string(); return projectId != nil
            case .sectionId:
                guard seen.insert(2), let v = r.optionalString() else { return false }
                sectionId = v
            case .parentId:
                guard seen.insert(3), let v = r.optionalString() else { return false }
                parentId = v
            case .content: guard seen.insert(4) else { return false }; content = r.string(); return content != nil
            case .description: guard seen.insert(5) else { return false }; description = r.string(); return description != nil
            case .priority: guard seen.insert(6) else { return false }; priority = r.priority(); return priority != nil
            case .due:
                guard seen.insert(7), let v = r.dueDate() else { return false }
                due = v
            case .labels: guard seen.insert(8) else { return false }; labels = r.stringArray(); return labels != nil
            case .isCompleted: guard seen.insert(9) else { return false }; isCompleted = r.bool(); return isCompleted != nil
            case .completedAt:
                guard seen.insert(10), let v = r.optionalDate() else { return false }
                completedAt = v
            case .order: guard seen.insert(11) else { return false }; order = r.double(); return order != nil
            case .collapsed: guard seen.insert(12) else { return false }; collapsed = r.bool(); return collapsed != nil
            case .recurrence:
                guard seen.insert(13), let v = r.optionalString() else { return false }
                recurrence = v
            case .createdAt: guard seen.insert(14) else { return false }; createdAt = r.date(); return createdAt != nil
            case .updatedAt: guard seen.insert(15) else { return false }; updatedAt = r.date(); return updatedAt != nil
            case .deleted: guard seen.insert(16) else { return false }; deleted = r.bool(); return deleted != nil
            default: return r.skipValue()
            }
            return true
        }
        guard ok, let id, let projectId, let content, let description, let priority, let labels, let isCompleted,
              let order, let collapsed, let createdAt, let updatedAt, let deleted else { return nil }
        return TodoTask(id: id, projectId: projectId, sectionId: sectionId, parentId: parentId, content: content,
                        description: description, priority: priority, due: due, labels: labels,
                        isCompleted: isCompleted, completedAt: completedAt, order: order, collapsed: collapsed,
                        recurrence: recurrence, createdAt: createdAt, updatedAt: updatedAt, deleted: deleted)
    }
}

/// Which fields of an object were seen (to reject duplicate keys and check required ones).
private struct Seen {
    private var bits: UInt32 = 0

    /// False when `field` was already seen.
    mutating func insert(_ field: Int) -> Bool {
        let bit: UInt32 = 1 << field
        guard bits & bit == 0 else { return false }
        bits |= bit
        return true
    }

    func has(_ fields: Int...) -> Bool { fields.allSatisfy { bits & (1 << $0) != 0 } }
}

/// An object key packed into 16 bytes, for comparing with the known field names without making
/// a string. Keys longer than 16 bytes cannot be field names and become `unknown`. JSON strings
/// cannot hold a raw NUL, so the zero padding cannot make two different keys equal.
private struct FieldKey: Equatable {
    private var lo: UInt64 = 0
    private var hi: UInt64 = 0

    init(_ b: UnsafeBufferPointer<UInt8>) {
        guard b.count <= 16 else { self = .unknown; return }
        for k in 0..<b.count {
            if k < 8 { lo |= UInt64(b[k]) << (8 * UInt64(k)) } else { hi |= UInt64(b[k]) << (8 * UInt64(k - 8)) }
        }
    }

    private init(_ s: StaticString) {
        self.init(UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
    }

    private init(lo: UInt64, hi: UInt64) {
        self.lo = lo
        self.hi = hi
    }

    /// Matches no field (0xFF never occurs in UTF-8).
    static let unknown = FieldKey(lo: .max, hi: .max)

    static let projects = FieldKey("projects"), sections = FieldKey("sections"), tasks = FieldKey("tasks")
    static let labels = FieldKey("labels"), id = FieldKey("id"), name = FieldKey("name"), color = FieldKey("color")
    static let order = FieldKey("order"), isInbox = FieldKey("isInbox"), updatedAt = FieldKey("updatedAt")
    static let deleted = FieldKey("deleted"), projectId = FieldKey("projectId"), date = FieldKey("date")
    static let sectionId = FieldKey("sectionId"), parentId = FieldKey("parentId"), content = FieldKey("content")
    static let description = FieldKey("description"), priority = FieldKey("priority"), due = FieldKey("due")
    static let isCompleted = FieldKey("isCompleted"), completedAt = FieldKey("completedAt")
    static let collapsed = FieldKey("collapsed"), recurrence = FieldKey("recurrence"), createdAt = FieldKey("createdAt")
}
