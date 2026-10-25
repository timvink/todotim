import Foundation

public struct TodoistImportOptions: Equatable, Sendable {
    /// Import completed tasks that were not imported before. A previously imported task that is
    /// now completed in Todoist is always updated to completed.
    public var includeCompleted: Bool
    /// Bring back an imported entity that was deleted in TodoTim. When false it stays deleted
    /// and is counted as skipped.
    public var restoreDeleted: Bool

    public init(includeCompleted: Bool = false, restoreDeleted: Bool = true) {
        self.includeCompleted = includeCompleted
        self.restoreDeleted = restoreDeleted
    }
}

public struct ImportReport: Equatable, Sendable {
    public struct Counts: Equatable, Sendable {
        public var created = 0
        public var updated = 0
        public var unchanged = 0
        public var skipped = 0
        public init(created: Int = 0, updated: Int = 0, unchanged: Int = 0, skipped: Int = 0) {
            self.created = created; self.updated = updated; self.unchanged = unchanged; self.skipped = skipped
        }
    }

    public var projects = Counts()
    public var sections = Counts()
    public var tasks = Counts()
    public var labels = Counts()
    /// Human-readable notes (recurrence dropped, invalid entries, ...).
    public var warnings: [String] = []

    public init() {}

    public var hasChanges: Bool {
        [projects, sections, tasks, labels].contains { $0.created + $0.updated > 0 }
    }

    /// One line per kind, e.g. "Tasks: 40 created, 2 updated, 0 unchanged, 3 skipped".
    public var summaryLines: [String] {
        [("Projects", projects), ("Sections", sections), ("Tasks", tasks), ("Labels", labels)].map { name, c in
            "\(name): \(c.created) created, \(c.updated) updated, \(c.unchanged) unchanged, \(c.skipped) skipped"
        }
    }

    public var summary: String { (summaryLines + warnings).joined(separator: "\n") }
}

/// Imports a `TodoistSnapshot` into TodoTim.
///
/// Mapping:
/// - The Todoist inbox becomes the TodoTim inbox (its name and color are kept). Other projects
///   become flat top-level projects; a sub-project is named "Parent / Child".
/// - Sections, tasks and labels map one to one; subtasks keep their parent; sibling order follows
///   Todoist's `child_order` (then `order_key`, then id).
/// - Priority is inverted (Todoist 4 → p1, 1 → p4). Due dates keep only the day; recurrence and
///   times are dropped (counted in a warning). Durations, deadlines, comments, reminders and
///   assignees are not imported.
/// - Completed, deleted and archived items are skipped (see `TodoistImportOptions`).
///
/// Idempotence: every TodoTim id is a name-based UUID (version 5) of "todoist:<kind>:<todoist id>"
/// (`entityID(_:_:)`), so a second import of the same data updates the entities from the first
/// one instead of creating duplicates. On update, an entity keeps its TodoTim-only state
/// (project order in the sidebar, a task's collapsed flag and creation date); everything else
/// is overwritten from Todoist. Nothing that is missing from the snapshot is deleted.
public enum TodoistImport {
    public enum Kind: String, Sendable {
        case project, section, task, label
        /// Labels referenced by tasks but missing from the label list (e.g. shared labels).
        case labelName = "label-name"
    }

    /// Deterministic TodoTim id for a Todoist entity: lowercase UUID v5, valid under `isValidEntityID`.
    public static func entityID(_ kind: Kind, _ todoistID: String) -> EntityID {
        uuidV5(namespace: namespace, name: "todoist:\(kind.rawValue):\(todoistID)")
    }

    /// Applies the snapshot to the store as one batch (one undo-free change, one save, one sync).
    @MainActor
    @discardableResult
    public static func apply(_ snapshot: TodoistSnapshot, to store: TodoStore,
                             options: TodoistImportOptions = TodoistImportOptions()) -> ImportReport {
        var db = store.db
        let report = apply(snapshot, to: &db, options: options)
        if db != store.db {
            // `replaceDatabase` inside `performBatch` commits as a local change, so the store
            // notifies observers once and calls `onLocalChange` (persist + sync).
            store.performBatch { store.replaceDatabase(db) }
        }
        return report
    }

    /// Pure variant of `apply(_:to:options:)` on a database value.
    public static func apply(_ snapshot: TodoistSnapshot, to db: inout Database,
                             options: TodoistImportOptions = TodoistImportOptions(),
                             now: Date = TodoStore.timestamp()) -> ImportReport {
        var importer = Importer(snapshot: snapshot, db: db, options: options, now: now)
        importer.run()
        db = importer.db
        return importer.report
    }

    /// Fixed namespace for TodoTim's Todoist ids (UUID v5). Never change it: ids derived from it are stored.
    static let namespace = UUID(uuidString: "5311d57f-6e3b-4629-900e-ab1e66711ea1")!
}

// MARK: - Importer

private struct Importer {
    let snapshot: TodoistSnapshot
    let original: Database
    var db: Database
    let options: TodoistImportOptions
    let now: Date
    var report = ImportReport()

    /// Todoist project id → TodoTim project id, for imported projects (including the inbox).
    var projectMap: [String: EntityID] = [:]
    /// Todoist section id → TodoTim section id, for sections imported in this run.
    var sectionMap: [String: EntityID] = [:]
    /// Lowercased Todoist label name → TodoTim label name.
    var labelNames: [String: String] = [:]
    /// Ids written in this run, classified after the structure repair.
    var touchedProjects: [EntityID] = []
    var touchedSections: [EntityID] = []
    var touchedTasks: [EntityID] = []
    var touchedLabels: [EntityID] = []

    /// `TodoStore.inboxID` (main-actor isolated, so repeated here).
    static let inboxID: EntityID = "inbox"

    init(snapshot: TodoistSnapshot, db: Database, options: TodoistImportOptions, now: Date) {
        self.snapshot = snapshot; self.original = db; self.db = db; self.options = options; self.now = now
    }

    mutating func run() {
        if snapshot.invalidEntries > 0 {
            report.warnings.append("\(snapshot.invalidEntries) entries in the snapshot could not be read and were skipped.")
        }
        importProjects()
        importSections()
        importLabels()
        importTasks()
        SyncEngine.repairStructure(&db)
        classify()
    }

    // MARK: Projects

    mutating func importProjects() {
        var live: [TodoistProject] = []
        var seen = Set<String>()
        for p in snapshot.projects {
            if p.isDeleted || p.isArchived || !seen.insert(p.id).inserted { report.projects.skipped += 1 } else { live.append(p) }
        }
        let inbox = live.filter(\.isInbox).sorted(by: Self.byOrder).first
        if let inbox { projectMap[inbox.id] = Self.inboxID }
        let others = live.filter { $0.id != inbox?.id }
        let byID = Dictionary(others.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Children by parent; a project whose parent is missing (archived, the inbox, unknown)
        // or part of a cycle is a root.
        var children: [String: [TodoistProject]] = [:]
        var roots: [TodoistProject] = []
        for p in others {
            if let pid = p.parentId, byID[pid] != nil, !Self.hasCycle(p.id, byID) {
                children[pid, default: []].append(p)
            } else {
                roots.append(p)
            }
        }

        var nextOrder = (original.projects.values.filter { !$0.deleted && !$0.isInbox }.map(\.order).max() ?? 0) + 1
        func visit(_ p: TodoistProject, path: [String]) {
            let name = path + [Self.clip(p.name.isEmpty ? "Untitled" : p.name, SyncLimits.maxNameLength)]
            let id = TodoistImport.entityID(.project, p.id)
            let fullName = Self.clip(name.joined(separator: " / "), SyncLimits.maxNameLength)
            let color = TodoistColors.paletteKey(p.color)
            if let existing = original.projects[id] {
                if existing.deleted && !options.restoreDeleted {
                    report.projects.skipped += 1
                } else {
                    var u = existing
                    u.name = fullName; u.color = color; u.isInbox = false; u.deleted = false
                    db.projects[id] = u
                    projectMap[p.id] = id
                    touchedProjects.append(id)
                }
            } else {
                db.projects[id] = Project(id: id, name: fullName, color: color, order: nextOrder, updatedAt: now)
                nextOrder += 1
                projectMap[p.id] = id
                touchedProjects.append(id)
            }
            for c in (children[p.id] ?? []).sorted(by: Self.byOrder) { visit(c, path: name) }
        }
        for r in roots.sorted(by: Self.byOrder) { visit(r, path: []) }
    }

    static func hasCycle(_ start: String, _ byID: [String: TodoistProject]) -> Bool {
        var seen: Set<String> = [start]
        var cur = byID[start]?.parentId
        while let c = cur, let p = byID[c] {
            if !seen.insert(c).inserted { return true }
            cur = p.parentId
        }
        return false
    }

    static func byOrder(_ a: TodoistProject, _ b: TodoistProject) -> Bool {
        orderLess((a.childOrder, a.orderKey, a.id), (b.childOrder, b.orderKey, b.id))
    }

    // MARK: Sections

    mutating func importSections() {
        var groups: [EntityID: [TodoistSection]] = [:]
        var seen = Set<String>()
        for s in snapshot.sections {
            guard !s.isDeleted, !s.isArchived, seen.insert(s.id).inserted, let pid = projectMap[s.projectId] else {
                report.sections.skipped += 1
                continue
            }
            groups[pid, default: []].append(s)
        }
        for (projectId, sections) in groups {
            let sorted = sections.sorted { Self.orderLess(($0.sectionOrder, $0.orderKey, $0.id), ($1.sectionOrder, $1.orderKey, $1.id)) }
            for (i, s) in sorted.enumerated() {
                let id = TodoistImport.entityID(.section, s.id)
                let name = Self.clip(s.name.isEmpty ? "Untitled" : s.name, SyncLimits.maxNameLength)
                if let existing = original.sections[id], existing.deleted, !options.restoreDeleted {
                    report.sections.skipped += 1
                    continue
                }
                var sec = original.sections[id] ?? Section(id: id, projectId: projectId, name: name, order: 0, updatedAt: now)
                sec.projectId = projectId; sec.name = name; sec.order = Double(i + 1); sec.deleted = false
                db.sections[id] = sec
                sectionMap[s.id] = id
                touchedSections.append(id)
            }
        }
    }

    // MARK: Labels

    mutating func importLabels() {
        var seen = Set<String>()
        var live: [TodoistLabel] = []
        for l in snapshot.labels {
            let name = l.name.trimmingCharacters(in: .whitespaces)
            if l.isDeleted || name.isEmpty || !seen.insert(l.id).inserted { report.labels.skipped += 1 } else { live.append(l) }
        }
        live.sort { Self.orderLess(($0.order, nil, $0.id), ($1.order, nil, $1.id)) }
        for l in live {
            let name = Self.clip(l.name.trimmingCharacters(in: .whitespaces), SyncLimits.maxNameLength)
            upsertLabel(id: TodoistImport.entityID(.label, l.id), name: name, color: TodoistColors.paletteKey(l.color))
        }
        // Labels used by tasks but not listed (shared labels, hand-made snapshots).
        for t in snapshot.tasks {
            for raw in t.labels {
                let name = Self.clip(raw.trimmingCharacters(in: .whitespaces), SyncLimits.maxNameLength)
                guard !name.isEmpty, labelNames[name.lowercased()] == nil else { continue }
                upsertLabel(id: TodoistImport.entityID(.labelName, name.lowercased()), name: name, color: "charcoal")
            }
        }
    }

    /// Updates our label `id`, or reuses a live TodoTim label with the same name (case-insensitive),
    /// or creates the label.
    mutating func upsertLabel(id: EntityID, name: String, color: String) {
        let key = name.lowercased()
        if labelNames[key] != nil {  // Two Todoist labels differing only in case.
            report.labels.skipped += 1
            return
        }
        if let existing = db.labels[id], !(existing.deleted && !options.restoreDeleted) {
            var l = existing
            if l.name != name, !existing.deleted { renameLabelOnTasks(from: l.name, to: name) }
            l.name = name; l.color = color; l.deleted = false
            db.labels[id] = l
            labelNames[key] = name
            touchedLabels.append(id)
        } else if let match = db.labels.values.first(where: { !$0.deleted && $0.name.lowercased() == key }) {
            labelNames[key] = match.name
            report.labels.unchanged += 1
        } else if db.labels[id] != nil {
            // Deleted in TodoTim and not restored: tasks keep the name, but no label entity.
            labelNames[key] = name
            report.labels.skipped += 1
        } else {
            let order = (db.labels.values.filter { !$0.deleted }.map(\.order).max() ?? 0) + 1
            db.labels[id] = Label(id: id, name: name, color: color, order: order, updatedAt: now)
            labelNames[key] = name
            touchedLabels.append(id)
        }
    }

    mutating func renameLabelOnTasks(from old: String, to new: String) {
        for (id, var t) in db.tasks where t.labels.contains(old) {
            t.labels = t.labels.map { $0 == old ? new : $0 }
            t.updatedAt = now
            db.tasks[id] = t
        }
    }

    // MARK: Tasks

    mutating func importTasks() {
        // 1. Which tasks are imported.
        var accepted: [TodoistTask] = []
        var seen = Set<String>()
        for t in snapshot.tasks {
            guard !t.isDeleted, seen.insert(t.id).inserted, projectMap[t.projectId] != nil else {
                report.tasks.skipped += 1
                continue
            }
            let id = TodoistImport.entityID(.task, t.id)
            let existing = original.tasks[id]
            if let existing, existing.deleted, !options.restoreDeleted {
                report.tasks.skipped += 1
                continue
            }
            if t.checked, !options.includeCompleted, existing == nil || existing!.deleted {
                report.tasks.skipped += 1
                continue
            }
            accepted.append(t)
        }
        let acceptedIDs = Set(accepted.map(\.id))

        // 2. Location. A subtask whose parent is not imported (and not already in TodoTim) becomes
        //    top-level; `repairStructure` moves subtasks to their root's project and section.
        struct Placed { var task: TodoistTask; var projectId: EntityID; var sectionId: EntityID?; var parentId: EntityID? }
        var placed: [Placed] = []
        for t in accepted {
            let projectId = projectMap[t.projectId]!
            var parentId: EntityID?
            if let pid = t.parentId, pid != t.id {
                let ours = TodoistImport.entityID(.task, pid)
                if acceptedIDs.contains(pid) || (db.tasks[ours].map { !$0.deleted } ?? false) { parentId = ours }
            }
            var sectionId: EntityID?
            if let sid = t.sectionId, let mapped = sectionMap[sid], db.sections[mapped]?.projectId == projectId { sectionId = mapped }
            placed.append(Placed(task: t, projectId: projectId, sectionId: sectionId, parentId: parentId))
        }

        // 3. Sibling order: rank within (parent) or (project, section).
        var rank: [String: Double] = [:]
        let groups = Dictionary(grouping: placed) { p in p.parentId ?? "\(p.projectId)/\(p.sectionId ?? "")" }
        for (_, siblings) in groups {
            let sorted = siblings.sorted {
                Self.orderLess(($0.task.childOrder, $0.task.orderKey, $0.task.id), ($1.task.childOrder, $1.task.orderKey, $1.task.id))
            }
            for (i, p) in sorted.enumerated() { rank[p.task.id] = Double(i + 1) }
        }

        // 4. Write.
        var recurring = 0, badDue = 0
        for p in placed {
            let t = p.task
            let id = TodoistImport.entityID(.task, t.id)
            let existing = original.tasks[id]  // may be a tombstone being restored
            var due: DueDate?
            if let d = t.due {
                if let day = d.day { due = DueDate(date: day) } else { badDue += 1 }
                if d.isRecurring { recurring += 1 }
            }
            var labels: [String] = []
            for raw in t.labels {
                let name = Self.clip(raw.trimmingCharacters(in: .whitespaces), SyncLimits.maxNameLength)
                guard !name.isEmpty, let mapped = labelNames[name.lowercased()], !labels.contains(mapped) else { continue }
                labels.append(mapped)
            }
            if labels.count > SyncLimits.maxLabelsPerTask { labels = Array(labels.prefix(SyncLimits.maxLabelsPerTask)) }
            let completedAt: Date? = t.checked
                ? (existing?.isCompleted == true && existing?.deleted == false ? existing?.completedAt : nil) ?? Self.parseDate(t.completedAt) ?? now
                : nil
            let task = TodoTask(
                id: id, projectId: p.projectId, sectionId: p.sectionId, parentId: p.parentId,
                content: Self.clip(t.content, SyncLimits.maxContentLength),
                description: Self.clip(t.description, SyncLimits.maxDescriptionLength),
                priority: Priority(rawValue: 5 - min(max(t.priority, 1), 4)) ?? .p4,
                due: due, labels: labels, isCompleted: t.checked, completedAt: completedAt,
                order: rank[t.id] ?? 1, collapsed: existing?.collapsed ?? t.isCollapsed,
                createdAt: existing?.createdAt ?? Self.parseDate(t.addedAt) ?? now,
                updatedAt: original.tasks[id]?.updatedAt ?? now, deleted: false)
            db.tasks[id] = task
            touchedTasks.append(id)
        }
        if recurring > 0 {
            report.warnings.append("\(recurring) recurring task\(recurring == 1 ? "" : "s") imported with only the next due date (TodoTim has no recurrence).")
        }
        if badDue > 0 {
            report.warnings.append("\(badDue) task\(badDue == 1 ? " has" : "s have") an unreadable due date; imported without one.")
        }
    }

    // MARK: Classification

    /// Compares each written entity with the original; bumps `updatedAt` only for real changes.
    mutating func classify() {
        let now = self.now
        func run<T: SyncEntity>(_ ids: [EntityID], _ table: inout [EntityID: T], _ original: [EntityID: T]) -> ImportReport.Counts {
            var counts = ImportReport.Counts()
            for id in ids {
                guard var new = table[id] else { continue }
                if let old = original[id] {
                    new.updatedAt = old.updatedAt
                    if new == old {
                        counts.unchanged += 1
                        table[id] = old
                        continue
                    }
                    counts.updated += 1
                } else {
                    counts.created += 1
                }
                new.updatedAt = now
                table[id] = new
            }
            return counts
        }
        func add(_ a: inout ImportReport.Counts, _ b: ImportReport.Counts) {
            a.created += b.created; a.updated += b.updated; a.unchanged += b.unchanged; a.skipped += b.skipped
        }
        add(&report.projects, run(touchedProjects, &db.projects, original.projects))
        add(&report.sections, run(touchedSections, &db.sections, original.sections))
        add(&report.labels, run(touchedLabels, &db.labels, original.labels))
        add(&report.tasks, run(touchedTasks, &db.tasks, original.tasks))
    }

    // MARK: Helpers

    /// Todoist order: `child_order` (missing sorts last), then `order_key`, then id.
    static func orderLess(_ a: (Int?, String?, String), _ b: (Int?, String?, String)) -> Bool {
        let oa = a.0 ?? Int.max, ob = b.0 ?? Int.max
        if oa != ob { return oa < ob }
        let ka = a.1 ?? "", kb = b.1 ?? ""
        if ka != kb { return ka < kb }
        return a.2 < b.2
    }

    static func clip(_ s: String, _ max: Int) -> String {
        s.count > max ? String(s.prefix(max)) : s
    }

    /// ISO 8601 with or without fractional seconds (Todoist sends up to 6 digits).
    static func parseDate(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            s.removeSubrange(dot..<end)
        } else if let dot = s.firstIndex(of: ".") {
            s.removeSubrange(dot...)
        }
        if !s.contains("Z"), s.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil, s.count == 19 { s += "Z" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s).map(TodoStore.millisecondPrecision)
    }
}
