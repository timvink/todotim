import XCTest
@testable import TodoCore

@MainActor
final class SyncControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "TodoTimSyncControllerTests"
    private let settings = SyncSettings(serverURL: "https://cloud.example.com/remote.php/dav/",
                                        username: "tim", enabled: true)

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeController(_ store: TodoStore, _ remote: FakeCalDAVServer,
                                credentials: CredentialStore = InMemoryCredentialStore(), stateURL: URL? = nil) -> SyncController {
        let c = SyncController(store: store, defaults: defaults, credentials: credentials, config: nil,
                               configPath: "/nonexistent", stateURL: stateURL) { _, _ in remote }
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
        let c = makeController(TodoStore(), FakeCalDAVServer(), credentials: creds)
        XCTAssertEqual(c.status, .disabled)
        var disabled = settings
        disabled.enabled = false
        c.configure(disabled, password: "secret")
        XCTAssertEqual(creds.password(for: "tim@cloud.example.com"), "secret")
        XCTAssertNil(creds.password(for: "tim"), "no username-only entry")
        XCTAssertEqual(c.storedPassword(), "secret")

        let reloaded = makeController(TodoStore(), FakeCalDAVServer(), credentials: creds)
        XCTAssertEqual(reloaded.settings, disabled)
        XCTAssertEqual(reloaded.status, .disabled)
    }

    func testMissingPasswordReportsError() async {
        let c = makeController(TodoStore(), FakeCalDAVServer())
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
        let c = SyncController(store: TodoStore(), defaults: defaults, credentials: creds, config: nil,
                               configPath: "/nonexistent", stateURL: nil) { s, pw in
            used.append("\(s.serverURL) \(pw)")
            return FakeCalDAVServer()
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
        let c = makeController(TodoStore(), FakeCalDAVServer(),
                               credentials: InMemoryCredentialStore(["tim@cloud.example.com:80": "pw"]))
        c.configure(insecure, password: nil)
        await c.syncNow()
        XCTAssertEqual(c.status, .error(SyncError.insecureURL(insecure.serverURL).errorDescription!))
    }

    func testKeychainSaveFailureIsSurfacedAndPasswordKeptForSession() async throws {
        let creds = InMemoryCredentialStore()
        creds.saveError = SyncError.network("keychain locked")
        let remote = FakeCalDAVServer()
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

    func testTestConnectionListsCalendars() async {
        let remote = FakeCalDAVServer()
        let c = makeController(TodoStore(), remote)
        let error = await c.testConnection(settings, password: "pw")
        XCTAssertNil(error)
        let listed = await remote.count("PROPFIND")
        XCTAssertEqual(listed, 1)
        let empty = await c.testConnection(settings, password: "")
        XCTAssertNotNil(empty)
    }

    func testTwoControllersConvergeAndCallback() async throws {
        let remote = FakeCalDAVServer()
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
        let remote = FakeCalDAVServer()
        // Another device already wrote a task.
        let other = TodoStore()
        let remoteTask = other.addTask(content: "remote", projectId: TodoStore.inboxID)
        let first = try await CalDAVSync.sync(local: other.db, state: CalDAVState(account: "x"), server: remote)
        XCTAssertGreaterThan(first.writes, 0)

        let store = TodoStore()
        let c = makeController(store, remote)
        let edited = TodoBox()
        await remote.setBeforeList { @MainActor in
            edited.id = store.addTask(content: "typed during sync", projectId: TodoStore.inboxID).id
        }
        c.configure(settings, password: "pw")
        try await waitUntil { c.lastSync != nil }

        let localID = try XCTUnwrap(edited.id)
        XCTAssertNotNil(store.task(localID), "local edit made while sync was in flight survives")
        XCTAssertNotNil(store.task(remoteTask.id))

        // The follow-up sync (scheduled because the db changed) pushes the edit.
        try await waitUntil { await remote.ics("calendars/tim/todotim-inbox/\(localID).ics") != nil }
    }

    func testStateIsSavedAfterTheDatabaseAndReloaded() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("todotim-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("caldav-state.json")
        let remote = FakeCalDAVServer()
        let store = TodoStore()
        store.addTask(content: "x", projectId: TodoStore.inboxID)
        let c = makeController(store, remote, stateURL: url)
        var events: [String] = []
        c.onDatabaseReplaced = { events.append("db") }
        c.flushDatabase = { events.append("flush"); return true }
        c.configure(settings, password: "pw")
        try await waitUntil { c.lastSync != nil }
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) }
        XCTAssertEqual(events, ["db", "flush"])
        let saved = try JSONDecoder().decode(CalDAVState.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.resources.count, 1)
        XCTAssertEqual(saved.account, "https://cloud.example.com/remote.php/dav/|tim")

        // When the database cannot be saved, the state file is left as it was.
        let before = try Data(contentsOf: url)
        c.flushDatabase = { false }
        store.addTask(content: "y", projectId: TodoStore.inboxID)
        await c.syncNow()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try Data(contentsOf: url), before)
        c.flushDatabase = { true }
        await c.syncNow()
        try await waitUntil { (try? Data(contentsOf: url)) != before }

        // A new controller (next launch) syncs from the saved state: nothing to write.
        await remote.resetCounts()
        let c2 = makeController(store, remote, stateURL: url)
        c2.configure(settings, password: "pw")
        try await waitUntil { c2.lastSync != nil }
        let puts = await remote.count("PUT"), mk = await remote.count("MKCALENDAR")
        XCTAssertEqual(puts + mk, 0)
    }
}

@MainActor
private final class TodoBox { var id: EntityID? }

@MainActor
final class SyncControllerConfigTests: XCTestCase {
    private let suite = "TodoTimSyncControllerConfigTests"

    #if os(macOS)  // password_command needs a login shell
    func testConfigFileSettingsWinAndPasswordCommandBypassesKeychain() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let managed = SyncSettings(serverURL: "https://cloud.example.com/remote.php/dav/files/tim/",
                                   username: "tim", enabled: true)
        let config = AppConfig(sync: managed, passwordCommand: "echo from-command")
        let creds = InMemoryCredentialStore()
        let remote = FakeCalDAVServer()
        let store = TodoStore()
        let c = SyncController(store: store, defaults: defaults, credentials: creds, config: config,
                               configPath: "/tmp/test.toml", stateURL: nil) { _, _ in remote }
        c.syncInterval = .seconds(3600)
        XCTAssertEqual(c.settings, managed)
        XCTAssertEqual(c.managedConfigPath, "/tmp/test.toml")

        // A Keychain password is ignored: the command's password is kept in memory only.
        try creds.savePassword("stale", for: "tim@cloud.example.com")
        await c.syncNow()
        XCTAssertEqual(c.storedPassword(), "from-command")
        XCTAssertEqual(creds.password(for: "tim@cloud.example.com"), "stale")
        guard case .idle = c.status else { return XCTFail("status \(c.status)") }

        // The Settings window cannot override managed settings.
        var other = managed
        other.username = "someone-else"
        c.configure(other, password: nil)
        XCTAssertEqual(c.settings, managed)
        XCTAssertNil(defaults.data(forKey: SyncController.settingsKey))
    }
    #endif
}
