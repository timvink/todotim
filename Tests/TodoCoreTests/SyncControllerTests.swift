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
        XCTAssertEqual(creds.password(for: "tim@cloud.example.com"), "secret")
        XCTAssertNil(creds.password(for: "tim"), "no username-only entry")
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

    func testPasswordIsScopedToServer() async {
        XCTAssertEqual(settings.credentialAccount, "tim@cloud.example.com")
        var other = settings
        other.serverURL = "https://Other.example.com:8443/dav/"
        XCTAssertEqual(other.credentialAccount, "tim@other.example.com:8443")
        other.serverURL = "http://localhost/dav/"
        XCTAssertEqual(other.credentialAccount, "tim@localhost:80")

        // A password saved for one server is not sent to another with the same username.
        let creds = InMemoryCredentialStore(["tim": "legacy", "tim@cloud.example.com": "pw"])
        var used: [String] = []
        let c = SyncController(store: TodoStore(), defaults: defaults, credentials: creds) { s, pw in
            used.append("\(s.serverURL) \(pw)")
            return InMemoryRemoteStorage()
        }
        c.syncInterval = .seconds(3600)
        other.serverURL = "https://other.example.com/dav/"
        c.configure(other, password: nil)
        await c.syncNow()
        XCTAssertEqual(c.status, .error(SyncError.missingPassword.errorDescription!))
        XCTAssertNil(c.storedPassword())
        XCTAssertTrue(used.isEmpty)
    }

    func testInsecureURLIsRefusedBeforePasswordLookup() async {
        var insecure = settings
        insecure.serverURL = "http://cloud.example.com/dav/"
        let c = makeController(TodoStore(), InMemoryRemoteStorage(),
                               credentials: InMemoryCredentialStore(["tim@cloud.example.com:80": "pw"]))
        c.configure(insecure, password: nil)
        await c.syncNow()
        XCTAssertEqual(c.status, .error(SyncError.insecureURL(insecure.serverURL).errorDescription!))
    }

    func testKeychainSaveFailureIsSurfacedAndPasswordKeptForSession() async throws {
        let creds = InMemoryCredentialStore()
        creds.saveError = KeychainError(status: -25308)
        let remote = InMemoryRemoteStorage()
        let c = makeController(TodoStore(), remote, credentials: creds)
        c.configure(settings, password: "pw")
        XCTAssertNotNil(c.credentialError)
        XCTAssertTrue(c.credentialError!.contains("Keychain"))
        XCTAssertEqual(c.storedPassword(), "pw")
        try await waitUntil { c.lastSync != nil }
        creds.saveError = nil
        c.configure(settings, password: "pw")
        XCTAssertNil(c.credentialError)
        XCTAssertEqual(creds.password(for: "tim@cloud.example.com"), "pw")
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

@MainActor
final class SyncControllerConfigTests: XCTestCase {
    private let suite = "TodoTimSyncControllerConfigTests"

    func testConfigFileSettingsWinAndPasswordCommandFillsKeychain() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let managed = SyncSettings(serverURL: "https://cloud.example.com/remote.php/dav/files/tim/",
                                   username: "tim", folder: "TodoTim", enabled: true)
        let config = AppConfig(sync: managed, passwordCommand: "echo from-command")
        let creds = InMemoryCredentialStore()
        let remote = InMemoryRemoteStorage()
        let store = TodoStore()
        let c = SyncController(store: store, defaults: defaults, credentials: creds, config: config,
                               configPath: "/tmp/test.toml") { _, _ in remote }
        c.syncInterval = .seconds(3600)
        XCTAssertEqual(c.settings, managed)
        XCTAssertEqual(c.managedConfigPath, "/tmp/test.toml")

        await c.syncNow()
        XCTAssertEqual(creds.password(for: "tim@cloud.example.com"), "from-command")
        guard case .idle = c.status else { return XCTFail("status \(c.status)") }

        // The Settings window cannot override managed settings.
        var other = managed
        other.username = "someone-else"
        c.configure(other, password: nil)
        XCTAssertEqual(c.settings, managed)
        XCTAssertNil(defaults.data(forKey: SyncController.settingsKey))
    }
}
