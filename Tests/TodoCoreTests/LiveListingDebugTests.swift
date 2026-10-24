import XCTest
@testable import TodoCore

/// Live checks of the WebDAV client and the sync cache against a real server. Runs only when
/// TODOTIM_LIVE_URL, TODOTIM_LIVE_USER and TODOTIM_LIVE_PASSWORD are set; uses (and then deletes)
/// the throwaway folder "TodoTim-etagtest2". Set TODOTIM_LIVE_VERBOSE=1 to print every request.
final class LiveListingDebugTests: XCTestCase {
    /// Two syncs sharing one cache, like the app: later syncs must reuse the ETags returned by
    /// PUT (also behind a compressing proxy that rewrites ETags) and upload without 412s.
    func testRepeatedSyncWithCacheOnRealServer() async throws {
        let client = try LiveServer.client()
        let storage = LoggingStorage(inner: client)
        let folder = "TodoTim-etagtest2"
        try? await client.delete(folder, ifMatch: nil)
        let cache = RemoteFileCache()
        let store = await TodoStore()
        // Big enough that the proxy compresses responses.
        for i in 0..<300 {
            await store.addTask(content: "Task \(i) with some padding text to make the file large", projectId: TodoStore.inboxID)
        }
        var db = await store.db
        do {
            for round in 0..<4 {
                let r = try await SyncEngine.sync(local: db, storage: storage, folder: folder, cache: cache, maxAttempts: 1)
                XCTAssertFalse(r.uploaded.isEmpty, "round \(round) uploads its new task")
                db = r.merged
                await store.replaceDatabase(db)
                await store.addTask(content: "Added in round \(round)", projectId: TodoStore.inboxID)
                db = await store.db
            }
        } catch {
            try? await client.delete(folder, ifMatch: nil)
            throw error
        }
        try await client.delete(folder, ifMatch: nil)
    }
}

enum LiveServer {
    /// A client for the live server, or `XCTSkip` when the environment is not set.
    static func client() throws -> WebDAVClient {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["TODOTIM_LIVE_URL"], let user = env["TODOTIM_LIVE_USER"],
              let password = env["TODOTIM_LIVE_PASSWORD"] else {
            throw XCTSkip("Set TODOTIM_LIVE_URL/USER/PASSWORD to run")
        }
        return try WebDAVClient(serverURL: url, username: user, password: password)
    }

    static var verbose: Bool { ProcessInfo.processInfo.environment["TODOTIM_LIVE_VERBOSE"] == "1" }
}

/// Forwards to `inner`; prints each request when TODOTIM_LIVE_VERBOSE=1 and runs `afterGet`
/// once after the first GET of `afterGetPath`.
final class LoggingStorage: RemoteStorage, @unchecked Sendable {
    let inner: RemoteStorage
    private let lock = NSLock()
    private var afterGetPath: String?
    private var afterGet: (@Sendable () async throws -> Void)?

    init(inner: RemoteStorage) { self.inner = inner }

    func setAfterGet(_ path: String, _ hook: @escaping @Sendable () async throws -> Void) {
        lock.withLock { afterGetPath = path; afterGet = hook }
    }

    private func log(_ message: @autoclosure () -> String) {
        if LiveServer.verbose { print("REQ \(message())") }
    }

    func listing(_ path: String) async throws -> RemoteListing {
        do {
            let r = try await inner.listing(path)
            log("LIST \(path) -> \(r.items.count) items, date \(r.serverDate.map { "\($0)" } ?? "nil")")
            return r
        } catch { log("LIST \(path) ERR \(error)"); throw error }
    }

    func get(_ path: String) async throws -> RemoteFile {
        let r: RemoteFile
        do {
            r = try await inner.get(path)
            log("GET \(path) -> \(r.data.count)B etag \(r.etag ?? "nil") modified \(r.modified.map { "\($0)" } ?? "nil")")
        } catch { log("GET \(path) ERR \(error)"); throw error }
        let hook: (@Sendable () async throws -> Void)? = lock.withLock {
            guard afterGetPath == path else { return nil }
            defer { afterGetPath = nil; afterGet = nil }
            return afterGet
        }
        try await hook?()
        return r
    }

    func put(_ path: String, data: Data, condition: PutCondition) async throws -> String? {
        do {
            let r = try await inner.put(path, data: data, condition: condition)
            log("PUT \(path) \(condition) -> \(r ?? "nil")")
            return r
        } catch { log("PUT \(path) \(condition) ERR \(error)"); throw error }
    }

    func makeCollection(_ path: String) async throws { try await inner.makeCollection(path) }

    func delete(_ path: String, ifMatch: String?) async throws {
        do {
            try await inner.delete(path, ifMatch: ifMatch)
            log("DELETE \(path) \(ifMatch ?? "")")
        } catch { log("DELETE \(path) ERR \(error)"); throw error }
    }
}
