import Foundation

/// `index.json` in the sync folder.
public struct IndexFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var projects: [Project]
    public var labels: [Label]
}

/// `projects/<projectId>.json` in the sync folder.
public struct ProjectFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var projectId: EntityID
    public var sections: [Section]
    public var tasks: [TodoTask]
}

/// A downloaded remote file.
public struct RemoteFile: Equatable, Sendable {
    public var data: Data
    public var etag: String?
    /// Last modification time (server clock, whole seconds), if known.
    public var modified: Date?
    /// Server clock when this version was observed (Date header of the GET or listing), if known.
    public var serverDate: Date?
    public init(data: Data, etag: String?, modified: Date? = nil, serverDate: Date? = nil) {
        self.data = data; self.etag = etag; self.modified = modified; self.serverDate = serverDate
    }
}

/// The remote state as downloaded. Paths are relative to the sync folder.
public struct RemoteSnapshot: Equatable, Sendable {
    public var index: RemoteFile?
    /// Keyed by project id (file name without ".json").
    public var projectFiles: [EntityID: RemoteFile]
    public init(index: RemoteFile? = nil, projectFiles: [EntityID: RemoteFile] = [:]) {
        self.index = index; self.projectFiles = projectFiles
    }
}

/// What a sync should do, computed without any I/O.
public struct SyncPlan: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        /// Path relative to the sync folder.
        case put(path: String, data: Data, condition: PutCondition)
        case delete(path: String, ifMatch: String?)

        public var path: String {
            switch self { case .put(let p, _, _), .delete(let p, _): return p }
        }
    }

    /// The merged state; becomes the local database.
    public var merged: Database
    /// In execution order: project files, then index.json, then deletions.
    /// Project files may be uploaded concurrently; index.json follows them, deletions run last.
    public var operations: [Operation]
    /// Decoded contents of each uploaded file, so the next sync need not decode its own uploads.
    var uploadedContents: [String: DecodedFile] = [:]
    /// Remote entities dropped as invalid (see `SyncResult.droppedRemoteEntities`).
    public var droppedRemoteEntities: Int = 0

    public var uploads: [String] { operations.compactMap { if case .put(let p, _, _) = $0 { p } else { nil } } }
    public var deletions: [String] { operations.compactMap { if case .delete(let p, _) = $0 { p } else { nil } } }
}

public struct SyncResult: Equatable, Sendable {
    public var merged: Database
    public var uploaded: [String]
    public var deleted: [String]
    /// Remote entities ignored because their id or a reference was not a valid id
    /// (see `isValidEntityID`). They are removed from the server by this sync's uploads.
    public var droppedRemoteEntities: Int = 0
}

/// Bounds on remote data, so a broken or hostile server cannot exhaust memory or stack.
public enum SyncLimits {
    /// Per HTTP response body, enforced while streaming.
    public static let maxResponseBytes = 32 * 1024 * 1024
    /// Entries in one PROPFIND listing.
    public static let maxListingEntries = 10_000
    /// Files in `projects/`.
    public static let maxProjectFiles = 10_000
    /// Total size of the files that make up one remote snapshot.
    public static let maxSnapshotBytes = 256 * 1024 * 1024
    /// Projects + labels + sections + tasks in one remote snapshot.
    public static let maxEntities = 200_000
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

/// Merge rules from AGENTS.md: every entity is merged globally by id (newer `updatedAt` wins,
/// on a tie the tombstone wins), then re-partitioned by `projectId`.
public enum SyncEngine {
    public static let schemaVersion = 1
    public static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600
    public static let indexPath = "index.json"
    public static let projectsDir = "projects"

    public static func projectPath(_ id: EntityID) -> String { "\(projectsDir)/\(id).json" }

    // MARK: - Merge

    /// Merges databases entity by entity (last-writer-wins) and normalizes the result
    /// (purges old tombstones, drops contents of deleted projects, repairs the task hierarchy;
    /// see `repairStructure`).
    /// When versions are equivalent, the earlier database's copy is kept.
    public static func merge(_ dbs: [Database], now: Date = Date()) -> Database {
        var out = Database()
        for db in dbs {
            mergeInto(&out.projects, db.projects.values)
            mergeInto(&out.sections, db.sections.values)
            mergeInto(&out.tasks, db.tasks.values)
            mergeInto(&out.labels, db.labels.values)
        }
        sanitize(&out)
        var result = normalize(out, now: now)
        repairStructure(&result)
        return result
    }

    static func mergeInto<T: SyncEntity>(_ dict: inout [EntityID: T], _ items: some Sequence<T>) {
        for item in items {
            if let existing = dict[item.id] {
                dict[item.id] = winner(existing, item)
            } else {
                dict[item.id] = item
            }
        }
    }

    /// Timestamps are compared at millisecond precision, which is what the JSON files store,
    /// so a local copy and its own round-tripped remote copy count as the same version.
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

    /// Purges tombstones older than `tombstoneLifetime` and removes sections/tasks of deleted
    /// projects (the project tombstone in index.json stands for them).
    public static func normalize(_ db: Database, now: Date = Date()) -> Database {
        let cutoff = now.addingTimeInterval(-tombstoneLifetime)
        func keep<T: SyncEntity>(_ e: T) -> Bool { !(e.deleted && e.updatedAt < cutoff) }
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

    // MARK: - Files

    static func decodeIndex(_ file: RemoteFile) throws -> IndexFile {
        try decode(IndexFile.self, file.data, path: indexPath, version: \.schemaVersion)
    }

    static func decodeProject(_ file: RemoteFile, id: EntityID) throws -> ProjectFile {
        try decode(ProjectFile.self, file.data, path: projectPath(id), version: \.schemaVersion)
    }

    private struct VersionProbe: Decodable { var schemaVersion: Int? }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, path: String, version: KeyPath<T, Int>) throws -> T {
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           let v = probe.schemaVersion, v > schemaVersion {
            throw SyncError.newerSchema(path)
        }
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw SyncError.badRemoteData(path: path, reason: describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let c): return c.debugDescription
        case DecodingError.keyNotFound(let k, _): return "missing field “\(k.stringValue)”"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return "unexpected value at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        default: return error.localizedDescription
        }
    }

    /// Canonical contents of every remote file for a database, as values.
    static func partitions(for db: Database) -> (index: IndexFile, projects: [EntityID: ProjectFile]) {
        let index = IndexFile(schemaVersion: schemaVersion,
                              projects: db.projects.values.sorted { $0.id < $1.id },
                              labels: db.labels.values.sorted { $0.id < $1.id })
        var sections: [EntityID: [Section]] = [:]
        var tasks: [EntityID: [TodoTask]] = [:]
        for s in db.sections.values { sections[s.projectId, default: []].append(s) }
        for t in db.tasks.values { tasks[t.projectId, default: []].append(t) }
        let ids = Set(db.projects.values.filter { !$0.deleted }.map(\.id))
            .union(sections.keys).union(tasks.keys)
        var projects: [EntityID: ProjectFile] = [:]
        for id in ids {
            projects[id] = ProjectFile(schemaVersion: schemaVersion, projectId: id,
                                       sections: (sections[id] ?? []).sorted { $0.id < $1.id },
                                       tasks: (tasks[id] ?? []).sorted { $0.id < $1.id })
        }
        return (index, projects)
    }

    /// Canonical file contents for a database: path (relative to the sync folder) → bytes.
    public static func files(for db: Database) throws -> [String: Data] {
        let enc = JSONCoding.encoder
        let (index, projects) = partitions(for: db)
        var out: [String: Data] = [indexPath: try enc.encode(index)]
        for (id, file) in projects { out[projectPath(id)] = try enc.encode(file) }
        return out
    }

    // MARK: - Plan

    /// Decoded remote files, keyed like `RemoteSnapshot`.
    struct DecodedRemote: Sendable {
        var index: IndexFile?
        var projects: [EntityID: ProjectFile] = [:]

        /// Throws when the files hold more than `SyncLimits.maxEntities` entities.
        func database() throws -> Database {
            var count = (index?.projects.count ?? 0) + (index?.labels.count ?? 0)
            for pf in projects.values { count += pf.sections.count + pf.tasks.count }
            guard count <= SyncLimits.maxEntities else {
                throw SyncError.limitExceeded("more than \(SyncLimits.maxEntities) entries")
            }
            var db = Database()
            if let index {
                mergeInto(&db.projects, index.projects)
                mergeInto(&db.labels, index.labels)
            }
            for (_, pf) in projects.sorted(by: { $0.key < $1.key }) {
                mergeInto(&db.sections, pf.sections)
                mergeInto(&db.tasks, pf.tasks)
            }
            return db
        }
    }

    static func decodeAll(_ remote: RemoteSnapshot) throws -> DecodedRemote {
        var out = DecodedRemote()
        out.index = try remote.index.map(decodeIndex)
        for (id, file) in remote.projectFiles { out.projects[id] = try decodeProject(file, id: id) }
        return out
    }

    /// Merges local state with the remote snapshot and lists the writes needed so that the
    /// remote matches the merged state. Files whose canonical bytes are unchanged are skipped.
    public static func plan(local: Database, remote: RemoteSnapshot, now: Date = Date()) throws -> SyncPlan {
        try plan(local: local, remote: remote, decoded: try decodeAll(remote), now: now)
    }

    /// `decoded` must be the decoded form of `remote`. A partition whose merged content equals the
    /// decoded remote file is skipped without encoding it.
    static func plan(local: Database, remote: RemoteSnapshot, decoded: DecodedRemote, now: Date) throws -> SyncPlan {
        var remoteDB = try decoded.database()
        let dropped = sanitize(&remoteDB)
        let merged = merge([local, remoteDB], now: now)
        let (targetIndex, targetProjects) = partitions(for: merged)
        let enc = JSONCoding.encoder

        func condition(_ existing: RemoteFile?) -> PutCondition {
            guard let existing else { return .ifNoneMatch }
            return existing.etag.map { .ifMatch($0) } ?? .none
        }

        var plan = SyncPlan(merged: merged, operations: [])
        plan.droppedRemoteEntities = dropped
        for id in targetProjects.keys.sorted() {
            let target = targetProjects[id]!
            let existing = remote.projectFiles[id]
            if existing != nil, decoded.projects[id] == target { continue }
            let data = try enc.encode(target)
            if existing?.data == data { continue }
            let path = projectPath(id)
            plan.operations.append(.put(path: path, data: data, condition: condition(existing)))
            plan.uploadedContents[path] = .project(target)
        }
        if remote.index == nil || decoded.index != targetIndex {
            let data = try enc.encode(targetIndex)
            if remote.index?.data != data {
                plan.operations.append(.put(path: indexPath, data: data, condition: condition(remote.index)))
                plan.uploadedContents[indexPath] = .index(targetIndex)
            }
        }
        // Deleting a project file is safe only after index.json holds the project tombstone,
        // so deletions run last.
        for id in remote.projectFiles.keys.sorted() where targetProjects[id] == nil {
            plan.operations.append(.delete(path: projectPath(id), ifMatch: remote.projectFiles[id]?.etag))
        }
        return plan
    }

    // MARK: - Run

    /// Concurrent requests for downloads and project-file uploads.
    public static let maxConcurrentRequests = 4

    /// Full sync against `storage`: download, merge, upload changed files. On a 412 (another
    /// device wrote in between) the whole sync is retried, up to `maxAttempts` times.
    /// Each file is written at most once per attempt (`plan` emits one operation per path).
    public static func sync(local: Database, storage: RemoteStorage, folder: String,
                            cache: RemoteFileCache? = nil, now: @Sendable () -> Date = { Date() },
                            maxAttempts: Int = 3) async throws -> SyncResult {
        try await sync(local: local, storage: storage, folder: folder, cache: cache, now: now,
                       maxAttempts: maxAttempts, sleep: defaultSleep, settleFreshFiles: true)
    }

    static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    /// `sleep` waits for the given number of seconds (tests advance a fake server clock).
    /// `settleFreshFiles: false` disables the same-second guard (tests only, to show what it prevents).
    static func sync(local: Database, storage: RemoteStorage, folder: String, cache: RemoteFileCache?,
                     now: @Sendable () -> Date, maxAttempts: Int,
                     sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
                     settleFreshFiles: Bool) async throws -> SyncResult {
        for attempt in 1...maxAttempts {
            do {
                let snapshot = try await download(storage: storage, folder: folder, cache: cache)
                let decoded = try await decode(snapshot, folder: folder, cache: cache)
                let plan = try plan(local: local, remote: snapshot, decoded: decoded, now: now())
                try await execute(plan, snapshot: snapshot, storage: storage, folder: folder, cache: cache,
                                  settle: settleFreshFiles ? sleep : nil)
                return SyncResult(merged: plan.merged, uploaded: plan.uploads, deleted: plan.deletions,
                                  droppedRemoteEntities: plan.droppedRemoteEntities)
            } catch SyncError.preconditionFailed where attempt < maxAttempts {
                continue
            } catch SyncError.preconditionFailed {
                throw SyncError.tooManyConflicts
            }
        }
        throw SyncError.tooManyConflicts
    }

    /// Decodes the snapshot, reusing decoded files from `cache` when their ETag is unchanged.
    static func decode(_ snapshot: RemoteSnapshot, folder: String, cache: RemoteFileCache?) async throws -> DecodedRemote {
        var out = DecodedRemote()
        if let file = snapshot.index {
            let full = joinPath(folder, indexPath)
            if case .index(let cached)? = await cache?.decoded(at: full, for: file) {
                out.index = cached
            } else {
                let index = try decodeIndex(file)
                out.index = index
                await cache?.storeDecoded(.index(index), at: full, for: file)
            }
        }
        var misses: [(EntityID, RemoteFile)] = []
        for (id, file) in snapshot.projectFiles {
            if case .project(let cached)? = await cache?.decoded(at: joinPath(folder, projectPath(id)), for: file) {
                out.projects[id] = cached
            } else {
                misses.append((id, file))
            }
        }
        // Decoding is CPU-bound; spread cold-cache decodes over a few tasks.
        let decodedMisses = try await forEachConcurrently(misses, limit: maxConcurrentRequests) { entry in
            (entry.0, try decodeProject(entry.1, id: entry.0))
        }
        for (id, pf) in decodedMisses {
            out.projects[id] = pf
            if let file = snapshot.projectFiles[id] {
                await cache?.storeDecoded(.project(pf), at: joinPath(folder, projectPath(id)), for: file)
            }
        }
        return out
    }

    /// Downloads index.json and all project files, creating the folder structure if missing.
    /// Up to `maxConcurrentRequests` files are fetched at once.
    public static func download(storage: RemoteStorage, folder: String, cache: RemoteFileCache? = nil) async throws -> RemoteSnapshot {
        let projectsFolder = joinPath(folder, projectsDir)
        let top: RemoteListing
        do {
            top = try await storage.listing(folder)
        } catch SyncError.notFound {
            try await ensureFolders(storage: storage, folder: folder)
            return RemoteSnapshot()
        }
        var snapshot = RemoteSnapshot()
        let indexFull = joinPath(folder, indexPath)
        var items: [(key: EntityID?, item: RemoteItem, serverDate: Date?)] = []
        if let item = top.items.first(where: { $0.path == indexFull && !$0.isCollection }) {
            items.append((nil, item, top.serverDate))
        }
        if top.items.contains(where: { $0.path == projectsFolder && $0.isCollection }) {
            let projects = try await storage.listing(projectsFolder)
            for item in projects.items where !item.isCollection && item.name.hasSuffix(".json") {
                // Files not named after a valid id are ignored (never read, written or deleted).
                let id = String(item.name.dropLast(5))
                guard isValidEntityID(id) else { continue }
                items.append((id, item, projects.serverDate))
            }
            guard items.count <= SyncLimits.maxProjectFiles + 1 else {
                throw SyncError.limitExceeded("more than \(SyncLimits.maxProjectFiles) project files")
            }
        } else {
            try await storage.makeCollection(projectsFolder)
        }
        // Cached files of the folder that are no longer listed are forgotten.
        await cache?.retain(Set(items.map(\.item.path)), under: folder)
        let fetched = try await forEachConcurrently(items, limit: maxConcurrentRequests) { entry in
            (entry.key, try await fetch(entry.item, serverDate: entry.serverDate, storage: storage, cache: cache))
        }
        let totalBytes = fetched.reduce(0) { $0 + ($1.1?.data.count ?? 0) }
        guard totalBytes <= SyncLimits.maxSnapshotBytes else {
            throw SyncError.limitExceeded("more than \(SyncLimits.maxSnapshotBytes / 1024 / 1024) MB of files")
        }
        for (key, file) in fetched {
            guard let file else { continue }
            if let key { snapshot.projectFiles[key] = file } else { snapshot.index = file }
        }
        return snapshot
    }

    /// Creates `folder` (and its parents) and `folder/projects`. Existing ones are fine.
    public static func ensureFolders(storage: RemoteStorage, folder: String) async throws {
        var current = ""
        for part in folder.split(separator: "/") {
            current = joinPath(current, String(part))
            try await storage.makeCollection(current)
        }
        try await storage.makeCollection(joinPath(folder, projectsDir))
    }

    /// Downloads `item`, or takes it from `cache` when ETag, size and modification time match the
    /// listing. `serverDate` is the server clock of the listing.
    private static func fetch(_ item: RemoteItem, serverDate: Date?, storage: RemoteStorage,
                              cache: RemoteFileCache?) async throws -> RemoteFile? {
        if let cache, var hit = await cache.file(at: item.path, matching: item) {
            hit.modified = item.modified
            hit.serverDate = serverDate
            return hit
        }
        do {
            var file = try await storage.get(item.path)
            let listedVersion = file.etag == nil || item.etag.map { RemoteFileCache.same($0, file.etag!) } == true
            if file.etag == nil { file.etag = item.etag }
            if file.modified == nil, listedVersion { file.modified = item.modified }
            // The listing is older than the GET, so its clock only makes the file look fresher.
            if file.serverDate == nil { file.serverDate = serverDate }
            // A file written in the last seconds may still be replaced without a new ETag (see
            // `settleInterval`), so its content is not cached; the next sync downloads it again.
            if isSettled(file) { await cache?.store(file, at: item.path) }
            return file
        } catch SyncError.notFound {
            return nil  // deleted between listing and download
        }
    }

    // MARK: - Same-second writes

    /// Nextcloud keeps a file's ETag when the file is rewritten within the same second as the
    /// previous write (modification times have whole-second precision). Until the server clock
    /// has moved on, an `If-Match` with the old ETag still succeeds although the content changed,
    /// which would silently overwrite the other write. A version counts as settled once the
    /// server clock (Date header) is this many seconds past its modification time: one second for
    /// the write's own second, and one for skew between the Date header and file times.
    static let settleInterval: TimeInterval = 2

    /// Whether `file` can no longer change without a new ETag. True when the server reports no
    /// modification time or clock (nothing to check against).
    static func isSettled(_ file: RemoteFile) -> Bool {
        guard let modified = file.modified, let serverDate = file.serverDate else { return true }
        return serverDate.timeIntervalSince(modified) >= settleInterval
    }

    /// Before overwriting or deleting `file`, waits until it is settled and downloads it again.
    /// Content or ETag differences mean another device wrote within that second: the write is
    /// treated as a conflict (`preconditionFailed`, which retries the sync). Once settled, any
    /// later write gets a new modification second and hence a new ETag, which `If-Match` catches.
    static func settle(_ path: String, _ file: RemoteFile, storage: RemoteStorage,
                       sleep: @Sendable (TimeInterval) async throws -> Void) async throws {
        guard !isSettled(file), let modified = file.modified, let observed = file.serverDate else { return }
        var delay = min(max(settleInterval - observed.timeIntervalSince(modified), 0.1), settleInterval + 1)
        for _ in 0..<5 {
            try await sleep(delay)
            let current: RemoteFile
            do {
                current = try await storage.get(path)
            } catch SyncError.notFound {
                throw SyncError.preconditionFailed(path)
            }
            let sameETag = switch (current.etag, file.etag) {
            case (nil, nil): true
            case (let a?, let b?): RemoteFileCache.same(a, b)
            default: false
            }
            guard sameETag, current.data == file.data else { throw SyncError.preconditionFailed(path) }
            if isSettled(RemoteFile(data: Data(), etag: nil, modified: current.modified ?? modified,
                                    serverDate: current.serverDate)) { return }
            delay = 0.5  // the server clock has not moved on yet
        }
    }

    /// Project files are uploaded concurrently; index.json only after all of them succeeded;
    /// deletions only after index.json (which holds the project tombstones).
    /// `settle` (a sleep function) enables the same-second guard for files in `snapshot`.
    private static func execute(_ plan: SyncPlan, snapshot: RemoteSnapshot, storage: RemoteStorage, folder: String,
                                cache: RemoteFileCache?,
                                settle sleep: (@Sendable (TimeInterval) async throws -> Void)?) async throws {
        var byPath: [String: RemoteFile] = [:]
        if let index = snapshot.index { byPath[indexPath] = index }
        for (id, file) in snapshot.projectFiles { byPath[projectPath(id)] = file }
        let existing = byPath
        let projectPuts = plan.operations.filter { if case .put = $0 { return $0.path != indexPath } else { return false } }
        let indexPut = plan.operations.filter { if case .put = $0 { return $0.path == indexPath } else { return false } }
        let deletes = plan.operations.filter { if case .delete = $0 { return true } else { return false } }
        let contents = plan.uploadedContents

        @Sendable func run(_ op: SyncPlan.Operation) async throws {
            let full = joinPath(folder, op.path)
            if let sleep, let file = existing[op.path] {
                try await settle(full, file, storage: storage, sleep: sleep)
            }
            switch op {
            case .put(_, let data, let condition):
                let etag = try await storage.put(full, data: data, condition: condition)
                // `settle` made this write land in a later second than the version it replaces, so
                // the returned ETag is new. The modification time is unknown (nil), so the next sync
                // reuses this entry only if the listed ETag and size match. An unchanged ETag means
                // the guard did not apply (no server clock); then the entry is dropped.
                var etagChanged = true
                if let etag, case .ifMatch(let previous) = condition { etagChanged = !RemoteFileCache.same(previous, etag) }
                if let etag, etagChanged {
                    let uploaded = RemoteFile(data: data, etag: etag)
                    await cache?.store(uploaded, at: full)
                    if let decoded = contents[op.path] { await cache?.storeDecoded(decoded, at: full, for: uploaded) }
                } else {
                    await cache?.remove(full)
                }
            case .delete(_, let ifMatch):
                try await storage.delete(full, ifMatch: ifMatch)
                await cache?.remove(full)
            }
        }
        _ = try await forEachConcurrently(projectPuts, limit: maxConcurrentRequests) { try await run($0) }
        for op in indexPut { try await run(op) }
        _ = try await forEachConcurrently(deletes, limit: maxConcurrentRequests) { try await run($0) }
    }

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

/// Decoded contents of a remote file.
enum DecodedFile: Equatable, Sendable {
    case index(IndexFile)
    case project(ProjectFile)
}

/// Remembers downloaded files (and their decoded contents) so unchanged files are neither
/// downloaded nor decoded again. An entry is reused only when the listing reports the same ETag,
/// size and modification time (an entry without a modification time, from our own upload, matches
/// on ETag and size).
///
/// Limit: a rewrite within the same second that keeps the size is invisible to all three (Nextcloud
/// keeps the ETag, and the time has whole-second precision). Sync avoids producing such rewrites
/// (`SyncEngine.settle`) and does not cache files fetched within `SyncEngine.settleInterval` of
/// their last write, so only a writer without that guard can make an entry stale.
public actor RemoteFileCache {
    struct Version: Equatable, Sendable {
        var etag: String
        var size: Int
        var modified: Date?

        init?(_ file: RemoteFile) {
            guard let etag = file.etag else { return nil }
            self.etag = etag; size = file.data.count; modified = file.modified
        }

        /// nil arguments are unknown and match anything.
        func matches(etag: String?, size: Int?, modified: Date?) -> Bool {
            guard let etag, RemoteFileCache.same(self.etag, etag) else { return false }
            if let size, size != self.size { return false }
            if let modified, let mine = self.modified, mine != modified { return false }
            return true
        }
    }

    private var files: [String: (version: Version, data: Data)] = [:]
    private var decodedFiles: [String: (version: Version, value: DecodedFile)] = [:]

    public init() {}

    /// The cached file for a listed item, without `modified`/`serverDate` (the caller sets them).
    func file(at path: String, matching item: RemoteItem) -> RemoteFile? {
        guard let f = files[path], f.version.matches(etag: item.etag, size: item.size, modified: item.modified) else { return nil }
        return RemoteFile(data: f.data, etag: f.version.etag)
    }

    func decoded(at path: String, for file: RemoteFile) -> DecodedFile? {
        guard let d = decodedFiles[path],
              d.version.matches(etag: file.etag, size: file.data.count, modified: file.modified) else { return nil }
        return d.value
    }

    /// Files without an ETag are not cached (and replace any older entry).
    func store(_ file: RemoteFile, at path: String) {
        guard let version = Version(file) else { return remove(path) }
        files[path] = (version, file.data)
        if let d = decodedFiles[path], d.version != version { decodedFiles[path] = nil }
    }

    /// Ignored for files without an ETag or written within the last seconds (see `SyncEngine.isSettled`).
    func storeDecoded(_ value: DecodedFile, at path: String, for file: RemoteFile) {
        guard SyncEngine.isSettled(file), let version = Version(file) else { return }
        decodedFiles[path] = (version, value)
    }

    func remove(_ path: String) {
        files[path] = nil
        decodedFiles[path] = nil
    }

    public func clear() {
        files = [:]
        decodedFiles = [:]
    }

    /// Paths with a cached file or decoded file (tests, diagnostics).
    var cachedPaths: Set<String> { Set(files.keys).union(decodedFiles.keys) }

    /// Removes entries inside `folder` whose path is not in `paths`.
    func retain(_ paths: Set<String>, under folder: String) {
        let prefix = joinPath(folder).isEmpty ? "" : joinPath(folder) + "/"
        for key in files.keys where key.hasPrefix(prefix) && !paths.contains(key) { files[key] = nil }
        for key in decodedFiles.keys where key.hasPrefix(prefix) && !paths.contains(key) { decodedFiles[key] = nil }
    }

    /// ETags may differ only in weak prefix / quoting between PROPFIND and GET.
    static func same(_ a: String, _ b: String) -> Bool { strip(a) == strip(b) }
    private static func strip(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("W/") { s.removeFirst(2) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
