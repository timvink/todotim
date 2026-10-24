import Foundation

/// WebDAV client for a Nextcloud-style server. `baseURL` is the WebDAV root of the user,
/// e.g. https://host/remote.php/dav/files/USER/ ; paths passed to the methods are relative
/// to it and are percent-encoded per segment here. Uses Basic auth (Nextcloud app password).
public final class WebDAVClient: RemoteStorage, @unchecked Sendable {
    public let baseURL: URL
    private let authorization: String
    private let session: URLSession
    /// Largest accepted response body (tests lower it).
    var maxResponseBytes = SyncLimits.maxResponseBytes

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

    /// Whether `url` has the scheme, host and port of `base` and a path inside base's path.
    static func isWithin(_ url: URL, base: URL) -> Bool {
        guard url.scheme?.lowercased() == base.scheme?.lowercased(),
              url.host?.lowercased() == base.host?.lowercased(),
              effectivePort(url) == effectivePort(base) else { return false }
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

    // MARK: - RemoteStorage

    public func listing(_ path: String) async throws -> RemoteListing {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """
        var req = try request(path, method: "PROPFIND", collection: true)
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, response) = try await send(req)
        switch response.statusCode {
        case 207:
            let entries: [MultistatusParser.Entry]?
            do {
                entries = try MultistatusParser.parse(data)
            } catch MultistatusParser.Failure.tooManyEntries {
                throw SyncError.limitExceeded("more than \(SyncLimits.maxListingEntries) entries in “\(path)”")
            } catch {
                throw SyncError.badRemoteData(path: path, reason: "the folder listing is not plain WebDAV XML (\(error))")
            }
            guard let entries else { throw SyncError.notWebDAV }
            return RemoteListing(items: Self.items(from: entries, baseURL: baseURL, listedPath: path),
                                 serverDate: Self.httpDate(response.value(forHTTPHeaderField: "Date")))
        case 200...299:
            throw SyncError.notWebDAV
        default:
            throw Self.error(status: response.statusCode, path: path)
        }
    }

    public func get(_ path: String) async throws -> RemoteFile {
        let (data, response) = try await send(try request(path, method: "GET"))
        guard (200...299).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, path: path)
        }
        return RemoteFile(data: data, etag: Self.normalizeETag(response.value(forHTTPHeaderField: "ETag")),
                          modified: Self.httpDate(response.value(forHTTPHeaderField: "Last-Modified")),
                          serverDate: Self.httpDate(response.value(forHTTPHeaderField: "Date")))
    }

    /// Parses an HTTP date (RFC 9110 IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT"), as
    /// used by the Date and Last-Modified headers and `getlastmodified`. nil if absent or invalid.
    public static func httpDate(_ string: String?) -> Date? {
        guard let s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return httpDateLock.withLock { httpDateFormatter.date(from: s) }
    }

    private static let httpDateLock = NSLock()
    nonisolated(unsafe) private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// Undoes what compressing reverse proxies do to a response's ETag, so it can be sent back
    /// in `If-Match`: Caddy and Apache append "-gzip"/"-br"/"-zstd" inside the quotes, and nginx
    /// marks it weak (`W/`). Without this, every update of a downloaded file fails with 412.
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

    @discardableResult
    public func put(_ path: String, data: Data, condition: PutCondition) async throws -> String? {
        var req = try request(path, method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch condition {
        case .none: break
        case .ifMatch(let etag): req.setValue(etag, forHTTPHeaderField: "If-Match")
        case .ifNoneMatch: req.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        req.httpBody = data
        let (_, response) = try await send(req)
        guard (200...299).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, path: path)
        }
        return Self.normalizeETag(response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "OC-ETag"))
    }

    public func makeCollection(_ path: String) async throws {
        let (_, response) = try await send(try request(path, method: "MKCOL", collection: true))
        switch response.statusCode {
        case 200...299, 405: return  // 405 Method Not Allowed = already exists
        default: throw Self.error(status: response.statusCode, path: path)
        }
    }

    public func delete(_ path: String, ifMatch: String?) async throws {
        var req = try request(path, method: "DELETE")
        if let ifMatch { req.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let (_, response) = try await send(req)
        switch response.statusCode {
        case 200...299, 404: return
        default: throw Self.error(status: response.statusCode, path: path)
        }
    }

    // MARK: - Helpers

    private func request(_ path: String, method: String, collection: Bool = false) throws -> URLRequest {
        var req = URLRequest(url: try url(for: path, collection: collection))
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    /// Sends `req`, reading at most `SyncLimits.maxResponseBytes` of the body (also when the
    /// server sends no or a wrong Content-Length). Redirects outside `baseURL` are refused.
    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = RedirectGuard(base: baseURL)
        let limit = maxResponseBytes
        do {
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
        } catch let e as SyncError {
            throw e
        } catch let e as URLError {
            throw SyncError.network(Self.message(for: e))
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
    }

    /// Follows only redirects that stay inside the base URL (same scheme, host, port, and a path
    /// below it); any other redirect is not followed and remembered in `rejectedTarget`.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let base: URL
        private let lock = NSLock()
        private var rejected: String?

        init(base: URL) { self.base = base }

        var rejectedTarget: String? { lock.withLock { rejected } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
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
        case 507: return .insufficientStorage
        default: return .http(status: status, path: path)
        }
    }

    /// Maps multistatus entries to items relative to `baseURL`, dropping the listed collection
    /// itself and anything that is not a direct child of it on the same server.
    static func items(from entries: [MultistatusParser.Entry], baseURL: URL, listedPath: String) -> [RemoteItem] {
        var basePath = baseURL.standardized.path(percentEncoded: false)
        if !basePath.hasSuffix("/") { basePath += "/" }
        let listed = joinPath(listedPath)
        return entries.compactMap { entry -> RemoteItem? in
            guard let hrefURL = URL(string: entry.href, relativeTo: baseURL)?.absoluteURL.standardized,
                  isWithin(hrefURL, base: baseURL) else { return nil }
            var p = hrefURL.path(percentEncoded: false)
            if !p.hasSuffix("/") { p += "/" }
            guard p.hasPrefix(basePath) else { return nil }
            let rel = joinPath(String(p.dropFirst(basePath.count)))
            guard rel != listed else { return nil }
            var parts = rel.split(separator: "/")
            guard let name = parts.popLast(), name != ".", name != "..",
                  parts.joined(separator: "/") == listed else { return nil }
            return RemoteItem(path: rel, etag: entry.etag, isCollection: entry.isCollection,
                              size: entry.size, modified: entry.modified)
        }
    }
}

/// Parses a WebDAV 207 Multi-Status body into hrefs, ETags, collection flags, sizes and
/// modification dates. Only properties inside a propstat with a 2xx status are used.
enum MultistatusParser {
    struct Entry: Equatable {
        var href: String
        var etag: String?
        var isCollection: Bool
        var size: Int? = nil
        var modified: Date? = nil
    }

    enum Failure: Error {
        /// The document declares a DTD or entities (never needed for WebDAV; refused to rule out
        /// entity expansion).
        case dtd
        case tooManyEntries
        case textTooLong
    }

    /// Longest text content of one element.
    static let maxTextLength = 64 * 1024

    /// nil if the body is not a DAV multistatus document. Throws `Failure` for documents with a
    /// DTD, more than `maxEntries` responses or over-long text.
    static func parse(_ data: Data, maxEntries: Int = SyncLimits.maxListingEntries) throws -> [Entry]? {
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
            throw Failure.dtd
        }
        let delegate = Delegate(maxEntries: maxEntries)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard ok, delegate.sawMultistatus else { return nil }
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let maxEntries: Int
        var entries: [Entry] = []
        var sawMultistatus = false
        var failure: Failure?

        init(maxEntries: Int) { self.maxEntries = maxEntries }

        private func fail(_ parser: XMLParser, _ f: Failure) {
            failure = f
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail(parser, .dtd)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            fail(parser, .dtd)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            fail(parser, .dtd)
            return nil
        }

        private var text = ""
        private var href: String?
        private var propEtag: String?
        private var propCollection = false
        private var propSize: Int?
        private var propModified: Date?
        private var propStatusOK = true
        private var etag: String?
        private var isCollection = false
        private var size: Int?
        private var modified: Date?
        private var inResourceType = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            guard namespaceURI == "DAV:" else { return }
            switch name {
            case "multistatus": sawMultistatus = true
            case "response": href = nil; etag = nil; isCollection = false; size = nil; modified = nil
            case "propstat": propEtag = nil; propCollection = false; propSize = nil; propModified = nil; propStatusOK = true
            case "resourcetype": inResourceType = true
            case "collection" where inResourceType: propCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard failure == nil else { return }
            text += string
            if text.utf8.count > MultistatusParser.maxTextLength { fail(parser, .textTooLong) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { text = "" }
            guard namespaceURI == "DAV:" else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href" where href == nil: href = value
            case "getetag": propEtag = WebDAVClient.normalizeETag(value)
            case "getcontentlength": propSize = Int(value).flatMap { $0 >= 0 ? $0 : nil }
            case "getlastmodified": propModified = WebDAVClient.httpDate(value)
            case "resourcetype": inResourceType = false
            case "status":
                // e.g. "HTTP/1.1 200 OK"; inside propstat it qualifies the props.
                let parts = value.split(separator: " ")
                if parts.count >= 2, let code = Int(parts[1]) { propStatusOK = (200...299).contains(code) }
            case "propstat":
                if propStatusOK {
                    if let propEtag { etag = propEtag }
                    if propCollection { isCollection = true }
                    if let propSize { size = propSize }
                    if let propModified { modified = propModified }
                }
            case "response":
                guard let href else { break }
                if entries.count >= maxEntries { return fail(parser, .tooManyEntries) }
                entries.append(Entry(href: href, etag: etag, isCollection: isCollection, size: size, modified: modified))
            default: break
            }
        }
    }
}
