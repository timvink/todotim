import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the user's calendars are, as found by discovery. `CalDAVState` keeps it, so discovery runs
/// once per account and again only when the home stops working.
public struct CalendarHome: Codable, Equatable, Sendable {
    /// Absolute URL of the calendar home collection, ending in "/".
    public var url: String
    /// Absolute URL of the user's principal (`current-user-principal`); nil when discovery found none.
    public var principal: String?

    public init(url: String, principal: String? = nil) {
        self.url = url
        self.principal = principal
    }
}

/// Finds the calendar home for a server URL, as RFC 6764 (§6) and RFC 4791 (§6.2.1) describe:
///
/// 1. `PROPFIND` (Depth 0) of `current-user-principal` on the server URL (the DAV root), and when
///    that names no principal, on `/.well-known/caldav` of the same origin.
/// 2. `PROPFIND` (Depth 0) of `calendar-home-set` on that principal.
///
/// When neither gives a home, the home is `calendars/<username>/` below the server URL: the
/// SabreDAV layout of Nextcloud, ownCloud and Baïkal, and what TodoTim used before discovery.
///
/// Every request goes to the server URL's origin (scheme, host and port). Redirects are not followed
/// by URLSession but here, one hop at a time, so PROPFIND stays PROPFIND and each target is checked.
/// A principal, home or redirect on another origin (such as iCloud's `pNN-caldav` hosts) is refused
/// with `SyncError.otherServer`, so the password only goes to the server the user entered.
enum CalDAVDiscovery {
    static let maxRedirects = 5
    /// Largest accepted discovery response: a few properties of one resource.
    static let maxResponseBytes = 1 << 20
    static let maxEntries = 64

    private static let caldavNS = "urn:ietf:params:xml:ns:caldav"

    static func discover(serverURL: String, username: String, password: String,
                         session: URLSession? = nil) async throws -> CalendarHome {
        let root = try CalDAVClient.davRoot(serverURL)
        guard let origin = WebDAVClient.originRoot(of: root) else { throw SyncError.invalidURL(serverURL) }
        let dav = try WebDAVClient(serverURL: origin.absoluteString, username: username, password: password, session: session)
        dav.followsRedirects = false
        dav.maxResponseBytes = maxResponseBytes

        var principal: URL?
        // The well-known URL has no trailing slash: servers often match it exactly.
        for start in [root, URL(string: ".well-known/caldav", relativeTo: origin)!.absoluteURL] {
            principal = try await href(of: "DAV:|current-user-principal", element: "<d:current-user-principal/>",
                                       at: start, dav: dav).first
            if principal != nil { break }
        }
        let principalURL = principal.flatMap { WebDAVClient.canonicalURL($0, collection: true) }?.absoluteString
        if let principal {
            let homes = try await href(of: "\(caldavNS)|calendar-home-set", element: "<c:calendar-home-set/>",
                                       at: principal, dav: dav)
            if let home = homes.lazy.compactMap({ WebDAVClient.canonicalURL($0, collection: true) }).first {
                return CalendarHome(url: home.absoluteString, principal: principalURL)
            }
        }
        guard let fallback = legacyHome(root: root, username: username) else { throw SyncError.invalidURL(serverURL) }
        return CalendarHome(url: fallback, principal: principalURL)
    }

    /// The home TodoTim used before discovery, and uses when discovery finds none:
    /// `calendars/<username>/` below the DAV root.
    static func legacyHome(root: URL, username: String) -> String? {
        guard let calendars = URL(string: "calendars/", relativeTo: root)?.absoluteURL else { return nil }
        return WebDAVClient.canonicalURL(calendars.appending(path: username, directoryHint: .isDirectory), collection: true)?
            .absoluteString
    }

    /// The hrefs in property `property` of the resource at `url`, resolved, on the origin of
    /// `dav.baseURL`. Empty when the server has no such resource or property (or is not WebDAV).
    /// Throws for a wrong password, a server error, and a redirect, principal or home on another
    /// origin.
    private static func href(of property: String, element: String, at start: URL, dav: WebDAVClient) async throws -> [URL] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="\(caldavNS)"><d:prop>\(element)</d:prop></d:propfind>
        """
        let headers = ["Content-Type": "application/xml; charset=utf-8", "Depth": "0"]
        var url = start
        for _ in 0...maxRedirects {
            let r = try await dav.send("PROPFIND", url: url, headers: headers, body: Data(body.utf8))
            switch r.status {
            case 207:
                let doc: Multistatus.Document?
                do {
                    doc = try Multistatus.parse(r.data, maxEntries: maxEntries)
                } catch {
                    return []
                }
                let hrefs = doc?.responses.flatMap { $0.properties[property]?.hrefs ?? [] } ?? []
                var found: [URL] = []
                var elsewhere: URL?
                for href in hrefs {
                    guard let target = resolve(href, against: url) else { continue }
                    if WebDAVClient.isSameOrigin(target, dav.baseURL) { found.append(target) } else { elsewhere = elsewhere ?? target }
                }
                if found.isEmpty, let elsewhere { throw SyncError.otherServer(WebDAVClient.displayString(elsewhere)) }
                return found
            case 300...399:
                guard let location = r.location, let target = resolve(location, against: url) else { return [] }
                guard WebDAVClient.isSameOrigin(target, dav.baseURL) else {
                    throw SyncError.otherServer(WebDAVClient.displayString(target))
                }
                url = target
            case 401:
                throw SyncError.unauthorized
            case 429, 500, 502...599:
                throw WebDAVClient.error(status: r.status, path: url.path(percentEncoded: false))
            default:
                // 404, 405, 403, 501, a web page (200), …: nothing here.
                return []
            }
        }
        throw SyncError.badRemoteData(path: start.path(percentEncoded: false), reason: "more than \(maxRedirects) redirects")
    }

    /// `href` resolved against `base`: an http(s) URL without credentials, query, fragment or dot
    /// segments, or nil.
    static func resolve(_ href: String, against base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              WebDAVClient.decodedSegments(url) != nil
        else { return nil }
        return url
    }
}
