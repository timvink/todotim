import XCTest
@testable import TodoCore

@MainActor
final class SyncEngineTests: XCTestCase {
    let folder = "TodoTim"
    let now = Date()

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    private let day: TimeInterval = 24 * 3600

    private func db(projects: [Project] = [], sections: [Section] = [], tasks: [TodoTask] = [], labels: [Label] = []) -> Database {
        var d = Database()
        for p in projects { d.projects[p.id] = p }
        for s in sections { d.sections[s.id] = s }
        for t in tasks { d.tasks[t.id] = t }
        for l in labels { d.labels[l.id] = l }
        return d
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONCoding.encoder.encode(value) }

    @discardableResult
    private func sync(_ store: TodoStore, _ remote: InMemoryRemoteStorage) async throws -> SyncResult {
        let r = try await SyncEngine.sync(local: store.db, storage: remote, folder: folder)
        store.replaceDatabase(r.merged)
        return r
    }

    private func assertConverged(_ a: TodoStore, _ b: TodoStore, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try SyncEngine.files(for: a.db), try SyncEngine.files(for: b.db), file: file, line: line)
    }

    // MARK: - Merge

    func testNewerUpdatedAtWins() {
        let old = TodoTask(id: "t", projectId: "p", content: "old", order: 1, updatedAt: ago(60))
        var new = old
        new.content = "new"; new.updatedAt = ago(10)
        XCTAssertEqual(SyncEngine.merge([db(tasks: [old]), db(tasks: [new])], now: now).tasks["t"]?.content, "new")
        XCTAssertEqual(SyncEngine.merge([db(tasks: [new]), db(tasks: [old])], now: now).tasks["t"]?.content, "new")
    }

    func testTieDeletedWins() {
        let live = TodoTask(id: "t", projectId: "p", content: "x", order: 1, updatedAt: ago(10))
        var dead = live
        dead.deleted = true
        XCTAssertEqual(SyncEngine.merge([db(tasks: [live]), db(tasks: [dead])], now: now).tasks["t"]?.deleted, true)
        XCTAssertEqual(SyncEngine.merge([db(tasks: [dead]), db(tasks: [live])], now: now).tasks["t"]?.deleted, true)
    }

    func testTieWithDifferentContentIsDeterministic() {
        let a = TodoTask(id: "t", projectId: "p", content: "a", order: 1, updatedAt: ago(10))
        var b = a
        b.content = "b"
        let ab = SyncEngine.merge([db(tasks: [a]), db(tasks: [b])], now: now).tasks["t"]
        let ba = SyncEngine.merge([db(tasks: [b]), db(tasks: [a])], now: now).tasks["t"]
        XCTAssertEqual(ab, ba)
    }

    func testSubMillisecondDifferenceKeepsFirstCopy() {
        // A local date with sub-ms precision vs. its round-tripped remote copy: same version.
        let local = TodoTask(id: "t", projectId: "p", content: "x", order: 1,
                             updatedAt: Date(timeIntervalSince1970: 1_700_000_000.123_8))
        var remote = local
        remote.updatedAt = Date(timeIntervalSince1970: 1_700_000_000.124)
        XCTAssertEqual(SyncEngine.merge([db(tasks: [local]), db(tasks: [remote])], now: now).tasks["t"], local)
    }

    func testDateEncodingRoundTripIsStable() throws {
        struct Box: Codable, Equatable { var d: Date }
        for _ in 0..<2000 {
            let date = Date(timeIntervalSince1970: 1_790_000_000 + Double.random(in: 0..<100_000))
            let once = try encode(Box(d: date))
            let decoded = try JSONCoding.decoder.decode(Box.self, from: once)
            XCTAssertEqual(try encode(decoded), once)
            XCTAssertEqual(SyncEngine.millis(decoded.d), SyncEngine.millis(date))
        }
        XCTAssertEqual(String(data: try encode(Box(d: Date(timeIntervalSince1970: 1_700_000_000.0996))), encoding: .utf8)!
            .contains("2023-11-14T22:13:20.100"), true)
    }

    func testPurgesOldTombstonesOnly() {
        let oldDead = TodoTask(id: "old", projectId: "p", content: "x", order: 1, updatedAt: ago(31 * day), deleted: true)
        let newDead = TodoTask(id: "new", projectId: "p", content: "x", order: 1, updatedAt: ago(29 * day), deleted: true)
        let oldLive = TodoTask(id: "live", projectId: "p", content: "x", order: 1, updatedAt: ago(400 * day))
        let oldLabel = Label(id: "l", name: "l", order: 1, updatedAt: ago(31 * day), deleted: true)
        let merged = SyncEngine.merge([db(tasks: [oldDead, newDead, oldLive], labels: [oldLabel])], now: now)
        XCTAssertNil(merged.tasks["old"])
        XCTAssertNotNil(merged.tasks["new"])
        XCTAssertNotNil(merged.tasks["live"])
        XCTAssertNil(merged.labels["l"])
    }

    // MARK: - Plan

    func testRepartitionByProject() throws {
        let a = Project(id: "a", name: "A", order: 1, updatedAt: ago(10))
        let b = Project(id: "b", name: "B", order: 2, updatedAt: ago(10))
        let s = Section(id: "s", projectId: "b", name: "S", order: 1, updatedAt: ago(10))
        let t1 = TodoTask(id: "t1", projectId: "a", content: "1", order: 1, updatedAt: ago(10))
        let t2 = TodoTask(id: "t2", projectId: "b", sectionId: "s", content: "2", order: 1, updatedAt: ago(10))
        let plan = try SyncEngine.plan(local: db(projects: [a, b], sections: [s], tasks: [t1, t2]), remote: RemoteSnapshot(), now: now)
        XCTAssertEqual(Set(plan.uploads), ["index.json", "projects/a.json", "projects/b.json"])
        XCTAssertEqual(plan.operations.last?.path, "index.json")
        for case let .put(path, data, condition) in plan.operations {
            XCTAssertEqual(condition, .ifNoneMatch)
            guard path != "index.json" else { continue }
            let pf = try JSONCoding.decoder.decode(ProjectFile.self, from: data)
            XCTAssertEqual(pf.schemaVersion, 1)
            XCTAssertEqual("projects/\(pf.projectId).json", path)
            XCTAssertEqual(pf.tasks.map(\.id), pf.projectId == "a" ? ["t1"] : ["t2"])
            XCTAssertEqual(pf.sections.map(\.id), pf.projectId == "a" ? [] : ["s"])
        }
    }

    func testTaskMovedBetweenProjectsAppearsInTwoFiles() throws {
        let a = Project(id: "a", name: "A", order: 1, updatedAt: ago(100))
        let b = Project(id: "b", name: "B", order: 2, updatedAt: ago(100))
        let inA = TodoTask(id: "t", projectId: "a", content: "x", order: 1, updatedAt: ago(50))
        var inB = inA
        inB.projectId = "b"; inB.updatedAt = ago(20)
        // Another device moved the task to B but only B's file got updated so far.
        let remote = RemoteSnapshot(
            index: RemoteFile(data: try encode(IndexFile(schemaVersion: 1, projects: [a, b], labels: [])), etag: "i1"),
            projectFiles: [
                "a": RemoteFile(data: try encode(ProjectFile(schemaVersion: 1, projectId: "a", sections: [], tasks: [inA])), etag: "a1"),
                "b": RemoteFile(data: try encode(ProjectFile(schemaVersion: 1, projectId: "b", sections: [], tasks: [inB])), etag: "b1"),
            ])
        let plan = try SyncEngine.plan(local: db(projects: [a, b], tasks: [inA]), remote: remote, now: now)
        XCTAssertEqual(plan.merged.tasks["t"]?.projectId, "b")
        XCTAssertEqual(plan.uploads, ["projects/a.json"])
        guard case let .put(_, data, condition) = plan.operations[0] else { return XCTFail() }
        XCTAssertEqual(condition, .ifMatch("a1"))
        XCTAssertEqual(try JSONCoding.decoder.decode(ProjectFile.self, from: data).tasks, [])
    }

    func testDeletedProjectFileIsDeletedAfterIndexUpload() throws {
        let p = Project(id: "p", name: "P", order: 1, updatedAt: ago(100))
        let t = TodoTask(id: "t", projectId: "p", content: "x", order: 1, updatedAt: ago(100))
        let remote = RemoteSnapshot(
            index: RemoteFile(data: try encode(IndexFile(schemaVersion: 1, projects: [p], labels: [])), etag: "i1"),
            projectFiles: ["p": RemoteFile(data: try encode(ProjectFile(schemaVersion: 1, projectId: "p", sections: [], tasks: [t])), etag: "p1")])
        var deadP = p
        deadP.deleted = true; deadP.updatedAt = ago(5)
        var deadT = t
        deadT.deleted = true; deadT.updatedAt = ago(5)
        let plan = try SyncEngine.plan(local: db(projects: [deadP], tasks: [deadT]), remote: remote, now: now)
        XCTAssertEqual(plan.operations.map(\.path), ["index.json", "projects/p.json"])
        XCTAssertEqual(plan.operations.last, .delete(path: "projects/p.json", ifMatch: "p1"))
        guard case let .put(_, data, _) = plan.operations[0] else { return XCTFail() }
        let index = try JSONCoding.decoder.decode(IndexFile.self, from: data)
        XCTAssertEqual(index.projects.map(\.id), ["p"])
        XCTAssertEqual(index.projects.first?.deleted, true)
        XCTAssertTrue(plan.merged.tasks.isEmpty)
    }

    func testNewerSchemaIsRejected() {
        let remote = RemoteSnapshot(index: RemoteFile(data: Data(#"{"schemaVersion": 2, "projects": [], "labels": []}"#.utf8), etag: nil))
        XCTAssertThrowsError(try SyncEngine.plan(local: Database(), remote: remote, now: now)) {
            XCTAssertEqual($0 as? SyncError, .newerSchema("index.json"))
        }
    }

    func testCorruptRemoteFileIsReported() {
        let remote = RemoteSnapshot(projectFiles: ["x": RemoteFile(data: Data("nope".utf8), etag: nil)])
        XCTAssertThrowsError(try SyncEngine.plan(local: Database(), remote: remote, now: now)) {
            guard case .badRemoteData(let path, _) = $0 as? SyncError else { return XCTFail("\($0)") }
            XCTAssertEqual(path, "projects/x.json")
        }
    }

    // MARK: - Round trips against a fake server

    func testFirstSyncCreatesFoldersAndSecondSyncUploadsNothing() async throws {
        let remote = InMemoryRemoteStorage()
        let store = TodoStore()
        let p = store.addProject(name: "Work")
        store.addTask(content: "a", projectId: p.id, labels: ["home"])
        store.addTask(content: "b", projectId: TodoStore.inboxID)

        let first = try await sync(store, remote)
        XCTAssertEqual(Set(first.uploaded), ["index.json", "projects/inbox.json", "projects/\(p.id).json"])
        let collections = await remote.collections
        XCTAssertTrue(collections.isSuperset(of: ["TodoTim", "TodoTim/projects"]))

        await remote.resetCounters()
        let second = try await sync(store, remote)
        XCTAssertEqual(second.uploaded, [])
        XCTAssertEqual(second.deleted, [])
        let puts = await remote.putPaths
        XCTAssertEqual(puts, [])
    }

    func testCacheAvoidsRedownloadingUnchangedFiles() async throws {
        let remote = InMemoryRemoteStorage()
        let cache = RemoteFileCache()
        let store = TodoStore()
        store.addTask(content: "a", projectId: TodoStore.inboxID)
        _ = try await SyncEngine.sync(local: store.db, storage: remote, folder: folder, cache: cache)
        await remote.resetCounters()
        let r = try await SyncEngine.sync(local: store.db, storage: remote, folder: folder, cache: cache)
        XCTAssertEqual(r.uploaded, [])
        let gets = await remote.getCount
        XCTAssertEqual(gets, 0)
    }

    func testTwoDevicesConverge() async throws {
        let remote = InMemoryRemoteStorage()
        let a = TodoStore(), b = TodoStore()

        let work = a.addProject(name: "Work")
        let t1 = a.addTask(content: "Write report", projectId: work.id)
        let t2 = a.addTask(content: "Call Bob", projectId: work.id)
        try await sync(a, remote)
        try await sync(b, remote)
        XCTAssertEqual(b.task(t1.id)?.content, "Write report")
        XCTAssertEqual(b.projects.map(\.name), ["Work"])

        // Concurrent edits: A renames t1 and deletes t2; B (later) renames t1 and adds a task.
        a.updateTask(t1.id) { $0.content = "Write report (A)" }
        a.deleteTask(t2.id)
        try await Task.sleep(for: .milliseconds(5))
        b.updateTask(t1.id) { $0.content = "Write report (B)" }
        let t3 = b.addTask(content: "From B", projectId: TodoStore.inboxID)

        try await sync(a, remote)
        try await sync(b, remote)
        try await sync(a, remote)

        try assertConverged(a, b)
        XCTAssertEqual(a.task(t1.id)?.content, "Write report (B)")
        XCTAssertNil(a.task(t2.id))
        XCTAssertNotNil(a.task(t3.id))

        // Move between projects on B, delete project on A afterwards.
        b.moveTask(t1.id, projectId: TodoStore.inboxID, sectionId: nil, parentId: nil)
        try await sync(b, remote)
        try await Task.sleep(for: .milliseconds(5))
        // A has not seen the move, so its project delete also tombstones t1 (still in Work there).
        // Contents of a deleted project are dropped, so B's moved copy in the inbox survives.
        a.deleteProject(work.id)
        try await sync(a, remote)
        try await sync(b, remote)
        try await sync(a, remote)
        try assertConverged(a, b)
        XCTAssertTrue(a.projects.isEmpty)
        XCTAssertEqual(a.task(t1.id)?.projectId, TodoStore.inboxID)
        let paths = Set(await remote.files.keys)
        XCTAssertEqual(paths, ["TodoTim/index.json", "TodoTim/projects/inbox.json"])
        // Project tombstone stays in index.json.
        let index = try JSONCoding.decoder.decode(IndexFile.self, from: await remote.data("TodoTim/index.json")!)
        XCTAssertEqual(index.projects.first { $0.id == work.id }?.deleted, true)

        // Both idle now.
        await remote.resetCounters()
        try await sync(a, remote)
        try await sync(b, remote)
        let puts = await remote.putPaths
        XCTAssertEqual(puts, [])
    }

    func testRetriesOnPreconditionFailed() async throws {
        let remote = InMemoryRemoteStorage()
        let a = TodoStore(), b = TodoStore()
        a.addTask(content: "a", projectId: TodoStore.inboxID)
        try await sync(a, remote)
        try await sync(b, remote)

        // While A syncs, B's newer inbox file lands on the server just before A's PUT.
        let fromB = b.addTask(content: "from B", projectId: TodoStore.inboxID)
        let bFiles = try SyncEngine.files(for: b.db)
        await remote.queueExternalWrite("TodoTim/projects/inbox.json", bFiles["projects/inbox.json"]!)
        let fromA = a.addTask(content: "from A", projectId: TodoStore.inboxID)

        try await sync(a, remote)
        XCTAssertNotNil(a.task(fromA.id))
        XCTAssertNotNil(a.task(fromB.id))
        let inbox = try JSONCoding.decoder.decode(ProjectFile.self, from: await remote.data("TodoTim/projects/inbox.json")!)
        XCTAssertEqual(Set(inbox.tasks.map(\.content)), ["a", "from A", "from B"])
    }

    func testGivesUpAfterThreeConflicts() async throws {
        let remote = InMemoryRemoteStorage()
        let store = TodoStore()
        store.addTask(content: "a", projectId: TodoStore.inboxID)
        try await sync(store, remote)
        store.addTask(content: "b", projectId: TodoStore.inboxID)
        do {
            _ = try await SyncEngine.sync(local: store.db, storage: ConflictingStorage(inner: remote), folder: folder)
            XCTFail("expected tooManyConflicts")
        } catch {
            XCTAssertEqual(error as? SyncError, .tooManyConflicts)
        }
    }
}

/// Wraps storage so every PUT fails with 412.
private struct ConflictingStorage: RemoteStorage {
    let inner: InMemoryRemoteStorage
    func list(_ path: String) async throws -> [RemoteItem] { try await inner.list(path) }
    func get(_ path: String) async throws -> (data: Data, etag: String?) { try await inner.get(path) }
    func put(_ path: String, data: Data, condition: PutCondition) async throws -> String? { throw SyncError.preconditionFailed(path) }
    func makeCollection(_ path: String) async throws { try await inner.makeCollection(path) }
    func delete(_ path: String, ifMatch: String?) async throws { try await inner.delete(path, ifMatch: ifMatch) }
}
