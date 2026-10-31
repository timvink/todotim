import Foundation

/// A calendar in the user's calendar home, with the properties TodoTim syncs (raw values).
struct RemoteCalendar: Codable, Equatable, Sendable {
    /// Relative to the DAV root, without trailing slash: "calendars/tim/work" on Nextcloud.
    var path: String
    var name: String?
    /// `{http://apple.com/ns/ical/}calendar-color`, e.g. "#DB4035" or "#DB4035FF".
    var color: String?
    /// `{http://apple.com/ns/ical/}calendar-order` (an integer on Nextcloud).
    var order: String?
    /// `{https://todotim.app/ns}sections` / `labels` (JSON); nil when the property is not set.
    var sections: String?
    var labels: String?
    /// `{DAV:}sync-token` (RFC 6578).
    var syncToken: String?

    /// Last path segment (the calendar's URI).
    var uri: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// One calendar object (task) on the server.
struct RemoteResource: Equatable, Sendable {
    /// Relative to the DAV root: "calendars/tim/work/abc.ics".
    var path: String
    var etag: String?
    var ics: String
}

/// What changed in a calendar since a sync token.
struct CalendarChanges: Equatable, Sendable {
    var syncToken: String?
    var changed: [RemoteResource]
    /// Paths of members removed since the token.
    var removed: [String]
    /// The token was not accepted (or none was given): `changed` is the complete content.
    var isFull: Bool
}

/// Calendar properties TodoTim writes.
enum CalendarProperty: String, CaseIterable, Codable, Sendable {
    case name, color, order, sections, labels

    /// Properties a server may refuse to store (extensions: Apple's and TodoTim's own dead
    /// properties); TodoTim then keeps them locally. The display name is standard WebDAV.
    static let optional: Set<CalendarProperty> = [.color, .order, .sections, .labels]

    var element: (ns: String, name: String) {
        switch self {
        case .name: ("DAV:", "displayname")
        case .color: ("http://apple.com/ns/ical/", "calendar-color")
        case .order: ("http://apple.com/ns/ical/", "calendar-order")
        case .sections: (CalDAVClient.todotimNS, "sections")
        case .labels: (CalDAVClient.todotimNS, "labels")
        }
    }
}

/// The CalDAV operations sync needs. `CalDAVClient` implements them over HTTP; tests use an
/// in-memory server. Paths are relative to the DAV root and not percent-encoded.
protocol CalDAVServer: Sendable {
    /// The calendar home, relative to the DAV root: "calendars/<user>" on Nextcloud, "<user>" on
    /// Radicale, "" when the home is the DAV root itself.
    var home: String { get }
    /// Where the home is, for the sync state (so the next sync needs no discovery).
    var calendarHome: CalendarHome { get }
    /// The user's own calendars that hold only VTODOs (shared, subscribed and event calendars
    /// are left out).
    func calendars() async throws -> [RemoteCalendar]
    /// Changes in `calendar` since `token` (RFC 6578 sync-collection, with calendar data); with a
    /// nil or rejected token, the full content.
    func changes(in calendar: String, since token: String?) async throws -> CalendarChanges
    /// MKCALENDAR with a VTODO-only component set. Returns the properties that could not be set
    /// with it (a server that refuses the color or order gets a calendar without them).
    func createCalendar(_ path: String, name: String, color: String, order: String) async throws -> Set<CalendarProperty>
    /// PROPPATCH; a nil value removes the property. Returns the optional properties the server
    /// refused to store (`CalendarProperty.optional`, e.g. dead properties on Xandikos); the
    /// others are set. Any other refusal throws.
    func setProperties(_ path: String, _ values: [CalendarProperty: String?]) async throws -> Set<CalendarProperty>
    func deleteCalendar(_ path: String) async throws
    /// Shares a calendar read-write with another user (Nextcloud's sharing; other servers refuse it).
    func share(_ path: String, with user: String) async throws
    /// PUT a calendar object: `ifMatch` nil creates it (`If-None-Match: *`). Returns the new ETag if reported.
    func put(_ path: String, ics: String, ifMatch: String?) async throws -> String?
    /// MOVE a calendar object to another calendar (`If-Match` on the source).
    func move(_ path: String, to destination: String, ifMatch: String?) async throws
    /// DELETE a calendar object; succeeds if it is already gone.
    func delete(_ path: String, ifMatch: String?) async throws
}

/// CalDAV over `WebDAVClient` (`docs/caldav.md`). Server data is validated: paths must be direct
/// children of the calendar home / calendar, and responses are bounded.
final class CalDAVClient: CalDAVServer {
    static let todotimNS = "https://todotim.app/ns"
    private static let caldavNS = "urn:ietf:params:xml:ns:caldav"

    let dav: WebDAVClient
    let username: String
    let home: String
    let calendarHome: CalendarHome
    /// Decoded path of the user's principal ("remote.php/dav/principals/users/tim"), if discovery
    /// found it.
    private let principalPath: String?
    /// Pages of a sync-collection REPORT followed before giving up.
    static let maxPages = 100

    /// A client for `home`, relative to `dav.baseURL` (by default the SabreDAV layout,
    /// "calendars/<username>").
    init(dav: WebDAVClient, username: String, home: String? = nil, calendarHome: CalendarHome? = nil) {
        let home = home ?? "calendars/\(username)"
        self.dav = dav
        self.username = username
        self.home = home
        self.calendarHome = calendarHome
            ?? CalendarHome(url: (try? dav.url(for: home, collection: true))?.absoluteString ?? dav.baseURL.absoluteString)
        principalPath = self.calendarHome.principal.flatMap(URL.init(string:)).flatMap(WebDAVClient.decodedSegments)?
            .joined(separator: "/")
    }

    /// A client for the calendar home `home` (from discovery or the sync state) of the server at
    /// `serverURL`. Requests stay inside the DAV root when the home is inside it, and otherwise
    /// inside the home itself. A home on another origin is refused.
    convenience init(serverURL: String, username: String, password: String, home: CalendarHome,
                     session: URLSession? = nil) throws {
        let root = try Self.davRoot(serverURL)
        guard let url = URL(string: home.url).flatMap({ WebDAVClient.canonicalURL($0, collection: true) }) else {
            throw SyncError.invalidPath(home.url)
        }
        guard WebDAVClient.isSameOrigin(url, root) else { throw SyncError.otherServer(WebDAVClient.displayString(url)) }
        let base = WebDAVClient.isWithin(url, base: root) ? root : url
        let dav = try WebDAVClient(serverURL: base.absoluteString, username: username, password: password, session: session)
        guard let path = dav.relativePath(ofHref: url.absoluteString) else { throw SyncError.invalidPath(home.url) }
        self.init(dav: dav, username: username, home: path, calendarHome: home)
    }

    /// A client for the calendar home of `serverURL`: `cached` (from the sync state), or else the
    /// one discovery finds (`CalDAVDiscovery`).
    static func connect(serverURL: String, username: String, password: String, cached: CalendarHome?,
                        session: URLSession? = nil) async throws -> CalDAVClient {
        var home = cached
        if home == nil {
            home = try await CalDAVDiscovery.discover(serverURL: serverURL, username: username, password: password,
                                                      session: session)
        }
        return try CalDAVClient(serverURL: serverURL, username: username, password: password, home: home!, session: session)
    }

    /// The DAV root for a configured server URL: the URL itself, or, for an old-style files URL
    /// (".../remote.php/dav/files/USER/"), the part before "files/".
    static func davRoot(_ serverURL: String) throws -> URL {
        let url = try WebDAVClient.normalizedBaseURL(serverURL)
        let segments = url.path(percentEncoded: true).split(separator: "/")
        if segments.count >= 2, segments[segments.count - 2] == "files",
           var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedPath = "/" + segments.dropLast(2).joined(separator: "/") + "/"
            if let root = c.url { return root }
        }
        return url
    }

    // MARK: - Calendars

    func calendars() async throws -> [RemoteCalendar] {
        let props = CalendarProperty.allCases.map { "<x:\($0.element.name) xmlns:x=\"\($0.element.ns)\"/>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="\(Self.caldavNS)" xmlns:oc="http://owncloud.org/ns" xmlns:cs="\(Self.calendarServerNS)">\
        <d:prop><d:resourcetype/><c:supported-calendar-component-set/><d:sync-token/><cs:getctag/><oc:owner-principal/>\(props)\
        </d:prop></d:propfind>
        """
        let doc = try await multistatus("PROPFIND", home, collection: true, depth: "1", body: body)
        var out: [RemoteCalendar] = []
        for r in doc.responses {
            let types = r.properties["DAV:|resourcetype"]?.children ?? []
            guard let path = dav.relativePath(ofHref: r.href), Self.isChild(path, of: home),
                  types.contains("\(Self.caldavNS)|calendar"),
                  // The scheduling inbox and outbox (RFC 6638) hold invitations, not tasks.
                  !types.contains("\(Self.caldavNS)|schedule-inbox"), !types.contains("\(Self.caldavNS)|schedule-outbox"),
                  r.properties["\(Self.caldavNS)|supported-calendar-component-set"]?.children == ["\(Self.caldavNS)|comp=VTODO"]
            else { continue }
            // Calendars shared by other users also appear in the home (Nextcloud names them
            // "<uri>_shared_by_<owner>"); only the user's own are synced. Calendars that Nextcloud
            // apps generate (such as Deck boards, "app-generated--…") are read-only.
            if path.split(separator: "/").last?.hasPrefix("app-generated--") == true { continue }
            if let owner = r.text("http://owncloud.org/ns|owner-principal"), !isOwnPrincipal(owner) { continue }
            func value(_ p: CalendarProperty) -> String? { r.text("\(p.element.ns)|\(p.element.name)") }
            func nonEmpty(_ qname: String) -> String? { r.text(qname).flatMap { $0.isEmpty ? nil : $0 } }
            // Without sync-collection (RFC 6578 is optional), the CalendarServer ctag tells changes.
            let token = nonEmpty("DAV:|sync-token") ?? nonEmpty("\(Self.calendarServerNS)|getctag").map { Self.ctagPrefix + $0 }
            out.append(RemoteCalendar(path: path, name: value(.name), color: value(.color), order: value(.order),
                                      sections: value(.sections), labels: value(.labels), syncToken: token))
        }
        return out
    }

    private static let calendarServerNS = "http://calendarserver.org/ns/"
    /// Marks a `RemoteCalendar.syncToken` that is a getctag: the calendar has no sync-collection.
    static let ctagPrefix = "ctag:"

    /// With a sync token (RFC 6578), the changes since it; otherwise the full content. On a server
    /// without sync-collection (a getctag token, or a REPORT it refuses), the full content by
    /// calendar-query, with no sync token.
    func changes(in calendar: String, since token: String?) async throws -> CalendarChanges {
        if token?.hasPrefix(Self.ctagPrefix) == true { return try await allObjects(in: calendar) }
        var result = CalendarChanges(syncToken: token, changed: [], removed: [], isFull: token == nil)
        var seen: [String: Int] = [:]
        /// Changed objects reported without their data (Xandikos leaves calendar-data out of
        /// sync-collection, and any server may fail a property): fetched with calendar-multiget.
        var withoutData = Set<String>()
        var finished = false
        // Servers may return results in pages (a 507 response for the collection means "more").
        for _ in 0..<Self.maxPages {
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:sync-collection xmlns:d="DAV:" xmlns:c="\(Self.caldavNS)"><d:sync-token>\(xmlEscape(result.syncToken ?? ""))</d:sync-token>\
            <d:sync-level>1</d:sync-level><d:prop><d:getetag/><c:calendar-data/></d:prop></d:sync-collection>
            """
            let doc: Multistatus.Document
            do {
                doc = try await multistatus("REPORT", calendar, collection: true, depth: nil, body: body,
                                            maxEntries: SyncLimits.maxTasks + 1)
            } catch let error as SyncError {
                switch error {
                case .forbidden where result.syncToken != nil, .conflict where result.syncToken != nil:
                    // valid-sync-token precondition failed (RFC 6578 §3.2, 403 or 409): start over.
                    result = CalendarChanges(syncToken: nil, changed: [], removed: [], isFull: true)
                    seen = [:]
                    withoutData = []
                    continue
                case .forbidden, .notCalDAV, .http(400, _), .http(405, _), .http(415, _), .http(422, _), .http(501, _):
                    // No sync-collection here (403 is RFC 3253's answer to an unsupported REPORT).
                    return try await allObjects(in: calendar)
                default: throw error
                }
            }
            var more = false
            for r in doc.responses {
                guard let path = dav.relativePath(ofHref: r.href) else { continue }
                if path == calendar {
                    if r.status == 507 { more = true }
                    continue
                }
                guard Self.isChild(path, of: calendar) else { continue }
                if r.status == 404 {
                    result.removed.append(path)
                    if let i = seen.removeValue(forKey: path) { result.changed[i].ics = "" }
                    withoutData.remove(path)
                } else if let ics = r.text("\(Self.caldavNS)|calendar-data"), !ics.isEmpty {
                    let res = RemoteResource(path: path, etag: WebDAVClient.normalizeETag(r.text("DAV:|getetag")), ics: ics)
                    result.removed.removeAll { $0 == path }
                    withoutData.remove(path)
                    if let i = seen[path] { result.changed[i] = res } else {
                        seen[path] = result.changed.count
                        result.changed.append(res)
                    }
                } else {
                    result.removed.removeAll { $0 == path }
                    if let i = seen.removeValue(forKey: path) { result.changed[i].ics = "" }
                    withoutData.insert(path)
                }
            }
            result.syncToken = doc.syncToken ?? result.syncToken
            if !more {
                finished = true
                break
            }
        }
        // A listing cut short must not count as complete (missing objects would look deleted).
        guard finished else { throw SyncError.limitExceeded("more than \(Self.maxPages) pages of changes in “\(calendar)”") }
        if !withoutData.isEmpty {
            let fetched = try await multiget(withoutData.sorted(), in: calendar)
            result.changed += fetched.found
            result.removed += fetched.removed
        }
        result.changed.removeAll { $0.ics.isEmpty }
        guard result.changed.count <= SyncLimits.maxTasks else {
            throw SyncError.limitExceeded("more than \(SyncLimits.maxTasks) tasks in “\(calendar)”")
        }
        return result
    }

    /// Objects per calendar-multiget request.
    static let multigetBatch = 100

    /// The objects at `paths` in `calendar`, by calendar-multiget (RFC 4791 §7.9). Objects the
    /// server reports as gone are `removed`. Any other object it leaves out fails the listing, so
    /// that it cannot look deleted.
    private func multiget(_ paths: [String], in calendar: String) async throws -> (found: [RemoteResource], removed: [String]) {
        var found: [RemoteResource] = [], removed: [String] = []
        for start in stride(from: 0, to: paths.count, by: Self.multigetBatch) {
            let batch = paths[start..<min(start + Self.multigetBatch, paths.count)]
            var hrefs = ""
            for path in batch { hrefs += "<d:href>\(xmlEscape(try dav.url(for: path).path(percentEncoded: true)))</d:href>" }
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <c:calendar-multiget xmlns:d="DAV:" xmlns:c="\(Self.caldavNS)"><d:prop><d:getetag/><c:calendar-data/></d:prop>\
            \(hrefs)</c:calendar-multiget>
            """
            let doc = try await multistatus("REPORT", calendar, collection: true, depth: "1", body: body,
                                            maxEntries: batch.count + 10)
            var missing = Set(batch)
            for r in doc.responses {
                guard let path = dav.relativePath(ofHref: r.href), missing.contains(path) else { continue }
                if let ics = r.text("\(Self.caldavNS)|calendar-data"), !ics.isEmpty {
                    found.append(RemoteResource(path: path, etag: WebDAVClient.normalizeETag(r.text("DAV:|getetag")), ics: ics))
                    missing.remove(path)
                } else if r.status == 404 {
                    removed.append(path)
                    missing.remove(path)
                }
            }
            if let path = missing.sorted().first {
                throw SyncError.badRemoteData(path: path, reason: "the server did not return its calendar data")
            }
        }
        return (found, removed)
    }

    /// Every object in `calendar`, by a calendar-query REPORT (RFC 4791 §7.8, which every CalDAV
    /// server has), with no sync token. An object listed without its data is fetched by
    /// calendar-multiget, which fails the listing if it cannot be read: the listing is taken as
    /// complete, so a missing object would look deleted.
    private func allObjects(in calendar: String) async throws -> CalendarChanges {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="\(Self.caldavNS)"><d:prop><d:getetag/><c:calendar-data/></d:prop>\
        <c:filter><c:comp-filter name="VCALENDAR"/></c:filter></c:calendar-query>
        """
        let doc = try await multistatus("REPORT", calendar, collection: true, depth: "1", body: body,
                                        maxEntries: SyncLimits.maxTasks + 1)
        var changed: [RemoteResource] = []
        var seen = Set<String>()
        var withoutData: [String] = []
        for r in doc.responses {
            guard let path = dav.relativePath(ofHref: r.href), Self.isChild(path, of: calendar), seen.insert(path).inserted else { continue }
            if let ics = r.text("\(Self.caldavNS)|calendar-data"), !ics.isEmpty {
                changed.append(RemoteResource(path: path, etag: WebDAVClient.normalizeETag(r.text("DAV:|getetag")), ics: ics))
            } else if r.status != 404 {
                withoutData.append(path)
            }
        }
        if !withoutData.isEmpty { changed += try await multiget(withoutData, in: calendar).found }
        guard changed.count <= SyncLimits.maxTasks else {
            throw SyncError.limitExceeded("more than \(SyncLimits.maxTasks) tasks in “\(calendar)”")
        }
        return CalendarChanges(syncToken: nil, changed: changed, removed: [], isFull: true)
    }

    func createCalendar(_ path: String, name: String, color: String, order: String) async throws -> Set<CalendarProperty> {
        let status = try await mkcalendar(path, name: name, color: color, order: order)
        if (200...299).contains(status) { return [] }
        guard [400, 403, 409, 415, 422, 424].contains(status) else { throw Self.mkcalendarError(status, path: path) }
        // A server may refuse a property it does not know: try again with only the name and the
        // component set (the color and order then go through PROPPATCH, which may refuse them).
        let plain = try await mkcalendar(path, name: name, color: nil, order: nil)
        guard (200...299).contains(plain) else { throw Self.mkcalendarError(plain, path: path) }
        return [.color, .order]
    }

    private func mkcalendar(_ path: String, name: String, color: String?, order: String?) async throws -> Int {
        let apple = (color.map { "<a:calendar-color>\(xmlEscape($0))</a:calendar-color>" } ?? "")
            + (order.map { "<a:calendar-order>\(xmlEscape($0))</a:calendar-order>" } ?? "")
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:mkcalendar xmlns:d="DAV:" xmlns:c="\(Self.caldavNS)" xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop>\
        <d:displayname>\(xmlEscape(name))</d:displayname>\(apple)\
        <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>\
        </d:prop></d:set></c:mkcalendar>
        """
        return try await dav.send("MKCALENDAR", path, collection: true, headers: xmlHeaders, body: Data(body.utf8)).status
    }

    private static func mkcalendarError(_ status: Int, path: String) -> SyncError {
        status == 405 ? .calendarExists(path) : WebDAVClient.error(status: status, path: path)
    }

    func setProperties(_ path: String, _ values: [CalendarProperty: String?]) async throws -> Set<CalendarProperty> {
        guard !values.isEmpty else { return [] }
        let status = try await proppatch(path, values)
        func failed(_ s: Int?) -> Bool { s.map { !(200...299).contains($0) } ?? false }
        let failures = Set(values.keys.filter { failed(status[$0]) })
        guard !failures.isEmpty else { return [] }
        // A property the server will not store fails with its own status (403, 409, …), the others
        // with 424 (RFC 4918 §9.2), unless the server applied them anyway (Xandikos does).
        let refused = failures.filter { status[$0] != 424 }
        guard !refused.isEmpty, refused.isSubset(of: CalendarProperty.optional) else {
            throw SyncError.http(status: 424, path: path)
        }
        let retry = values.filter { failures.contains($0.key) && !refused.contains($0.key) }
        if !retry.isEmpty {
            let again = try await proppatch(path, retry)
            if retry.keys.contains(where: { failed(again[$0]) }) { throw SyncError.http(status: 424, path: path) }
        }
        return refused
    }

    /// Sends a PROPPATCH; returns each property's status from a 207 response (none for another 2xx).
    private func proppatch(_ path: String, _ values: [CalendarProperty: String?]) async throws -> [CalendarProperty: Int] {
        var set = "", remove = ""
        for (p, v) in values.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let (ns, name) = p.element
            if let v { set += "<x:\(name) xmlns:x=\"\(ns)\">\(xmlEscape(v))</x:\(name)>" } else { remove += "<x:\(name) xmlns:x=\"\(ns)\"/>" }
        }
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propertyupdate xmlns:d=\"DAV:\">"
        if !set.isEmpty { body += "<d:set><d:prop>\(set)</d:prop></d:set>" }
        if !remove.isEmpty { body += "<d:remove><d:prop>\(remove)</d:prop></d:remove>" }
        body += "</d:propertyupdate>"
        let r = try await dav.send("PROPPATCH", path, collection: true, headers: xmlHeaders, body: Data(body.utf8))
        guard r.status == 207 || (200...299).contains(r.status) else { throw WebDAVClient.error(status: r.status, path: path) }
        guard r.status == 207 else { return [:] }
        if let doc = try? Multistatus.parse(r.data, maxEntries: 16) {
            var status: [CalendarProperty: Int] = [:]
            for response in doc.responses {
                for p in values.keys {
                    if let s = response.propertyStatus["\(p.element.ns)|\(p.element.name)"] { status[p] = s }
                }
            }
            return status
        }
        // An unreadable 207 that reports an error fails the whole update.
        if let text = String(data: r.data, encoding: .utf8), text.range(of: #"HTTP/1\.[01] [45]\d\d"#, options: .regularExpression) != nil {
            throw SyncError.http(status: 424, path: path)
        }
        return [:]
    }

    func deleteCalendar(_ path: String) async throws {
        let r = try await dav.send("DELETE", path, collection: true)
        guard (200...299).contains(r.status) || r.status == 404 else { throw WebDAVClient.error(status: r.status, path: path) }
    }

    func share(_ path: String, with user: String) async throws {
        let body = """
        <o:share xmlns:d="DAV:" xmlns:o="http://owncloud.org/ns"><o:set><d:href>principal:principals/users/\(xmlEscape(user))</d:href>\
        <o:read-write/></o:set></o:share>
        """
        let r = try await dav.send("POST", path, collection: true, headers: ["Content-Type": "application/xml"], body: Data(body.utf8))
        guard (200...299).contains(r.status) else {
            // A server without Nextcloud's sharing has no POST here.
            if r.status == 405 || r.status == 501 { throw SyncError.sharingUnsupported }
            throw WebDAVClient.error(status: r.status, path: path)
        }
    }

    // MARK: - Tasks

    func put(_ path: String, ics: String, ifMatch: String?) async throws -> String? {
        var headers = ["Content-Type": "text/calendar; charset=utf-8"]
        if let ifMatch { headers["If-Match"] = ifMatch } else { headers["If-None-Match"] = "*" }
        let r = try await dav.send("PUT", path, headers: headers, body: Data(ics.utf8))
        guard (200...299).contains(r.status) else { throw WebDAVClient.error(status: r.status, path: path) }
        return r.etag
    }

    func move(_ path: String, to destination: String, ifMatch: String?) async throws {
        var headers = ["Destination": try dav.absoluteString(for: destination), "Overwrite": "F"]
        if let ifMatch { headers["If-Match"] = ifMatch }
        let r = try await dav.send("MOVE", path, headers: headers)
        guard (200...299).contains(r.status) else { throw WebDAVClient.error(status: r.status, path: path) }
    }

    func delete(_ path: String, ifMatch: String?) async throws {
        let r = try await dav.send("DELETE", path, headers: ifMatch.map { ["If-Match": $0] } ?? [:])
        guard (200...299).contains(r.status) || r.status == 404 else { throw WebDAVClient.error(status: r.status, path: path) }
    }

    // MARK: - Helpers

    private let xmlHeaders = ["Content-Type": "application/xml; charset=utf-8"]

    private func multistatus(_ method: String, _ path: String, collection: Bool, depth: String?, body: String,
                             maxEntries: Int = SyncLimits.maxListingEntries) async throws -> Multistatus.Document {
        var headers = xmlHeaders
        if let depth { headers["Depth"] = depth }
        let r = try await dav.send(method, path, collection: collection, headers: headers, body: Data(body.utf8))
        switch r.status {
        case 207:
            do {
                guard let doc = try Multistatus.parse(r.data, maxEntries: maxEntries) else { throw SyncError.notCalDAV }
                return doc
            } catch Multistatus.Failure.tooManyEntries {
                throw SyncError.limitExceeded("more than \(maxEntries) entries in “\(path)”")
            } catch let e as SyncError {
                throw e
            } catch {
                throw SyncError.badRemoteData(path: path, reason: "the response is not plain WebDAV XML (\(error))")
            }
        case 200...299: throw SyncError.notCalDAV
        default: throw WebDAVClient.error(status: r.status, path: path)
        }
    }

    /// Whether `path` is a direct child of `parent` ("" is the DAV root).
    static func isChild(_ path: String, of parent: String) -> Bool {
        let name: Substring
        if parent.isEmpty {
            name = Substring(path)
        } else {
            guard path.hasPrefix(parent + "/") else { return false }
            name = path.dropFirst(parent.count + 1)
        }
        return !name.isEmpty && !name.contains("/")
    }

    /// Whether a Nextcloud `owner-principal` ("principals/users/tim") is this user: the principal
    /// named after the username, or the discovered one (the login name can differ from the user id).
    private func isOwnPrincipal(_ owner: String) -> Bool {
        let trimmed = owner.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == "principals/users/\(username)" { return true }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        guard let principalPath, !decoded.isEmpty else { return false }
        return principalPath == decoded || principalPath.hasSuffix("/" + decoded)
    }
}

/// The path of `child` in the collection `parent`, both relative to the DAV root ("" is the root).
func davPath(_ parent: String, _ child: String) -> String {
    parent.isEmpty ? child : "\(parent)/\(child)"
}

func xmlEscape(_ s: String) -> String {
    var out = ""
    for c in s {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(c)
        }
    }
    return out
}
