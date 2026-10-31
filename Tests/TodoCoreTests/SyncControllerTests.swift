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
                               configPath: "/nonexistent", stateURL: stateURL) { _, _, cached in await remote.connect(cached: cached) }
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
                               configPath: "/nonexistent", stateURL: nil) { s, pw, _ in
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

    /// An app can start the loop after its first frame: nothing syncs before `start()`.
    func testDeferredStartSyncsOnlyAfterStart() async throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: SyncController.settingsKey)
        let remote = FakeCalDAVServer()
        let c = SyncController(store: TodoStore(), defaults: defaults,
                               credentials: InMemoryCredentialStore(["tim@cloud.example.com": "pw"]), config: nil,
                               configPath: "/nonexistent", stateURL: nil, makeServer: { _, _, _ in remote }, startSyncing: false)
        c.syncInterval = .seconds(3600)
        c.debounceInterval = .milliseconds(20)
        XCTAssertEqual(c.status, .idle(lastSync: nil), "enabled settings show as not synced yet")
        c.scheduleSync()
        try await Task.sleep(for: .milliseconds(200))
        let requests = await remote.count("PROPFIND")
        XCTAssertEqual(requests, 0)
        XCTAssertNil(c.lastSync)

        c.start()
        try await waitUntil { c.lastSync != nil }
        c.start()  // already running: no second loop
        XCTAssertEqual(c.status, .idle(lastSync: c.lastSync))
    }

    /// The Keychain is a call to another process (and can show a prompt): never on the main thread.
    func testKeychainIsReadOffTheMainThread() async throws {
        let creds = ThreadRecordingCredentials()
        let c = makeController(TodoStore(), FakeCalDAVServer(), credentials: creds)
        c.configure(settings, password: nil)
        try await waitUntil { c.lastSync != nil }
        XCTAssertFalse(creds.readsOnMainThread.isEmpty)
        XCTAssertFalse(creds.readsOnMainThread.contains(true))
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

/// Discovery of the calendar home: once, kept in the sync state, and again only when needed.
@MainActor
final class SyncControllerDiscoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "TodoTimSyncControllerDiscoveryTests"
    private let settings = SyncSettings(serverURL: "https://cloud.example.com/remote.php/dav/", username: "tim", enabled: true)
    private var dir: URL!
    private var stateURL: URL { dir.appendingPathComponent("caldav-state.json") }

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("todotim-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeController(_ store: TodoStore, _ makeServer: @escaping SyncController.ServerFactory) -> SyncController {
        let c = SyncController(store: store, defaults: defaults, credentials: InMemoryCredentialStore(), config: nil,
                               configPath: "/nonexistent", stateURL: stateURL, makeServer: makeServer)
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

    private func savedState() throws -> CalDAVState {
        try JSONDecoder().decode(CalDAVState.self, from: Data(contentsOf: stateURL))
    }

    func testHomeIsDiscoveredOnceAndKept() async throws {
        let remote = FakeCalDAVServer(layout: .radicale())
        let store = TodoStore()
        store.addTask(content: "x", projectId: TodoStore.inboxID)
        let c = makeController(store) { _, _, cached in await remote.connect(cached: cached) }
        c.configure(settings, password: "pw")
        try await waitUntil { c.lastSync != nil }
        try await waitUntil { (try? self.savedState())?.home != nil }
        XCTAssertEqual(try savedState().home, remote.calendarHome)
        XCTAssertTrue(try savedState().resources.keys.allSatisfy { $0.hasPrefix("tim/todotim-inbox/") })

        // Later syncs use the kept home: an idle sync is a single request.
        await c.syncNow()
        await remote.resetCounts()
        await c.syncNow()
        let requests = await remote.requests
        XCTAssertEqual(requests, ["PROPFIND": 1])
        // So does the next launch.
        let c2 = makeController(store) { _, _, cached in await remote.connect(cached: cached) }
        c2.configure(settings, password: "pw")
        try await waitUntil { c2.lastSync != nil }
        let discoveries = await remote.discoveries
        XCTAssertEqual(discoveries, 1)
    }

    func testHomeIsDiscoveredAgainWhenItIsGone() async throws {
        // The account moves to another calendar home (say, a server migration); the old one
        // answers 404.
        let old = FakeCalDAVServer(), new = FakeCalDAVServer(layout: .radicale())
        let store = TodoStore()
        let t = store.addTask(content: "keep me", projectId: TodoStore.inboxID)
        let c = makeController(store) { _, _, cached in
            if cached == nil, await old.homeGone { return await new.connect(cached: nil) }
            return cached == new.calendarHome ? new : await old.connect(cached: cached)
        }
        c.configure(settings, password: "pw")
        try await waitUntil { c.lastSync != nil }
        let first = c.lastSync
        await old.setHomeGone(true)
        await c.syncNow()
        XCTAssertNotEqual(c.lastSync, first)
        XCTAssertEqual(c.status, .idle(lastSync: c.lastSync))
        XCTAssertEqual(store.task(t.id)?.content, "keep me", "nothing is deleted")
        let uploaded = await new.ics("tim/todotim-inbox/\(t.id).ics")
        XCTAssertNotNil(uploaded, "a new home is synced from scratch")
        let discoveries = await new.discoveries
        XCTAssertEqual(discoveries, 1)
        try await waitUntil { (try? self.savedState())?.home == new.calendarHome }
    }

    func testAnotherServerOrUserIsDiscoveredAgain() async throws {
        let remote = FakeCalDAVServer()
        let c = makeController(TodoStore()) { _, _, cached in await remote.connect(cached: cached) }
        c.configure(settings, password: "pw")
        try await waitUntil { await remote.discoveries == 1 }
        var other = settings
        other.username = "tim2"
        c.configure(other, password: "pw")
        try await waitUntil { await remote.discoveries == 2 }
        other.serverURL = "https://other.example.com/dav/"
        c.configure(other, password: "pw")
        try await waitUntil { await remote.discoveries == 3 }
    }

    /// The sync state of an earlier version has no home; its paths are those of the SabreDAV
    /// layout. When discovery finds that home, the state still applies: nothing is fetched or
    /// written again.
    func testStateFromBeforeDiscoveryIsKept() async throws {
        let remote = FakeCalDAVServer()
        let store = TodoStore()
        store.addTask(content: "x", projectId: TodoStore.inboxID)
        var legacy = CalDAVState(account: try XCTUnwrap(settings.stateAccount))
        for _ in 0..<2 {
            let r = try await CalDAVSync.sync(local: store.db, state: legacy, server: remote)
            store.replaceDatabase(r.merged)
            legacy = r.state
        }
        XCTAssertNil(legacy.home)
        try JSONEncoder().encode(legacy).write(to: stateURL)
        await remote.resetCounts()

        let c = makeController(store) { _, _, cached in await remote.connect(cached: cached) }
        c.configure(settings, password: "pw")
        try await waitUntil { c.lastSync != nil }
        let requests = await remote.requests
        XCTAssertEqual(requests, ["PROPFIND": 1])
        try await waitUntil { (try? self.savedState())?.home == remote.calendarHome }
        XCTAssertEqual(try savedState().resources, legacy.resources)
    }
}

@MainActor
private final class TodoBox { var id: EntityID? }

/// Returns "pw" and records whether each read ran on the main thread.
private final class ThreadRecordingCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Bool] = []
    var readsOnMainThread: [Bool] { lock.withLock { reads } }

    func password(for account: String) -> String? {
        lock.withLock { reads.append(Thread.isMainThread) }
        return "pw"
    }

    func setPassword(_ password: String?, for account: String) {}
}

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
                               configPath: "/tmp/test.toml", stateURL: nil) { _, _, _ in remote }
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
