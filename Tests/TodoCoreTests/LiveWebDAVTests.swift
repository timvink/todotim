import XCTest
@testable import TodoCore

/// Runs against a real WebDAV server only when TODOTIM_LIVE_URL, TODOTIM_LIVE_USER and
/// TODOTIM_LIVE_PASSWORD are set. Uses (and then deletes) the folder "TodoTim-livetest".
@MainActor
final class LiveWebDAVTests: XCTestCase {
    func testTwoDevicesConvergeOnRealServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["TODOTIM_LIVE_URL"], let user = env["TODOTIM_LIVE_USER"],
              let password = env["TODOTIM_LIVE_PASSWORD"] else {
            throw XCTSkip("Set TODOTIM_LIVE_URL/USER/PASSWORD to run")
        }
        let folder = "TodoTim-livetest"
        let storage = try WebDAVClient(serverURL: url, username: user, password: password)
        try? await storage.delete(folder, ifMatch: nil)
        defer { Task { try? await storage.delete(folder, ifMatch: nil) } }

        let a = TodoStore(), b = TodoStore()
        let work = a.addProject(name: "Work")
        let section = a.addSection(projectId: work.id, name: "Planning")
        let parent = a.addTask(content: "Draft roadmap", projectId: work.id, sectionId: section.id, priority: .p1, labels: ["focus"])
        a.addTask(content: "Interview owners", projectId: work.id, parentId: parent.id)
        a.addTask(content: "Inbox item ünïcode ✓", projectId: TodoStore.inboxID)

        let cacheA = RemoteFileCache(), cacheB = RemoteFileCache()
        let r1 = try await SyncEngine.sync(local: a.db, storage: storage, folder: folder, cache: cacheA)
        a.replaceDatabase(r1.merged)
        let r2 = try await SyncEngine.sync(local: b.db, storage: storage, folder: folder, cache: cacheB)
        b.replaceDatabase(r2.merged)
        XCTAssertEqual(b.tasks(projectId: work.id, sectionId: section.id).map(\.content), ["Draft roadmap"])
        XCTAssertEqual(b.subtasks(of: parent.id).map(\.content), ["Interview owners"])

        // Concurrent edits on both devices, then both sync twice.
        b.updateTask(parent.id) { $0.content = "Draft 2027 roadmap" }
        a.moveTask(parent.id, projectId: TodoStore.inboxID, sectionId: nil, parentId: nil)
        for _ in 0..<2 {
            a.replaceDatabase(try await SyncEngine.sync(local: a.db, storage: storage, folder: folder, cache: cacheA).merged)
            b.replaceDatabase(try await SyncEngine.sync(local: b.db, storage: storage, folder: folder, cache: cacheB).merged)
        }
        XCTAssertEqual(a.db, b.db)
        XCTAssertEqual(a.task(parent.id)?.projectId, TodoStore.inboxID)

        let files = try await storage.list(folder + "/projects")
        XCTAssertFalse(files.isEmpty)
        try await storage.delete(folder, ifMatch: nil)
    }
}
