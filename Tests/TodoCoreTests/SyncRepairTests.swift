import XCTest
@testable import TodoCore

@MainActor
final class SyncRepairTests: XCTestCase {
    let folder = "TodoTim"
    let now = Date()
    private func ago(_ s: TimeInterval) -> Date { TodoStore.millisecondPrecision(now.addingTimeInterval(-s)) }

    private func db(projects: [Project] = [], sections: [Section] = [], tasks: [TodoTask]) -> Database {
        var d = Database()
        for p in projects { d.projects[p.id] = p }
        for s in sections { d.sections[s.id] = s }
        for t in tasks { d.tasks[t.id] = t }
        return d
    }

    func testConcurrentMovesCreatingACycleAreBroken() {
        let a = TodoTask(id: "a", projectId: "p", content: "a", order: 1, updatedAt: ago(100))
        let b = TodoTask(id: "b", projectId: "p", content: "b", order: 2, updatedAt: ago(100))
        // Device 1 makes b a child of a; device 2 (later) makes a a child of b.
        var b1 = b; b1.parentId = "a"; b1.updatedAt = ago(20)
        var a2 = a; a2.parentId = "b"; a2.updatedAt = ago(10)
        let one = db(tasks: [a, b1]), two = db(tasks: [a2, b])
        let m1 = SyncEngine.merge([one, two], now: now), m2 = SyncEngine.merge([two, one], now: now)
        XCTAssertEqual(m1, m2)
        // The newest edit (a2) is the one undone.
        XCTAssertNil(m1.tasks["a"]?.parentId)
        XCTAssertEqual(m1.tasks["b"]?.parentId, "a")
        XCTAssertEqual(SyncEngine.merge([m1], now: now), m1, "repair is idempotent")
        let store = TodoStore(db: m1)
        XCTAssertEqual(store.tasks(projectId: "p", sectionId: nil).map(\.id), ["a"])
        XCTAssertEqual(store.descendantIDs(of: "a"), ["b"])
    }

    func testLongCycleIsBrokenOnce() {
        let ids = ["a", "b", "c", "d"]
        let tasks = ids.enumerated().map { i, id in
            TodoTask(id: id, projectId: "p", parentId: ids[(i + 1) % ids.count], content: id, order: 1, updatedAt: ago(Double(10 + i)))
        }
        let merged = SyncEngine.merge([db(tasks: tasks)], now: now)
        XCTAssertEqual(merged.tasks.values.filter { $0.parentId == nil }.map(\.id), ["a"])  // newest updatedAt
    }

    func testOrphanOfDeletedParentBecomesVisibleTopLevel() {
        let parent = TodoTask(id: "parent", projectId: "p", content: "parent", order: 1, updatedAt: ago(50))
        let child = TodoTask(id: "child", projectId: "p", parentId: "parent", content: "child", order: 1, updatedAt: ago(40))
        var deadParent = parent; deadParent.deleted = true; deadParent.updatedAt = ago(30)
        // Device 1 deleted the parent before it knew about the child added on device 2.
        let merged = SyncEngine.merge([db(tasks: [deadParent]), db(tasks: [parent, child])], now: now)
        XCTAssertNil(merged.tasks["child"]?.parentId)
        let store = TodoStore(db: merged)
        XCTAssertEqual(store.tasks(projectId: "p", sectionId: nil).map(\.id), ["child"])

        let missing = SyncEngine.merge([db(tasks: [child])], now: now)
        XCTAssertNil(missing.tasks["child"]?.parentId)
    }

    func testSubtasksFollowTheirParentsProjectAndSection() {
        let projects = [Project(id: "p", name: "P", order: 1, updatedAt: ago(100)), Project(id: "q", name: "Q", order: 2, updatedAt: ago(100))]
        let sq = Section(id: "sq", projectId: "q", name: "S", order: 1, updatedAt: ago(100))
        let parent = TodoTask(id: "parent", projectId: "p", content: "parent", order: 1, updatedAt: ago(50))
        let child = TodoTask(id: "child", projectId: "p", parentId: "parent", content: "child", order: 1, updatedAt: ago(50))
        let grandchild = TodoTask(id: "gc", projectId: "p", parentId: "child", content: "gc", order: 1, updatedAt: ago(50))
        // Device 1 moved the parent (and children) to q/sq; device 2 later edited the child's title.
        var movedParent = parent; movedParent.projectId = "q"; movedParent.sectionId = "sq"; movedParent.updatedAt = ago(20)
        var movedGC = grandchild; movedGC.projectId = "q"; movedGC.sectionId = "sq"; movedGC.updatedAt = ago(20)
        var editedChild = child; editedChild.content = "edited"; editedChild.updatedAt = ago(10)
        let merged = SyncEngine.merge([db(projects: projects, sections: [sq], tasks: [movedParent, movedGC]),
                                       db(projects: projects, sections: [sq], tasks: [parent, editedChild, grandchild])], now: now)
        XCTAssertEqual(merged.tasks["child"]?.content, "edited")
        XCTAssertEqual(merged.tasks["child"]?.projectId, "q")
        XCTAssertEqual(merged.tasks["child"]?.sectionId, "sq")
        XCTAssertEqual(merged.tasks["gc"]?.projectId, "q")
        let store = TodoStore(db: merged)
        XCTAssertEqual(store.subtasks(of: "parent").map(\.id), ["child"])
        XCTAssertEqual(store.openTaskCount(projectId: "q"), 3)
    }

    func testTaskInDeletedSectionMovesToProjectTop() {
        let p = Project(id: "p", name: "P", order: 1, updatedAt: ago(100))
        let s = Section(id: "s", projectId: "p", name: "S", order: 1, updatedAt: ago(100))
        var deadS = s; deadS.deleted = true; deadS.updatedAt = ago(20)
        let added = TodoTask(id: "t", projectId: "p", sectionId: "s", content: "t", order: 1, updatedAt: ago(10))
        let merged = SyncEngine.merge([db(projects: [p], sections: [deadS], tasks: []), db(projects: [p], sections: [s], tasks: [added])], now: now)
        XCTAssertNil(merged.tasks["t"]?.sectionId)
    }

    // MARK: - Sync engine I/O

    func testUploadOrderingAndManyFiles() async throws {
        let remote = InMemoryRemoteStorage()
        let store = TodoStore()
        let ps = (0..<12).map { store.addProject(name: "P\($0)") }
        for p in ps { store.addTask(content: "t", projectId: p.id) }
        let r = try await SyncEngine.sync(local: store.db, storage: remote, folder: folder)
        XCTAssertEqual(r.uploaded.count, 14)  // 12 projects + inbox + index
        let puts = await remote.putPaths
        XCTAssertEqual(puts.last, "TodoTim/index.json", "index.json is written after all project files")
        XCTAssertEqual(Set(puts.dropLast()).count, 13)

        // A second device downloads everything concurrently and converges.
        let other = TodoStore()
        let r2 = try await SyncEngine.sync(local: other.db, storage: remote, folder: folder)
        other.replaceDatabase(r2.merged)
        XCTAssertEqual(other.projects.count, 12)

        // Deleting projects: their files are removed only after index.json.
        await remote.resetCounters()
        for p in ps.prefix(3) { store.deleteProject(p.id) }
        let r3 = try await SyncEngine.sync(local: store.db, storage: remote, folder: folder)
        XCTAssertEqual(r3.deleted.count, 3)
        let puts3 = await remote.putPaths, deletes3 = await remote.deletePaths
        XCTAssertEqual(puts3, ["TodoTim/index.json"])
        XCTAssertEqual(deletes3.count, 3)
    }

    func testUnchangedSyncReusesDecodedFiles() async throws {
        let remote = InMemoryRemoteStorage()
        let cache = RemoteFileCache()
        let store = TodoStore()
        store.addTask(content: "a", projectId: TodoStore.inboxID)
        _ = try await SyncEngine.sync(local: store.db, storage: remote, folder: folder, cache: cache)
        // Our own uploads are cached decoded, so the next sync decodes nothing.
        let items = try await remote.list("TodoTim/projects")
        for item in items {
            let decoded = await cache.decoded(at: item.path, etag: item.etag)
            XCTAssertNotNil(decoded, item.path)
        }
        let index = try await remote.list("TodoTim").first { $0.name == "index.json" }!
        let decodedIndex = await cache.decoded(at: index.path, etag: index.etag)
        XCTAssertNotNil(decodedIndex)

        // A file changed by another device is decoded again (stale decoded entry not used).
        let other = TodoStore()
        let r = try await SyncEngine.sync(local: other.db, storage: remote, folder: folder)
        other.replaceDatabase(r.merged)
        other.addTask(content: "from other", projectId: TodoStore.inboxID)
        _ = try await SyncEngine.sync(local: other.db, storage: remote, folder: folder)
        let merged = try await SyncEngine.sync(local: store.db, storage: remote, folder: folder, cache: cache)
        XCTAssertEqual(Set(merged.merged.tasks.values.map(\.content)), ["a", "from other"])
    }

    func testConcurrentHelperPreservesOrderAndLimit() async throws {
        actor Counter { var current = 0, peak = 0
            func enter() { current += 1; peak = max(peak, current) }
            func leave() { current -= 1 }
        }
        let counter = Counter()
        let out = try await SyncEngine.forEachConcurrently(Array(0..<40), limit: 4) { i -> Int in
            await counter.enter()
            try await Task.sleep(for: .milliseconds(Int.random(in: 1...5)))
            await counter.leave()
            return i * 2
        }
        XCTAssertEqual(out, (0..<40).map { $0 * 2 })
        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, 4)
    }
}
