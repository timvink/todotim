import XCTest
@testable import TodoCore

/// Remote data validation and resource limits.
@MainActor
final class SyncSecurityTests: XCTestCase {
    let folder = "TodoTim"
    let now = Date()

    func testEntityIDValidation() {
        for ok in ["inbox", newID(), "a", "A_b-9", String(repeating: "x", count: 64)] {
            XCTAssertTrue(isValidEntityID(ok), ok)
        }
        for bad in ["", "..", ".", "a/b", "../../outside", "a.b", "a b", "a\n", "é", String(repeating: "x", count: 65)] {
            XCTAssertFalse(isValidEntityID(bad), bad)
        }
    }

    func testInvalidRemoteEntitiesAreDroppedAndCounted() async throws {
        let remote = InMemoryRemoteStorage()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let index = IndexFile(schemaVersion: 1, projects: [
            Project(id: "inbox", name: "Inbox", order: 0, isInbox: true, updatedAt: date),
            Project(id: "../../outside", name: "Evil", order: 1, updatedAt: date),
        ], labels: [Label(id: "l/1", name: "x", order: 0, updatedAt: date)])
        let pf = ProjectFile(schemaVersion: 1, projectId: "inbox", sections: [
            Section(id: "s1", projectId: "../x", name: "S", order: 0, updatedAt: date),
        ], tasks: [
            TodoTask(id: "ok", projectId: "inbox", content: "fine", order: 0, updatedAt: date),
            TodoTask(id: "t2", projectId: "../../outside", content: "evil", order: 1, updatedAt: date),
            TodoTask(id: "t3", projectId: "inbox", parentId: "a/b", content: "evil", order: 2, updatedAt: date),
        ])
        await remote.write("TodoTim/index.json", try JSONCoding.encoder.encode(index))
        await remote.write("TodoTim/projects/inbox.json", try JSONCoding.encoder.encode(pf))
        // A file not named after a valid id is ignored entirely.
        await remote.write("TodoTim/projects/a.b.json", try JSONCoding.encoder.encode(pf))
        try await remote.makeCollection("TodoTim")
        try await remote.makeCollection("TodoTim/projects")

        let result = try await SyncEngine.sync(local: Database(), storage: remote, folder: folder, now: { self.now })
        XCTAssertEqual(result.droppedRemoteEntities, 5)
        XCTAssertEqual(Set(result.merged.tasks.keys), ["ok"])
        XCTAssertEqual(Set(result.merged.projects.keys), ["inbox"])
        XCTAssertTrue(result.merged.labels.isEmpty && result.merged.sections.isEmpty)
        let puts = await remote.putPaths
        XCTAssertFalse(puts.contains { $0.contains("..") || $0.contains("outside") }, "\(puts)")
        let ignored = await remote.data("TodoTim/projects/a.b.json")
        XCTAssertNotNil(ignored, "invalid file names are never deleted either")
    }

    func testLongTextIsTruncatedDeterministically() {
        var db = Database()
        var t = TodoTask(id: "t", projectId: "inbox", content: String(repeating: "é", count: 20_000), order: 0)
        t.description = String(repeating: "d", count: 200_000)
        t.labels = (0..<500).map { "l\($0)" } + [String(repeating: "x", count: 5_000)]
        t.due = DueDate(date: String(repeating: "9", count: 100))
        db.tasks["t"] = t
        let updatedAt = t.updatedAt
        let merged = SyncEngine.merge([db], now: now)
        let out = merged.tasks["t"]!
        XCTAssertEqual(out.content.count, SyncLimits.maxContentLength)
        XCTAssertEqual(out.description.count, SyncLimits.maxDescriptionLength)
        XCTAssertEqual(out.labels.count, SyncLimits.maxLabelsPerTask)
        XCTAssertNil(out.due)
        XCTAssertEqual(out.updatedAt, updatedAt)
        XCTAssertEqual(SyncEngine.merge([merged], now: now), merged, "idempotent")
    }

    func testDeepHierarchyIsCapped() {
        var db = Database()
        let n = 100
        for i in 0..<n {
            db.tasks["t\(i)"] = TodoTask(id: "t\(i)", projectId: "inbox", parentId: i == 0 ? nil : "t\(i - 1)",
                                         content: "\(i)", order: Double(i), updatedAt: now)
        }
        let merged = SyncEngine.merge([db], now: now)
        // Depth of each task in the result.
        func depth(_ id: EntityID) -> Int {
            var d = 0, cur = id
            while let p = merged.tasks[cur]?.parentId { d += 1; cur = p }
            return d
        }
        XCTAssertLessThanOrEqual(merged.tasks.keys.map(depth).max()!, SyncLimits.maxTaskDepth)
        XCTAssertNil(merged.tasks["t33"]?.parentId)
        XCTAssertNil(merged.tasks["t66"]?.parentId)
        XCTAssertNil(merged.tasks["t99"]?.parentId)
        XCTAssertEqual(merged.tasks["t32"]?.parentId, "t31")
        XCTAssertEqual(merged.tasks["t34"]?.parentId, "t33")
        XCTAssertTrue(merged.tasks.values.allSatisfy { $0.updatedAt == now })
        XCTAssertEqual(SyncEngine.merge([merged], now: now), merged, "idempotent")
    }

    func testCacheForgetsFilesRemovedRemotely() async throws {
        let remote = InMemoryRemoteStorage()
        let cache = RemoteFileCache()
        let store = TodoStore()
        let p = store.addProject(name: "P")
        store.addTask(content: "x", projectId: p.id)
        let path = "TodoTim/projects/\(p.id).json"
        _ = try await SyncEngine.sync(local: store.db, storage: remote, folder: folder, cache: cache)
        let before = await cache.cachedPaths
        XCTAssertTrue(before.contains(path))
        try await remote.delete(path, ifMatch: nil)
        _ = try await SyncEngine.download(storage: remote, folder: folder, cache: cache)
        let after = await cache.cachedPaths
        XCTAssertFalse(after.contains(path))
    }
}

final class PersistencePermissionTests: XCTestCase {
    func testDatabaseFilesArePrivate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("todotim-perm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("data/db.json")
        try LocalPersistence.save(Database(), to: url)
        func mode(_ u: URL) throws -> Int { (try fm.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
        try LocalPersistence.save(Database(), to: url)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["db.json"], "no temp files left")

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try Data("garbage".utf8).write(to: url)
        XCTAssertThrowsError(try LocalPersistence.loadChecked(from: url)) { error in
            guard case .corrupt(let backup, _)? = error as? PersistenceError else { return XCTFail("\(error)") }
            XCTAssertEqual(try? mode(URL(fileURLWithPath: backup)), 0o600)
        }
    }
}
