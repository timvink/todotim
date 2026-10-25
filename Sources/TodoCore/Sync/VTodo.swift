import Foundation

/// A task as read from one CalDAV resource: the `TodoTask` plus what only the resource knows.
struct VTodoTask: Equatable, Sendable {
    var task: TodoTask
    var uid: String
    /// Section name and order from the `X-TODOTIM-SECTION` parameters (see `docs/caldav.md`).
    var sectionName: String?
    var sectionOrder: Double?
}

/// Mapping between `TodoTask` and a VTODO (`docs/caldav.md`). Reading never fails on content
/// TodoTim does not understand; writing patches only the properties TodoTim owns, so alarms,
/// recurrence details, start dates and other clients' X- properties survive.
enum VTodo {
    static let prodID = "-//TodoTim//TodoTim//EN"

    /// Namespace for ids derived from UIDs and calendar names that are not valid entity ids.
    /// Never change it: derived ids are stored.
    static let idNamespace = UUID(uuidString: "0f6f0c1e-5a43-4bd4-9a0f-2f4c2b1e7a55")!

    /// The entity id for a UID: the UID itself when it passes `isValidEntityID`, else a stable
    /// name-based UUID.
    static func taskID(forUID uid: String) -> EntityID {
        isValidEntityID(uid) ? uid : uuidV5(namespace: idNamespace, name: "uid:" + uid)
    }

    /// Largest UID accepted (longer ones make the resource unreadable).
    static let maxUIDLength = 1_000

    /// Seconds between 1970-01-01 and 2001-01-01, the epoch of `X-APPLE-SORT-ORDER` defaults.
    static let appleEpoch: TimeInterval = 978_307_200

    // MARK: - Read

    /// The task in `ics`, or nil when it holds no usable VTODO (no VCALENDAR, no UID, malformed).
    /// The master VTODO (without RECURRENCE-ID) is used. Remote text is clipped to `SyncLimits`.
    static func read(_ ics: String, projectId: EntityID, calendar: Calendar = .current) -> VTodoTask? {
        guard let root = try? ICalendar.parse(ics), root.name == "VCALENDAR",
              let todo = master(root) else { return nil }
        guard let uid = todo.first("UID")?.value.trimmingCharacters(in: .whitespaces), !uid.isEmpty,
              uid.utf8.count <= maxUIDLength else { return nil }
        func text(_ name: String, _ limit: Int) -> String {
            clip(todo.first(name).map { ICalendar.unescapeText($0.value) } ?? "", limit)
        }
        func instant(_ name: String) -> Date? {
            todo.first(name).flatMap { ICalendar.instant($0) }.map(TodoStore.millisecondPrecision)
        }
        let created = instant("CREATED") ?? instant("DTSTAMP") ?? instant("LAST-MODIFIED") ?? Date(timeIntervalSince1970: 0)
        let modified = instant("LAST-MODIFIED") ?? instant("DTSTAMP") ?? created

        let status = todo.first("STATUS")?.value.uppercased()
        let completed = status == "COMPLETED" || status == "CANCELLED" || (status == nil && todo.first("COMPLETED") != nil)

        var labels: [String] = []
        for p in todo.all("CATEGORIES") {
            for name in ICalendar.splitTextList(p.value) {
                let n = clip(name.trimmingCharacters(in: .whitespaces), SyncLimits.maxNameLength)
                if !n.isEmpty, !labels.contains(n), labels.count < SyncLimits.maxLabelsPerTask { labels.append(n) }
            }
        }

        let parentUID = todo.all("RELATED-TO").first { isParent($0) }
            .map { $0.value.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.utf8.count > maxUIDLength ? nil : $0 }

        let sectionLine = todo.first("X-TODOTIM-SECTION")
        let sectionID = sectionLine.map { $0.value.trimmingCharacters(in: .whitespaces) }.flatMap { isValidEntityID($0) ? $0 : nil }

        var task = TodoTask(
            id: taskID(forUID: uid), projectId: projectId, sectionId: sectionID,
            parentId: parentUID.map(taskID(forUID:)),
            content: text("SUMMARY", SyncLimits.maxContentLength),
            description: text("DESCRIPTION", SyncLimits.maxDescriptionLength),
            priority: priority(todo.first("PRIORITY")?.value),
            due: todo.first("DUE").flatMap(ICalendar.DateValue.init).map { $0.localDate(calendar: calendar) },
            labels: labels, isCompleted: completed,
            completedAt: completed ? (instant("COMPLETED") ?? modified) : nil,
            order: order(todo, created: created),
            collapsed: todo.first("X-OC-HIDESUBTASKS")?.value.trimmingCharacters(in: .whitespaces) == "1",
            recurrence: todo.first("RRULE").map { clip($0.value, maxRuleLength) },
            createdAt: created, updatedAt: modified)
        if task.parentId == task.id { task.parentId = nil }
        return VTodoTask(task: task, uid: uid,
                         sectionName: sectionID == nil ? nil : sectionLine?.param("X-NAME").map { clip(normalizeNewlines($0), SyncLimits.maxNameLength) },
                         sectionOrder: sectionID == nil ? nil : sectionLine?.param("X-ORDER").flatMap(finiteDouble))
    }

    static let maxRuleLength = 1_000

    private static func master(_ root: ICalComponent) -> ICalComponent? {
        let todos = root.components.filter { $0.name == "VTODO" }
        return todos.first { $0.first("RECURRENCE-ID") == nil } ?? todos.first
    }

    private static func isParent(_ p: ICalProperty) -> Bool {
        let type = p.param("RELTYPE")?.uppercased()
        return type == nil || type == "PARENT"
    }

    /// RFC 5545 priority: 1–4 high, 5 medium, 6–9 low, 0 or absent none.
    static func priority(_ value: String?) -> Priority {
        switch value.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) ?? 0 {
        case 1...4: return .p1
        case 5: return .p2
        case 6...9: return .p3
        default: return .p4
        }
    }

    static func icalPriority(_ p: Priority) -> String {
        switch p {
        case .p1: "1"
        case .p2: "5"
        case .p3: "9"
        case .p4: "0"
        }
    }

    /// `X-TODOTIM-ORDER` when it agrees with `X-APPLE-SORT-ORDER` (equal to its floor) or that is
    /// absent; else `X-APPLE-SORT-ORDER` (another client reordered); else CREATED in seconds since
    /// 2001, so tasks without an order sort after ordered ones by age.
    static func order(_ todo: ICalComponent, created: Date) -> Double {
        let precise = todo.first("X-TODOTIM-ORDER").flatMap { finiteDouble($0.value) }
        let apple = todo.first("X-APPLE-SORT-ORDER").flatMap { Int64($0.value.trimmingCharacters(in: .whitespaces)) }
        if let precise, apple == nil || apple == appleOrder(precise) { return precise }
        if let apple { return Double(apple) }
        return (created.timeIntervalSince1970 - appleEpoch).rounded(.down)
    }

    /// The integer `X-APPLE-SORT-ORDER` written for an order: its floor (clamped).
    static func appleOrder(_ order: Double) -> Int64 {
        let f = order.rounded(.down)
        if f >= 9.2e18 { return Int64.max }
        if f <= -9.2e18 { return Int64.min }
        return Int64(f)
    }

    static func finiteDouble(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
    }

    /// Shortest representation that reads back as the same Double.
    static func format(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : "\(d)"
    }

    /// CR LF and CR become LF (a parameter cannot hold a CR, so names are compared without it).
    static func normalizeNewlines(_ s: String) -> String {
        guard s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        s.utf8.count > max && s.count > max ? String(s.prefix(max)) : s
    }

    // MARK: - Write

    /// What TodoTim writes, compared between the resource and the local task to decide whether
    /// (and which properties) to write. Times are compared in whole seconds, like iCalendar.
    struct Fields: Equatable {
        var content: String
        var description: String
        var priority: Priority
        var due: String?
        var isCompleted: Bool
        var completedAt: Int64?
        var parentId: EntityID?
        var order: Double
        var collapsed: Bool
        var labels: [String]
        var sectionId: EntityID?
        var sectionName: String?
        var sectionOrder: Double?
        var recurrence: String?
        var createdAt: Int64

        init(_ t: TodoTask, section: Section?) {
            content = t.content; description = t.description; priority = t.priority; due = t.due?.date
            isCompleted = t.isCompleted
            completedAt = t.isCompleted ? t.completedAt.map(seconds) : nil
            parentId = t.parentId; order = t.order; collapsed = t.collapsed; labels = t.labels
            sectionId = section?.id; sectionName = section?.name; sectionOrder = section?.order
            recurrence = t.recurrence; createdAt = seconds(t.createdAt)
        }

        init(_ v: VTodoTask) {
            self.init(v.task, section: nil)
            sectionId = v.task.sectionId; sectionName = v.sectionName; sectionOrder = v.sectionOrder
        }
    }

    static func seconds(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) }

    /// A new calendar object for `task`. `parentUID` is the parent's UID; `section` the task's
    /// (live) section, whose name and order are copied into `X-TODOTIM-SECTION`.
    static func make(_ task: TodoTask, uid: String, parentUID: String?, section: Section?) -> String {
        var todo = ICalComponent("VTODO", properties: [ICalProperty("UID", value: uid)])
        apply(task, parentUID: parentUID, section: section, changed: nil, old: nil, to: &todo)
        let root = ICalComponent("VCALENDAR", properties: [ICalProperty("VERSION", value: "2.0"),
                                                             ICalProperty("PRODID", value: prodID)],
                                 components: [todo])
        return ICalendar.serialize(root)
    }

    /// `ics` with the master VTODO's owned properties rewritten where `task` differs from `old`
    /// (the resource as read). Returns nil when nothing differs or `ics` cannot be parsed.
    static func patch(_ ics: String, old: VTodoTask, to task: TodoTask, parentUID: String?, section: Section?) -> String? {
        let before = Fields(old), after = Fields(task, section: section)
        guard before != after, var root = try? ICalendar.parse(ics),
              let index = root.components.firstIndex(where: { $0.name == "VTODO" && $0.first("RECURRENCE-ID") == nil })
                ?? root.components.firstIndex(where: { $0.name == "VTODO" }) else { return nil }
        apply(task, parentUID: parentUID, section: section, changed: (before, after), old: root.components[index],
              to: &root.components[index])
        return ICalendar.serialize(root)
    }

    /// Sets the owned properties of `todo`; with `changed`, only those whose field differs.
    /// `old` is the VTODO before the change (for DATE-TIME due dates and DTSTART).
    private static func apply(_ t: TodoTask, parentUID: String?, section: Section?, changed: (Fields, Fields)?,
                              old: ICalComponent?, to todo: inout ICalComponent) {
        func differs<V: Equatable>(_ key: KeyPath<Fields, V>) -> Bool {
            guard let (a, b) = changed else { return true }
            return a[keyPath: key] != b[keyPath: key]
        }
        let stamp = ICalendar.utcString(t.updatedAt)
        if differs(\.createdAt) || todo.first("CREATED") == nil {
            todo.set(ICalProperty("CREATED", value: ICalendar.utcString(t.createdAt)))
        }
        todo.set(ICalProperty("DTSTAMP", value: stamp))
        todo.set(ICalProperty("LAST-MODIFIED", value: stamp))
        if differs(\.content) { todo.set(ICalProperty("SUMMARY", value: ICalendar.escapeText(t.content))) }
        if differs(\.description) {
            if t.description.isEmpty { todo.remove("DESCRIPTION") }
            else { todo.set(ICalProperty("DESCRIPTION", value: ICalendar.escapeText(t.description))) }
        }
        if differs(\.priority) { todo.set(ICalProperty("PRIORITY", value: icalPriority(t.priority))) }
        if differs(\.due) { setDue(t.due, old: old, to: &todo) }
        if differs(\.isCompleted) || differs(\.completedAt) {
            if t.isCompleted {
                todo.set(ICalProperty("STATUS", value: "COMPLETED"))
                todo.set(ICalProperty("COMPLETED", value: ICalendar.utcString(t.completedAt ?? t.updatedAt)))
                todo.set(ICalProperty("PERCENT-COMPLETE", value: "100"))
            } else {
                todo.set(ICalProperty("STATUS", value: "NEEDS-ACTION"))
                todo.remove("COMPLETED")
                todo.remove("PERCENT-COMPLETE")
            }
        }
        if differs(\.parentId) {
            todo.properties.removeAll { $0.name == "RELATED-TO" && isParent($0) }
            if let parentUID { todo.properties.append(ICalProperty("RELATED-TO", params: [("RELTYPE", "PARENT")], value: parentUID)) }
        }
        if differs(\.order) {
            todo.set(ICalProperty("X-APPLE-SORT-ORDER", value: String(appleOrder(t.order))))
            todo.set(ICalProperty("X-TODOTIM-ORDER", value: format(t.order)))
        }
        if differs(\.collapsed) {
            if t.collapsed { todo.set(ICalProperty("X-OC-HIDESUBTASKS", value: "1")) } else { todo.remove("X-OC-HIDESUBTASKS") }
        }
        if differs(\.labels) {
            todo.remove("CATEGORIES")
            if !t.labels.isEmpty {
                todo.properties.append(ICalProperty("CATEGORIES", value: t.labels.map(ICalendar.escapeText).joined(separator: ",")))
            }
        }
        if differs(\.sectionId) || differs(\.sectionName) || differs(\.sectionOrder) {
            if let section {
                todo.set(ICalProperty("X-TODOTIM-SECTION", params: [("X-NAME", section.name), ("X-ORDER", format(section.order))],
                                      value: section.id))
            } else {
                todo.remove("X-TODOTIM-SECTION")
            }
        }
        if differs(\.recurrence) {
            if let rule = t.recurrence { todo.set(ICalProperty("RRULE", value: rule)) } else { todo.remove("RRULE") }
        }
    }

    /// TodoTim writes `DUE;VALUE=DATE`. A DATE-TIME due date from another client keeps its time
    /// of day and is moved by the same number of days; DTSTART (if any) moves along, so the
    /// span between start and due stays the same.
    private static func setDue(_ due: DueDate?, old: ICalComponent?, to todo: inout ICalComponent) {
        guard let due else {
            todo.remove("DUE")
            return
        }
        let oldDueProp = old?.first("DUE")
        let oldValue = oldDueProp.flatMap(ICalendar.DateValue.init)
        var delta: Int?
        if let oldValue, let from = oldValue.localDate(calendar: .current).day(), let to = due.day() {
            delta = Calendar.current.dateComponents([.day], from: from, to: to).day
        }
        if let oldDueProp, let oldValue, !oldValue.isDate, let delta {
            todo.set(oldValue.shifted(days: delta).property("DUE", keeping: oldDueProp))
        } else {
            todo.set(ICalendar.dateProperty("DUE", due))
        }
        if let delta, delta != 0, let start = todo.first("DTSTART"), let value = ICalendar.DateValue(start) {
            todo.set(value.shifted(days: delta).property("DTSTART", keeping: start))
        }
    }
}
