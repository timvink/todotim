import Foundation
import Observation

/// Single source of truth for the UI. All mutations go through here so that
/// `updatedAt` is bumped (for sync) and the database is persisted.
@MainActor
@Observable
public final class TodoStore {
    public private(set) var db: Database

    /// Called after every local mutation (not after `replaceDatabase`). The app uses it
    /// to persist and schedule a sync.
    @ObservationIgnored public var onLocalChange: (() -> Void)?

    public init(db: Database = Database()) {
        self.db = db
        ensureInbox()
    }

    // MARK: - Queries

    public var inbox: Project {
        db.projects.values.first { $0.isInbox && !$0.deleted }!
    }

    /// Live projects excluding the inbox, sorted.
    public var projects: [Project] {
        db.projects.values.filter { !$0.deleted && !$0.isInbox }.sorted(by: Self.byOrder)
    }

    public var labels: [Label] {
        db.labels.values.filter { !$0.deleted }.sorted(by: Self.byOrder)
    }

    public func project(_ id: EntityID) -> Project? {
        db.projects[id].flatMap { $0.deleted ? nil : $0 }
    }

    public func task(_ id: EntityID) -> TodoTask? {
        db.tasks[id].flatMap { $0.deleted ? nil : $0 }
    }

    public func sections(in projectId: EntityID) -> [Section] {
        db.sections.values.filter { $0.projectId == projectId && !$0.deleted }.sorted(by: Self.byOrder)
    }

    /// Top-level tasks of a project area. `sectionId == nil` means the area above all sections.
    public func tasks(projectId: EntityID, sectionId: EntityID?, includeCompleted: Bool = false) -> [TodoTask] {
        db.tasks.values.filter {
            !$0.deleted && $0.projectId == projectId && $0.sectionId == sectionId && $0.parentId == nil
                && (includeCompleted || !$0.isCompleted)
        }.sorted(by: Self.taskOrder)
    }

    public func subtasks(of parentId: EntityID, includeCompleted: Bool = false) -> [TodoTask] {
        db.tasks.values.filter {
            !$0.deleted && $0.parentId == parentId && (includeCompleted || !$0.isCompleted)
        }.sorted(by: Self.taskOrder)
    }

    /// Open (non-completed) tasks with the given label, any project.
    public func tasks(withLabel name: String) -> [TodoTask] {
        db.tasks.values.filter { !$0.deleted && !$0.isCompleted && $0.labels.contains(name) }
            .sorted(by: Self.taskOrder)
    }

    /// Case-insensitive search over content and description of open tasks.
    public func search(_ query: String) -> [TodoTask] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return db.tasks.values.filter {
            !$0.deleted && !$0.isCompleted
                && ($0.content.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q))
        }.sorted(by: Self.taskOrder)
    }

    /// Number of open tasks (including subtasks) in a project, for the sidebar badge.
    public func openTaskCount(projectId: EntityID) -> Int {
        db.tasks.values.reduce(0) { $0 + (!$1.deleted && !$1.isCompleted && $1.projectId == projectId ? 1 : 0) }
    }

    // MARK: - Projects

    @discardableResult
    public func addProject(name: String, color: String = "charcoal") -> Project {
        let p = Project(name: name, color: color, order: nextOrder(projects.map(\.order)))
        db.projects[p.id] = p
        changed()
        return p
    }

    public func updateProject(_ id: EntityID, _ mutate: (inout Project) -> Void) {
        guard var p = db.projects[id] else { return }
        mutate(&p)
        p.updatedAt = Date()
        db.projects[id] = p
        changed()
    }

    /// Deletes a project with all its sections and tasks. The inbox cannot be deleted.
    public func deleteProject(_ id: EntityID) {
        guard let p = db.projects[id], !p.isInbox else { return }
        let now = Date()
        db.projects[id]?.deleted = true
        db.projects[id]?.updatedAt = now
        for s in db.sections.values where s.projectId == id && !s.deleted {
            db.sections[s.id]?.deleted = true
            db.sections[s.id]?.updatedAt = now
        }
        for t in db.tasks.values where t.projectId == id && !t.deleted {
            db.tasks[t.id]?.deleted = true
            db.tasks[t.id]?.updatedAt = now
        }
        changed()
    }

    /// Moves project to `index` within `projects`.
    public func moveProject(_ id: EntityID, to index: Int) {
        let others = projects.filter { $0.id != id }
        let order = orderForInsert(at: index, in: others.map(\.order))
        updateProject(id) { $0.order = order }
    }

    // MARK: - Sections

    /// Adds a section. `index` nil = at the end.
    @discardableResult
    public func addSection(projectId: EntityID, name: String, at index: Int? = nil) -> Section {
        let existing = sections(in: projectId)
        let order = orderForInsert(at: index ?? existing.count, in: existing.map(\.order))
        let s = Section(projectId: projectId, name: name, order: order)
        db.sections[s.id] = s
        changed()
        return s
    }

    public func updateSection(_ id: EntityID, _ mutate: (inout Section) -> Void) {
        guard var s = db.sections[id] else { return }
        mutate(&s)
        s.updatedAt = Date()
        db.sections[id] = s
        changed()
    }

    /// Deletes a section and all of its tasks.
    public func deleteSection(_ id: EntityID) {
        let now = Date()
        db.sections[id]?.deleted = true
        db.sections[id]?.updatedAt = now
        for t in db.tasks.values where t.sectionId == id && !t.deleted {
            db.tasks[t.id]?.deleted = true
            db.tasks[t.id]?.updatedAt = now
        }
        changed()
    }

    public func moveSection(_ id: EntityID, to index: Int) {
        guard let s = db.sections[id] else { return }
        let others = sections(in: s.projectId).filter { $0.id != id }
        let order = orderForInsert(at: index, in: others.map(\.order))
        updateSection(id) { $0.order = order }
    }

    // MARK: - Tasks

    /// Adds a task. `index` is among open siblings; nil = at the end.
    /// Labels that do not exist yet are created.
    @discardableResult
    public func addTask(content: String, projectId: EntityID, sectionId: EntityID? = nil,
                        parentId: EntityID? = nil, at index: Int? = nil, description: String = "",
                        priority: Priority = .p4, due: DueDate? = nil, labels: [String] = []) -> TodoTask {
        var projectId = projectId, sectionId = sectionId
        if let parentId, let parent = db.tasks[parentId] {
            projectId = parent.projectId
            sectionId = parent.sectionId
        }
        let siblings = siblings(projectId: projectId, sectionId: sectionId, parentId: parentId)
        let order = orderForInsert(at: index ?? siblings.count, in: siblings.map(\.order))
        let t = TodoTask(projectId: projectId, sectionId: sectionId, parentId: parentId, content: content,
                         description: description, priority: priority, due: due, labels: labels, order: order)
        db.tasks[t.id] = t
        ensureLabels(labels)
        changed()
        return t
    }

    /// Generic edit. Do not use it to change projectId/sectionId/parentId; use `moveTask`.
    public func updateTask(_ id: EntityID, _ mutate: (inout TodoTask) -> Void) {
        guard var t = db.tasks[id] else { return }
        mutate(&t)
        t.updatedAt = Date()
        db.tasks[id] = t
        ensureLabels(t.labels)
        changed()
    }

    /// Completing a task also completes its subtasks. Uncompleting only affects the task
    /// itself and its ancestors (so it becomes visible again).
    public func toggleComplete(_ id: EntityID) {
        guard let t = db.tasks[id] else { return }
        let now = Date()
        if t.isCompleted {
            var cur: EntityID? = id
            while let cid = cur, let ct = db.tasks[cid] {
                if ct.isCompleted {
                    db.tasks[cid]?.isCompleted = false
                    db.tasks[cid]?.completedAt = nil
                    db.tasks[cid]?.updatedAt = now
                }
                cur = ct.parentId
            }
        } else {
            for did in [id] + descendantIDs(of: id) where db.tasks[did]?.isCompleted == false {
                db.tasks[did]?.isCompleted = true
                db.tasks[did]?.completedAt = now
                db.tasks[did]?.updatedAt = now
            }
        }
        changed()
    }

    /// Deletes a task and all its subtasks.
    public func deleteTask(_ id: EntityID) {
        let now = Date()
        for did in [id] + descendantIDs(of: id) {
            db.tasks[did]?.deleted = true
            db.tasks[did]?.updatedAt = now
        }
        changed()
    }

    /// Moves a task (with its subtasks) to a new location. `index` is among the open
    /// siblings at the destination, excluding the task itself; nil = at the end.
    public func moveTask(_ id: EntityID, projectId: EntityID, sectionId: EntityID?, parentId: EntityID?, at index: Int? = nil) {
        guard db.tasks[id] != nil else { return }
        // Never make a task a descendant of itself.
        if let parentId, parentId == id || descendantIDs(of: id).contains(parentId) { return }
        var projectId = projectId, sectionId = sectionId
        if let parentId, let parent = db.tasks[parentId] {
            projectId = parent.projectId
            sectionId = parent.sectionId
        }
        let sibs = siblings(projectId: projectId, sectionId: sectionId, parentId: parentId).filter { $0.id != id }
        let order = orderForInsert(at: index ?? sibs.count, in: sibs.map(\.order))
        let now = Date()
        db.tasks[id]?.projectId = projectId
        db.tasks[id]?.sectionId = sectionId
        db.tasks[id]?.parentId = parentId
        db.tasks[id]?.order = order
        db.tasks[id]?.updatedAt = now
        for did in descendantIDs(of: id) {
            db.tasks[did]?.projectId = projectId
            db.tasks[did]?.sectionId = sectionId
            db.tasks[did]?.updatedAt = now
        }
        changed()
    }

    /// Makes the task a subtask of its previous open sibling (Todoist ⌘]).
    public func indentTask(_ id: EntityID) {
        guard let t = task(id) else { return }
        let sibs = siblings(projectId: t.projectId, sectionId: t.sectionId, parentId: t.parentId)
        guard let i = sibs.firstIndex(where: { $0.id == id }), i > 0 else { return }
        moveTask(id, projectId: t.projectId, sectionId: t.sectionId, parentId: sibs[i - 1].id)
        if db.tasks[sibs[i - 1].id]?.collapsed == true { updateTask(sibs[i - 1].id) { $0.collapsed = false } }
    }

    /// Moves the task one level up, placing it right after its former parent (Todoist ⌘[).
    public func outdentTask(_ id: EntityID) {
        guard let t = task(id), let pid = t.parentId, let parent = task(pid) else { return }
        let sibs = siblings(projectId: parent.projectId, sectionId: parent.sectionId, parentId: parent.parentId)
        let idx = (sibs.firstIndex(where: { $0.id == pid }) ?? sibs.count - 1) + 1
        moveTask(id, projectId: parent.projectId, sectionId: parent.sectionId, parentId: parent.parentId, at: idx)
    }

    /// Moves the task one position up or down among its open siblings (Todoist ⌘↑ / ⌘↓).
    public func shiftTask(_ id: EntityID, by delta: Int) {
        guard let t = task(id) else { return }
        let sibs = siblings(projectId: t.projectId, sectionId: t.sectionId, parentId: t.parentId)
        guard let i = sibs.firstIndex(where: { $0.id == id }) else { return }
        let target = i + delta
        guard target >= 0, target < sibs.count else { return }
        moveTask(id, projectId: t.projectId, sectionId: t.sectionId, parentId: t.parentId, at: target)
    }

    public func descendantIDs(of id: EntityID) -> [EntityID] {
        var result: [EntityID] = []
        var queue = [id]
        while let cur = queue.popLast() {
            let kids = db.tasks.values.filter { $0.parentId == cur && !$0.deleted }.map(\.id)
            result += kids
            queue += kids
        }
        return result
    }

    // MARK: - Labels

    @discardableResult
    public func addLabel(name: String, color: String = "charcoal") -> Label {
        if let existing = labels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let l = Label(name: name, color: color, order: nextOrder(labels.map(\.order)))
        db.labels[l.id] = l
        changed()
        return l
    }

    /// Renaming a label also renames it on all tasks.
    public func updateLabel(_ id: EntityID, _ mutate: (inout Label) -> Void) {
        guard var l = db.labels[id] else { return }
        let oldName = l.name
        mutate(&l)
        l.updatedAt = Date()
        db.labels[id] = l
        if l.name != oldName {
            for t in db.tasks.values where t.labels.contains(oldName) {
                db.tasks[t.id]?.labels = t.labels.map { $0 == oldName ? l.name : $0 }
                db.tasks[t.id]?.updatedAt = l.updatedAt
            }
        }
        changed()
    }

    /// Deletes the label and removes it from all tasks.
    public func deleteLabel(_ id: EntityID) {
        guard let l = db.labels[id] else { return }
        let now = Date()
        db.labels[id]?.deleted = true
        db.labels[id]?.updatedAt = now
        for t in db.tasks.values where t.labels.contains(l.name) {
            db.tasks[t.id]?.labels.removeAll { $0 == l.name }
            db.tasks[t.id]?.updatedAt = now
        }
        changed()
    }

    // MARK: - Sync hooks

    /// Replaces state with a merged database from sync. Does not call `onLocalChange`.
    public func replaceDatabase(_ newDB: Database) {
        guard newDB != db else { return }
        db = newDB
        ensureInbox()
    }

    // MARK: - Helpers

    private func changed() { onLocalChange?() }

    private func siblings(projectId: EntityID, sectionId: EntityID?, parentId: EntityID?) -> [TodoTask] {
        if let parentId { return subtasks(of: parentId) }
        return tasks(projectId: projectId, sectionId: sectionId)
    }

    private func ensureLabels(_ names: [String]) {
        for n in names where !labels.contains(where: { $0.name == n }) {
            let l = Label(name: n, order: nextOrder(labels.map(\.order)))
            db.labels[l.id] = l
        }
    }

    /// The inbox has a fixed id so that two devices starting fresh do not create two inboxes.
    public static let inboxID = "inbox"

    private func ensureInbox() {
        if db.projects[Self.inboxID] == nil {
            db.projects[Self.inboxID] = Project(id: Self.inboxID, name: "Inbox", color: "charcoal", order: -1,
                                                isInbox: true, updatedAt: Date(timeIntervalSince1970: 0))
        } else if db.projects[Self.inboxID]?.deleted == true {
            db.projects[Self.inboxID]?.deleted = false
        }
    }

    private func nextOrder(_ orders: [Double]) -> Double { (orders.max() ?? 0) + 1 }

    /// Order value that places an item at `index` in a list with the given sorted orders.
    func orderForInsert(at index: Int, in orders: [Double]) -> Double {
        let i = max(0, min(index, orders.count))
        switch (i == 0 ? nil : orders[i - 1], i == orders.count ? nil : orders[i]) {
        case (nil, nil): return 1
        case let (nil, next?): return next - 1
        case let (prev?, nil): return prev + 1
        case let (prev?, next?): return (prev + next) / 2
        }
    }

    nonisolated static func byOrder<T: SyncEntity>(_ a: T, _ b: T) -> Bool where T: Orderable {
        a.order == b.order ? a.id < b.id : a.order < b.order
    }

    nonisolated static func taskOrder(_ a: TodoTask, _ b: TodoTask) -> Bool {
        a.order == b.order ? a.createdAt < b.createdAt : a.order < b.order
    }
}

public protocol Orderable { var order: Double { get } }
extension Project: Orderable {}
extension Section: Orderable {}
extension Label: Orderable {}
extension TodoTask: Orderable {}
