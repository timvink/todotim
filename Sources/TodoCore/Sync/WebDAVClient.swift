import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A WebDAV response with the body read (bounded) and the ETag normalized.
public struct DAVResponse: Sendable {
    public var status: Int
    public var data: Data
    public var etag: String?
    /// The `Location` header (of a redirect that was not followed).
    public var location: String?
}

/// HTTP client for a WebDAV server. `baseURL` is the allowed root, e.g. the DAV root
/// https://host/remote.php/dav/ ; paths passed to the methods are relative to it and are
/// percent-encoded per segment here. Uses Basic auth (an app password where the server has them).
/// The security rules live here: https only (except localhost), no requests, redirects or hrefs
/// outside `baseURL`, capped bodies.
public final class WebDAVClient: @unchecked Sendable {
    public let baseURL: URL
    private let authorization: String
    private let session: URLSession
    /// Largest accepted response body (tests lower it).
    var maxResponseBytes = SyncLimits.maxResponseBytes
    /// Whether redirects inside `baseURL` are followed. When false, every redirect response is
    /// returned to the caller (with `location`), which checks the target itself (discovery).
    var followsRedirects = true
    /// A request answered 423 (Locked) was not performed: it is sent again up to this many times,
    /// after `lockedRetryDelay`, doubled each time, with jitter. Xandikos locks its store while it
    /// writes and refuses concurrent writes that way.
    static let lockedRetries = 4
    var lockedRetryDelay: Duration = .milliseconds(50)

    /// Throws `SyncError.invalidURL` if `serverURL` is not an http(s) URL, and
    /// `SyncError.insecureURL` for http:// to anything but localhost.
    public init(serverURL: String, username: String, password: String, session: URLSession? = nil) throws {
        self.baseURL = try Self.normalizedBaseURL(serverURL)
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        self.authorization = "Basic \(token)"
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    /// Trims whitespace, validates scheme/host and ensures a trailing slash. Plain http:// is
    /// accepted only for localhost (127.0.0.1, ::1), so the password never travels unencrypted.
    /// URLs with credentials, a query or a fragment are rejected.
    public static func normalizedBaseURL(_ string: String) throws -> URL {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw SyncError.invalidURL(string) }
        if !s.hasSuffix("/") { s += "/" }
        let url = URL(string: s)
            ?? s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw SyncError.invalidURL(string) }
        if scheme == "http" && !isLoopback(host) { throw SyncError.insecureURL(string) }
        return url
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    /// Port used for `url`, including the scheme's default.
    static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
    }

    /// Whether `a` and `b` have the same origin: scheme, host and port.
    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && effectivePort(a) == effectivePort(b)
    }

    /// The root of `url`'s origin: "scheme://host[:port]/".
    static func originRoot(of url: URL) -> URL? {
        URL(string: "/", relativeTo: url)?.absoluteURL
    }

    /// Whether `url` has the scheme, host and port of `base` and a path inside base's path.
    static func isWithin(_ url: URL, base: URL) -> Bool {
        guard isSameOrigin(url, base) else { return false }
        // Decoded paths: servers may percent-encode differently from the configured URL
        // (e.g. "@" in Nextcloud user names). Dot segments that survive standardization
        // (encoded as %2E) are refused.
        var basePath = base.standardized.path(percentEncoded: false)
        if !basePath.hasSuffix("/") { basePath += "/" }
        var path = url.standardized.path(percentEncoded: false)
        if path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) { return false }
        if !path.hasSuffix("/") { path += "/" }
        return path.hasPrefix(basePath)
    }

    /// Characters allowed unescaped in a single path segment (RFC 3986 pchar without "/" and ";").
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        set.insert(charactersIn: "-._~!$&'()*+,=@")
        return set
    }()

    /// URL for a relative path; `collection` adds a trailing slash. Leading and trailing slashes
    /// are ignored; empty, "." and ".." segments throw `SyncError.invalidPath`, and so does any
    /// result outside `baseURL`.
    func url(for path: String, collection: Bool = false) throws -> URL {
        var trimmed = Substring(path)
        while trimmed.hasPrefix("/") { trimmed = trimmed.dropFirst() }
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        var rel = ""
        if !trimmed.isEmpty {
            var encoded: [String] = []
            for segment in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
                guard !segment.isEmpty, segment != ".", segment != "..",
                      let e = String(segment).addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed)
                else { throw SyncError.invalidPath(path) }
                encoded.append(e)
            }
            rel = encoded.joined(separator: "/")
            if collection { rel += "/" }
        }
        // baseURL ends with "/" and every segment is percent-encoded, so this parses.
        guard let url = URL(string: baseURL.absoluteString + rel), Self.isWithin(url, base: baseURL) else {
            throw SyncError.invalidPath(path)
        }
        return url
    }

    // MARK: - Requests

    /// Sends a request to `path` (relative to `baseURL`). `collection` adds a trailing slash.
    /// Any status is returned; callers map errors with `error(status:path:)`.
    public func send(_ method: String, _ path: String, collection: Bool = false, headers: [String: String] = [:],
                     body: Data? = nil) async throws -> DAVResponse {
        try await send(method, url: try url(for: path, collection: collection), headers: headers, body: body)
    }

    /// Sends a request to the absolute `url` (no query or fragment), which must be inside
    /// `baseURL` and have no dot segments; otherwise throws `SyncError.invalidPath` without
    /// sending anything.
    func send(_ method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> DAVResponse {
        guard Self.isWithin(url, base: baseURL), url.query == nil, url.fragment == nil, Self.decodedSegments(url) != nil else {
            throw SyncError.invalidPath(Self.displayString(url))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        var (data, response) = try await send(req)
        var delay = lockedRetryDelay
        for _ in 0..<Self.lockedRetries where response.statusCode == 423 {
            try await Task.sleep(for: delay * Double.random(in: 0.5...1.5))
            delay *= 2
            (data, response) = try await send(req)
        }
        return DAVResponse(status: response.statusCode, data: data,
                           etag: Self.normalizeETag(response.value(forHTTPHeaderField: "ETag")
                                                    ?? response.value(forHTTPHeaderField: "OC-ETag")),
                           location: response.value(forHTTPHeaderField: "Location"))
    }

    /// The path of `href` (absolute or relative, percent-encoded, from a multistatus response)
    /// relative to `baseURL`, decoded, without leading or trailing slash. nil when it is outside
    /// the base URL, on another server, or has a segment that decodes to "/", "." or "..".
    /// Segments are compared decoded: servers may percent-encode differently from the base URL.
    public func relativePath(ofHref href: String) -> String? {
        guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL, Self.isWithin(url, base: baseURL),
              let base = Self.decodedSegments(baseURL), let segments = Self.decodedSegments(url), segments.starts(with: base)
        else { return nil }
        return segments.dropFirst(base.count).joined(separator: "/")
    }

    /// `url` with its path segments encoded the way requests encode them, so that two spellings
    /// of the same location compare equal; `collection` adds a trailing slash. nil for a URL with
    /// dot segments.
    static func canonicalURL(_ url: URL, collection: Bool) -> URL? {
        guard let origin = originRoot(of: url), let segments = decodedSegments(url) else { return nil }
        var encoded: [String] = []
        for segment in segments {
            guard let e = segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) else { return nil }
            encoded.append(e)
        }
        var path = encoded.joined(separator: "/")
        if collection && !path.isEmpty { path += "/" }
        return URL(string: origin.absoluteString + path)
    }

    /// The decoded, non-empty segments of `url`'s path; nil when one decodes to "/", "." or "..".
    static func decodedSegments(_ url: URL) -> [String]? {
        var segments: [String] = []
        for raw in url.path(percentEncoded: true).split(separator: "/") {
            guard let s = String(raw).removingPercentEncoding, !s.isEmpty, s != ".", s != "..", !s.contains("/") else { return nil }
            segments.append(s)
        }
        return segments
    }

    /// Absolute URL string for `path`, for the `Destination` header of MOVE.
    func absoluteString(for path: String) throws -> String { try url(for: path).absoluteString }

    /// Undoes what compressing reverse proxies do to a response's ETag, so it can be sent back
    /// in `If-Match`: Caddy and Apache append "-gzip"/"-br"/"-zstd" inside the quotes, and nginx
    /// marks it weak (`W/`). Without this, every update of a downloaded task fails with 412.
    public static func normalizeETag(_ etag: String?) -> String? {
        guard var e = etag?.trimmingCharacters(in: .whitespaces), !e.isEmpty else { return nil }
        if e.hasPrefix("W/") { e.removeFirst(2) }
        let quoted = e.count >= 2 && e.hasPrefix("\"") && e.hasSuffix("\"")
        var inner = quoted ? String(e.dropFirst().dropLast()) : e
        for suffix in ["-gzip", "-br", "-zstd", "-deflate"] where inner.hasSuffix(suffix) {
            inner.removeLast(suffix.count)
            break
        }
        // A strong ETag is a quoted string (RFC 9110); some responses omit the quotes.
        return "\"\(inner)\""
    }

    // MARK: - Helpers

    /// Sends `req`, reading at most `SyncLimits.maxResponseBytes` of the body (also when the
    /// server sends no or a wrong Content-Length). Redirects outside `baseURL` are refused.
    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = RedirectGuard(base: baseURL, follows: followsRedirects)
        let limit = maxResponseBytes
        do {
            #if canImport(FoundationNetworking)
            // swift-corelibs-foundation (Linux, used for tests only) has no `bytes(for:)`: the body
            // is read whole and the final URL checked after the fact.
            let (data, response) = try await session.data(for: req, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw SyncError.network("Invalid server response") }
            if let target = delegate.rejectedTarget { throw SyncError.redirectRejected(target) }
            if let url = http.url, !Self.isWithin(url, base: baseURL) { throw SyncError.redirectRejected(Self.displayString(url)) }
            if data.count > limit { throw SyncError.limitExceeded("a server response is larger than \(limit / 1024 / 1024) MB") }
            return (data, http)
            #else
            let (bytes, response) = try await session.bytes(for: req, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw SyncError.network("Invalid server response") }
            if let target = delegate.rejectedTarget {
                bytes.task.cancel()
                throw SyncError.redirectRejected(target)
            }
            let tooLarge = SyncError.limitExceeded("a server response is larger than \(limit / 1024 / 1024) MB")
            if http.expectedContentLength > Int64(limit) {
                bytes.task.cancel()
                throw tooLarge
            }
            var data = Data()
            data.reserveCapacity(Int(max(0, min(http.expectedContentLength, 4 << 20))))
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
            #endif
        } catch let e as SyncError {
            throw e
        } catch let e as URLError {
            throw SyncError.network(Self.message(for: e))
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
    }

    /// Follows only redirects that stay inside the base URL (same scheme, host, port, and a path
    /// below it); any other redirect is not followed and remembered in `rejectedTarget`. With
    /// `follows` false, no redirect is followed and none is rejected: the caller gets the response.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let base: URL
        let follows: Bool
        private let lock = NSLock()
        private var rejected: String?

        init(base: URL, follows: Bool = true) { self.base = base; self.follows = follows }

        var rejectedTarget: String? { lock.withLock { rejected } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard follows else { return nil }
            if let url = request.url, WebDAVClient.isWithin(url, base: base) { return request }
            lock.withLock { rejected = request.url.map(WebDAVClient.displayString) ?? "?" }
            return nil
        }
    }

    /// scheme://host[:port]/path, without credentials, query or fragment.
    static func displayString(_ url: URL) -> String {
        var c = URLComponents()
        c.scheme = url.scheme
        c.host = url.host
        c.port = url.port
        c.path = url.path
        return c.string ?? url.host ?? "?"
    }

    static func message(for e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost: return "No internet connection"
        case .cannotFindHost, .dnsLookupFailed: return "Server not found. Check the server URL."
        case .cannotConnectToHost: return "Could not connect to the server"
        case .timedOut: return "The server did not respond in time"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            return "Secure connection to the server failed (certificate problem)"
        default: return e.localizedDescription
        }
    }

    static func error(status: Int, path: String) -> SyncError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden(path)
        case 404: return path.isEmpty ? .baseNotFound : .notFound(path)
        case 409: return .conflict(path)
        case 412: return .preconditionFailed(path)
        case 429: return .rateLimited(path)
        case 507: return .insufficientStorage
        default: return .http(status: status, path: path)
        }
    }
}

