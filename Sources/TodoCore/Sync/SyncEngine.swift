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
    public var operations: [Operation]

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
    /// (purges old tombstones, drops contents of deleted projects).
    /// When versions are equivalent, the earlier database's copy is kept.
    public static func merge(_ dbs: [Database], now: Date = Date()) -> Database {
        var out = Database()
        for db in dbs {
            mergeInto(&out.projects, db.projects.values)
            mergeInto(&out.sections, db.sections.values)
            mergeInto(&out.tasks, db.tasks.values)
            mergeInto(&out.labels, db.labels.values)
        }
        return normalize(out, now: now)
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

    /// Canonical file contents for a database: path (relative to the sync folder) → bytes.
    public static func files(for db: Database) throws -> [String: Data] {
        let enc = JSONCoding.encoder
        var out: [String: Data] = [:]
        let index = IndexFile(schemaVersion: schemaVersion,
                              projects: db.projects.values.sorted { $0.id < $1.id },
                              labels: db.labels.values.sorted { $0.id < $1.id })
        out[indexPath] = try enc.encode(index)

        var sections: [EntityID: [Section]] = [:]
        var tasks: [EntityID: [TodoTask]] = [:]
        for s in db.sections.values { sections[s.projectId, default: []].append(s) }
        for t in db.tasks.values { tasks[t.projectId, default: []].append(t) }
        let ids = Set(db.projects.values.filter { !$0.deleted }.map(\.id))
            .union(sections.keys).union(tasks.keys)
        for id in ids {
            let file = ProjectFile(schemaVersion: schemaVersion, projectId: id,
                                   sections: (sections[id] ?? []).sorted { $0.id < $1.id },
                                   tasks: (tasks[id] ?? []).sorted { $0.id < $1.id })
            out[projectPath(id)] = try enc.encode(file)
        }
        return out
    }

    // MARK: - Plan

    /// Merges local state with the remote snapshot and lists the writes needed so that the
    /// remote matches the merged state. Files whose canonical bytes are unchanged are skipped.
    public static func plan(local: Database, remote: RemoteSnapshot, now: Date = Date()) throws -> SyncPlan {
        var remoteDB = Database()
        if let indexFile = remote.index {
            let index = try decodeIndex(indexFile)
            mergeInto(&remoteDB.projects, index.projects)
            mergeInto(&remoteDB.labels, index.labels)
        }
        for (id, file) in remote.projectFiles.sorted(by: { $0.key < $1.key }) {
            let pf = try decodeProject(file, id: id)
            mergeInto(&remoteDB.sections, pf.sections)
            mergeInto(&remoteDB.tasks, pf.tasks)
        }
        let merged = merge([local, remoteDB], now: now)
        let target = try files(for: merged)

        var projectOps: [SyncPlan.Operation] = []
        var indexOp: SyncPlan.Operation?
        for (path, data) in target.sorted(by: { $0.key < $1.key }) {
            let existing: RemoteFile? = path == indexPath
                ? remote.index
                : remote.projectFiles[String(path.dropFirst(projectsDir.count + 1).dropLast(5))]
            if existing?.data == data { continue }
            let condition: PutCondition
            if let existing { condition = existing.etag.map { .ifMatch($0) } ?? .none } else { condition = .ifNoneMatch }
            let op = SyncPlan.Operation.put(path: path, data: data, condition: condition)
            if path == indexPath { indexOp = op } else { projectOps.append(op) }
        }
        // Deleting a project file is safe only after index.json holds the project tombstone,
        // so deletions run last.
        let deletes = remote.projectFiles.keys.sorted()
            .filter { target[projectPath($0)] == nil }
            .map { SyncPlan.Operation.delete(path: projectPath($0), ifMatch: remote.projectFiles[$0]?.etag) }
        return SyncPlan(merged: merged, operations: projectOps + (indexOp.map { [$0] } ?? []) + deletes)
    }

    // MARK: - Run

    /// Full sync against `storage`: download, merge, upload changed files. On a 412 (another
    /// device wrote in between) the whole sync is retried, up to `maxAttempts` times.
    public static func sync(local: Database, storage: RemoteStorage, folder: String,
                            cache: RemoteFileCache? = nil, now: @Sendable () -> Date = { Date() },
                            maxAttempts: Int = 3) async throws -> SyncResult {
        for attempt in 1...maxAttempts {
            do {
                let snapshot = try await download(storage: storage, folder: folder, cache: cache)
                let plan = try plan(local: local, remote: snapshot, now: now())
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

    /// Downloads index.json and all project files, creating the folder structure if missing.
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
        if let item = top.first(where: { $0.path == indexFull && !$0.isCollection }) {
            snapshot.index = try await fetch(item, storage: storage, cache: cache)
        }
        guard top.contains(where: { $0.path == projectsFolder && $0.isCollection }) else {
            try await storage.makeCollection(projectsFolder)
            return snapshot
        }
        for item in try await storage.list(projectsFolder) where !item.isCollection && item.name.hasSuffix(".json") {
            let id = String(item.name.dropLast(5))
            guard !id.isEmpty else { continue }
            snapshot.projectFiles[id] = try await fetch(item, storage: storage, cache: cache)
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

    private static func execute(_ plan: SyncPlan, storage: RemoteStorage, folder: String, cache: RemoteFileCache?) async throws {
        for op in plan.operations {
            let full = joinPath(folder, op.path)
            switch op {
            case .put(_, let data, let condition):
                let etag = try await storage.put(full, data: data, condition: condition)
                if let etag { await cache?.store(RemoteFile(data: data, etag: etag), at: full) } else { await cache?.remove(full) }
            case .delete(_, let ifMatch):
                try await storage.delete(full, ifMatch: ifMatch)
                await cache?.remove(full)
            }
        }
    }
}

/// Remembers downloaded files by ETag so unchanged files are not downloaded again.
public actor RemoteFileCache {
    private var files: [String: RemoteFile] = [:]

    public init() {}

    func file(at path: String, etag: String) -> RemoteFile? {
        guard let f = files[path], let cached = f.etag, Self.same(cached, etag) else { return nil }
        return f
    }

    func store(_ file: RemoteFile, at path: String) { files[path] = file }
    func remove(_ path: String) { files[path] = nil }
    public func clear() { files = [:] }

    /// ETags may differ only in weak prefix / quoting between PROPFIND and GET.
    static func same(_ a: String, _ b: String) -> Bool { strip(a) == strip(b) }
    private static func strip(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("W/") { s.removeFirst(2) }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
