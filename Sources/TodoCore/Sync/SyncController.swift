import Foundation
import Observation

/// Connection settings for a Nextcloud (or any) WebDAV server. Password lives in the Keychain.
public struct SyncSettings: Codable, Equatable, Sendable {
    /// e.g. "https://cloud.example.com/remote.php/dav/files/tim/"
    public var serverURL: String
    public var username: String
    /// Folder inside the WebDAV root that holds the data, e.g. "TodoTim".
    public var folder: String
    public var enabled: Bool

    public init(serverURL: String = "", username: String = "", folder: String = "TodoTim", enabled: Bool = false) {
        self.serverURL = serverURL; self.username = username; self.folder = folder; self.enabled = enabled
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
}

public enum SyncStatus: Equatable, Sendable {
    case disabled
    case idle(lastSync: Date?)
    case syncing
    case error(String)
}

/// Owns settings, the Keychain password, and the sync loop between `TodoStore` and the
/// WebDAV server. Syncs every `syncInterval` while enabled, and `debounceInterval` after
/// `scheduleSync()`.
@MainActor
@Observable
public final class SyncController {
    public private(set) var status: SyncStatus = .disabled
    public private(set) var settings: SyncSettings = SyncSettings()
    public private(set) var lastSync: Date?
    /// Path of the config file (`~/.todotim.toml`) that sets the sync settings, or nil when they
    /// come from the Settings window. Managed settings cannot be changed in the app.
    public private(set) var managedConfigPath: String?
    /// Set when the password could not be saved in the Keychain (it is then kept in memory
    /// until the app quits); nil after a successful save.
    public private(set) var credentialError: String?

    /// Called after sync replaced the store's database with merged remote changes.
    /// The app uses it to persist the database.
    @ObservationIgnored public var onDatabaseReplaced: (() -> Void)?

    @ObservationIgnored public var debounceInterval: Duration = .seconds(2)
    @ObservationIgnored public var syncInterval: Duration = .seconds(60)

    public static let settingsKey = "syncSettings"

    public typealias StorageFactory = (SyncSettings, String) throws -> RemoteStorage

    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let makeStorage: StorageFactory
    @ObservationIgnored private let cache = RemoteFileCache()
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncRequestedWhileSyncing = false
    @ObservationIgnored private var passwordCommand: String?
    /// The password command runs at most once per launch (or per `configure`), so a locked
    /// vault does not prompt again every sync interval.
    @ObservationIgnored private var passwordCommandAttempted = false
    /// Password whose Keychain save failed, for the account it belongs to.
    @ObservationIgnored private var sessionPassword: (account: String, password: String)?

    /// Loads settings from `config` (when it has a `[sync]` table) or else from `defaults`, and
    /// starts syncing if enabled (the first sync starts after the current main-actor turn, so
    /// callbacks set right after `init` are in place).
    public init(store: TodoStore, defaults: UserDefaults = .standard,
                credentials: CredentialStore = KeychainCredentialStore(),
                config: AppConfig? = nil, configPath: String = AppConfig.defaultURL.path,
                makeStorage: StorageFactory? = nil) {
        self.store = store
        self.defaults = defaults
        self.credentials = credentials
        self.makeStorage = makeStorage ?? { s, password in
            try WebDAVClient(serverURL: s.serverURL, username: s.username, password: password)
        }
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(SyncSettings.self, from: data) {
            settings = saved
        }
        if let managed = config?.sync {
            settings = managed
            managedConfigPath = configPath
            passwordCommand = config?.passwordCommand
        }
        restartLoop()
    }

    /// Saves settings + password (nil keeps the stored one) and starts syncing if enabled.
    /// When the settings are managed by the config file, only the password is taken.
    public func configure(_ settings: SyncSettings, password: String?) {
        let settings = managedConfigPath == nil ? settings : self.settings
        passwordCommandAttempted = false
        let old = self.settings
        if let password, let account = settings.credentialAccount { storePassword(password, for: account) }
        self.settings = settings
        if managedConfigPath == nil, let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
        if old.serverURL != settings.serverURL || old.username != settings.username || old.folder != settings.folder {
            let cache = self.cache
            Task { await cache.clear() }
        }
        restartLoop()
    }

    /// Current password from the Keychain (for the settings form).
    public func storedPassword() -> String? { settings.credentialAccount.flatMap(password(for:)) }

    /// Checks credentials and folder access, creating the folder and `projects/` if needed.
    /// Returns nil on success or an error message.
    public func testConnection(_ settings: SyncSettings, password: String) async -> String? {
        guard !settings.username.trimmingCharacters(in: .whitespaces).isEmpty else { return "Enter a username" }
        guard !password.isEmpty else { return "Enter an app password" }
        do {
            let storage = try makeStorage(settings, password)
            _ = try await storage.list("")
            try await SyncEngine.ensureFolders(storage: storage, folder: settings.folder)
            _ = try await storage.list(joinPath(settings.folder, SyncEngine.projectsDir))
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
            _ = try WebDAVClient.normalizedBaseURL(settings.serverURL)
        } catch {
            status = .error(Self.message(for: error))
            return
        }
        guard let account = settings.credentialAccount else {
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
        let snapshot = store.db
        do {
            let storage = try makeStorage(settings, password)
            let result = try await SyncEngine.sync(local: snapshot, storage: storage, folder: settings.folder, cache: cache)
            // Settings changed mid-sync: the result belongs to another server/folder.
            guard self.settings == settings else { return }
            let latest = store.db
            if latest == snapshot {
                apply(result.merged)
            } else {
                // Local edits happened while the request was in flight: merge them in again
                // (LWW) instead of overwriting, and push them with another sync.
                apply(SyncEngine.merge([latest, result.merged]))
                scheduleSync()
            }
            lastSync = Date()
            status = .idle(lastSync: lastSync)
        } catch is CancellationError {
            status = .idle(lastSync: lastSync)
        } catch {
            status = .error(Self.message(for: error))
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

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
