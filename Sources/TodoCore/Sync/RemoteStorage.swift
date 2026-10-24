import Foundation

/// One entry of a remote folder listing.
public struct RemoteItem: Equatable, Sendable {
    /// Path relative to the storage root, without leading or trailing slash, not percent-encoded.
    public var path: String
    public var etag: String?
    public var isCollection: Bool

    public init(path: String, etag: String?, isCollection: Bool) {
        self.path = path; self.etag = etag; self.isCollection = isCollection
    }

    /// Last path component.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// Precondition for a PUT.
public enum PutCondition: Equatable, Sendable {
    /// Unconditional write.
    case none
    /// Only overwrite if the remote file still has this ETag.
    case ifMatch(String)
    /// Only create; fail if the file already exists (`If-None-Match: *`).
    case ifNoneMatch
}

/// Minimal file storage used by sync. `WebDAVClient` implements it against a server;
/// tests use an in-memory fake. All paths are relative to the storage root and are
/// plain (not percent-encoded) strings like "TodoTim/projects/abc.json".
public protocol RemoteStorage: Sendable {
    /// Direct children of the collection at `path` (Depth 1), excluding the collection itself.
    /// Throws `SyncError.notFound` if the collection does not exist.
    func list(_ path: String) async throws -> [RemoteItem]
    /// Returns the file content and its ETag. Throws `SyncError.notFound` if missing.
    func get(_ path: String) async throws -> (data: Data, etag: String?)
    /// Writes a file. Throws `SyncError.preconditionFailed` if `condition` does not hold.
    /// Returns the new ETag if the server reported one.
    @discardableResult
    func put(_ path: String, data: Data, condition: PutCondition) async throws -> String?
    /// Creates a collection. Succeeds if it already exists.
    func makeCollection(_ path: String) async throws
    /// Deletes a file. `ifMatch` makes the delete conditional. Succeeds if already gone.
    func delete(_ path: String, ifMatch: String?) async throws
}

public enum SyncError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case unauthorized
    case forbidden(String)
    case baseNotFound
    case notFound(String)
    case notWebDAV
    case preconditionFailed(String)
    case conflict(String)
    case insufficientStorage
    case http(status: Int, path: String)
    case network(String)
    case badRemoteData(path: String, reason: String)
    case newerSchema(String)
    case missingPassword
    case tooManyConflicts

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s):
            return "Invalid server URL “\(s)”. It should look like https://cloud.example.com/remote.php/dav/files/USER/"
        case .unauthorized:
            return "Wrong username or app password"
        case .forbidden(let p):
            return "Access denied to “\(p.isEmpty ? "/" : p)”"
        case .baseNotFound:
            return "Server URL not found. It should look like https://cloud.example.com/remote.php/dav/files/USER/"
        case .notFound(let p):
            return "Not found on server: “\(p)”"
        case .notWebDAV:
            return "This URL is not a WebDAV folder. For Nextcloud use https://cloud.example.com/remote.php/dav/files/USER/"
        case .preconditionFailed(let p):
            return "“\(p)” was changed by another device during sync"
        case .conflict(let p):
            return "Could not create “\(p)”: its parent folder does not exist"
        case .insufficientStorage:
            return "The server is out of storage space"
        case .http(let status, let p):
            return "Server returned HTTP \(status) for “\(p.isEmpty ? "/" : p)”"
        case .network(let msg):
            return msg
        case .badRemoteData(let p, let reason):
            return "Could not read “\(p)” from the server: \(reason)"
        case .newerSchema(let p):
            return "“\(p)” was written by a newer version of TodoTim. Please update the app."
        case .missingPassword:
            return "No app password saved. Enter it in Settings."
        case .tooManyConflicts:
            return "Sync kept conflicting with changes from another device. It will retry."
        }
    }
}

/// Joins relative path components, ignoring empty parts and stray slashes.
func joinPath(_ parts: String...) -> String {
    parts.flatMap { $0.split(separator: "/") }.map(String.init).joined(separator: "/")
}
