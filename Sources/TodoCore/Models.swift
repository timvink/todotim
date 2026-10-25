import Foundation

public typealias EntityID = String

public func newID() -> EntityID { UUID().uuidString.lowercased() }

/// Whether `id` is acceptable as an entity id or reference: 1–64 characters from
/// `[A-Za-z0-9_-]`. Ids become remote names (calendar `<id>/`, task `<id>.ics`; see
/// `docs/caldav.md`), so anything that could form a path (separators, dot segments, control
/// characters) is rejected. App-created ids are lowercase UUIDs; the inbox is `inbox`.
public func isValidEntityID(_ id: String) -> Bool {
    let utf8 = id.utf8
    guard (1...64).contains(utf8.count) else { return false }
    for c in utf8 {
        switch c {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            continue
        default:
            return false
        }
    }
    return true
}

/// Todoist-style priority. p1 is the most urgent, p4 is the default ("no priority").
public enum Priority: Int, Codable, CaseIterable, Hashable, Sendable {
    case p1 = 1, p2 = 2, p3 = 3, p4 = 4
}

/// A due date without time. Stored as a local calendar date ("yyyy-MM-dd") so it
/// does not shift when the machine changes timezone.
public struct DueDate: Codable, Hashable, Sendable {
    public var date: String

    public init(date: String) { self.date = date }

    public init(_ day: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        self.date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Start of the day in `calendar`'s timezone.
    public func day(calendar: Calendar = .current) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Common fields used by sync to merge entities (last-writer-wins on `updatedAt`).
/// Deletes are tombstones (`deleted = true`) so they propagate to other devices.
public protocol SyncEntity: Codable, Identifiable, Hashable, Sendable where ID == EntityID {
    var id: EntityID { get }
    var updatedAt: Date { get set }
    var deleted: Bool { get set }
}

public struct Project: SyncEntity {
    public var id: EntityID
    public var name: String
    /// Key into `ProjectColor` (e.g. "red", "blue").
    public var color: String
    public var order: Double
    public var isInbox: Bool
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: EntityID = newID(), name: String, color: String = "charcoal", order: Double,
                isInbox: Bool = false, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.color = color; self.order = order
        self.isInbox = isInbox; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Section: SyncEntity {
    public var id: EntityID
    public var projectId: EntityID
    public var name: String
    public var order: Double
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: EntityID = newID(), projectId: EntityID, name: String, order: Double,
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.projectId = projectId; self.name = name; self.order = order
        self.updatedAt = updatedAt; self.deleted = deleted
    }
}

/// Named `TodoTask` to avoid clashing with Swift Concurrency's `Task`.
public struct TodoTask: SyncEntity {
    public var id: EntityID
    public var projectId: EntityID
    /// nil = task is in the project's top area (no section).
    public var sectionId: EntityID?
    /// nil = top-level task; otherwise this is a subtask. A subtask always has the
    /// same projectId and sectionId as its parent.
    public var parentId: EntityID?
    public var content: String
    public var description: String
    public var priority: Priority
    public var due: DueDate?
    /// Label names (not ids), like Todoist.
    public var labels: [String]
    public var isCompleted: Bool
    public var completedAt: Date?
    /// Sort key among siblings (same project/section/parent).
    public var order: Double
    /// Whether subtasks are hidden in the list.
    public var collapsed: Bool
    /// iCalendar RRULE value (e.g. "FREQ=WEEKLY;INTERVAL=2") of a repeating task, as synced from
    /// CalDAV. Completing such a task moves its due date to the next occurrence (`Recurrence`).
    public var recurrence: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: EntityID = newID(), projectId: EntityID, sectionId: EntityID? = nil,
                parentId: EntityID? = nil, content: String, description: String = "",
                priority: Priority = .p4, due: DueDate? = nil, labels: [String] = [],
                isCompleted: Bool = false, completedAt: Date? = nil, order: Double,
                collapsed: Bool = false, recurrence: String? = nil, createdAt: Date = Date(),
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.projectId = projectId; self.sectionId = sectionId; self.parentId = parentId
        self.content = content; self.description = description; self.priority = priority
        self.due = due; self.labels = labels; self.isCompleted = isCompleted
        self.completedAt = completedAt; self.order = order; self.collapsed = collapsed
        self.recurrence = recurrence
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deleted = deleted
    }
}

public struct Label: SyncEntity {
    public var id: EntityID
    public var name: String
    public var color: String
    public var order: Double
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: EntityID = newID(), name: String, color: String = "charcoal", order: Double,
                updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.color = color; self.order = order
        self.updatedAt = updatedAt; self.deleted = deleted
    }
}

/// The complete local state. Includes tombstones; use `TodoStore` accessors for live data.
public struct Database: Codable, Equatable, Sendable {
    public var projects: [EntityID: Project] = [:]
    public var sections: [EntityID: Section] = [:]
    public var tasks: [EntityID: TodoTask] = [:]
    public var labels: [EntityID: Label] = [:]

    public init() {}
}
