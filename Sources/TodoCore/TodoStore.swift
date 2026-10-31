import Foundation
import Observation

/// Single source of truth for the UI. All mutations go through here so that
/// `updatedAt` is bumped (for sync) and the database is persisted.
///
/// ## Performance design
///
/// **Indexes.** Alongside the `Database` value the store keeps a `TaskIndex`: live children by
/// parent, live top-level tasks by (project, section), open counts per project / area / label and
/// subtask progress per parent. Every task write goes through `writeTask`, which updates the index
/// incrementally (O(1) per changed task) and skips the index entirely when only content fields
/// changed (title, description, priority, due, collapsed, ...). Sorted sibling lists are cached per
/// bucket and re-sorted lazily after the bucket changes. Queries therefore cost O(result).
///
/// **Observation.** `db` is not a stored observable property. Views observe narrower slots:
/// - `structureVersion`: task membership, hierarchy, order, completion, deletion and task labels.
///   Read by `tasks(projectId:…)`, `subtasks`, counts, `subtaskProgress`, `descendantIDs`.
/// - one slot per project list / section list / label list (`projects`, `sections(in:)`, `labels`).
/// - one slot per task id (`task(_:)`; also registered for every task returned by a list query).
/// - one slot for "any task content" (`search`).
/// - `db` itself (for persistence and sync only).
/// Editing a task title therefore invalidates only views that read that task (or `search`/`db`),
/// not the sidebar counts or other lists. Mutations are batched: notifications and `onLocalChange`
/// fire once per public mutation (or per `performBatch`).
@MainActor
@Observable
public final class TodoStore {
    @ObservationIgnored private var storage: Database
    @ObservationIgnored private var index: TaskIndex
    @ObservationIgnored private var cachedProjects: [Project]?
    @ObservationIgnored private var cachedLabels: [Label]?
    @ObservationIgnored private var cachedSections: [EntityID: [Section]]?
    @ObservationIgnored private var pending = PendingChanges()
    @ObservationIgnored private var batchDepth = 0

    /// Changes whenever task structure changes: membership in a project/section, parent, order,
    /// completion, deletion, or a task's labels. Not bumped by content edits (title, description,
    /// priority, due date, collapsed). Views can use it as a cache key for flattened rows.
    public private(set) var structureVersion = 0
    private var projectsVersion = 0
    private var sectionsVersion = 0
    private var labelsVersion = 0
    private var taskContentVersion = 0

    /// The full database, including tombstones. Reading it observes every change; use it for
    /// persistence and sync, not in views.
    public var db: Database {
        access(keyPath: \.db)
        return storage
    }

    /// Called after every local mutation (not after `replaceDatabase`). The app uses it
    /// to persist and schedule a sync.
    @ObservationIgnored public var onLocalChange: (() -> Void)?

    public init(db: Database = Database()) {
        var db = db
        Self.ensureInbox(in: &db)
        self.storage = db
        self.index = TaskIndex(db.tasks.values)
    }

    // MARK: - Queries

    public var inbox: Project {
        _ = projectsVersion
        return storage.projects[Self.inboxID]!
    }

    /// Live projects excluding the inbox, sorted.
    public var projects: [Project] {
        _ = projectsVersion
        return liveProjects()
    }

    public var labels: [Label] {
        _ = labelsVersion
        return liveLabels()
    }

    public func project(_ id: EntityID) -> Project? {
        _ = projectsVersion
        return storage.projects[id].flatMap { $0.deleted ? nil : $0 }
    }

    public func task(_ id: EntityID) -> TodoTask? {
        trackTask(id)
        return storage.tasks[id].flatMap { $0.deleted ? nil : $0 }
    }

    public func sections(in projectId: EntityID) -> [Section] {
        _ = sectionsVersion
        return liveSections(in: projectId)
    }

    /// Top-level tasks of a project area. `sectionId == nil` means the area above all sections.
    public func tasks(projectId: EntityID, sectionId: EntityID?, includeCompleted: Bool = false) -> [TodoTask] {
        _ = structureVersion
        return resolve(sortedTop(AreaKey(projectId: projectId, sectionId: sectionId)), includeCompleted: includeCompleted)
    }

    public func subtasks(of parentId: EntityID, includeCompleted: Bool = false) -> [TodoTask] {
        _ = structureVersion
        return resolve(sortedChildren(parentId), includeCompleted: includeCompleted)
    }

    /// Ids of `tasks(projectId:sectionId:includeCompleted:)`. Observes structure only, so a list
    /// built from ids (with each row reading `task(_:)`) is not invalidated by content edits.
    public func taskIDs(projectId: EntityID, sectionId: EntityID?, includeCompleted: Bool = false) -> [EntityID] {
        _ = structureVersion
        return filterOpen(sortedTop(AreaKey(projectId: projectId, sectionId: sectionId)), includeCompleted: includeCompleted)
    }

    /// Ids of `subtasks(of:includeCompleted:)`. Observes structure only.
    public func subtaskIDs(of parentId: EntityID, includeCompleted: Bool = false) -> [EntityID] {
        _ = structureVersion
        return filterOpen(sortedChildren(parentId), includeCompleted: includeCompleted)
    }

    /// Open (non-completed) tasks with the given label, any project.
    public func tasks(withLabel name: String) -> [TodoTask] {
        _ = structureVersion
        let ids: [EntityID]
        if let cached = index.sortedByLabel[name] {
            ids = cached
        } else {
            ids = sortIDs(index.openByLabel[name])
            index.sortedByLabel[name] = ids
        }
        return resolve(ids, includeCompleted: false)
    }

    /// Case-insensitive search over content and description of open tasks
    /// (`localizedCaseInsensitiveContains`). The last result is reused while no task changed, so
    /// views that ask again for the same query (one keystroke) do not scan again.
    public func search(_ query: String) -> [TodoTask] {
        let version = taskContentVersion
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let locale = Locale.current
        if let c = lastSearch, c.query == q, c.version == version, c.locale == locale.identifier { return c.result }
        let matcher = TextMatcher(q, locale: locale)
        let result = Self.sortedByTaskOrder(storage.tasks.values.filter {
            !$0.deleted && !$0.isCompleted && (matcher.matches($0.content) || matcher.matches($0.description))
        })
        lastSearch = (q, version, locale.identifier, result)
        return result
    }

    /// Every task change bumps `taskContentVersion` (structure changes too), so it keys the cache.
    @ObservationIgnored private var lastSearch: (query: String, version: Int, locale: String, result: [TodoTask])?

    /// Number of open tasks (including subtasks) in a project, for the sidebar badge.
    public func openTaskCount(projectId: EntityID) -> Int {
        _ = structureVersion
        return index.openByProject[projectId] ?? 0
    }

    /// Number of open top-level tasks in a project area (`sectionId == nil`: above all sections).
    /// Equals `tasks(projectId:sectionId:).count`; used for section headers.
    public func openTaskCount(projectId: EntityID, sectionId: EntityID?) -> Int {
        _ = structureVersion
        return index.openTopByArea[AreaKey(projectId: projectId, sectionId: sectionId)] ?? 0
    }

    /// Number of open tasks (any depth, any project) with the label. Equals `tasks(withLabel:).count`.
    public func openTaskCount(label name: String) -> Int {
        _ = structureVersion
        return index.openByLabel[name]?.count ?? 0
    }

    /// Direct live subtasks of a task: how many are completed, and how many there are in total.
    public func subtaskProgress(of parentId: EntityID) -> (done: Int, total: Int) {
        _ = structureVersion
        let p = index.childProgress[parentId] ?? SubtaskProgress()
        return (p.done, p.total)
    }

    /// Live descendants (any depth, completed included) in depth-first order. Cycle-safe.
    public func descendantIDs(of id: EntityID) -> [EntityID] {
        _ = structureVersion
        return descendants(of: id)
    }

    // MARK: - Batching

    /// Runs several mutations as one change: views are notified and `onLocalChange` is called
    /// once at the end. Use it for undo (restoring many tasks) and other multi-step edits.
    public func performBatch(_ body: () -> Void) {
        perform(body)
    }

    // MARK: - Projects

    @discardableResult
    public func addProject(name: String, color: String = "charcoal") -> Project {
        perform {
            let p = Project(name: name, color: color, order: nextOrder(liveProjects().map(\.order)), updatedAt: Self.timestamp())
            writeProject(p)
            return p
        }
    }

    public func updateProject(_ id: EntityID, _ mutate: (inout Project) -> Void) {
        perform {
            guard let old = storage.projects[id] else { return }
            var p = old
            mutate(&p)
            guard p != old else { return }
            p.updatedAt = Self.timestamp()
            writeProject(p)
        }
    }

    /// Deletes a project with all its sections and tasks. The inbox cannot be deleted.
    public func deleteProject(_ id: EntityID) {
        perform {
            guard var p = storage.projects[id], !p.isInbox else { return }
            let now = Self.timestamp()
            p.deleted = true
            p.updatedAt = now
            writeProject(p)
            for var s in storage.sections.values where s.projectId == id && !s.deleted {
                s.deleted = true
                s.updatedAt = now
                writeSection(s)
            }
            for var t in storage.tasks.values where t.projectId == id && !t.deleted {
                t.deleted = true
                t.updatedAt = now
                writeTask(t)
            }
        }
    }

    /// Moves project to `index` within `projects`.
    public func moveProject(_ id: EntityID, to index: Int) {
        perform {
            let others = liveProjects().filter { $0.id != id }
            let order = insertionOrder(at: index, open: others.map(\.id), all: others.map { ($0.id, $0.order) }) { pid, order, now in
                guard var p = storage.projects[pid] else { return }
                p.order = order
                p.updatedAt = now
                writeProject(p)
            }
            updateProject(id) { $0.order = order }
        }
    }

    // MARK: - Sections

    /// Adds a section. `index` nil = at the end.
    @discardableResult
    public func addSection(projectId: EntityID, name: String, at index: Int? = nil) -> Section {
        perform {
            let existing = liveSections(in: projectId)
            let order = insertionOrder(at: index ?? existing.count, open: existing.map(\.id),
                                       all: existing.map { ($0.id, $0.order) }, renumber: renumberSection)
            let s = Section(projectId: projectId, name: name, order: order, updatedAt: Self.timestamp())
            writeSection(s)
            return s
        }
    }

    public func updateSection(_ id: EntityID, _ mutate: (inout Section) -> Void) {
        perform {
            guard let old = storage.sections[id] else { return }
            var s = old
            mutate(&s)
            guard s != old else { return }
            s.updatedAt = Self.timestamp()
            writeSection(s)
        }
    }

    /// Deletes a section and all of its tasks.
    public func deleteSection(_ id: EntityID) {
        perform {
            guard var s = storage.sections[id] else { return }
            let now = Self.timestamp()
            s.deleted = true
            s.updatedAt = now
            writeSection(s)
            for var t in storage.tasks.values where t.sectionId == id && !t.deleted {
                t.deleted = true
                t.updatedAt = now
                writeTask(t)
            }
        }
    }

    public func moveSection(_ id: EntityID, to index: Int) {
        perform {
            guard let s = storage.sections[id] else { return }
            let others = liveSections(in: s.projectId).filter { $0.id != id }
            let order = insertionOrder(at: index, open: others.map(\.id), all: others.map { ($0.id, $0.order) },
                                       renumber: renumberSection)
            updateSection(id) { $0.order = order }
        }
    }

    // MARK: - Tasks

    /// Adds a task. `index` is among open siblings; nil = at the end.
    /// Labels that do not exist yet are created.
    @discardableResult
    public func addTask(content: String, projectId: EntityID, sectionId: EntityID? = nil,
                        parentId: EntityID? = nil, at index: Int? = nil, description: String = "",
                        priority: Priority = .p4, due: DueDate? = nil, labels: [String] = []) -> TodoTask {
        perform {
            var projectId = projectId, sectionId = sectionId
            if let parentId, let parent = storage.tasks[parentId] {
                projectId = parent.projectId
                sectionId = parent.sectionId
            }
            let order = taskInsertionOrder(at: index, projectId: projectId, sectionId: sectionId, parentId: parentId, excluding: nil)
            let now = Self.timestamp()
            let t = TodoTask(projectId: projectId, sectionId: sectionId, parentId: parentId, content: content,
                             description: description, priority: priority, due: due, labels: labels, order: order,
                             createdAt: now, updatedAt: now)
            writeTask(t)
            ensureLabels(labels)
            return t
        }
    }

    /// Generic edit. Do not use it to change projectId/sectionId/parentId; use `moveTask`.
    /// Does nothing (no `updatedAt` bump, no `onLocalChange`) when `mutate` changes nothing.
    public func updateTask(_ id: EntityID, _ mutate: (inout TodoTask) -> Void) {
        perform {
            guard let old = storage.tasks[id] else { return }
            var t = old
            mutate(&t)
            guard t != old else { return }
            t.updatedAt = Self.timestamp()
            t.createdAt = Self.millisecondPrecision(t.createdAt)
            t.completedAt = t.completedAt.map(Self.millisecondPrecision)
            writeTask(t)
            ensureLabels(t.labels)
        }
    }

    /// Completing a task also completes its subtasks. Uncompleting only affects the task
    /// itself and its ancestors (so it becomes visible again). Completing a repeating task
    /// (`recurrence`) moves its due date to the next occurrence instead, while the rule allows
    /// (`Recurrence.advance`).
    public func toggleComplete(_ id: EntityID, calendar: Calendar = .current) {
        perform {
            guard let t = storage.tasks[id] else { return }
            let now = Self.timestamp()
            if !t.isCompleted, let rule = t.recurrence,
               let next = Recurrence.advance(rule, from: t.due ?? DueDate(Date(), calendar: calendar), calendar: calendar) {
                var advanced = t
                advanced.due = next.due
                advanced.recurrence = next.rule
                advanced.updatedAt = now
                writeTask(advanced)
                return
            }
            if t.isCompleted {
                var cur: EntityID? = id
                var seen = Set<EntityID>()
                while let cid = cur, seen.insert(cid).inserted, var ct = storage.tasks[cid] {
                    if ct.isCompleted {
                        ct.isCompleted = false
                        ct.completedAt = nil
                        ct.updatedAt = now
                        writeTask(ct)
                    }
                    cur = ct.parentId
                }
            } else {
                for did in [id] + descendants(of: id) {
                    guard var dt = storage.tasks[did], !dt.isCompleted else { continue }
                    dt.isCompleted = true
                    dt.completedAt = now
                    dt.updatedAt = now
                    writeTask(dt)
                }
            }
        }
    }

    /// Deletes a task and all its subtasks.
    public func deleteTask(_ id: EntityID) {
        perform {
            let now = Self.timestamp()
            for did in [id] + descendants(of: id) {
                guard var t = storage.tasks[did] else { continue }
                t.deleted = true
                t.updatedAt = now
                writeTask(t)
            }
        }
    }

    /// Moves a task (with its subtasks) to a new location. `index` is among the open
    /// siblings at the destination, excluding the task itself; nil = at the end.
    public func moveTask(_ id: EntityID, projectId: EntityID, sectionId: EntityID?, parentId: EntityID?, at index: Int? = nil) {
        perform {
            guard storage.tasks[id] != nil else { return }
            // Never make a task a descendant of itself.
            if let parentId, parentId == id || descendants(of: id).contains(parentId) { return }
            var projectId = projectId, sectionId = sectionId
            if let parentId, let parent = storage.tasks[parentId] {
                projectId = parent.projectId
                sectionId = parent.sectionId
            }
            let order = taskInsertionOrder(at: index, projectId: projectId, sectionId: sectionId, parentId: parentId, excluding: id)
            let now = Self.timestamp()
            guard var t = storage.tasks[id] else { return }
            t.projectId = projectId
            t.sectionId = sectionId
            t.parentId = parentId
            t.order = order
            t.updatedAt = now
            writeTask(t)
            for did in descendants(of: id) {
                guard var d = storage.tasks[did], d.projectId != projectId || d.sectionId != sectionId else { continue }
                d.projectId = projectId
                d.sectionId = sectionId
                d.updatedAt = now
                writeTask(d)
            }
        }
    }

    /// Makes the task a subtask of its previous open sibling (Todoist ⌘]).
    public func indentTask(_ id: EntityID) {
        perform {
            guard let t = liveTask(id) else { return }
            let sibs = siblingIDs(projectId: t.projectId, sectionId: t.sectionId, parentId: t.parentId, includeCompleted: false)
            guard let i = sibs.firstIndex(of: id), i > 0 else { return }
            moveTask(id, projectId: t.projectId, sectionId: t.sectionId, parentId: sibs[i - 1])
            if storage.tasks[sibs[i - 1]]?.collapsed == true { updateTask(sibs[i - 1]) { $0.collapsed = false } }
        }
    }

    /// Moves the task one level up, placing it right after its former parent (Todoist ⌘[).
    public func outdentTask(_ id: EntityID) {
        perform {
            guard let t = liveTask(id), let pid = t.parentId, let parent = liveTask(pid) else { return }
            let sibs = siblingIDs(projectId: parent.projectId, sectionId: parent.sectionId, parentId: parent.parentId,
                                  includeCompleted: false)
            let idx = (sibs.firstIndex(of: pid) ?? sibs.count - 1) + 1
            moveTask(id, projectId: parent.projectId, sectionId: parent.sectionId, parentId: parent.parentId, at: idx)
        }
    }

    /// Moves the task one position up or down among its open siblings (Todoist ⌘↑ / ⌘↓).
    public func shiftTask(_ id: EntityID, by delta: Int) {
        perform {
            guard let t = liveTask(id) else { return }
            let sibs = siblingIDs(projectId: t.projectId, sectionId: t.sectionId, parentId: t.parentId, includeCompleted: false)
            guard let i = sibs.firstIndex(of: id) else { return }
            let target = i + delta
            guard target >= 0, target < sibs.count else { return }
            moveTask(id, projectId: t.projectId, sectionId: t.sectionId, parentId: t.parentId, at: target)
        }
    }

    // MARK: - Labels

    @discardableResult
    public func addLabel(name: String, color: String = "charcoal") -> Label {
        perform {
            let live = liveLabels()
            if let existing = live.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return existing
            }
            let l = Label(name: name, color: color, order: nextOrder(live.map(\.order)), updatedAt: Self.timestamp())
            writeLabel(l)
            return l
        }
    }

    /// Renaming a label also renames it on all tasks.
    public func updateLabel(_ id: EntityID, _ mutate: (inout Label) -> Void) {
        perform {
            guard let old = storage.labels[id] else { return }
            var l = old
            mutate(&l)
            guard l != old else { return }
            l.updatedAt = Self.timestamp()
            writeLabel(l)
            if l.name != old.name {
                for var t in storage.tasks.values where t.labels.contains(old.name) {
                    t.labels = t.labels.map { $0 == old.name ? l.name : $0 }
                    t.updatedAt = l.updatedAt
                    writeTask(t)
                }
            }
        }
    }

    /// Deletes the label and removes it from all tasks.
    public func deleteLabel(_ id: EntityID) {
        perform {
            guard var l = storage.labels[id] else { return }
            let now = Self.timestamp()
            l.deleted = true
            l.updatedAt = now
            writeLabel(l)
            for var t in storage.tasks.values where t.labels.contains(l.name) {
                t.labels.removeAll { $0 == l.name }
                t.updatedAt = now
                writeTask(t)
            }
        }
    }

    // MARK: - Sync hooks

    /// Replaces state with a merged database from sync. Does not call `onLocalChange`.
    /// Only entities that differ are rewritten, so views of unchanged tasks are not invalidated.
    /// Returns whether anything changed.
    @discardableResult
    public func replaceDatabase(_ newDB: Database) -> Bool {
        var newDB = newDB
        Self.ensureInbox(in: &newDB)
        batchDepth += 1
        var changed = false
        if newDB.projects != storage.projects {
            storage.projects = newDB.projects
            cachedProjects = nil
            pending.projects = true
            changed = true
        }
        if newDB.sections != storage.sections {
            storage.sections = newDB.sections
            cachedSections = nil
            pending.sections = true
            changed = true
        }
        if newDB.labels != storage.labels {
            storage.labels = newDB.labels
            cachedLabels = nil
            pending.labels = true
            changed = true
        }
        var tasksChanged = false
        for (id, t) in newDB.tasks where storage.tasks[id] != t {
            writeTask(t)
            tasksChanged = true
        }
        // With no changed or added tasks and equal counts, no task can have been removed.
        if tasksChanged || storage.tasks.count != newDB.tasks.count {
            for id in Array(storage.tasks.keys) where newDB.tasks[id] == nil {
                removeTask(id)
                tasksChanged = true
            }
        }
        batchDepth -= 1
        if batchDepth == 0 { commit(local: false) }
        return changed || tasksChanged
    }

    // MARK: - Write path

    /// Every task write goes through here: keeps the index in sync and records what to notify.
    private func writeTask(_ new: TodoTask) {
        let old = storage.tasks[new.id]
        if old == new { return }
        storage.tasks[new.id] = new
        if let old, TaskIndex.sameStructure(old, new) {
            // Content-only edit: no index work, no structural invalidation.
        } else {
            if let old { index.remove(old) }
            index.add(new)
            pending.structure = true
        }
        pending.tasks.insert(new.id)
    }

    private func removeTask(_ id: EntityID) {
        guard let old = storage.tasks.removeValue(forKey: id) else { return }
        index.remove(old)
        pending.structure = true
        pending.tasks.insert(id)
    }

    private func writeProject(_ p: Project) {
        guard storage.projects[p.id] != p else { return }
        storage.projects[p.id] = p
        cachedProjects = nil
        pending.projects = true
    }

    private func writeSection(_ s: Section) {
        guard storage.sections[s.id] != s else { return }
        storage.sections[s.id] = s
        cachedSections = nil
        pending.sections = true
    }

    private func writeLabel(_ l: Label) {
        guard storage.labels[l.id] != l else { return }
        storage.labels[l.id] = l
        cachedLabels = nil
        pending.labels = true
    }

    @discardableResult
    private func perform<R>(_ body: () -> R) -> R {
        batchDepth += 1
        let result = body()
        batchDepth -= 1
        if batchDepth == 0 { commit(local: true) }
        return result
    }

    /// Publishes pending changes to observers (once per batch) and calls `onLocalChange`.
    private func commit(local: Bool) {
        let p = pending
        pending = PendingChanges()
        guard p.hasChanges else { return }
        if p.projects { projectsVersion &+= 1 }
        if p.sections { sectionsVersion &+= 1 }
        if p.labels { labelsVersion &+= 1 }
        if p.structure { structureVersion &+= 1 }
        if !p.tasks.isEmpty {
            taskContentVersion &+= 1
            for id in p.tasks { withMutation(keyPath: \.[taskSlot: id]) {} }
        }
        withMutation(keyPath: \.db) {}
        if local { onLocalChange?() }
    }

    /// Observation slot for one task (a hashable subscript key path per id).
    nonisolated private subscript(taskSlot id: EntityID) -> Int { 0 }

    private func trackTask(_ id: EntityID) { access(keyPath: \.[taskSlot: id]) }

    // MARK: - Untracked helpers

    private func liveTask(_ id: EntityID) -> TodoTask? {
        storage.tasks[id].flatMap { $0.deleted ? nil : $0 }
    }

    private func liveProjects() -> [Project] {
        if let cachedProjects { return cachedProjects }
        let ps = storage.projects.values.filter { !$0.deleted && !$0.isInbox }.sorted(by: Self.byOrder)
        cachedProjects = ps
        return ps
    }

    private func liveLabels() -> [Label] {
        if let cachedLabels { return cachedLabels }
        let ls = storage.labels.values.filter { !$0.deleted }.sorted(by: Self.byOrder)
        cachedLabels = ls
        return ls
    }

    private func liveSections(in projectId: EntityID) -> [Section] {
        if cachedSections == nil {
            var byProject: [EntityID: [Section]] = [:]
            for s in storage.sections.values where !s.deleted { byProject[s.projectId, default: []].append(s) }
            for key in byProject.keys { byProject[key]!.sort(by: Self.byOrder) }
            cachedSections = byProject
        }
        return cachedSections?[projectId] ?? []
    }

    private func sortedTop(_ area: AreaKey) -> [EntityID] {
        if let ids = index.sortedTop[area] { return ids }
        let ids = sortIDs(index.topLevel[area])
        index.sortedTop[area] = ids
        return ids
    }

    private func sortedChildren(_ parentId: EntityID) -> [EntityID] {
        if let ids = index.sortedChildren[parentId] { return ids }
        let ids = sortIDs(index.children[parentId])
        index.sortedChildren[parentId] = ids
        return ids
    }

    private func sortIDs(_ ids: Set<EntityID>?) -> [EntityID] {
        guard let ids, !ids.isEmpty else { return [] }
        let tasks = ids.compactMap { storage.tasks[$0] }
        return tasks.indices.sorted { Self.taskOrder(tasks[$0], tasks[$1]) }.map { tasks[$0].id }
    }

    /// Tasks for sorted ids; registers each returned task's observation slot.
    private func resolve(_ ids: [EntityID], includeCompleted: Bool) -> [TodoTask] {
        var out: [TodoTask] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let t = storage.tasks[id], includeCompleted || !t.isCompleted else { continue }
            trackTask(id)
            out.append(t)
        }
        return out
    }

    private func filterOpen(_ ids: [EntityID], includeCompleted: Bool) -> [EntityID] {
        includeCompleted ? ids : ids.filter { storage.tasks[$0]?.isCompleted == false }
    }

    private func siblingIDs(projectId: EntityID, sectionId: EntityID?, parentId: EntityID?, includeCompleted: Bool) -> [EntityID] {
        filterOpen(parentId.map(sortedChildren) ?? sortedTop(AreaKey(projectId: projectId, sectionId: sectionId)),
                   includeCompleted: includeCompleted)
    }

    /// Depth-first (pre-order) live descendants; a visited set guards against parent cycles.
    private func descendants(of id: EntityID) -> [EntityID] {
        var result: [EntityID] = []
        var seen: Set<EntityID> = [id]
        var stack: [EntityID] = sortedChildren(id).reversed()
        while let cur = stack.popLast() {
            guard seen.insert(cur).inserted else { continue }
            result.append(cur)
            stack.append(contentsOf: sortedChildren(cur).reversed())
        }
        return result
    }

    private func ensureLabels(_ names: [String]) {
        guard !names.isEmpty else { return }
        for n in names where !liveLabels().contains(where: { $0.name == n }) {
            writeLabel(Label(name: n, order: nextOrder(liveLabels().map(\.order)), updatedAt: Self.timestamp()))
        }
    }

    /// The inbox has a fixed id so that two devices starting fresh do not create two inboxes.
    nonisolated public static let inboxID = "inbox"

    private static func ensureInbox(in db: inout Database) {
        if db.projects[inboxID] == nil {
            db.projects[inboxID] = Project(id: inboxID, name: "Inbox", color: "charcoal", order: -1,
                                           isInbox: true, updatedAt: Date(timeIntervalSince1970: 0))
        } else if db.projects[inboxID]?.deleted == true {
            db.projects[inboxID]?.deleted = false
        }
    }

    // MARK: - Ordering

    private func nextOrder(_ orders: [Double]) -> Double { (orders.max() ?? 0) + 1 }

    /// Order value that places an item at `index` in a list with the given sorted orders
    /// (plain midpoint; see `gapOrder` for the exhaustion-aware variant).
    func orderForInsert(at index: Int, in orders: [Double]) -> Double {
        Self.gapOrder(at: index, in: orders) ?? {
            let i = max(0, min(index, orders.count))
            return (orders[i - 1] + orders[i]) / 2
        }()
    }

    /// Order for inserting at `index` among sorted `orders`, or nil when the neighbours are too
    /// close (or out of order) for a distinct midpoint, so the siblings must be renumbered.
    nonisolated static func gapOrder(at index: Int, in orders: [Double]) -> Double? {
        let i = max(0, min(index, orders.count))
        switch (i == 0 ? nil : orders[i - 1], i == orders.count ? nil : orders[i]) {
        case (nil, nil): return 1
        case let (nil, next?): return next - 1
        case let (prev?, nil): return prev + 1
        case let (prev?, next?):
            let mid = (prev + next) / 2
            let minGap = max(1, abs(prev), abs(next)) * 1e-9
            guard next - prev > minGap, mid > prev, mid < next else { return nil }
            return mid
        }
    }

    /// Order for inserting at `index` among `open` (sorted ids). When the gap is exhausted, all
    /// siblings (`all`, sorted, including hidden ones) are renumbered 1, 2, 3… in one mutation.
    private func insertionOrder(at index: Int, open: [EntityID], all: [(EntityID, Double)],
                                renumber: (EntityID, Double, Date) -> Void) -> Double {
        let orderOf = Dictionary(all, uniquingKeysWith: { a, _ in a })
        if let o = Self.gapOrder(at: index, in: open.map { orderOf[$0] ?? 0 }) { return o }
        let now = Self.timestamp()
        var renumbered: [EntityID: Double] = [:]
        for (k, (id, order)) in all.enumerated() {
            let newOrder = Double(k + 1)
            renumbered[id] = newOrder
            if order != newOrder { renumber(id, newOrder, now) }
        }
        return Self.gapOrder(at: index, in: open.map { renumbered[$0] ?? 0 }) ?? Double(all.count + 1)
    }

    private func taskInsertionOrder(at index: Int?, projectId: EntityID, sectionId: EntityID?, parentId: EntityID?,
                                    excluding id: EntityID?) -> Double {
        let all = siblingIDs(projectId: projectId, sectionId: sectionId, parentId: parentId, includeCompleted: true)
            .filter { $0 != id }
        let open = all.filter { storage.tasks[$0]?.isCompleted == false }
        return insertionOrder(at: index ?? open.count, open: open, all: all.map { ($0, storage.tasks[$0]?.order ?? 0) }) { tid, order, now in
            guard var t = storage.tasks[tid] else { return }
            t.order = order
            t.updatedAt = now
            writeTask(t)
        }
    }

    private func renumberSection(_ id: EntityID, _ order: Double, _ now: Date) {
        guard var s = storage.sections[id] else { return }
        s.order = order
        s.updatedAt = now
        writeSection(s)
    }

    // MARK: - Timestamps

    /// Current time at millisecond precision (what the JSON files store), so a local entity and
    /// its round-tripped remote copy compare equal.
    nonisolated public static func timestamp() -> Date { millisecondPrecision(Date()) }

    nonisolated public static func millisecondPrecision(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(Int64((date.timeIntervalSince1970 * 1000).rounded())) / 1000)
    }

    nonisolated static func byOrder<T: SyncEntity>(_ a: T, _ b: T) -> Bool where T: Orderable {
        a.order == b.order ? a.id < b.id : a.order < b.order
    }

    nonisolated static func taskOrder(_ a: TodoTask, _ b: TodoTask) -> Bool {
        if a.order != b.order { return a.order < b.order }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    /// `tasks.sorted(by: taskOrder)`, sorting indices: moving the large task values around while
    /// sorting costs more than the comparisons.
    nonisolated static func sortedByTaskOrder(_ tasks: [TodoTask]) -> [TodoTask] {
        tasks.indices.sorted { taskOrder(tasks[$0], tasks[$1]) }.map { tasks[$0] }
    }
}

public protocol Orderable { var order: Double { get } }
extension Project: Orderable {}
extension Section: Orderable {}
extension Label: Orderable {}
extension TodoTask: Orderable {}

// MARK: - Index

struct AreaKey: Hashable {
    var projectId: EntityID
    var sectionId: EntityID?
}

struct SubtaskProgress: Equatable {
    var done = 0
    var total = 0
}

private struct PendingChanges {
    var tasks: Set<EntityID> = []
    var structure = false
    var projects = false
    var sections = false
    var labels = false

    var hasChanges: Bool { structure || projects || sections || labels || !tasks.isEmpty }
}

/// Derived lookups over live (non-deleted) tasks. Maintained incrementally by `TodoStore.writeTask`.
struct TaskIndex {
    var children: [EntityID: Set<EntityID>] = [:]
    var topLevel: [AreaKey: Set<EntityID>] = [:]
    /// Lazily sorted caches; an entry is dropped when its bucket changes.
    var sortedChildren: [EntityID: [EntityID]] = [:]
    var sortedTop: [AreaKey: [EntityID]] = [:]
    var sortedByLabel: [String: [EntityID]] = [:]
    /// Open tasks (any depth) per project.
    var openByProject: [EntityID: Int] = [:]
    /// Open top-level tasks per project area.
    var openTopByArea: [AreaKey: Int] = [:]
    /// Open tasks (any depth) per label name.
    var openByLabel: [String: Set<EntityID>] = [:]
    /// Live direct children per parent.
    var childProgress: [EntityID: SubtaskProgress] = [:]

    init() {}

    init(_ tasks: some Sequence<TodoTask>) {
        for t in tasks { add(t) }
    }

    /// Whether two versions of a task contribute identically to the index (and to sort order).
    static func sameStructure(_ a: TodoTask, _ b: TodoTask) -> Bool {
        a.projectId == b.projectId && a.sectionId == b.sectionId && a.parentId == b.parentId
            && a.order == b.order && a.isCompleted == b.isCompleted && a.deleted == b.deleted
            && a.labels == b.labels && a.createdAt == b.createdAt
    }

    mutating func add(_ t: TodoTask) { apply(t, adding: true) }
    mutating func remove(_ t: TodoTask) { apply(t, adding: false) }

    private mutating func apply(_ t: TodoTask, adding: Bool) {
        guard !t.deleted else { return }
        let delta = adding ? 1 : -1
        let open = !t.isCompleted
        if let p = t.parentId {
            Self.update(&children, p, t.id, adding)
            sortedChildren[p] = nil
            var prog = childProgress[p] ?? SubtaskProgress()
            prog.total += delta
            if !open { prog.done += delta }
            childProgress[p] = prog.total == 0 ? nil : prog
        } else {
            let area = AreaKey(projectId: t.projectId, sectionId: t.sectionId)
            Self.update(&topLevel, area, t.id, adding)
            sortedTop[area] = nil
            if open { Self.bump(&openTopByArea, area, delta) }
        }
        if open {
            Self.bump(&openByProject, t.projectId, delta)
            for label in Set(t.labels) {
                Self.update(&openByLabel, label, t.id, adding)
                sortedByLabel[label] = nil
            }
        }
    }

    private static func update<K: Hashable>(_ dict: inout [K: Set<EntityID>], _ key: K, _ id: EntityID, _ adding: Bool) {
        if adding {
            dict[key, default: []].insert(id)
        } else if dict[key]?.remove(id) != nil, dict[key]?.isEmpty == true {
            dict[key] = nil
        }
    }

    private static func bump<K: Hashable>(_ dict: inout [K: Int], _ key: K, _ delta: Int) {
        let v = (dict[key] ?? 0) + delta
        dict[key] = v == 0 ? nil : v
    }
}
