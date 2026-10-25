import Foundation
import Observation

/// Connection settings for a Nextcloud (or other CalDAV) server. Password lives in the Keychain.
public struct SyncSettings: Codable, Equatable, Sendable {
    /// The DAV root, e.g. "https://cloud.example.com/remote.php/dav/" (an old-style files URL,
    /// ".../remote.php/dav/files/USER/", also works). Calendars live under `calendars/<username>/`.
    public var serverURL: String
    public var username: String
    public var enabled: Bool

    public init(serverURL: String = "", username: String = "", enabled: Bool = false) {
        self.serverURL = serverURL; self.username = username; self.enabled = enabled
    }

    /// Keychain account for these settings: "user@host", plus ":port" when the port is not 443
    /// (e.g. "tim@cloud.example.com", "tim@localhost:8080"). Scoping by server means a password
    /// saved for one server is never sent to another. nil when the URL or username is unusable.
    public var credentialAccount: String? {
        guard !username.isEmpty, let url = try? WebDAVClient.normalizedBaseURL(serverURL),
              let host = url.host?.lowercased() else { return nil }
        let port = WebDAVClient.effectivePort(url)
        return "\(username)@\(host)" + (port == 443 ? "" : ":\(port)")
    }

    /// Identifies whose data a `CalDAVState` describes.
    var stateAccount: String? {
        guard !username.isEmpty, let root = try? CalDAVClient.davRoot(serverURL) else { return nil }
        return "\(root.absoluteString)|\(username)"
    }
}

public enum SyncStatus: Equatable, Sendable {
    case disabled
    case idle(lastSync: Date?)
    case syncing
    case error(String)
}

/// Owns settings, the Keychain password, the CalDAV sync state and the sync loop between
/// `TodoStore` and the server. Syncs every `syncInterval` while enabled, and `debounceInterval`
/// after `scheduleSync()`.
@MainActor
@Observable
public final class SyncController {
    public private(set) var status: SyncStatus = .disabled
    public private(set) var settings: SyncSettings = SyncSettings()
    public private(set) var lastSync: Date?
    /// Problems from the last sync that did not stop it (e.g. a list that could not be shared).
    public private(set) var warning: String?
    /// Path of the config file (`~/.todotim.toml`) that sets the sync settings, or nil when they
    /// come from the Settings window. Managed settings cannot be changed in the app.
    public private(set) var managedConfigPath: String?
    /// Set when the password could not be saved in the Keychain (it is then kept in memory
    /// until the app quits); nil after a successful save.
    public private(set) var credentialError: String?

    /// Called after sync replaced the store's database with merged remote changes.
    /// The app uses it to persist the database.
    @ObservationIgnored public var onDatabaseReplaced: (() -> Void)?
    /// Called before the sync state is saved; must write any pending database save to disk and
    /// return whether the database on disk is current. The state describes what the database
    /// holds, so it is saved only then (never ahead of the database).
    @ObservationIgnored public var flushDatabase: (() -> Bool)?

    @ObservationIgnored public var debounceInterval: Duration = .seconds(2)
    @ObservationIgnored public var syncInterval: Duration = .seconds(60)

    public static let settingsKey = "syncSettings"

    typealias ServerFactory = (SyncSettings, String) throws -> CalDAVServer

    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let makeServer: ServerFactory
    @ObservationIgnored private let stateURL: URL?
    @ObservationIgnored private let stateQueue = DispatchQueue(label: "TodoTim.CalDAVState", qos: .utility)
    @ObservationIgnored private var state: CalDAVState?
    /// The state as last written to `stateURL`.
    @ObservationIgnored private var savedState: CalDAVState?
    /// The database right after the last sync, so an idle sync can skip merging.
    @ObservationIgnored private var lastSynced: Database?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncRequestedWhileSyncing = false
    @ObservationIgnored private var passwordCommand: String?
    @ObservationIgnored private var shareWith: [String] = []
    /// The password command runs at most once per launch (or per `configure`), so a locked
    /// vault does not prompt again every sync interval.
    @ObservationIgnored private var passwordCommandAttempted = false
    /// Password whose Keychain save failed, for the account it belongs to.
    @ObservationIgnored private var sessionPassword: (account: String, password: String)?

    /// Loads settings from `config` (when it has a `[sync]` table) or else from `defaults`, and
    /// starts syncing if enabled (the first sync starts after the current main-actor turn, so
    /// callbacks set right after `init` are in place). `stateURL` is where the CalDAV sync state
    /// is kept (nil: memory only).
    public convenience init(store: TodoStore, defaults: UserDefaults = .standard, credentials: CredentialStore,
                            config: AppConfig? = nil, configPath: String = AppConfig.defaultURL.path, stateURL: URL? = nil) {
        self.init(store: store, defaults: defaults, credentials: credentials, config: config, configPath: configPath,
                  stateURL: stateURL, makeServer: nil)
    }

    init(store: TodoStore, defaults: UserDefaults, credentials: CredentialStore, config: AppConfig?,
         configPath: String, stateURL: URL?, makeServer: ServerFactory?) {
        self.store = store
        self.defaults = defaults
        self.credentials = credentials
        self.stateURL = stateURL
        self.makeServer = makeServer ?? { s, password in
            let dav = try WebDAVClient(serverURL: try CalDAVClient.davRoot(s.serverURL).absoluteString,
                                       username: s.username, password: password)
            return CalDAVClient(dav: dav, username: s.username)
        }
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(SyncSettings.self, from: data) {
            settings = saved
        }
        if let managed = config?.sync {
            settings = managed
            managedConfigPath = configPath
            passwordCommand = config?.passwordCommand
            shareWith = config?.shareWith ?? []
        }
        restartLoop()
    }

    /// Saves settings + password (nil keeps the stored one) and starts syncing if enabled.
    /// When the settings are managed by the config file, only the password is taken.
    public func configure(_ settings: SyncSettings, password: String?) {
        let settings = managedConfigPath == nil ? settings : self.settings
        passwordCommandAttempted = false
        if let password, let account = settings.credentialAccount { storePassword(password, for: account) }
        self.settings = settings
        if managedConfigPath == nil, let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
        restartLoop()
    }

    /// Current password from the Keychain (for the settings form).
    public func storedPassword() -> String? { settings.credentialAccount.flatMap(password(for:)) }

    /// Checks the server URL, credentials and access to the calendars. Returns nil on success or
    /// an error message.
    public func testConnection(_ settings: SyncSettings, password: String) async -> String? {
        guard !settings.username.trimmingCharacters(in: .whitespaces).isEmpty else { return "Enter a username" }
        guard !password.isEmpty else { return "Enter an app password" }
        do {
            _ = try await makeServer(settings, password).calendars()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Call after local edits; debounces and then syncs.
    public func scheduleSync() {
        guard settings.enabled else { return }
        debounceTask?.cancel()
        let delay = debounceInterval
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Immediate full sync (⌘R). If a sync is running, another one follows it.
    public func syncNow() async {
        guard settings.enabled else { status = .disabled; return }
        if isSyncing { syncRequestedWhileSyncing = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncRequestedWhileSyncing = false
            await performSync()
        } while syncRequestedWhileSyncing && settings.enabled
    }

    // MARK: - Private

    private func restartLoop() {
        periodicTask?.cancel()
        periodicTask = nil
        debounceTask?.cancel()
        guard settings.enabled else { status = .disabled; return }
        status = .idle(lastSync: lastSync)
        let interval = syncInterval
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func performSync() async {
        let settings = self.settings
        // Validate the URL first: no password lookup or password_command for an unusable server.
        do {
            _ = try CalDAVClient.davRoot(settings.serverURL)
        } catch {
            status = .error(Self.message(for: error))
            return
        }
        guard let account = settings.credentialAccount, let stateAccount = settings.stateAccount else {
            status = .error(Self.message(for: SyncError.missingPassword))
            return
        }
        var password = self.password(for: account) ?? ""
        if password.isEmpty, let command = passwordCommand, !passwordCommandAttempted {
            passwordCommandAttempted = true
            status = .syncing
            do {
                password = try await PasswordCommand.run(command)
                storePassword(password, for: account)
            } catch {
                status = .error(Self.message(for: error))
                return
            }
        }
        guard !password.isEmpty else {
            status = .error(Self.message(for: SyncError.missingPassword))
            return
        }
        status = .syncing
        let state = loadState(account: stateAccount)
        let snapshot = store.db
        do {
            let server = try makeServer(settings, password)
            let result = try await CalDAVSync.sync(local: snapshot, state: state, server: server, shareWith: shareWith,
                                                   previous: lastSynced)
            // Settings changed mid-sync: the result belongs to another server or user.
            guard self.settings == settings else { return }
            let latest = store.db
            if latest == snapshot {
                apply(result.merged)
            } else {
                // Local edits happened while the request was in flight: keep them on top of the
                // result and push them with another sync.
                apply(SyncEngine.rebase(latest: latest, snapshot: snapshot, merged: result.merged))
                scheduleSync()
            }
            saveState(result.state)
            // An idle sync is allowed next time only if everything was written.
            lastSynced = latest == snapshot && result.isComplete ? store.db : nil
            if !result.isIdle { warning = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n") }
            lastSync = Date()
            status = .idle(lastSync: lastSync)
        } catch is CancellationError {
            status = .idle(lastSync: lastSync)
        } catch {
            status = .error(Self.message(for: error))
        }
    }

    /// The sync state for `account`, from memory or `stateURL`; a fresh one for another account
    /// or an unreadable file (the next sync then compares everything, which is safe but slower).
    private func loadState(account: String) -> CalDAVState {
        if let state, state.account == account { return state }
        lastSynced = nil
        if let stateURL, let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(CalDAVState.self, from: data), saved.account == account {
            state = saved
            savedState = saved
            return saved
        }
        let fresh = CalDAVState(account: account)
        state = fresh
        return fresh
    }

    private func saveState(_ new: CalDAVState) {
        state = new
        guard let stateURL, new != savedState else { return }
        guard flushDatabase?() ?? true else {
            // The database could not be written: keep the file's older state (safe with an
            // older or newer database) and try again after the next sync.
            NSLog("TodoTim: not saving the sync state, because the database could not be saved")
            return
        }
        savedState = new
        stateQueue.async {
            do {
                try LocalPersistence.writePrivately(try JSONEncoder().encode(new), to: stateURL)
            } catch {
                NSLog("TodoTim: could not save the sync state: \(error.localizedDescription)")
            }
        }
    }

    private func password(for account: String) -> String? {
        if let s = sessionPassword, s.account == account { return s.password }
        return credentials.password(for: account)
    }

    private func storePassword(_ password: String, for account: String) {
        do {
            try credentials.savePassword(password, for: account)
            sessionPassword = nil
            credentialError = nil
        } catch {
            sessionPassword = (account, password)
            credentialError = "Could not save the password in the Keychain (\(Self.message(for: error))). It is kept in memory until TodoTim quits."
            NSLog("TodoTim: \(credentialError!)")
        }
    }

    private func apply(_ db: Database) {
        guard store.replaceDatabase(db) else { return }
        onDatabaseReplaced?()
    }

    nonisolated static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
