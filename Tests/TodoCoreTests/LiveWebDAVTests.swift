import XCTest
@testable import TodoCore

/// Runs against a real WebDAV server only when TODOTIM_LIVE_URL, TODOTIM_LIVE_USER and
/// TODOTIM_LIVE_PASSWORD are set. Uses (and then deletes) the throwaway folders
/// "TodoTim-livetest" and "TodoTim-livetest-race".
@MainActor
final class LiveWebDAVTests: XCTestCase {
    func testTwoDevicesConvergeOnRealServer() async throws {
        let folder = "TodoTim-livetest"
        let storage = try LiveServer.client()
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

    private let raceFolder = "TodoTim-livetest-race"

    private func inboxTasks(_ storage: RemoteStorage) async throws -> Set<String> {
        let file = try await storage.get(raceFolder + "/projects/inbox.json")
        return Set(try JSONCoding.decoder.decode(ProjectFile.self, from: file.data).tasks.map(\.content))
    }

    /// Two devices with separate caches sync back to back, each right after the other's write
    /// (well within Nextcloud's same-second ETag window). No task may be lost.
    func testRapidWritesFromTwoDevicesLoseNothing() async throws {
        let client = try LiveServer.client()
        let storage = LoggingStorage(inner: client)
        try? await client.delete(raceFolder, ifMatch: nil)
        defer { Task { try? await client.delete(raceFolder, ifMatch: nil) } }

        let a = TodoStore(), b = TodoStore()
        let cacheA = RemoteFileCache(), cacheB = RemoteFileCache()
        var expected: Set<String> = []
        for round in 0..<3 {
            for (name, store, cache) in [("A", a, cacheA), ("B", b, cacheB)] {
                let content = "\(name) round \(round)"
                store.addTask(content: content, projectId: TodoStore.inboxID)
                expected.insert(content)
                store.replaceDatabase(try await SyncEngine.sync(local: store.db, storage: storage,
                                                                folder: raceFolder, cache: cache).merged)
            }
        }
        a.replaceDatabase(try await SyncEngine.sync(local: a.db, storage: storage, folder: raceFolder, cache: cacheA).merged)
        XCTAssertEqual(Set(a.db.tasks.values.filter { !$0.deleted }.map(\.content)), expected)
        // B synced last in the loop, after A's final write.
        XCTAssertEqual(Set(b.db.tasks.values.filter { !$0.deleted }.map(\.content)), expected)
        let onServer = try await inboxTasks(client)
        XCTAssertEqual(onServer, expected)
        try await client.delete(raceFolder, ifMatch: nil)
    }

    /// Device B downloads the inbox; right after that GET, a device without the same-second
    /// guard rewrites it (same second, so Nextcloud keeps the ETag). B's sync must notice and
    /// merge that write instead of overwriting it.
    func testSameSecondRewriteDuringSyncIsNotLost() async throws {
        let client = try LiveServer.client()
        let storage = LoggingStorage(inner: client)
        try? await client.delete(raceFolder, ifMatch: nil)
        defer { Task { try? await client.delete(raceFolder, ifMatch: nil) } }

        let a = TodoStore(), b = TodoStore()
        a.addTask(content: "v1", projectId: TodoStore.inboxID)
        a.replaceDatabase(try await SyncEngine.sync(local: a.db, storage: client, folder: raceFolder).merged)
        a.addTask(content: "v2 from A", projectId: TodoStore.inboxID)
        let v2 = try XCTUnwrap(try SyncEngine.files(for: a.db)["projects/inbox.json"])
        let inboxPath = raceFolder + "/projects/inbox.json"
        storage.setAfterGet(inboxPath) {
            let before = try await client.listing(self.raceFolder + "/projects").items.first { $0.path == inboxPath }
            let etag = try await client.put(inboxPath, data: v2, condition: .none)
            print("LIVE same-second rewrite: ETag \(before?.etag ?? "nil") -> \(etag ?? "nil")"
                  + (before?.etag == etag ? " (unchanged, as expected for Nextcloud)" : " (changed; crossed a second)"))
        }
        b.addTask(content: "from B", projectId: TodoStore.inboxID)
        b.replaceDatabase(try await SyncEngine.sync(local: b.db, storage: storage, folder: raceFolder).merged)

        let onServer = try await inboxTasks(client)
        XCTAssertEqual(onServer, ["v1", "v2 from A", "from B"])
        try await client.delete(raceFolder, ifMatch: nil)
    }
}
