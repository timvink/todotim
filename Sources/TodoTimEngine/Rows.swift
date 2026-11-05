import Foundation
import TodoCore

/// What the list shows: a project (the inbox is one), the open tasks with a label, or search results.
public enum ViewSpec: Equatable, Sendable {
    case project(EntityID)
    case label(String)
    case search(String)

    init?(_ json: JSON?) {
        guard let json else { return nil }
        switch json["kind"]?.string {
        case "project": if let id = json["id"]?.string { self = .project(id) } else { return nil }
        case "label": if let name = json["name"]?.string { self = .label(name) } else { return nil }
        case "search": self = .search(json["query"]?.string ?? "")
        default: return nil
        }
    }
}

/// Builds the rows of a list (flattened like the Mac app's `DisplayBuilder`) and the sidebar, as
/// JSON for the UI. Only structure and display fields: the UI does not need tombstones, orders or
/// timestamps.
@MainActor
struct RowBuilder {
    let store: TodoStore
    let now: Date
    let calendar: Calendar
    var showCompleted: Bool
    var collapsedSections: Set<EntityID>
    private(set) var rows: [JSON] = []
    private let labelColors: [String: String]

    init(store: TodoStore, now: Date, calendar: Calendar, showCompleted: Bool, collapsedSections: Set<EntityID>) {
        self.store = store
        self.now = now
        self.calendar = calendar
        self.showCompleted = showCompleted
        self.collapsedSections = collapsedSections
        var colors: [String: String] = [:]
        for l in store.labels { colors[l.name] = ProjectColor.hex(l.color) }
        labelColors = colors
    }

    // MARK: Views

    mutating func build(_ view: ViewSpec) -> [JSON] {
        rows = []
        switch view {
        case .project(let pid): buildProject(pid)
        case .label(let name): buildGroups(store.tasks(withLabel: name), empty: "No open tasks with this label.")
        case .search(let query):
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(["type": "message", "key": "message", "message": "Type to search task names and descriptions."])
            } else {
                buildGroups(store.search(query), empty: "No results for “\(query)”")
            }
        }
        return rows
    }

    private mutating func buildProject(_ pid: EntityID) {
        guard store.project(pid) != nil else { return }
        if store.openTaskCount(projectId: pid) == 0 {
            rows.append(["type": "empty", "key": "empty", "projectId": .string(pid)])
        }
        appendArea(pid, nil)
        for s in store.sections(in: pid) {
            let collapsed = collapsedSections.contains(s.id)
            rows.append([
                "type": "section", "key": .string("section:" + s.id), "id": .string(s.id), "projectId": .string(pid),
                "name": .string(s.name), "count": .int(store.openTaskCount(projectId: pid, sectionId: s.id)),
                "collapsed": .bool(collapsed),
            ])
            if !collapsed { appendArea(pid, s.id) }
        }
    }

    private mutating func appendArea(_ pid: EntityID, _ sid: EntityID?) {
        for id in store.taskIDs(projectId: pid, sectionId: sid, includeCompleted: showCompleted) {
            appendTree(id, depth: 0)
        }
        rows.append(["type": "add", "key": .string("add:" + (sid ?? pid)), "projectId": .string(pid), "sectionId": .string(sid)])
    }

    private mutating func appendTree(_ id: EntityID, depth: Int) {
        guard let t = store.task(id) else { return }
        let progress = store.subtaskProgress(of: id)
        let shown = showCompleted ? progress.total : progress.total - progress.done
        let expanded = shown > 0 && !t.collapsed
        rows.append(taskRow(t, depth: depth, progress: progress, hasChildren: shown > 0, expanded: expanded, showProject: false))
        if expanded {
            for c in store.subtaskIDs(of: id, includeCompleted: showCompleted) { appendTree(c, depth: depth + 1) }
        }
    }

    /// Flat rows grouped by project, in sidebar order (label and search views).
    private mutating func buildGroups(_ tasks: [TodoTask], empty: String) {
        guard !tasks.isEmpty else {
            rows.append(["type": "message", "key": "message", "message": .string(empty)])
            return
        }
        var byProject: [EntityID: [TodoTask]] = [:]
        for t in tasks { byProject[t.projectId, default: []].append(t) }
        for p in [store.inbox] + store.projects {
            guard let group = byProject[p.id] else { continue }
            rows.append([
                "type": "group", "key": .string("group:" + p.id), "projectId": .string(p.id), "name": .string(p.name),
                "color": Self.projectColor(p), "count": .int(group.count),
            ])
            for t in group {
                rows.append(taskRow(t, depth: 0, progress: store.subtaskProgress(of: t.id), hasChildren: false,
                                    expanded: false, showProject: true))
            }
        }
    }

    // MARK: Row JSON

    func taskRow(_ t: TodoTask, depth: Int, progress: (done: Int, total: Int), hasChildren: Bool, expanded: Bool,
                 showProject: Bool) -> JSON {
        var row: [String: JSON] = [
            "type": "task", "key": .string(t.id), "id": .string(t.id), "depth": .int(depth),
            "content": .string(t.content), "note": .string(Self.notePreview(t.description)),
            "priority": .int(t.priority.rawValue), "completed": .bool(t.isCompleted),
            "due": dueJSON(t.due), "labels": .array(t.labels.map(labelJSON)),
            "hasChildren": .bool(hasChildren), "expanded": .bool(expanded),
            "subDone": .int(progress.done), "subTotal": .int(progress.total),
            "repeat": .string(t.recurrence.map(Recurrence.summary)),
            "projectId": .string(t.projectId), "sectionId": .string(t.sectionId), "parentId": .string(t.parentId),
        ]
        if showProject, let p = store.project(t.projectId) {
            var name = p.name
            if let sid = t.sectionId, let s = store.sections(in: p.id).first(where: { $0.id == sid }) { name += " / " + s.name }
            row["project"] = ["name": .string(name), "color": Self.projectColor(p)]
        }
        return .object(row)
    }

    func labelJSON(_ name: String) -> JSON {
        ["name": .string(name), "color": .string(labelColors[name] ?? ProjectColor.hex("charcoal"))]
    }

    func dueJSON(_ due: DueDate?) -> JSON {
        guard let due else { return .null }
        return Self.dueJSON(due, now: now, calendar: calendar)
    }

    static func dueJSON(_ due: DueDate, now: Date, calendar: Calendar) -> JSON {
        let days = due.daysFromToday(now: now, calendar: calendar) ?? 99
        let kind: String
        switch days {
        case ..<0: kind = "overdue"
        case 0: kind = "today"
        case 1: kind = "tomorrow"
        case 2...6: kind = "week"
        default: kind = "later"
        }
        return ["date": .string(due.date), "label": .string(due.displayString(now: now, calendar: calendar)), "kind": .string(kind)]
    }

    /// First line of a description, shortened, for the row's second line.
    static func notePreview(_ description: String) -> String {
        let first = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
    }

    /// The project's palette hex; null for the inbox (the UI draws it in the theme accent).
    static func projectColor(_ p: Project) -> JSON {
        p.isInbox ? .null : .string(ProjectColor.hex(p.color))
    }

    // MARK: Sidebar

    static func sidebar(_ store: TodoStore) -> JSON {
        let inbox = store.inbox
        return [
            "inbox": ["id": .string(inbox.id), "name": .string(inbox.name), "count": .int(store.openTaskCount(projectId: inbox.id))],
            "projects": .array(store.projects.map { p in
                ["id": .string(p.id), "name": .string(p.name), "color": projectColor(p), "colorKey": .string(p.color),
                 "count": .int(store.openTaskCount(projectId: p.id))]
            }),
            "labels": .array(store.labels.map { l in
                ["id": .string(l.id), "name": .string(l.name), "color": .string(ProjectColor.hex(l.color)),
                 "colorKey": .string(l.color), "count": .int(store.openTaskCount(label: l.name))]
            }),
        ]
    }

    /// Projects with their sections, for the move picker and Quick Add.
    static func targets(_ store: TodoStore) -> JSON {
        .array(([store.inbox] + store.projects).map { p in
            ["id": .string(p.id), "name": .string(p.name), "color": projectColor(p), "isInbox": .bool(p.isInbox),
             "sections": .array(store.sections(in: p.id).map { ["id": .string($0.id), "name": .string($0.name)] })]
        })
    }

    static var palette: JSON {
        .array(ProjectColor.entries.map { ["key": .string($0.key), "name": .string($0.name), "hex": .string(ProjectColor.hex($0.key))] })
    }
}
