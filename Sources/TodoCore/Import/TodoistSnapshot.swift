import Foundation

/// A complete Todoist export: projects, sections, tasks and labels, in Todoist API v1 field names.
///
/// Decoding is lenient so a snapshot can come from the REST API v1, the older REST API v2 or a
/// hand-made file:
/// - every field except `id` is optional; ids may be strings or numbers;
/// - v2 names are accepted (`is_inbox_project`, `order`, `is_completed`, `collapsed`), and the Sync
///   API's `items` is accepted for `tasks`;
/// - an entry that cannot be decoded (for example one without an id) is skipped and counted in
///   `invalidEntries` instead of failing the whole snapshot.
/// Encoding always writes v1 names.
public struct TodoistSnapshot: Codable, Equatable, Sendable {
    public var projects: [TodoistProject]
    public var sections: [TodoistSection]
    public var tasks: [TodoistTask]
    public var labels: [TodoistLabel]
    /// Entries skipped while decoding. Not encoded.
    public var invalidEntries: Int = 0

    public init(projects: [TodoistProject] = [], sections: [TodoistSection] = [],
                tasks: [TodoistTask] = [], labels: [TodoistLabel] = []) {
        self.projects = projects; self.sections = sections; self.tasks = tasks; self.labels = labels
    }

    private enum CodingKeys: String, CodingKey { case projects, sections, tasks, labels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TodoistKey.self)
        var invalid = 0
        func list<T: Decodable>(_ keys: String...) throws -> [T] {
            for k in keys {
                let key = TodoistKey(k)
                guard c.contains(key), try !c.decodeNil(forKey: key) else { continue }
                let lossy = try c.decode(LossyList<T>.self, forKey: key)
                invalid += lossy.invalid
                return lossy.items
            }
            return []
        }
        projects = try list("projects")
        sections = try list("sections")
        tasks = try list("tasks", "items")
        labels = try list("labels")
        invalidEntries = invalid
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projects, forKey: .projects)
        try c.encode(sections, forKey: .sections)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(labels, forKey: .labels)
    }

    /// Decodes a snapshot file. Refuses files larger than `SyncLimits.maxSnapshotBytes`.
    public static func load(from url: URL) throws -> TodoistSnapshot {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SyncLimits.maxSnapshotBytes else {
            throw TodoistImportError.tooLarge("the file is larger than \(SyncLimits.maxSnapshotBytes / 1024 / 1024) MB")
        }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> TodoistSnapshot {
        do {
            return try JSONDecoder().decode(TodoistSnapshot.self, from: data)
        } catch {
            throw TodoistImportError.invalidSnapshot(String(describing: error))
        }
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

public enum TodoistImportError: LocalizedError, Equatable, Sendable {
    case invalidSnapshot(String)
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot(let r): "Not a valid Todoist snapshot: \(r)"
        case .tooLarge(let r): "Import refused: \(r)."
        }
    }
}

public struct TodoistProject: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Todoist color name ("berry_red", ...); v2 numeric colors (30–49) are converted on decode.
    public var color: String?
    public var parentId: String?
    public var childOrder: Int?
    public var orderKey: String?
    public var isInbox: Bool
    public var isArchived: Bool
    public var isDeleted: Bool

    public init(id: String, name: String, color: String? = nil, parentId: String? = nil, childOrder: Int? = nil,
                orderKey: String? = nil, isInbox: Bool = false, isArchived: Bool = false, isDeleted: Bool = false) {
        self.id = id; self.name = name; self.color = color; self.parentId = parentId; self.childOrder = childOrder
        self.orderKey = orderKey; self.isInbox = isInbox; self.isArchived = isArchived; self.isDeleted = isDeleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TodoistKey.self)
        id = try c.requiredID()
        name = c.string("name") ?? ""
        color = c.color("color")
        parentId = c.string("parent_id")
        childOrder = c.int("child_order", "order")
        orderKey = c.string("order_key")
        isInbox = c.bool("inbox_project", "is_inbox_project") ?? false
        isArchived = c.bool("is_archived") ?? false
        isDeleted = c.bool("is_deleted") ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TodoistKey.self)
        try c.encode(id, forKey: "id")
        try c.encode(name, forKey: "name")
        try c.encodeIfPresent(color, forKey: "color")
        try c.encodeIfPresent(parentId, forKey: "parent_id")
        try c.encodeIfPresent(childOrder, forKey: "child_order")
        try c.encodeIfPresent(orderKey, forKey: "order_key")
        try c.encode(isInbox, forKey: "inbox_project")
        try c.encode(isArchived, forKey: "is_archived")
        try c.encode(isDeleted, forKey: "is_deleted")
    }
}

public struct TodoistSection: Codable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var name: String
    public var sectionOrder: Int?
    public var orderKey: String?
    public var isArchived: Bool
    public var isDeleted: Bool

    public init(id: String, projectId: String, name: String, sectionOrder: Int? = nil, orderKey: String? = nil,
                isArchived: Bool = false, isDeleted: Bool = false) {
        self.id = id; self.projectId = projectId; self.name = name; self.sectionOrder = sectionOrder
        self.orderKey = orderKey; self.isArchived = isArchived; self.isDeleted = isDeleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TodoistKey.self)
        id = try c.requiredID()
        projectId = c.string("project_id") ?? ""
        name = c.string("name") ?? ""
        sectionOrder = c.int("section_order", "order")
        orderKey = c.string("order_key")
        isArchived = c.bool("is_archived") ?? false
        isDeleted = c.bool("is_deleted") ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TodoistKey.self)
        try c.encode(id, forKey: "id")
        try c.encode(projectId, forKey: "project_id")
        try c.encode(name, forKey: "name")
        try c.encodeIfPresent(sectionOrder, forKey: "section_order")
        try c.encodeIfPresent(orderKey, forKey: "order_key")
        try c.encode(isArchived, forKey: "is_archived")
        try c.encode(isDeleted, forKey: "is_deleted")
    }
}

public struct TodoistDue: Codable, Equatable, Sendable {
    /// "YYYY-MM-DD", or "YYYY-MM-DDTHH:MM:SS[Z]" for a due date with a time.
    public var date: String
    public var string: String?
    public var isRecurring: Bool

    public init(date: String, string: String? = nil, isRecurring: Bool = false) {
        self.date = date; self.string = string; self.isRecurring = isRecurring
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TodoistKey.self)
        // v2 had both `date` and `datetime`; `date` is always the calendar day.
        guard let d = c.string("date") ?? c.string("datetime") else {
            throw DecodingError.keyNotFound(TodoistKey("date"), .init(codingPath: c.codingPath, debugDescription: "due without date"))
        }
        date = d
        string = c.string("string")
        isRecurring = c.bool("is_recurring") ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TodoistKey.self)
        try c.encode(date, forKey: "date")
        try c.encodeIfPresent(string, forKey: "string")
        try c.encode(isRecurring, forKey: "is_recurring")
    }

    /// The calendar-day part ("YYYY-MM-DD") if `date` starts with a valid one. The time and
    /// timezone of a timed due date are dropped (TodoTim has no times).
    public var day: String? {
        let prefix = String(date.prefix(10))
        let parts = prefix.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              y > 0, (1...12).contains(m), (1...31).contains(d) else { return nil }
        if date.count > 10, date[date.index(date.startIndex, offsetBy: 10)] != "T" { return nil }
        return prefix
    }
}

public struct TodoistTask: Codable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var sectionId: String?
    public var parentId: String?
    public var content: String
    public var description: String
    /// Todoist priority: 4 is the most urgent (shown as p1), 1 is normal.
    public var priority: Int
    public var due: TodoistDue?
    /// Label names.
    public var labels: [String]
    public var checked: Bool
    public var isDeleted: Bool
    public var childOrder: Int?
    public var orderKey: String?
    public var isCollapsed: Bool
    /// ISO 8601.
    public var addedAt: String?
    public var completedAt: String?

    public init(id: String, projectId: String, sectionId: String? = nil, parentId: String? = nil, content: String,
                description: String = "", priority: Int = 1, due: TodoistDue? = nil, labels: [String] = [],
                checked: Bool = false, isDeleted: Bool = false, childOrder: Int? = nil, orderKey: String? = nil,
                isCollapsed: Bool = false, addedAt: String? = nil, completedAt: String? = nil) {
        self.id = id; self.projectId = projectId; self.sectionId = sectionId; self.parentId = parentId
        self.content = content; self.description = description; self.priority = priority; self.due = due
        self.labels = labels; self.checked = checked; self.isDeleted = isDeleted; self.childOrder = childOrder
        self.orderKey = orderKey; self.isCollapsed = isCollapsed; self.addedAt = addedAt; self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TodoistKey.self)
        id = try c.requiredID()
        projectId = c.string("project_id") ?? ""
        sectionId = c.string("section_id")
        parentId = c.string("parent_id")
        content = c.string("content") ?? ""
        description = c.string("description") ?? ""
        priority = c.int("priority") ?? 1
        due = c.value(TodoistDue.self, "due")
        labels = c.value([String].self, "labels") ?? []
        checked = c.bool("checked", "is_completed") ?? false
        isDeleted = c.bool("is_deleted") ?? false
        childOrder = c.int("child_order", "order")
        orderKey = c.string("order_key")
        isCollapsed = c.bool("is_collapsed", "collapsed") ?? false
        addedAt = c.string("added_at", "created_at")
        completedAt = c.string("completed_at")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TodoistKey.self)
        try c.encode(id, forKey: "id")
        try c.encode(projectId, forKey: "project_id")
        try c.encodeIfPresent(sectionId, forKey: "section_id")
        try c.encodeIfPresent(parentId, forKey: "parent_id")
        try c.encode(content, forKey: "content")
        try c.encode(description, forKey: "description")
        try c.encode(priority, forKey: "priority")
        try c.encodeIfPresent(due, forKey: "due")
        try c.encode(labels, forKey: "labels")
        try c.encode(checked, forKey: "checked")
        try c.encode(isDeleted, forKey: "is_deleted")
        try c.encodeIfPresent(childOrder, forKey: "child_order")
        try c.encodeIfPresent(orderKey, forKey: "order_key")
        try c.encode(isCollapsed, forKey: "is_collapsed")
        try c.encodeIfPresent(addedAt, forKey: "added_at")
        try c.encodeIfPresent(completedAt, forKey: "completed_at")
    }
}

public struct TodoistLabel: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String?
    public var order: Int?
    public var isDeleted: Bool

    public init(id: String, name: String, color: String? = nil, order: Int? = nil, isDeleted: Bool = false) {
        self.id = id; self.name = name; self.color = color; self.order = order; self.isDeleted = isDeleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TodoistKey.self)
        id = try c.requiredID()
        name = c.string("name") ?? ""
        color = c.color("color")
        order = c.int("order", "item_order")
        isDeleted = c.bool("is_deleted") ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TodoistKey.self)
        try c.encode(id, forKey: "id")
        try c.encode(name, forKey: "name")
        try c.encodeIfPresent(color, forKey: "color")
        try c.encodeIfPresent(order, forKey: "order")
        try c.encode(isDeleted, forKey: "is_deleted")
    }
}

// MARK: - Lenient decoding helpers

struct TodoistKey: CodingKey, ExpressibleByStringLiteral {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init(stringLiteral s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// An array that skips elements that fail to decode.
struct LossyList<T: Decodable>: Decodable {
    var items: [T] = []
    var invalid = 0

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) {
                items.append(v)
            } else {
                // A failed decode does not advance the container; consume the element explicitly.
                invalid += 1
                guard (try? c.decode(LossyScalar.self)) != nil else { break }
            }
        }
    }
}

/// Consumes any single JSON value.
private struct LossyScalar: Decodable {
    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            if c.decodeNil() { return }
            if (try? c.decode(Bool.self)) != nil { return }
            if (try? c.decode(Double.self)) != nil { return }
            if (try? c.decode(String.self)) != nil { return }
        }
        if var u = try? decoder.unkeyedContainer() {
            while !u.isAtEnd { _ = try u.decode(LossyScalar.self) }
            return
        }
        _ = try decoder.container(keyedBy: TodoistKey.self)
    }
}

extension KeyedDecodingContainer where K == TodoistKey {
    func requiredID() throws -> String {
        guard let id = string("id"), !id.isEmpty else {
            throw DecodingError.keyNotFound(TodoistKey("id"), .init(codingPath: codingPath, debugDescription: "missing id"))
        }
        return id
    }

    /// First present key as a string; numbers are converted (older APIs used numeric ids).
    func string(_ keys: String...) -> String? {
        for k in keys {
            let key = TodoistKey(k)
            if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
            if let v = try? decodeIfPresent(Int64.self, forKey: key) { return String(v) }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for k in keys {
            let key = TodoistKey(k)
            if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
            if let v = try? decodeIfPresent(Double.self, forKey: key), v.isFinite, abs(v) < 1e15 { return Int(v) }
            if let s = try? decodeIfPresent(String.self, forKey: key), let v = Int(s) { return v }
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? {
        for k in keys {
            let key = TodoistKey(k)
            if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v }
            if let v = try? decodeIfPresent(Int.self, forKey: key) { return v != 0 }
        }
        return nil
    }

    func value<T: Decodable>(_ type: T.Type, _ keys: String...) -> T? {
        for k in keys {
            if let v = try? decodeIfPresent(T.self, forKey: TodoistKey(k)) { return v }
        }
        return nil
    }

    /// A color name, or a v2-era numeric color id (30–49) converted to its name.
    func color(_ key: String) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: TodoistKey(key)) { return s }
        if let n = try? decodeIfPresent(Int.self, forKey: TodoistKey(key)) {
            let i = n - 30
            return TodoistColors.names.indices.contains(i) ? TodoistColors.names[i] : nil
        }
        return nil
    }
}

extension KeyedEncodingContainer where K == TodoistKey {
    mutating func encode<T: Encodable>(_ v: T, forKey k: String) throws { try encode(v, forKey: TodoistKey(k)) }
    mutating func encodeIfPresent<T: Encodable>(_ v: T?, forKey k: String) throws { try encodeIfPresent(v, forKey: TodoistKey(k)) }
}

/// Todoist's color names. They match TodoTim's palette keys (`Palette` in the app).
public enum TodoistColors {
    /// In Todoist's order; index + 30 is the v2-era numeric color id.
    public static let names = [
        "berry_red", "red", "orange", "yellow", "olive_green", "lime_green", "green", "mint_green", "teal",
        "sky_blue", "light_blue", "blue", "grape", "violet", "lavender", "magenta", "salmon", "charcoal",
        "grey", "taupe",
    ]
    private static let known = Set(names)

    /// Palette key for a Todoist color name; unknown or missing colors become "charcoal".
    /// Accepts "Olive Green", "olive-green", "gray" and "mint" as well.
    public static func paletteKey(_ todoist: String?) -> String {
        guard let raw = todoist?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return "charcoal" }
        let k = raw.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if known.contains(k) { return k }
        switch k {
        case "gray": return "grey"
        case "mint": return "mint_green"
        default: break
        }
        let squashed = k.replacingOccurrences(of: "_", with: "")
        return names.first { $0.replacingOccurrences(of: "_", with: "") == squashed } ?? "charcoal"
    }
}
