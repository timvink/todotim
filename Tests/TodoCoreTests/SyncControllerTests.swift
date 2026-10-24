import XCTest
@testable import TodoCore

@MainActor
final class SyncControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "TodoTimSyncControllerTests"
    private let settings = SyncSettings(serverURL: "https://cloud.example.com/remote.php/dav/files/tim/",
                                        username: "tim", folder: "TodoTim", enabled: true)

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeController(_ store: TodoStore, _ remote: InMemoryRemoteStorage,
                                credentials: CredentialStore = InMemoryCredentialStore()) -> SyncController {
        let c = SyncController(store: store, defaults: defaults, credentials: credentials) { _, _ in remote }
        c.syncInterval = .seconds(3600)
        c.debounceInterval = .milliseconds(20)
        return c
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testSettingsPersistAndPasswordStored() {
        let creds = InMemoryCredentialStore()
        let c = makeController(TodoStore(), InMemoryRemoteStorage(), credentials: creds)
        XCTAssertEqual(c.status, .disabled)
        var disabled = settings
        disabled.enabled = false
        c.configure(disabled, password: "secret")
        XCTAssertEqual(creds.password(for: "tim"), "secret")
        XCTAssertEqual(c.storedPassword(), "secret")

        let reloaded = makeController(TodoStore(), InMemoryRemoteStorage(), credentials: creds)
        XCTAssertEqual(reloaded.settings, disabled)
        XCTAssertEqual(reloaded.status, .disabled)
    }

    func testMissingPasswordReportsError() async {
        let c = makeController(TodoStore(), InMemoryRemoteStorage())
        c.configure(settings, password: nil)
        await c.syncNow()
        XCTAssertEqual(c.status, .error(SyncError.missingPassword.errorDescription!))
    }

    func testTestConnectionCreatesFolders() async {
        let remote = InMemoryRemoteStorage()
        let c = makeController(TodoStore(), remote)
        let error = await c.testConnection(settings, password: "pw")
        XCTAssertNil(error)
        let collections = await remote.collections
        XCTAssertTrue(collections.isSuperset(of: ["TodoTim", "TodoTim/projects"]))
        let empty = await c.testConnection(settings, password: "")
        XCTAssertNotNil(empty)
    }

    func testTwoControllersConvergeAndCallback() async throws {
        let remote = InMemoryRemoteStorage()
        let a = TodoStore(), b = TodoStore()
        let ca = makeController(a, remote), cb = makeController(b, remote)
        var replacedOnB = 0
        cb.onDatabaseReplaced = { replacedOnB += 1 }

        let t = a.addTask(content: "hello", projectId: TodoStore.inboxID)
        ca.configure(settings, password: "pw")
        try await waitUntil { ca.lastSync != nil }
        cb.configure(settings, password: "pw")
        try await waitUntil { cb.lastSync != nil }

        XCTAssertEqual(b.task(t.id)?.content, "hello")
        XCTAssertEqual(replacedOnB, 1)
        XCTAssertEqual(cb.status, .idle(lastSync: cb.lastSync))
    }

    func testLocalEditDuringSyncIsKeptAndPushed() async throws {
        let remote = InMemoryRemoteStorage()
        // Another device already wrote a task.
        let other = TodoStore()
        let remoteTask = other.addTask(content: "remote", projectId: TodoStore.inboxID)
        _ = try await SyncEngine.sync(local: other.db, storage: remote, folder: "TodoTim")

        let store = TodoStore()
        let c = makeController(store, remote)
        let edited = TodoBox()
        await remote.setBeforeGet { @MainActor in
            edited.id = store.addTask(content: "typed during sync", projectId: TodoStore.inboxID).id
        }
        c.configure(settings, password: "pw")
        try await waitUntil { c.lastSync != nil }

        let localID = try XCTUnwrap(edited.id)
        XCTAssertNotNil(store.task(localID), "local edit made while sync was in flight survives")
        XCTAssertNotNil(store.task(remoteTask.id))

        // The follow-up sync (scheduled because the db changed) pushes the edit.
        try await waitUntil {
            guard let data = await remote.data("TodoTim/projects/inbox.json"),
                  let pf = try? JSONCoding.decoder.decode(ProjectFile.self, from: data) else { return false }
            return pf.tasks.contains { $0.id == localID }
        }
    }
}

@MainActor
private final class TodoBox { var id: EntityID? }
