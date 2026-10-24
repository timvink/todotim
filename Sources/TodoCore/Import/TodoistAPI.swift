import Foundation

public enum TodoistAPIError: LocalizedError, Equatable, Sendable {
    case missingToken
    case insecureURL
    case unauthorized
    case rateLimited(retryAfter: Int?)
    case http(status: Int)
    case redirectRejected
    case limitExceeded(String)
    case invalidResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: "Enter your Todoist API token."
        case .insecureURL: "The Todoist API must be reached over HTTPS."
        case .unauthorized: "Todoist rejected the API token. Copy it again from Settings › Integrations › Developer."
        case .rateLimited(let s): "Todoist is rate limiting requests. Try again\(s.map { " in \($0) seconds" } ?? " later")."
        case .http(let status): "Todoist returned HTTP \(status)."
        case .redirectRejected: "Todoist redirected the request; it was not followed."
        case .limitExceeded(let what): "Import refused: \(what)."
        case .invalidResponse(let why): "Unexpected response from Todoist: \(why)"
        case .network(let why): "Could not reach Todoist: \(why)"
        }
    }
}

/// Read-only client for the Todoist API v1 (https://developer.todoist.com/api/v1/).
///
/// Fetches the active projects, sections, tasks and labels with a personal API token
/// (Bearer auth). List endpoints are paginated: each response is `{ "results": [...],
/// "next_cursor": "..." | null }`, and the cursor is passed back as `cursor=`.
///
/// Safety: HTTPS only, redirects are never followed (the token must not leave api.todoist.com),
/// each response body is capped at `SyncLimits.maxResponseBytes` and the total number of
/// entities at `SyncLimits.maxEntities`. The token is held in memory only.
public struct TodoistAPI: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.todoist.com/api/v1/")!
    /// Largest page the API allows.
    static let pageSize = 200
    /// Guards against a server that keeps returning cursors.
    static let maxPages = 10_000

    public let baseURL: URL
    private let token: String
    private let session: URLSession
    var maxResponseBytes = SyncLimits.maxResponseBytes
    var maxEntities = SyncLimits.maxEntities

    public init(token: String, baseURL: URL = TodoistAPI.defaultBaseURL, session: URLSession? = nil) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TodoistAPIError.missingToken }
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else { throw TodoistAPIError.insecureURL }
        self.token = token
        self.baseURL = baseURL.absoluteString.hasSuffix("/") ? baseURL : URL(string: baseURL.absoluteString + "/") ?? baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    /// Progress: the step that is being fetched ("projects", "sections", "tasks", "labels") and
    /// the number of items fetched so far in that step.
    public typealias Progress = @Sendable (_ step: String, _ count: Int) -> Void

    /// Fetches everything needed for an import. Only active (not completed, not archived) items.
    public func fetchSnapshot(progress: Progress? = nil) async throws -> TodoistSnapshot {
        var total = 0
        let projects: [TodoistProject] = try await fetchAll("projects", total: &total, progress: progress)
        let sections: [TodoistSection] = try await fetchAll("sections", total: &total, progress: progress)
        let tasks: [TodoistTask] = try await fetchAll("tasks", total: &total, progress: progress)
        let labels: [TodoistLabel] = try await fetchAll("labels", total: &total, progress: progress)
        return TodoistSnapshot(projects: projects, sections: sections, tasks: tasks, labels: labels)
    }

    /// All pages of a list endpoint.
    func fetchAll<T: Decodable>(_ path: String, total: inout Int, progress: Progress?) async throws -> [T] {
        var items: [T] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<Self.maxPages {
            let page: Page<T> = try await fetchPage(path, cursor: cursor)
            items.append(contentsOf: page.results.items)
            total += page.results.items.count
            guard total <= maxEntities else { throw TodoistAPIError.limitExceeded("more than \(maxEntities) items") }
            progress?(path, items.count)
            guard let next = page.nextCursor, !next.isEmpty else { return items }
            guard seenCursors.insert(next).inserted else { throw TodoistAPIError.invalidResponse("repeated page cursor") }
            cursor = next
        }
        throw TodoistAPIError.limitExceeded("more than \(Self.maxPages) pages of \(path)")
    }

    struct Page<T: Decodable>: Decodable {
        var results: LossyList<T>
        var nextCursor: String?
        enum CodingKeys: String, CodingKey { case results, nextCursor = "next_cursor" }
    }

    func request(_ path: String, cursor: String?) throws -> URLRequest {
        guard var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw TodoistAPIError.insecureURL
        }
        var query = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        c.queryItems = query
        guard let url = c.url, url.scheme == "https" else { throw TodoistAPIError.insecureURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    func fetchPage<T: Decodable>(_ path: String, cursor: String?) async throws -> Page<T> {
        let (data, http) = try await send(request(path, cursor: cursor))
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw TodoistAPIError.unauthorized
        case 429: throw TodoistAPIError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        case 300..<400: throw TodoistAPIError.redirectRejected
        default: throw TodoistAPIError.http(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Page<T>.self, from: data)
        } catch {
            throw TodoistAPIError.invalidResponse("\(path): \(error.localizedDescription)")
        }
    }

    /// Sends `req`, reading at most `maxResponseBytes` of the body. Redirects are not followed.
    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let limit = maxResponseBytes
        let tooLarge = TodoistAPIError.limitExceeded("a Todoist response is larger than \(max(1, limit / 1024 / 1024)) MB")
        do {
            let (bytes, response) = try await session.bytes(for: req, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { throw TodoistAPIError.invalidResponse("not HTTP") }
            if http.expectedContentLength > Int64(limit) {
                bytes.task.cancel()
                throw tooLarge
            }
            var data = Data()
            var chunk: [UInt8] = []
            chunk.reserveCapacity(64 << 10)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 64 << 10 {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    if data.count > limit {
                        bytes.task.cancel()
                        throw tooLarge
                    }
                }
            }
            data.append(contentsOf: chunk)
            if data.count > limit { throw tooLarge }
            return (data, http)
        } catch let e as TodoistAPIError {
            throw e
        } catch let e as URLError {
            throw TodoistAPIError.network(e.localizedDescription)
        } catch {
            throw TodoistAPIError.network(error.localizedDescription)
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
