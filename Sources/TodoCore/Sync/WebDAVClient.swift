import Foundation

/// WebDAV client for a Nextcloud-style server. `baseURL` is the WebDAV root of the user,
/// e.g. https://host/remote.php/dav/files/USER/ ; paths passed to the methods are relative
/// to it and are percent-encoded per segment here. Uses Basic auth (Nextcloud app password).
public final class WebDAVClient: RemoteStorage, @unchecked Sendable {
    public let baseURL: URL
    private let authorization: String
    private let session: URLSession

    /// Throws `SyncError.invalidURL` if `serverURL` is not an http(s) URL.
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
            self.session = URLSession(configuration: config)
        }
    }

    /// Trims whitespace, validates scheme/host and ensures a trailing slash.
    public static func normalizedBaseURL(_ string: String) throws -> URL {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw SyncError.invalidURL(string) }
        if !s.hasSuffix("/") { s += "/" }
        let url = URL(string: s)
            ?? s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { throw SyncError.invalidURL(string) }
        return url
    }

    /// Characters allowed unescaped in a single path segment (RFC 3986 pchar without "/" and ";").
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        set.insert(charactersIn: "-._~!$&'()*+,=@")
        return set
    }()

    /// URL for a relative path; `collection` adds a trailing slash.
    func url(for path: String, collection: Bool = false) -> URL {
        let segments = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? String($0)
        }
        var rel = segments.joined(separator: "/")
        if collection && !rel.isEmpty { rel += "/" }
        // baseURL ends with "/" and every segment is percent-encoded, so this always parses.
        return URL(string: baseURL.absoluteString + rel) ?? baseURL
    }

    // MARK: - RemoteStorage

    public func list(_ path: String) async throws -> [RemoteItem] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:resourcetype/></d:prop></d:propfind>
        """
        var req = request(path, method: "PROPFIND", collection: true)
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, response) = try await send(req)
        switch response.statusCode {
        case 207:
            guard let entries = MultistatusParser.parse(data) else { throw SyncError.notWebDAV }
            return Self.items(from: entries, baseURL: baseURL, listedPath: path)
        case 200...299:
            throw SyncError.notWebDAV
        default:
            throw Self.error(status: response.statusCode, path: path)
        }
    }

    public func get(_ path: String) async throws -> (data: Data, etag: String?) {
        let (data, response) = try await send(request(path, method: "GET"))
        guard (200...299).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, path: path)
        }
        return (data, response.value(forHTTPHeaderField: "ETag"))
    }

    @discardableResult
    public func put(_ path: String, data: Data, condition: PutCondition) async throws -> String? {
        var req = request(path, method: "PUT")
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
        return response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "OC-ETag")
    }

    public func makeCollection(_ path: String) async throws {
        let (_, response) = try await send(request(path, method: "MKCOL", collection: true))
        switch response.statusCode {
        case 200...299, 405: return  // 405 Method Not Allowed = already exists
        default: throw Self.error(status: response.statusCode, path: path)
        }
    }

    public func delete(_ path: String, ifMatch: String?) async throws {
        var req = request(path, method: "DELETE")
        if let ifMatch { req.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let (_, response) = try await send(req)
        switch response.statusCode {
        case 200...299, 404: return
        default: throw Self.error(status: response.statusCode, path: path)
        }
    }

    // MARK: - Helpers

    private func request(_ path: String, method: String, collection: Bool = false) -> URLRequest {
        var req = URLRequest(url: url(for: path, collection: collection))
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw SyncError.network("Invalid server response") }
            return (data, http)
        } catch let e as SyncError {
            throw e
        } catch let e as URLError {
            throw SyncError.network(Self.message(for: e))
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
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

    /// Maps multistatus entries to items relative to `baseURL`, dropping the listed collection itself.
    static func items(from entries: [MultistatusParser.Entry], baseURL: URL, listedPath: String) -> [RemoteItem] {
        var basePath = baseURL.path(percentEncoded: false)
        if !basePath.hasSuffix("/") { basePath += "/" }
        let listed = joinPath(listedPath)
        return entries.compactMap { entry -> RemoteItem? in
            guard let hrefURL = URL(string: entry.href, relativeTo: baseURL) else { return nil }
            var p = hrefURL.path(percentEncoded: false)
            if !p.hasSuffix("/") { p += "/" }
            guard p.hasPrefix(basePath) else { return nil }
            let rel = joinPath(String(p.dropFirst(basePath.count)))
            guard rel != listed else { return nil }
            return RemoteItem(path: rel, etag: entry.etag, isCollection: entry.isCollection)
        }
    }
}

/// Parses a WebDAV 207 Multi-Status body into hrefs, ETags and collection flags.
/// Only properties inside a propstat with a 2xx status are used.
enum MultistatusParser {
    struct Entry: Equatable {
        var href: String
        var etag: String?
        var isCollection: Bool
    }

    /// nil if the body is not a DAV multistatus document.
    static func parse(_ data: Data) -> [Entry]? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), delegate.sawMultistatus else { return nil }
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        var sawMultistatus = false

        private var text = ""
        private var href: String?
        private var propEtag: String?
        private var propCollection = false
        private var propStatusOK = true
        private var etag: String?
        private var isCollection = false
        private var inResourceType = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            guard namespaceURI == "DAV:" else { return }
            switch name {
            case "multistatus": sawMultistatus = true
            case "response": href = nil; etag = nil; isCollection = false
            case "propstat": propEtag = nil; propCollection = false; propStatusOK = true
            case "resourcetype": inResourceType = true
            case "collection" where inResourceType: propCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { text = "" }
            guard namespaceURI == "DAV:" else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href" where href == nil: href = value
            case "getetag": propEtag = value.isEmpty ? nil : value
            case "resourcetype": inResourceType = false
            case "status":
                // e.g. "HTTP/1.1 200 OK"; inside propstat it qualifies the props.
                let parts = value.split(separator: " ")
                if parts.count >= 2, let code = Int(parts[1]) { propStatusOK = (200...299).contains(code) }
            case "propstat":
                if propStatusOK {
                    if let propEtag { etag = propEtag }
                    if propCollection { isCollection = true }
                }
            case "response":
                if let href { entries.append(Entry(href: href, etag: etag, isCollection: isCollection)) }
            default: break
            }
        }
    }
}
