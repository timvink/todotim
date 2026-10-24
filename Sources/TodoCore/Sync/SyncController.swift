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

    /// Loads settings from `defaults` and starts syncing if enabled (the first sync starts after
    /// the current main-actor turn, so callbacks set right after `init` are in place).
    public init(store: TodoStore, defaults: UserDefaults = .standard,
                credentials: CredentialStore = KeychainCredentialStore(),
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
        restartLoop()
    }

    /// Saves settings + password (nil keeps the stored one) and starts syncing if enabled.
    public func configure(_ settings: SyncSettings, password: String?) {
        let old = self.settings
        if let password { credentials.setPassword(password, for: settings.username) }
        self.settings = settings
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        if old.serverURL != settings.serverURL || old.username != settings.username || old.folder != settings.folder {
            let cache = self.cache
            Task { await cache.clear() }
        }
        restartLoop()
    }

    /// Current password from the Keychain (for the settings form).
    public func storedPassword() -> String? { credentials.password(for: settings.username) }

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
        guard let password = credentials.password(for: settings.username), !password.isEmpty else {
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

    private func apply(_ db: Database) {
        guard db != store.db else { return }
        store.replaceDatabase(db)
        onDatabaseReplaced?()
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
