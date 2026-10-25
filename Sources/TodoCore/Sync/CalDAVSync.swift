import Foundation

/// What the last sync saw on the server: the base for three-way merges. Stored next to the
/// database (`caldav-state.json`); it must be saved after the database it belongs to.
public struct CalDAVState: Codable, Equatable, Sendable {
    /// "<DAV root>|<username>". State for another account is discarded.
    public var account: String
    /// Calendars by path, with the sync token up to which their tasks are in `resources`.
    var calendars: [String: RemoteCalendar] = [:]
    /// Calendar objects by path.
    var resources: [String: ResourceRecord] = [:]

    public init(account: String) { self.account = account }

    struct ResourceRecord: Codable, Equatable, Sendable {
        var etag: String?
        var ics: String
    }
}

public struct SyncResult: Equatable, Sendable {
    /// The merged database; becomes the local database.
    public var merged: Database
    public var state: CalDAVState
    /// Problems that did not stop the sync (e.g. a failed share).
    public var warnings: [String] = []
    /// Number of write requests sent.
    public var writes = 0
}

/// Two-way sync between the local database and the user's CalDAV task lists (`docs/caldav.md`).
///
/// Every sync: list the calendars (one PROPFIND), fetch what changed in each calendar whose sync
/// token moved (RFC 6578), then merge three ways per entity: the local version, the server's,
/// and the base (`CalDAVState`, what the previous sync saw). A side that did not change since the
/// base takes the other side's version; when both changed, tasks are last-writer-wins on
/// `updatedAt`/LAST-MODIFIED, and project, section and label fields take the local value. The
/// merged state is then written back: MKCALENDAR/PROPPATCH for lists, PUT/MOVE/DELETE for tasks,
/// every write conditional on the ETag it was based on. A 412 leaves that entity for the next
/// pass, which re-fetches it and merges again.
enum CalDAVSync {
    /// URI of the inbox calendar. Not "inbox": that is the CalDAV scheduling inbox on Nextcloud.
    static let inboxURI = "todotim-inbox"

    static func sync(local: Database, state: CalDAVState, server: CalDAVServer, shareWith: [String] = [],
                     previous: Database? = nil, now: @Sendable () -> Date = { Date() }, maxPasses: Int = 3) async throws -> SyncResult {
        var result = SyncResult(merged: local, state: state)
        var previous = previous
        for _ in 1...maxPasses {
            var round = Pass(local: result.merged, state: result.state, server: server, shareWith: shareWith, now: now())
            let pass = try await round.run(previous: previous)
            result.merged = pass.merged
            result.state = pass.state
            result.warnings += pass.warnings
            result.writes += pass.writes
            if !pass.conflicted { return result }
            previous = nil
        }
        // Keep what was done; the next sync tries the rest again.
        result.warnings.append(SyncError.tooManyConflicts.errorDescription!)
        return result
    }
}

/// One fetch–merge–write round.
private struct Pass {
    let local: Database
    var state: CalDAVState
    let server: CalDAVServer
    let shareWith: [String]
    let now: Date

    var merged = Database()
    var warnings: [String] = []
    var writes = 0
    var conflicted = false

    init(local: Database, state: CalDAVState, server: CalDAVServer, shareWith: [String], now: Date) {
        self.local = local; self.state = state; self.server = server; self.shareWith = shareWith; self.now = now
    }

    // MARK: - Remote view

    /// Server content interpreted as TodoTim entities.
    struct View {
        var calendarOf: [EntityID: RemoteCalendar] = [:]
        var projects: [EntityID: Project] = [:]
        var sections: [EntityID: Section] = [:]
        var labels: [EntityID: Label] = [:]
        /// Projects whose sections come from the calendar property (else from the tasks).
        var hasSectionsProperty: Set<EntityID> = []
        var tasks: [EntityID: (todo: VTodoTask, path: String, etag: String?, ics: String)] = [:]

        func uid(of id: EntityID) -> String { tasks[id]?.todo.uid ?? id }
    }

    /// The project id of a calendar: the inbox, the URI when it is a valid id, else derived.
    static func projectID(uri: String) -> EntityID {
        if uri == CalDAVSync.inboxURI { return TodoStore.inboxID }
        if isValidEntityID(uri) && uri != TodoStore.inboxID { return uri }
        return uuidV5(namespace: VTodo.idNamespace, name: "calendar:" + uri)
    }

    static func view(_ calendars: [String: RemoteCalendar], _ resources: [String: CalDAVState.ResourceRecord]) -> View {
        var v = View()
        for cal in calendars.values.sorted(by: { $0.path < $1.path }) {
            let id = projectID(uri: cal.uri)
            guard v.calendarOf[id] == nil else { continue }
            v.calendarOf[id] = cal
            v.projects[id] = Project(id: id, name: cal.name.map { String($0.prefix(SyncLimits.maxNameLength)) } ?? cal.uri,
                                     color: cal.color.flatMap(ProjectColor.key(hex:)) ?? "charcoal",
                                     order: id == TodoStore.inboxID ? -1 : (cal.order.flatMap(VTodo.finiteDouble) ?? 0),
                                     isInbox: id == TodoStore.inboxID, updatedAt: Date(timeIntervalSince1970: 0))
            if let list = cal.sections.flatMap(PropertyList.decode) {
                v.hasSectionsProperty.insert(id)
                for e in list where v.sections[e.id] == nil {
                    v.sections[e.id] = Section(id: e.id, projectId: id, name: e.name, order: e.order,
                                               updatedAt: Date(timeIntervalSince1970: 0))
                }
            }
            if id == TodoStore.inboxID, let list = cal.labels.flatMap(PropertyList.decode) {
                for e in list where v.labels[e.id] == nil {
                    v.labels[e.id] = Label(id: e.id, name: e.name, color: e.color.flatMap(ProjectColor.key(hex:)) ?? "charcoal",
                                           order: e.order, updatedAt: Date(timeIntervalSince1970: 0))
                }
            }
        }
        let byCalendarPath = Dictionary(v.calendarOf.map { ($0.value.path, $0.key) }, uniquingKeysWith: { a, _ in a })
        for (path, record) in resources.sorted(by: { $0.key < $1.key }) {
            let parent = String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)])
            guard let projectId = byCalendarPath[parent],
                  let todo = VTodoCache.shared.read(path: path, ics: record.ics, projectId: projectId),
                  v.tasks[todo.task.id] == nil else { continue }  // a duplicate UID: the first path wins
            v.tasks[todo.task.id] = (todo, path, record.etag, record.ics)
            // Without the sections property (e.g. a list shared with this user), sections come
            // from the tasks' X-TODOTIM-SECTION parameters.
            if !v.hasSectionsProperty.contains(projectId), let sid = todo.task.sectionId, v.sections[sid] == nil {
                v.sections[sid] = Section(id: sid, projectId: projectId, name: todo.sectionName ?? "Section",
                                          order: todo.sectionOrder ?? 0, updatedAt: Date(timeIntervalSince1970: 0))
            }
        }
        return v
    }

    // MARK: - Run

    mutating func run(previous: Database?) async throws -> Pass {
        let base = Self.view(state.calendars, state.resources)
        let listed = try await server.calendars()
        guard listed.count <= SyncLimits.maxCalendars else {
            throw SyncError.limitExceeded("more than \(SyncLimits.maxCalendars) calendars")
        }

        // Fetch changes.
        var calendars: [String: RemoteCalendar] = [:]
        var resources = state.resources
        var remoteChanged = Set(listed.map(\.path)) != Set(state.calendars.keys)
        for var cal in listed {
            let known = state.calendars[cal.path]
            var withoutToken = cal
            withoutToken.syncToken = known?.syncToken
            if withoutToken != known { remoteChanged = true }
            if let known, let token = cal.syncToken, known.syncToken == token {
                calendars[cal.path] = cal
                continue
            }
            let changes = try await server.changes(in: cal.path, since: known?.syncToken)
            if changes.isFull {
                for path in resources.keys where path.hasPrefix(cal.path + "/") { resources[path] = nil }
            }
            for path in changes.removed { resources[path] = nil }
            for r in changes.changed { resources[r.path] = .init(etag: r.etag, ics: r.ics) }
            if !changes.changed.isEmpty || !changes.removed.isEmpty || changes.isFull { remoteChanged = true }
            cal.syncToken = changes.syncToken
            calendars[cal.path] = cal
        }
        let listedPaths = Set(listed.map(\.path))
        for path in resources.keys {
            let parent = String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)])
            if !listedPaths.contains(parent) { resources[path] = nil }
        }
        guard resources.count <= SyncLimits.maxEntities else {
            throw SyncError.limitExceeded("more than \(SyncLimits.maxEntities) tasks")
        }
        state.calendars = calendars
        state.resources = resources

        // Nothing changed on either side: an idle sync costs one PROPFIND.
        if !remoteChanged, let previous, previous == local {
            merged = local
            return self
        }

        let remote = Self.view(calendars, resources)
        merge(base: base, remote: remote)
        try await write(remote: remote)
        return self
    }

    // MARK: - Merge

    private mutating func merge(base: View, remote: View) {
        var db = Database()

        // Projects: field by field, a local change wins; otherwise the server's value.
        for id in Set(local.projects.keys).union(base.projects.keys).union(remote.projects.keys) {
            let l = local.projects[id], b = base.projects[id], r = remote.projects[id]
            switch (r, b) {
            case let (r?, b):
                guard let l else { db.projects[id] = r; continue }
                if l.deleted {
                    // A list deleted here is deleted on the server only if this device synced it
                    // before; otherwise (and always for the inbox) the server's list comes back.
                    if b != nil && !l.isInbox { db.projects[id] = l } else { db.projects[id] = Self.revived(r, l) }
                    continue
                }
                var p = l
                if b == nil || l.name != b!.name { p.name = l.name } else { p.name = r.name }
                if b == nil || l.color != b!.color { p.color = l.color } else { p.color = r.color }
                if !l.isInbox { p.order = b == nil || l.order != b!.order ? l.order : r.order }
                db.projects[id] = p
            case (nil, _?):
                // Deleted on the server (the inbox is recreated).
                if var l {
                    if !l.isInbox && !l.deleted { l.deleted = true; l.updatedAt = now }
                    db.projects[id] = l
                }
            case (nil, nil):
                if let l { db.projects[id] = l }
            }
        }

        // Sections and labels: the same rules, per entry of the calendar's property.
        db.sections = Self.mergeEntries(local: local.sections, base: base.sections, remote: remote.sections, now: now) { l, b, r in
            var s = l
            s.name = l.name != b.name ? l.name : r.name
            s.order = l.order != b.order ? l.order : r.order
            return s
        }
        db.labels = Self.mergeEntries(local: local.labels, base: base.labels, remote: remote.labels, now: now) { l, b, r in
            var x = l
            x.name = l.name != b.name ? l.name : r.name
            x.color = l.color != b.color ? l.color : r.color
            x.order = l.order != b.order ? l.order : r.order
            return x
        }

        // Tasks.
        for id in Set(local.tasks.keys).union(base.tasks.keys).union(remote.tasks.keys) {
            let l = local.tasks[id], b = base.tasks[id]?.todo.task, r = remote.tasks[id]?.todo.task
            switch (r, b) {
            case let (r?, b?):
                guard let l else { db.tasks[id] = r; continue }
                let localChanged = l != b
                let rr = remote.tasks[id]!, br = base.tasks[id]!
                // The server may hand back our own upload with other line endings: compare ETags first.
                let remoteChanged = rr.path != br.path
                    || (rr.etag != nil && br.etag != nil ? rr.etag != br.etag : rr.ics != br.ics)
                switch (localChanged, remoteChanged) {
                case (false, _): db.tasks[id] = r
                case (true, false): db.tasks[id] = l
                case (true, true): db.tasks[id] = SyncEngine.winner(l, r)
                }
            case let (r?, nil):
                // New on the server, or created on both sides (e.g. a migration run twice).
                db.tasks[id] = l.map { SyncEngine.winner($0, r) } ?? r
            case (nil, _?):
                // Deleted on the server.
                if var l {
                    if !l.deleted { l.deleted = true; l.updatedAt = now }
                    db.tasks[id] = l
                }
            case (nil, nil):
                if let l { db.tasks[id] = l }
            }
        }

        // Tags from other clients (CATEGORIES) become labels; the id is derived from the name,
        // so every device creates the same one.
        var labelNames = Set(db.labels.values.filter { !$0.deleted }.map(\.name))
        var nextLabelOrder = (db.labels.values.map(\.order).max() ?? 0) + 1
        for t in db.tasks.values.sorted(by: { $0.id < $1.id }) where !t.deleted {
            for name in t.labels where !labelNames.contains(name) {
                let lid = uuidV5(namespace: VTodo.idNamespace, name: "label:" + name)
                db.labels[lid] = Label(id: lid, name: name, order: nextLabelOrder, updatedAt: now)
                labelNames.insert(name)
                nextLabelOrder += 1
            }
        }

        // Calendar order is an integer on the server: renumber the lists 1…N when needed.
        let lists = db.projects.values.filter { !$0.deleted && !$0.isInbox }.sorted { TodoStore.byOrder($0, $1) }
        if lists.contains(where: { $0.order != $0.order.rounded() }) {
            for (i, p) in lists.enumerated() where db.projects[p.id]!.order != Double(i + 1) {
                db.projects[p.id]!.order = Double(i + 1)
            }
        }

        // Tombstones of tasks still on the server stay until their DELETE succeeds.
        let pending = Set(db.tasks.values.filter { $0.deleted && remote.tasks[$0.id] != nil }.map(\.id))
            .union(db.projects.values.filter { $0.deleted && remote.calendarOf[$0.id] != nil }.map(\.id))
        merged = SyncEngine.clean(db, now: now, keepTombstones: pending)
    }

    /// A project the server still has although it was deleted here before it was ever synced.
    private static func revived(_ remote: Project, _ local: Project) -> Project {
        var p = remote
        p.updatedAt = local.updatedAt
        return p
    }

    /// Three-way merge of section or label entries (which have no server timestamps). Removed on
    /// the server → deleted here; deleted here → removed on the server; changed on both → `fields`.
    private static func mergeEntries<T: SyncEntity>(local: [EntityID: T], base: [EntityID: T], remote: [EntityID: T], now: Date,
                                                    fields: (T, T, T) -> T) -> [EntityID: T] {
        var out: [EntityID: T] = [:]
        for id in Set(local.keys).union(base.keys).union(remote.keys) {
            let l = local[id], b = base[id], r = remote[id]
            switch (r, b) {
            case let (r?, b?):
                guard let l else { out[id] = r; continue }
                out[id] = l.deleted ? l : fields(l, b, r)
            case let (r?, nil):
                out[id] = l ?? r
            case (nil, _?):
                if var l {
                    if !l.deleted { l.deleted = true; l.updatedAt = now }
                    out[id] = l
                }
            case (nil, nil):
                if let l { out[id] = l }
            }
        }
        return out
    }

    // MARK: - Write

    private mutating func write(remote: View) async throws {
        let home = server.home
        func calendarPath(_ projectId: EntityID) -> String {
            remote.calendarOf[projectId]?.path ?? "\(home)/\(projectId == TodoStore.inboxID ? CalDAVSync.inboxURI : projectId)"
        }

        // 1. Lists: create, then update properties. A list that cannot be created is reported and
        //    its tasks wait; the other lists still sync.
        let projects = merged.projects.values.sorted { $0.id < $1.id }
        var unavailable = Set<EntityID>()
        for p in projects where !p.deleted {
            let path = calendarPath(p.id)
            var props = calendarProperties(p)
            var cal: RemoteCalendar
            if let existing = remote.calendarOf[p.id] {
                cal = existing
            } else {
                do {
                    try await server.createCalendar(path, name: props[.name]!!, color: props[.color]!!, order: props[.order]!!)
                } catch let e as SyncError where e.isPerResource {
                    warnings.append(SyncController.message(for: e))
                    unavailable.insert(p.id)
                    continue
                }
                writes += 1
                cal = RemoteCalendar(path: path, name: props[.name]!, color: props[.color]!, order: props[.order]!)
                state.calendars[path] = cal
                for user in shareWith {
                    do {
                        try await server.share(path, with: user)
                        writes += 1
                    } catch {
                        warnings.append("Could not share “\(p.name)” with \(user): \(SyncController.message(for: error))")
                    }
                }
            }
            props = props.filter { key, value in
                switch key {
                case .name: value != cal.name
                case .color: value.flatMap(ProjectColor.key(hex:)) != cal.color.flatMap(ProjectColor.key(hex:))
                case .order: !p.isInbox && value.flatMap(VTodo.finiteDouble) != cal.order.flatMap(VTodo.finiteDouble)
                case .sections: value.flatMap(PropertyList.decode) != cal.sections.flatMap(PropertyList.decode)
                case .labels: value.flatMap(PropertyList.decode) != cal.labels.flatMap(PropertyList.decode)
                }
            }
            if !props.isEmpty {
                do {
                    try await server.setProperties(path, props)
                } catch let e as SyncError where e.isPerResource {
                    warnings.append(SyncController.message(for: e))
                    continue
                }
                writes += 1
                for (k, v) in props {
                    switch k {
                    case .name: cal.name = v
                    case .color: cal.color = v
                    case .order: cal.order = v
                    case .sections: cal.sections = v
                    case .labels: cal.labels = v
                    }
                }
                state.calendars[path] = cal
            }
        }

        // 2. Tasks, a few at a time.
        let liveProjects = Set(merged.projects.values.filter { !$0.deleted }.map(\.id)).subtracting(unavailable)
        var ops: [TaskOp] = []
        for t in merged.tasks.values.sorted(by: { $0.id < $1.id }) where liveProjects.contains(t.projectId) {
            let r = remote.tasks[t.id]
            let section = t.sectionId.flatMap { merged.sections[$0] }.flatMap { $0.deleted ? nil : $0 }
            let parentUID = t.parentId.map { remote.uid(of: $0) }
            if t.deleted {
                if let r { ops.append(.delete(path: r.path, etag: r.etag)) }
                continue
            }
            let target = calendarPath(t.projectId)
            guard let r else {
                ops.append(.put(id: t.id, path: "\(target)/\(t.id).ics", projectId: t.projectId,
                                ics: VTodo.make(t, uid: t.id, parentUID: parentUID, section: section), etag: nil, moveFrom: nil))
                continue
            }
            let parent = String(r.path[..<(r.path.lastIndex(of: "/") ?? r.path.startIndex)])
            let movePath = parent == target ? nil : "\(target)/\(r.path.split(separator: "/").last!)"
            if let movePath, state.resources[movePath] != nil {
                // Another object already has this name in the target list (a duplicate UID).
                warnings.append("Could not move “\(t.content)”: “\(movePath)” already exists on the server")
                continue
            }
            let patched = VTodo.patch(r.ics, old: r.todo, to: t, parentUID: parentUID, section: section)
            if patched == nil && movePath == nil {
                merged.tasks[t.id] = r.todo.task  // same content: adopt the server's (second-precision) copy
                continue
            }
            ops.append(.put(id: t.id, path: movePath ?? r.path, projectId: t.projectId, ics: patched, etag: r.etag,
                            moveFrom: movePath == nil ? nil : r.path))
        }
        let server = self.server
        let outcomes = try await SyncEngine.forEachConcurrently(ops, limit: SyncEngine.maxConcurrentRequests) { op in
            try await Self.execute(op, server: server)
        }
        for (op, outcome) in zip(ops, outcomes) {
            switch outcome {
            case .conflict:
                conflicted = true
            case .failed(let message):
                warnings.append(message)
            case .done(let requests, let etag):
                writes += requests
                switch op {
                case .delete(let path, _):
                    // The local tombstone stays until it expires (`SyncEngine.tombstoneLifetime`).
                    state.resources[path] = nil
                case .put(let id, let path, let projectId, let patched, let oldETag, let moveFrom):
                    var record = moveFrom.flatMap { state.resources.removeValue(forKey: $0) }
                    if let patched { record = .init(etag: etag, ics: patched) } else { record?.etag = etag ?? oldETag }
                    guard let record else { continue }
                    state.resources[path] = record
                    let ics = record.ics
                    // The task as the server now holds it (whole-second times), so the next sync
                    // sees no local change.
                    if let t = VTodoCache.shared.read(path: path, ics: ics, projectId: projectId)?.task, t.id == id {
                        merged.tasks[id] = t
                    }
                }
            }
        }

        // 3. Deleted lists last (their tasks go with them).
        for p in projects where p.deleted && !p.isInbox {
            guard let cal = remote.calendarOf[p.id] else { continue }
            try await server.deleteCalendar(cal.path)
            writes += 1
            state.calendars[cal.path] = nil
            for path in state.resources.keys where path.hasPrefix(cal.path + "/") { state.resources[path] = nil }
        }
    }

    /// The calendar properties for a project (sections on every list, labels on the inbox).
    private func calendarProperties(_ p: Project) -> [CalendarProperty: String?] {
        var props: [CalendarProperty: String?] = [
            .name: p.name,
            .color: ProjectColor.hex(p.color),
            .order: p.isInbox ? "0" : VTodo.format(p.order),
        ]
        let sections = merged.sections.values.filter { $0.projectId == p.id && !$0.deleted }.sorted { TodoStore.byOrder($0, $1) }
        props[.sections] = PropertyList.encode(sections.map { .init(id: $0.id, name: $0.name, order: $0.order) })
        if p.isInbox {
            let labels = merged.labels.values.filter { !$0.deleted }.sorted { TodoStore.byOrder($0, $1) }
            props[.labels] = PropertyList.encode(labels.map { .init(id: $0.id, name: $0.name, order: $0.order, color: ProjectColor.hex($0.color)) })
        }
        return props
    }

    enum TaskOp: Sendable {
        /// PUT `ics` at `path` (`etag` nil: create); with `moveFrom`, MOVE it there first (then `ics`
        /// nil means the content stays as it is).
        case put(id: EntityID, path: String, projectId: EntityID, ics: String?, etag: String?, moveFrom: String?)
        case delete(path: String, etag: String?)
    }

    enum Outcome: Sendable {
        case done(requests: Int, etag: String?)
        /// 412: the server version changed; the next pass merges it.
        case conflict
        /// Refused for this task only (e.g. 403); reported, retried next sync.
        case failed(String)
    }

    private static func execute(_ op: TaskOp, server: CalDAVServer) async throws -> Outcome {
        do {
            switch op {
            case .delete(let path, let etag):
                try await server.delete(path, ifMatch: etag)
                return .done(requests: 1, etag: nil)
            case .put(_, let path, _, let ics, let etag, let moveFrom):
                var requests = 0
                if let moveFrom {
                    try await server.move(moveFrom, to: path, ifMatch: etag)
                    requests += 1
                }
                guard let ics else { return .done(requests: requests, etag: nil) }
                // MOVE keeps the ETag, so the same precondition holds for the PUT.
                let newETag = try await server.put(path, ics: ics, ifMatch: etag)
                return .done(requests: requests + 1, etag: newETag)
            }
        } catch SyncError.preconditionFailed {
            return .conflict
        } catch let e as SyncError where e.isPerResource {
            return .failed(SyncController.message(for: e))
        }
    }
}

/// The JSON of the sections and labels calendar properties: `[{"id","name","order"}]`, labels
/// with `"color"` (`#RRGGBB`). Entries with an invalid id are dropped; text is clipped.
enum PropertyList {
    struct Entry: Codable, Equatable, Sendable {
        var id: EntityID
        var name: String
        var order: Double
        var color: String?
    }

    static func decode(_ json: String) -> [Entry]? {
        guard json.utf8.count <= SyncLimits.maxPropertyBytes,
              let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else { return nil }
        var out: [Entry] = []
        var seen = Set<EntityID>()
        for item in raw.prefix(SyncLimits.maxPropertyEntries) {
            guard let o = item as? [String: Any], let id = o["id"] as? String, isValidEntityID(id), seen.insert(id).inserted
            else { continue }
            let name = (o["name"] as? String).map { String($0.prefix(SyncLimits.maxNameLength)) } ?? ""
            let order = (o["order"] as? NSNumber)?.doubleValue ?? 0
            let color = (o["color"] as? String).map { String($0.prefix(SyncLimits.maxColorLength)) }
            out.append(Entry(id: id, name: name, order: order.isFinite ? order : 0, color: color))
        }
        return out
    }

    static func encode(_ entries: [Entry]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: enc.encode(entries), as: UTF8.self)) ?? "[]"
    }
}

/// Parsed calendar objects by path and content, so an unchanged task is parsed once per launch.
final class VTodoCache: @unchecked Sendable {
    static let shared = VTodoCache()
    private let lock = NSLock()
    private var entries: [String: (ics: String, projectId: EntityID, todo: VTodoTask?)] = [:]

    func read(path: String, ics: String, projectId: EntityID) -> VTodoTask? {
        if let e = lock.withLock({ entries[path] }), e.ics == ics, e.projectId == projectId { return e.todo }
        let todo = VTodo.read(ics, projectId: projectId)
        lock.withLock {
            if entries.count > 2 * SyncLimits.maxTasks { entries = [:] }
            entries[path] = (ics, projectId, todo)
        }
        return todo
    }
}
