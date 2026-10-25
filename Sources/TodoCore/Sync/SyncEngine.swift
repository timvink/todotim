import Foundation

/// Bounds on remote data, so a broken or hostile server cannot exhaust memory or stack.
public enum SyncLimits {
    /// Per HTTP response body, enforced while streaming.
    public static let maxResponseBytes = 32 * 1024 * 1024
    /// Entries in one PROPFIND or REPORT response.
    public static let maxListingEntries = 10_000
    /// Tasks in one calendar, and calendars in the home.
    public static let maxTasks = 50_000
    public static let maxCalendars = 1_000
    /// Projects + labels + sections + tasks synced.
    public static let maxEntities = 200_000
    /// Entries in a sections or labels property, and its size in bytes.
    public static let maxPropertyEntries = 5_000
    public static let maxPropertyBytes = 1 << 20
    /// Largest Todoist snapshot file imported.
    public static let maxSnapshotBytes = 256 * 1024 * 1024
    /// Text limits in characters; longer remote values are truncated.
    public static let maxContentLength = 10_000
    public static let maxDescriptionLength = 100_000
    /// Project, section and label names, and label names on tasks.
    public static let maxNameLength = 1_000
    public static let maxColorLength = 64
    public static let maxLabelsPerTask = 100
    /// Subtask nesting depth (a top-level task has depth 0); deeper tasks are detached.
    public static let maxTaskDepth = 32
}

/// Database-level rules shared by sync (`CalDAVSync`) and its tests: last-writer-wins between
/// two versions of an entity, validation of remote data, tombstone purging and the structural
/// repair that makes any merged state a valid tree.
public enum SyncEngine {
    public static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600

    /// Normalizes a merged database: validates it (`sanitize`), purges old tombstones (except
    /// those in `keepTombstones`, whose server delete is still pending) and repairs the task
    /// hierarchy (`repairStructure`).
    public static func clean(_ db: Database, now: Date = Date(), keepTombstones: Set<EntityID> = []) -> Database {
        var out = db
        sanitize(&out)
        out = normalize(out, now: now, keep: keepTombstones)
        repairStructure(&out)
        return out
    }

    /// Timestamps are compared at millisecond precision, which is what the database stores.
    static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    /// Last-writer-wins. Ties: deleted wins; otherwise `a` if equivalent, else a deterministic
    /// choice (larger canonical JSON) so that all devices pick the same version.
    static func winner<T: SyncEntity>(_ a: T, _ b: T) -> T {
        if a == b { return a }
        let ma = millis(a.updatedAt), mb = millis(b.updatedAt)
        if ma != mb { return ma > mb ? a : b }
        if a.deleted != b.deleted { return a.deleted ? a : b }
        var bSameDate = b
        bSameDate.updatedAt = a.updatedAt
        if a == bSameDate { return a }
        let ea = (try? JSONCoding.encoder.encode(a)) ?? Data()
        let eb = (try? JSONCoding.encoder.encode(b)) ?? Data()
        return ea.lexicographicallyPrecedes(eb) ? b : a
    }

    /// Purges tombstones older than `tombstoneLifetime` (except ids in `keep`) and removes
    /// sections/tasks of deleted projects (deleting the calendar deletes them on the server).
    static func normalize(_ db: Database, now: Date, keep ids: Set<EntityID>) -> Database {
        let cutoff = now.addingTimeInterval(-tombstoneLifetime)
        func keep<T: SyncEntity>(_ e: T) -> Bool { !(e.deleted && e.updatedAt < cutoff) || ids.contains(e.id) }
        var out = db
        let deletedProjects = Set(db.projects.values.filter(\.deleted).map(\.id))
        out.projects = db.projects.filter { keep($0.value) }
        out.labels = db.labels.filter { keep($0.value) }
        out.sections = db.sections.filter { keep($0.value) && !deletedProjects.contains($0.value.projectId) }
        out.tasks = db.tasks.filter { keep($0.value) && !deletedProjects.contains($0.value.projectId) }
        return out
    }

    // MARK: - Validation

    /// Drops entities whose id or project/section/parent reference is not a valid id
    /// (`isValidEntityID`) and truncates over-long text (`SyncLimits`). Returns the number of
    /// dropped entities. Deterministic and leaves `updatedAt` alone, so devices converge.
    @discardableResult
    static func sanitize(_ db: inout Database) -> Int {
        func ok(_ id: EntityID?) -> Bool { id.map(isValidEntityID) ?? true }
        func clip(_ s: String, _ max: Int) -> String? {
            guard s.utf8.count > max, s.count > max else { return nil }
            return String(s.prefix(max))
        }
        var dropped = 0
        func drop<T>(_ dict: inout [EntityID: T], where invalid: (EntityID, T) -> Bool) {
            let bad = dict.filter { invalid($0.key, $0.value) }.map(\.key)
            for id in bad { dict[id] = nil }
            dropped += bad.count
        }
        drop(&db.projects) { k, p in !isValidEntityID(k) || p.id != k }
        drop(&db.labels) { k, l in !isValidEntityID(k) || l.id != k }
        drop(&db.sections) { k, s in !isValidEntityID(k) || s.id != k || !isValidEntityID(s.projectId) }
        drop(&db.tasks) { k, t in
            !isValidEntityID(k) || t.id != k || !isValidEntityID(t.projectId) || !ok(t.sectionId) || !ok(t.parentId)
        }

        for (id, p) in db.projects {
            if let v = clip(p.name, SyncLimits.maxNameLength) { db.projects[id]!.name = v }
            if let v = clip(p.color, SyncLimits.maxColorLength) { db.projects[id]!.color = v }
        }
        for (id, l) in db.labels {
            if let v = clip(l.name, SyncLimits.maxNameLength) { db.labels[id]!.name = v }
            if let v = clip(l.color, SyncLimits.maxColorLength) { db.labels[id]!.color = v }
        }
        for (id, s) in db.sections {
            if let v = clip(s.name, SyncLimits.maxNameLength) { db.sections[id]!.name = v }
        }
        for (id, t) in db.tasks {
            if let v = clip(t.content, SyncLimits.maxContentLength) { db.tasks[id]!.content = v }
            if let v = clip(t.description, SyncLimits.maxDescriptionLength) { db.tasks[id]!.description = v }
            if let due = t.due, due.date.utf8.count > 32 { db.tasks[id]!.due = nil }
            if t.labels.count > SyncLimits.maxLabelsPerTask || t.labels.contains(where: { $0.utf8.count > SyncLimits.maxNameLength }) {
                db.tasks[id]!.labels = t.labels.prefix(SyncLimits.maxLabelsPerTask).map { clip($0, SyncLimits.maxNameLength) ?? $0 }
            }
        }
        return dropped
    }

    // MARK: - Structural repair

    /// Entity-by-entity merging can produce hierarchies no single device created. Repairs live
    /// tasks deterministically, so every device computes the same result from the same merge:
    /// 1. A subtask whose parent is missing or deleted becomes a top-level task.
    /// 2. Parent cycles are broken: in each cycle, the task with the newest `updatedAt` (then the
    ///    largest id) becomes top-level.
    /// 3. Nesting is capped: a task at depth `SyncLimits.maxTaskDepth + 1` (or a multiple of it)
    ///    becomes top-level, so no task is deeper than `maxTaskDepth`.
    /// 4. A top-level task whose section is missing, deleted or in another project moves to the
    ///    project's top area.
    /// 5. Subtasks take the projectId and sectionId of their root task.
    /// `updatedAt` is not bumped: the repair is a pure function of the merged state, so devices
    /// converge without generating new versions.
    public static func repairStructure(_ db: inout Database) {
        func live(_ id: EntityID?) -> TodoTask? {
            guard let id, let t = db.tasks[id], !t.deleted else { return nil }
            return t
        }
        // Iteration order does not affect the result: each step is per task, and parent cycles are
        // disjoint, so each is found once with the same victim wherever the walk starts.
        let liveIDs = db.tasks.values.filter { !$0.deleted }.map(\.id)

        // 1. Orphans.
        for id in liveIDs {
            if let pid = db.tasks[id]?.parentId, live(pid) == nil { db.tasks[id]?.parentId = nil }
        }

        // 2. Cycles. state: 1 = on the current path, 2 = known to reach a root.
        var state: [EntityID: UInt8] = [:]
        for start in liveIDs where state[start] == nil {
            var path: [EntityID] = []
            var cur: EntityID? = start
            while let c = cur, state[c] == nil {
                state[c] = 1
                path.append(c)
                cur = db.tasks[c]?.parentId
            }
            if let c = cur, state[c] == 1, let from = path.firstIndex(of: c) {
                let cycle = path[from...]
                let victim = cycle.max { a, b in
                    let ma = millis(db.tasks[a]!.updatedAt), mb = millis(db.tasks[b]!.updatedAt)
                    return ma == mb ? a < b : ma < mb
                }!
                db.tasks[victim]?.parentId = nil
            }
            for p in path { state[p] = 2 }
        }

        // 3. Depth cap (hierarchy is acyclic now). Depths are computed iteratively from the
        //    original tree, so the result does not depend on iteration order.
        var depth: [EntityID: Int] = [:]
        var tooDeep: [EntityID] = []
        let period = SyncLimits.maxTaskDepth + 1
        for start in liveIDs where depth[start] == nil {
            var chain: [EntityID] = []
            var cur = start
            while depth[cur] == nil, let pid = db.tasks[cur]?.parentId {
                chain.append(cur)
                cur = pid
            }
            var d = depth[cur] ?? 0
            depth[cur] = d
            for c in chain.reversed() {
                d += 1
                depth[c] = d
                if d % period == 0 { tooDeep.append(c) }
            }
        }
        for id in tooDeep { db.tasks[id]?.parentId = nil }

        // 4. Sections of top-level tasks.
        for id in liveIDs {
            guard let t = db.tasks[id], t.parentId == nil, let sid = t.sectionId else { continue }
            if let s = db.sections[sid], !s.deleted, s.projectId == t.projectId { continue }
            db.tasks[id]?.sectionId = nil
        }

        // 5. Subtasks follow their root.
        var rootOf: [EntityID: (EntityID, EntityID?)] = [:]
        func location(_ id: EntityID) -> (EntityID, EntityID?) {
            if let known = rootOf[id] { return known }
            var chain: [EntityID] = []
            var cur = id
            while let pid = db.tasks[cur]?.parentId, rootOf[cur] == nil {
                chain.append(cur)
                cur = pid
            }
            let loc = rootOf[cur] ?? (db.tasks[cur]!.projectId, db.tasks[cur]!.sectionId)
            rootOf[cur] = loc
            for c in chain { rootOf[c] = loc }
            return loc
        }
        for id in liveIDs where db.tasks[id]?.parentId != nil {
            let (pid, sid) = location(id)
            if db.tasks[id]!.projectId != pid { db.tasks[id]!.projectId = pid }
            if db.tasks[id]!.sectionId != sid { db.tasks[id]!.sectionId = sid }
        }
    }

    // MARK: - Rebase

    /// Combines a sync result with local edits made while it ran: an entity the user changed
    /// since `snapshot` (the database the sync started from) keeps the local version, every
    /// other entity takes `merged`'s. The edits are pushed by the next sync.
    public static func rebase(latest: Database, snapshot: Database, merged: Database) -> Database {
        func pick<T: Equatable>(_ l: [EntityID: T], _ s: [EntityID: T], _ m: [EntityID: T]) -> [EntityID: T] {
            var out = m
            for id in Set(l.keys).union(s.keys) where l[id] != s[id] { out[id] = l[id] }
            return out
        }
        var out = Database()
        out.projects = pick(latest.projects, snapshot.projects, merged.projects)
        out.sections = pick(latest.sections, snapshot.sections, merged.sections)
        out.tasks = pick(latest.tasks, snapshot.tasks, merged.tasks)
        out.labels = pick(latest.labels, snapshot.labels, merged.labels)
        repairStructure(&out)
        return out
    }

    // MARK: - Concurrency

    /// Concurrent requests for uploads.
    static let maxConcurrentRequests = 4

    /// Runs `body` for every element with at most `limit` in flight; results in input order.
    /// The first error cancels the remaining work and is rethrown.
    static func forEachConcurrently<T: Sendable, R: Sendable>(_ items: [T], limit: Int,
                                                              _ body: @escaping @Sendable (T) async throws -> R) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            func launch() {
                let i = next
                let item = items[i]
                next += 1
                group.addTask { (i, try await body(item)) }
            }
            while next < min(limit, items.count) { launch() }
            while let (i, r) = try await group.next() {
                results[i] = r
                if next < items.count { launch() }
            }
            return results.map { $0! }
        }
    }
}
