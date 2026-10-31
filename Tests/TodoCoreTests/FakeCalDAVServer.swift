import Foundation
@testable import TodoCore

/// In-memory CalDAV server for sync tests: calendars with properties and sync tokens (RFC 6578
/// semantics: changes and removals since a token), objects with ETags and conditional writes. Its
/// calendar home follows `layout` (by default Nextcloud's).
actor FakeCalDAVServer: CalDAVServer {
    nonisolated let home: String
    nonisolated let calendarHome: CalendarHome
    nonisolated let layout: FakeDAVLayout

    struct Calendar {
        var props: RemoteCalendar
        var components = ["VTODO"]
        var sharedBy: String?
    }

    private(set) var calendarsByPath: [String: Calendar] = [:]
    private(set) var objects: [String: (etag: String, ics: String)] = [:]
    /// Version at which each object (or its removal) happened, per calendar.
    private var changeLog: [String: [String: (version: Int, removed: Bool)]] = [:]
    private var version = 0
    private var etagCounter = 0

    /// Request counts by method ("PROPFIND", "REPORT", "PUT", ...).
    private(set) var requests: [String: Int] = [:]
    private(set) var shares: [(path: String, user: String)] = []
    var failShares = false
    var failMoves = false
    /// Calendar paths whose MKCALENDAR fails with 429 (Nextcloud's creation rate limit).
    var rateLimitedCreates: Set<String> = []
    /// Called before each PUT; lets tests change an object "concurrently".
    var beforePut: (@Sendable (String) async -> Void)?
    /// Called once at the next calendar listing.
    var beforeList: (@Sendable () async -> Void)?
    /// The calendar home answers 404 (it moved or was removed).
    var homeGone = false
    /// Connections made without a known home (`connect(cached: nil)`): discoveries.
    private(set) var discoveries = 0

    init(user: String = "tim", layout: FakeDAVLayout? = nil) {
        let layout = layout ?? .nextcloud(user: user)
        self.layout = layout
        home = layout.homePath
        calendarHome = layout.calendarHome
    }

    /// What `CalDAVClient.connect` does for this server: discovery when there is no home yet.
    func connect(cached: CalendarHome?) -> FakeCalDAVServer {
        if cached == nil { discoveries += 1 }
        return self
    }

    // MARK: - Test helpers

    func addCalendar(_ uri: String, name: String? = nil, components: [String] = ["VTODO"], sharedBy: String? = nil,
                     sections: String? = nil, labels: String? = nil, color: String? = nil) {
        let path = davPath(home, uri)
        calendarsByPath[path] = Calendar(props: RemoteCalendar(path: path, name: name ?? uri, color: color, order: "1",
                                                               sections: sections, labels: labels),
                                         components: components, sharedBy: sharedBy)
        changeLog[path] = [:]
        bump(path)
    }

    /// Writes an object directly (as another client would).
    @discardableResult
    func store(_ path: String, _ ics: String) -> String {
        etagCounter += 1
        let etag = "\"e\(etagCounter)\""
        objects[path] = (etag, ics)
        record(path, removed: false)
        return etag
    }

    func remove(_ path: String) {
        objects[path] = nil
        record(path, removed: true)
    }

    func setProperty(_ path: String, _ p: CalendarProperty, _ value: String?) {
        set(p, value, on: &calendarsByPath[path]!.props)
        bump(path)
    }

    func removeCalendar(_ path: String) {
        calendarsByPath[path] = nil
        for key in objects.keys where key.hasPrefix(path + "/") { objects[key] = nil }
    }

    func ics(_ path: String) -> String? { objects[path]?.ics }
    func paths(in calendar: String) -> [String] { objects.keys.filter { $0.hasPrefix(calendar + "/") }.sorted() }
    func count(_ method: String) -> Int { requests[method, default: 0] }
    func resetCounts() { requests = [:] }
    func setFailShares(_ v: Bool) { failShares = v }
    func setFailMoves(_ v: Bool) { failMoves = v }
    func setRateLimitedCreates(_ v: Set<String>) { rateLimitedCreates = v }
    func setBeforePut(_ f: (@Sendable (String) async -> Void)?) { beforePut = f }
    func setBeforeList(_ f: (@Sendable () async -> Void)?) { beforeList = f }
    func setHomeGone(_ v: Bool) { homeGone = v }

    private func bump(_ calendar: String) {
        version += 1
        calendarsByPath[calendar]?.props.syncToken = "v\(version)"
    }

    private func record(_ path: String, removed: Bool) {
        let cal = String(path[..<path.lastIndex(of: "/")!])
        version += 1
        changeLog[cal, default: [:]][path] = (version, removed)
        calendarsByPath[cal]?.props.syncToken = "v\(version)"
    }

    private func set(_ p: CalendarProperty, _ value: String?, on props: inout RemoteCalendar) {
        switch p {
        case .name: props.name = value
        case .color: props.color = value
        case .order: props.order = value.map { String(Int((Double($0) ?? 0).rounded())) }  // Nextcloud stores an integer
        case .sections: props.sections = value
        case .labels: props.labels = value
        }
    }

    private func note(_ m: String) { requests[m, default: 0] += 1 }

    // MARK: - CalDAVServer

    func calendars() async throws -> [RemoteCalendar] {
        if let f = beforeList {
            beforeList = nil
            await f()
        }
        note("PROPFIND")
        if homeGone { throw home.isEmpty ? SyncError.baseNotFound : SyncError.notFound(home) }
        return calendarsByPath.values.filter { $0.components == ["VTODO"] && $0.sharedBy == nil }.map(\.props)
    }

    func changes(in calendar: String, since token: String?) async throws -> CalendarChanges {
        note("REPORT")
        guard let cal = calendarsByPath[calendar] else { throw SyncError.notFound(calendar) }
        let since = token.flatMap { Int($0.dropFirst()) }
        var out = CalendarChanges(syncToken: cal.props.syncToken, changed: [], removed: [], isFull: since == nil)
        for (path, entry) in changeLog[calendar, default: [:]] where since == nil || entry.version > since! {
            if let o = objects[path] {
                out.changed.append(RemoteResource(path: path, etag: o.etag, ics: o.ics))
            } else if since != nil {
                out.removed.append(path)
            }
        }
        return out
    }

    func createCalendar(_ path: String, name: String, color: String, order: String) async throws {
        note("MKCALENDAR")
        if rateLimitedCreates.contains(path) { throw SyncError.rateLimited(path) }
        guard calendarsByPath[path] == nil else { throw SyncError.calendarExists(path) }
        calendarsByPath[path] = Calendar(props: RemoteCalendar(path: path, name: name, color: color, order: order))
        changeLog[path] = [:]
        bump(path)
    }

    func setProperties(_ path: String, _ values: [CalendarProperty: String?]) async throws {
        note("PROPPATCH")
        guard calendarsByPath[path] != nil else { throw SyncError.notFound(path) }
        for (k, v) in values { set(k, v, on: &calendarsByPath[path]!.props) }
        bump(path)
    }

    func deleteCalendar(_ path: String) async throws {
        note("DELETE-CALENDAR")
        removeCalendar(path)
    }

    func share(_ path: String, with user: String) async throws {
        note("POST")
        if failShares { throw SyncError.forbidden(path) }
        shares.append((path, user))
    }

    func put(_ path: String, ics: String, ifMatch: String?) async throws -> String? {
        if let beforePut { await beforePut(path) }
        note("PUT")
        let cal = String(path[..<path.lastIndex(of: "/")!])
        guard calendarsByPath[cal] != nil else { throw SyncError.conflict(path) }
        switch (ifMatch, objects[path]) {
        case (nil, _?): throw SyncError.preconditionFailed(path)
        case (let m?, let o?) where o.etag != m: throw SyncError.preconditionFailed(path)
        case (_?, nil): throw SyncError.preconditionFailed(path)
        default: break
        }
        XCTAssertValid(ics)
        return store(path, ics)
    }

    func move(_ path: String, to destination: String, ifMatch: String?) async throws {
        note("MOVE")
        if failMoves { throw SyncError.forbidden(path) }
        guard let o = objects[path] else { throw SyncError.notFound(path) }
        if let ifMatch, ifMatch != o.etag { throw SyncError.preconditionFailed(path) }
        guard objects[destination] == nil else { throw SyncError.preconditionFailed(destination) }
        remove(path)
        objects[destination] = o
        record(destination, removed: false)
    }

    func delete(_ path: String, ifMatch: String?) async throws {
        note("DELETE")
        guard let o = objects[path] else { return }
        if let ifMatch, ifMatch != o.etag { throw SyncError.preconditionFailed(path) }
        remove(path)
    }

    /// Every object TodoTim writes must parse and hold exactly one master VTODO.
    private func XCTAssertValid(_ ics: String) {
        guard let root = try? ICalendar.parse(ics), root.name == "VCALENDAR",
              root.components.filter({ $0.name == "VTODO" }).count >= 1 else {
            fatalError("invalid calendar object written:\n\(ics)")
        }
    }
}

/// Where a CalDAV server keeps the user's principal and calendar home, and how it answers
/// discovery over HTTP (`respond(to:)`, for `StubURLProtocol`). Paths are relative to the origin,
/// without slashes at either end.
struct FakeDAVLayout: Sendable {
    struct Collection: Sendable {
        var name: String
        /// `resourcetype` children, e.g. ["d:collection", "c:calendar"].
        var types: [String]
        var components: [String] = []
    }

    var user = "tim"
    /// "https://cloud.example.com"
    var origin: String
    /// The server URL the user enters (the DAV root).
    var root: String
    /// Where PROPFIND works (and names the principal); elsewhere the server answers 404.
    var davArea: String
    /// nil: the server has no `current-user-principal`.
    var principal: String?
    /// The principal's `calendar-home-set`; nil: none.
    var home: String?
    /// The origin in the `calendar-home-set` href, when the home is on another server (iCloud).
    var homeOrigin: String?
    /// Target of the redirect at `/.well-known/caldav` (a path, or an absolute URL); nil: 404.
    var wellKnown: String?
    /// What a Depth 1 PROPFIND of the home lists.
    var collections: [Collection] = []
    /// When set, requests without this password get 401.
    var password: String?

    static func nextcloud(user: String = "tim") -> FakeDAVLayout {
        FakeDAVLayout(user: user, origin: "https://cloud.example.com", root: "remote.php/dav", davArea: "remote.php/dav",
                      principal: "remote.php/dav/principals/users/\(user)", home: "remote.php/dav/calendars/\(user)",
                      wellKnown: "remote.php/dav/")
    }

    /// Radicale: the principal is the calendar home, "/<user>/"; no well-known redirect.
    static func radicale(user: String = "tim") -> FakeDAVLayout {
        FakeDAVLayout(user: user, origin: "http://localhost:5232", root: "", davArea: "", principal: user, home: user)
    }

    /// Xandikos: principal "/user/", calendar home "/user/calendars/".
    static let xandikos = FakeDAVLayout(origin: "http://localhost:8080", root: "", davArea: "", principal: "user",
                                        home: "user/calendars", wellKnown: "")

    /// A hosted service that answers WebDAV only below /dav/, found through /.well-known/caldav.
    static let hosted = FakeDAVLayout(user: "tim@example.com", origin: "https://caldav.example.com", root: "", davArea: "dav",
                                      principal: "dav/principals/user/tim@example.com",
                                      home: "dav/calendars/user/tim@example.com", wellKnown: "dav/")

    var serverURL: String { "\(origin)/" + (root.isEmpty ? "" : "\(root)/") }

    /// The calendar home relative to the DAV root, as `CalDAVClient` sees it.
    var homePath: String {
        guard let home else { return "calendars/\(user)" }
        if root.isEmpty { return home }
        if home.hasPrefix(root + "/") { return String(home.dropFirst(root.count + 1)) }
        return ""  // the home itself, or outside the server URL: the home is the DAV root
    }

    var calendarHome: CalendarHome {
        CalendarHome(url: home.map { "\(homeOrigin ?? origin)/\($0)/" } ?? "\(serverURL)calendars/\(user)/",
                     principal: principal.map { "\(origin)/\($0)/" })
    }

    /// An absolute-path href for `path`; "@" is percent-encoded, as some servers do.
    private func href(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed)! }
        return "/" + encoded.map { $0 + "/" }.joined()
    }

    func respond(to request: URLRequest) -> (Int, [String: String], Data) {
        guard let url = request.url, let segments = WebDAVClient.decodedSegments(url) else { return (400, [:], Data()) }
        if let password, request.value(forHTTPHeaderField: "Authorization")
            != "Basic " + Data("\(user):\(password)".utf8).base64EncodedString() {
            return (401, ["WWW-Authenticate": "Basic realm=\"dav\""], Data())
        }
        let path = segments.joined(separator: "/")
        guard request.httpMethod == "PROPFIND" else { return (405, [:], Data()) }
        if path == ".well-known/caldav" {
            guard let wellKnown else { return (404, [:], Data()) }
            return (301, ["Location": wellKnown.hasPrefix("http") ? wellKnown : "/" + wellKnown], Data())
        }
        guard davArea.isEmpty || path == davArea || path.hasPrefix(davArea + "/") else {
            return (404, ["Content-Type": "text/html"], Data("<html><body>Not found</body></html>".utf8))
        }
        let body = WebDAVClientTests.body(request) ?? ""
        var responses: [String] = []
        var props = ""
        if body.contains("current-user-principal"), let principal {
            props += "<d:current-user-principal><d:href>\(href(principal))</d:href></d:current-user-principal>"
        }
        if body.contains("calendar-home-set"), path == principal, let home {
            props += "<c:calendar-home-set><d:href>\(homeOrigin ?? "")\(href(home))</d:href></c:calendar-home-set>"
        }
        if request.value(forHTTPHeaderField: "Depth") == "1", path == home {
            props += "<d:resourcetype><d:collection/></d:resourcetype>"
            for c in collections {
                responses.append("""
                <d:response><d:href>\(href(path + "/" + c.name))</d:href><d:propstat><d:prop>\
                <d:resourcetype>\(c.types.map { "<\($0)/>" }.joined())</d:resourcetype>\
                <c:supported-calendar-component-set>\(c.components.map { "<c:comp name=\"\($0)\"/>" }.joined())\
                </c:supported-calendar-component-set><d:sync-token>http://example.com/sync/1</d:sync-token>\
                <d:displayname>\(c.name)</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                """)
            }
        }
        let own = props.isEmpty
            ? "<d:propstat><d:prop><d:current-user-principal/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>"
            : "<d:propstat><d:prop>\(props)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
        responses.insert("<d:response><d:href>\(href(path))</d:href>\(own)</d:response>", at: 0)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\(responses.joined())</d:multistatus>
        """
        return (207, ["Content-Type": "application/xml; charset=utf-8"], Data(xml.utf8))
    }
}

/// Last-writer-wins merge of whole databases entity by entity, then `SyncEngine.clean` (what two
/// devices editing the same entities converge to).
func lwwMerge(_ dbs: [Database], now: Date) -> Database {
    func merge<T: SyncEntity>(_ dicts: [[EntityID: T]]) -> [EntityID: T] {
        var out: [EntityID: T] = [:]
        for d in dicts { for (id, e) in d { out[id] = out[id].map { SyncEngine.winner($0, e) } ?? e } }
        return out
    }
    var db = Database()
    db.projects = merge(dbs.map(\.projects))
    db.sections = merge(dbs.map(\.sections))
    db.tasks = merge(dbs.map(\.tasks))
    db.labels = merge(dbs.map(\.labels))
    return SyncEngine.clean(db, now: now)
}
