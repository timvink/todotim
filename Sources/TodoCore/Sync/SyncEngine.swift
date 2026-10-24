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
    public init(data: Data, etag: String?) { self.data = data; self.etag = etag }
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

    public var uploads: [String] { operations.compactMap { if case .put(let p, _, _) = $0 { p } else { nil } } }
    public var deletions: [String] { operations.compactMap { if case .delete(let p, _) = $0 { p } else { nil } } }
}

public struct SyncResult: Equatable, Sendable {
    public var merged: Database
    public var uploaded: [String]
    public var deleted: [String]
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

    // MARK: - Structural repair

    /// Entity-by-entity merging can produce hierarchies no single device created. Repairs live
    /// tasks deterministically, so every device computes the same result from the same merge:
    /// 1. A subtask whose parent is missing or deleted becomes a top-level task.
    /// 2. Parent cycles are broken: in each cycle, the task with the newest `updatedAt` (then the
    ///    largest id) becomes top-level.
    /// 3. A top-level task whose section is missing, deleted or in another project moves to the
    ///    project's top area.
    /// 4. Subtasks take the projectId and sectionId of their root task.
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

        // 3. Sections of top-level tasks.
        for id in liveIDs {
            guard let t = db.tasks[id], t.parentId == nil, let sid = t.sectionId else { continue }
            if let s = db.sections[sid], !s.deleted, s.projectId == t.projectId { continue }
            db.tasks[id]?.sectionId = nil
        }

        // 4. Subtasks follow their root (hierarchy is acyclic now).
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

        var database: Database {
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
        let merged = merge([local, decoded.database], now: now)
        let (targetIndex, targetProjects) = partitions(for: merged)
        let enc = JSONCoding.encoder

        func condition(_ existing: RemoteFile?) -> PutCondition {
            guard let existing else { return .ifNoneMatch }
            return existing.etag.map { .ifMatch($0) } ?? .none
        }

        var plan = SyncPlan(merged: merged, operations: [])
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
    public static func sync(local: Database, storage: RemoteStorage, folder: String,
                            cache: RemoteFileCache? = nil, now: @Sendable () -> Date = { Date() },
                            maxAttempts: Int = 3) async throws -> SyncResult {
        for attempt in 1...maxAttempts {
            do {
                let snapshot = try await download(storage: storage, folder: folder, cache: cache)
                let decoded = try await decode(snapshot, folder: folder, cache: cache)
                let plan = try plan(local: local, remote: snapshot, decoded: decoded, now: now())
                try await execute(plan, storage: storage, folder: folder, cache: cache)
                return SyncResult(merged: plan.merged, uploaded: plan.uploads, deleted: plan.deletions)
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
            if case .index(let cached)? = await cache?.decoded(at: full, etag: file.etag) {
                out.index = cached
            } else {
                let index = try decodeIndex(file)
                out.index = index
                await cache?.storeDecoded(.index(index), at: full, etag: file.etag)
            }
        }
        var misses: [(EntityID, RemoteFile)] = []
        for (id, file) in snapshot.projectFiles {
            if case .project(let cached)? = await cache?.decoded(at: joinPath(folder, projectPath(id)), etag: file.etag) {
                out.projects[id] = cached
            } else {
                misses.append((id, file))
            }
        }
        // Decoding is CPU-bound; spread cold-cache decodes over the cooperative pool.
        let decodedMisses = try await withThrowingTaskGroup(of: (EntityID, ProjectFile).self) { group in
            for (id, file) in misses { group.addTask { (id, try decodeProject(file, id: id)) } }
            var result: [(EntityID, ProjectFile)] = []
            for try await r in group { result.append(r) }
            return result
        }
        for (id, pf) in decodedMisses {
            out.projects[id] = pf
            await cache?.storeDecoded(.project(pf), at: joinPath(folder, projectPath(id)), etag: snapshot.projectFiles[id]?.etag)
        }
        return out
    }

    /// Downloads index.json and all project files, creating the folder structure if missing.
    /// Up to `maxConcurrentRequests` files are fetched at once.
    public static func download(storage: RemoteStorage, folder: String, cache: RemoteFileCache? = nil) async throws -> RemoteSnapshot {
        let projectsFolder = joinPath(folder, projectsDir)
        let top: [RemoteItem]
        do {
            top = try await storage.list(folder)
        } catch SyncError.notFound {
            try await ensureFolders(storage: storage, folder: folder)
            return RemoteSnapshot()
        }
        var snapshot = RemoteSnapshot()
        let indexFull = joinPath(folder, indexPath)
        var items: [(key: EntityID?, item: RemoteItem)] = []
        if let item = top.first(where: { $0.path == indexFull && !$0.isCollection }) { items.append((nil, item)) }
        if top.contains(where: { $0.path == projectsFolder && $0.isCollection }) {
            for item in try await storage.list(projectsFolder) where !item.isCollection && item.name.hasSuffix(".json") {
                let id = String(item.name.dropLast(5))
                guard !id.isEmpty else { continue }
                items.append((id, item))
            }
        } else {
            try await storage.makeCollection(projectsFolder)
        }
        let fetched = try await forEachConcurrently(items, limit: maxConcurrentRequests) { entry in
            (entry.key, try await fetch(entry.item, storage: storage, cache: cache))
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

    private static func fetch(_ item: RemoteItem, storage: RemoteStorage, cache: RemoteFileCache?) async throws -> RemoteFile? {
        if let cache, let etag = item.etag, let hit = await cache.file(at: item.path, etag: etag) { return hit }
        do {
            let (data, etag) = try await storage.get(item.path)
            let file = RemoteFile(data: data, etag: etag ?? item.etag)
            await cache?.store(file, at: item.path)
            return file
        } catch SyncError.notFound {
            return nil  // deleted between listing and download
        }
    }

    /// Project files are uploaded concurrently; index.json only after all of them succeeded;
    /// deletions only after index.json (which holds the project tombstones).
    private static func execute(_ plan: SyncPlan, storage: RemoteStorage, folder: String, cache: RemoteFileCache?) async throws {
        let projectPuts = plan.operations.filter { if case .put = $0 { return $0.path != indexPath } else { return false } }
        let indexPut = plan.operations.filter { if case .put = $0 { return $0.path == indexPath } else { return false } }
        let deletes = plan.operations.filter { if case .delete = $0 { return true } else { return false } }
        let contents = plan.uploadedContents

        @Sendable func run(_ op: SyncPlan.Operation) async throws {
            let full = joinPath(folder, op.path)
            switch op {
            case .put(_, let data, let condition):
                let etag = try await storage.put(full, data: data, condition: condition)
                if let etag {
                    await cache?.store(RemoteFile(data: data, etag: etag), at: full)
                    if let decoded = contents[op.path] { await cache?.storeDecoded(decoded, at: full, etag: etag) }
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

/// Remembers downloaded files (and their decoded contents) by ETag so unchanged files are
/// neither downloaded nor decoded again.
public actor RemoteFileCache {
    private var files: [String: RemoteFile] = [:]
    private var decodedFiles: [String: (etag: String, value: DecodedFile)] = [:]

    public init() {}

    func file(at path: String, etag: String) -> RemoteFile? {
        guard let f = files[path], let cached = f.etag, Self.same(cached, etag) else { return nil }
        return f
    }

    func decoded(at path: String, etag: String?) -> DecodedFile? {
        guard let etag, let d = decodedFiles[path], Self.same(d.etag, etag) else { return nil }
        return d.value
    }

    func store(_ file: RemoteFile, at path: String) {
        files[path] = file
        if let d = decodedFiles[path], file.etag.map({ Self.same($0, d.etag) }) != true { decodedFiles[path] = nil }
    }

    func storeDecoded(_ value: DecodedFile, at path: String, etag: String?) {
        guard let etag else { return }
        decodedFiles[path] = (etag, value)
    }

    func remove(_ path: String) {
        files[path] = nil
        decodedFiles[path] = nil
    }

    public func clear() {
        files = [:]
        decodedFiles = [:]
    }

    /// ETags may differ only in weak prefix / quoting between PROPFIND and GET.
    static func same(_ a: String, _ b: String) -> Bool { strip(a) == strip(b) }
    private static func strip(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("W/") { s.removeFirst(2) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
