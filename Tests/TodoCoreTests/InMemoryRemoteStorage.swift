import Foundation
@testable import TodoCore

/// In-memory WebDAV-like storage with ETags and conditional writes, for sync tests.
actor InMemoryRemoteStorage: RemoteStorage {
    private(set) var files: [String: (data: Data, etag: String)] = [:]
    private(set) var collections: Set<String> = [""]
    private(set) var putPaths: [String] = []
    private(set) var deletePaths: [String] = []
    private(set) var getCount = 0
    private var counter = 0
    /// Writes applied (as by another device) right before the next PUT is evaluated.
    private var pendingExternalWrites: [(String, Data)] = []
    /// Runs before each GET (e.g. to simulate a local edit while sync is in flight).
    private var beforeGet: (@Sendable () async -> Void)?

    func setBeforeGet(_ hook: (@Sendable () async -> Void)?) { beforeGet = hook }
    func queueExternalWrite(_ path: String, _ data: Data) { pendingExternalWrites.append((path, data)) }
    func resetCounters() { putPaths = []; deletePaths = []; getCount = 0 }

    func data(_ path: String) -> Data? { files[path]?.data }

    private func nextETag() -> String { counter += 1; return "\"etag-\(counter)\"" }

    private func parent(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Writes without conditions, creating parents (test setup / other device).
    func write(_ path: String, _ data: Data) {
        files[path] = (data, nextETag())
    }

    func list(_ path: String) async throws -> [RemoteItem] {
        let p = joinPath(path)
        guard collections.contains(p) else { throw SyncError.notFound(p) }
        let fileItems = files.filter { parent($0.key) == p }
            .map { RemoteItem(path: $0.key, etag: $0.value.etag, isCollection: false) }
        let dirItems = collections.filter { !$0.isEmpty && parent($0) == p }
            .map { RemoteItem(path: $0, etag: nil, isCollection: true) }
        return (fileItems + dirItems).sorted { $0.path < $1.path }
    }

    func get(_ path: String) async throws -> (data: Data, etag: String?) {
        if let hook = beforeGet { beforeGet = nil; await hook() }
        getCount += 1
        guard let f = files[path] else { throw SyncError.notFound(path) }
        return (f.data, f.etag)
    }

    @discardableResult
    func put(_ path: String, data: Data, condition: PutCondition) async throws -> String? {
        for (p, d) in pendingExternalWrites { write(p, d) }
        pendingExternalWrites = []
        guard collections.contains(parent(path)) else { throw SyncError.conflict(path) }
        switch condition {
        case .none: break
        case .ifMatch(let etag): guard files[path]?.etag == etag else { throw SyncError.preconditionFailed(path) }
        case .ifNoneMatch: guard files[path] == nil else { throw SyncError.preconditionFailed(path) }
        }
        let etag = nextETag()
        files[path] = (data, etag)
        putPaths.append(path)
        return etag
    }

    func makeCollection(_ path: String) async throws {
        let p = joinPath(path)
        guard collections.contains(parent(p)) else { throw SyncError.conflict(p) }
        collections.insert(p)
    }

    func delete(_ path: String, ifMatch: String?) async throws {
        guard let f = files[path] else { return }
        if let ifMatch, f.etag != ifMatch { throw SyncError.preconditionFailed(path) }
        files[path] = nil
        deletePaths.append(path)
    }
}
