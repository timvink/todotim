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

/// STUB — replaced by the sync agent. Owns settings, the Keychain password, and the
/// sync loop between `TodoStore` and the WebDAV server.
@MainActor
@Observable
public final class SyncController {
    public private(set) var status: SyncStatus = .disabled
    public private(set) var settings: SyncSettings = SyncSettings()

    public init(store: TodoStore) {}

    /// Saves settings + password and starts syncing if enabled.
    public func configure(_ settings: SyncSettings, password: String?) { self.settings = settings }

    /// Current password from the Keychain (for the settings form).
    public func storedPassword() -> String? { nil }

    /// Checks credentials and folder access; returns nil on success or an error message.
    public func testConnection(_ settings: SyncSettings, password: String) async -> String? { "Not implemented" }

    /// Call after local edits; debounces and then syncs.
    public func scheduleSync() {}

    /// Immediate full sync (⌘R).
    public func syncNow() async {}
}
