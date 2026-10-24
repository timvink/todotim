import Foundation
@testable import TodoCore

/// A settable clock for the fake server; `advance` doubles as the sync engine's sleep in tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    /// Starts 0.2 s into a whole second.
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000.2)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// In-memory WebDAV-like storage with ETags and conditional writes, for sync tests.
///
/// With `nextcloudSameSecondETags`, it behaves like the Nextcloud server we sync with: file
/// times have whole-second precision, a file rewritten within the same second as its previous
/// write keeps its ETag (also for an `If-Match` PUT), and listings and GETs report sizes,
/// modification times and the server clock (`clock`).
actor InMemoryRemoteStorage: RemoteStorage {
    struct StoredFile {
        var data: Data
        var etag: String
        var modified: Date
    }

    let nextcloudSameSecondETags: Bool
    private let clock: @Sendable () -> Date
    private(set) var files: [String: StoredFile] = [:]
    private(set) var collections: Set<String> = [""]
    private(set) var putPaths: [String] = []
    private(set) var deletePaths: [String] = []
    private(set) var getCount = 0
    private var counter = 0
    /// Writes applied (as by another device) right before the next PUT is evaluated.
    private var pendingExternalWrites: [(String, Data)] = []
    /// Runs before each GET (e.g. to simulate a local edit while sync is in flight).
    private var beforeGet: (@Sendable () async -> Void)?
    /// Runs once after the next GET of a given path (e.g. another device writing right after it).
    private var afterGet: [String: @Sendable () async -> Void] = [:]

    init(nextcloudSameSecondETags: Bool = false, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.nextcloudSameSecondETags = nextcloudSameSecondETags
        self.clock = clock
    }

    func setBeforeGet(_ hook: (@Sendable () async -> Void)?) { beforeGet = hook }
    func setAfterGet(_ path: String, _ hook: @escaping @Sendable () async -> Void) { afterGet[path] = hook }
    func queueExternalWrite(_ path: String, _ data: Data) { pendingExternalWrites.append((path, data)) }
    func resetCounters() { putPaths = []; deletePaths = []; getCount = 0 }

    func data(_ path: String) -> Data? { files[path]?.data }

    /// Server clock truncated to whole seconds, like HTTP dates.
    private var serverNow: Date { Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down)) }

    private func nextETag() -> String { counter += 1; return "\"etag-\(counter)\"" }

    private func parent(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Writes without conditions (test setup / other device). Returns the new ETag.
    @discardableResult
    func write(_ path: String, _ data: Data) -> String {
        let now = serverNow
        let etag: String
        if nextcloudSameSecondETags, let old = files[path], old.modified == now {
            etag = old.etag  // Nextcloud: same second, same ETag
        } else {
            etag = nextETag()
        }
        files[path] = StoredFile(data: data, etag: etag, modified: now)
        return etag
    }

    /// Replaces the content but keeps the ETag, as a server whose ETags miss a change would
    /// (cache tests). `modified` defaults to the current one.
    func overwriteKeepingETag(_ path: String, _ data: Data, modified: Date? = nil) {
        guard let old = files[path] else { return }
        files[path] = StoredFile(data: data, etag: old.etag, modified: modified ?? old.modified)
    }

    func listing(_ path: String) async throws -> RemoteListing {
        let p = joinPath(path)
        guard collections.contains(p) else { throw SyncError.notFound(p) }
        let dates = nextcloudSameSecondETags
        let fileItems = files.filter { parent($0.key) == p }
            .map { RemoteItem(path: $0.key, etag: $0.value.etag, isCollection: false,
                              size: $0.value.data.count, modified: dates ? $0.value.modified : nil) }
        let dirItems = collections.filter { !$0.isEmpty && parent($0) == p }
            .map { RemoteItem(path: $0, etag: nil, isCollection: true) }
        return RemoteListing(items: (fileItems + dirItems).sorted { $0.path < $1.path },
                             serverDate: dates ? serverNow : nil)
    }

    func get(_ path: String) async throws -> RemoteFile {
        if let hook = beforeGet { beforeGet = nil; await hook() }
        getCount += 1
        guard let f = files[path] else { throw SyncError.notFound(path) }
        let dates = nextcloudSameSecondETags
        let file = RemoteFile(data: f.data, etag: f.etag, modified: dates ? f.modified : nil,
                              serverDate: dates ? serverNow : nil)
        if let hook = afterGet.removeValue(forKey: path) { await hook() }
        return file
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
        let etag = write(path, data)
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
