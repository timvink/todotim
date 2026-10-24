import Foundation

/// One entry of a remote folder listing.
public struct RemoteItem: Equatable, Sendable {
    /// Path relative to the storage root, without leading or trailing slash, not percent-encoded.
    public var path: String
    public var etag: String?
    public var isCollection: Bool
    /// File size in bytes (`getcontentlength`), if the server reported it.
    public var size: Int?
    /// Last modification time (`getlastmodified`, server clock, whole seconds), if reported.
    public var modified: Date?

    public init(path: String, etag: String?, isCollection: Bool, size: Int? = nil, modified: Date? = nil) {
        self.path = path; self.etag = etag; self.isCollection = isCollection
        self.size = size; self.modified = modified
    }

    /// Last path component.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// A folder listing and the server clock when it was made.
public struct RemoteListing: Equatable, Sendable {
    public var items: [RemoteItem]
    /// The response's `Date` header (server clock, whole seconds), if any. Compared with
    /// `RemoteItem.modified` to tell whether a file was written within the last seconds.
    public var serverDate: Date?

    public init(items: [RemoteItem], serverDate: Date? = nil) {
        self.items = items; self.serverDate = serverDate
    }
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
    func listing(_ path: String) async throws -> RemoteListing
    /// Returns the file content with its ETag, `modified` (Last-Modified) and `serverDate`
    /// (Date header) when the server sends them. Throws `SyncError.notFound` if missing.
    func get(_ path: String) async throws -> RemoteFile
    /// Writes a file. Throws `SyncError.preconditionFailed` if `condition` does not hold.
    /// Returns the new ETag if the server reported one.
    @discardableResult
    func put(_ path: String, data: Data, condition: PutCondition) async throws -> String?
    /// Creates a collection. Succeeds if it already exists.
    func makeCollection(_ path: String) async throws
    /// Deletes a file. `ifMatch` makes the delete conditional. Succeeds if already gone.
    func delete(_ path: String, ifMatch: String?) async throws
}

extension RemoteStorage {
    /// The items of `listing(path)`.
    public func list(_ path: String) async throws -> [RemoteItem] { try await listing(path).items }
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
    /// The server URL uses plain http:// for a host other than localhost.
    case insecureURL(String)
    /// A remote path with empty, "." or ".." segments, or one that would leave the server URL.
    case invalidPath(String)
    /// The server redirected outside the configured server URL (other scheme, host, port or path).
    case redirectRejected(String)
    /// Remote data exceeds a `SyncLimits` bound.
    case limitExceeded(String)

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
        case .insecureURL(let s):
            return "“\(s)” uses http://. TodoTim only sends your password over https:// (http:// is allowed for localhost only). Use the https:// address of your server."
        case .invalidPath(let p):
            return "Refused to use the unsafe remote path “\(p)”"
        case .redirectRejected(let target):
            return "The server redirected to “\(target)”, outside the configured server URL. Check the server URL in Settings (use the final https:// address)."
        case .limitExceeded(let what):
            return "The data on the server is too large to sync safely: \(what)"
        }
    }
}

/// Joins relative path components, ignoring empty parts and stray slashes.
func joinPath(_ parts: String...) -> String {
    parts.flatMap { $0.split(separator: "/") }.map(String.init).joined(separator: "/")
}
