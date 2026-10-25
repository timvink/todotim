import Foundation

/// A calendar in the user's calendar home, with the properties TodoTim syncs (raw values).
struct RemoteCalendar: Codable, Equatable, Sendable {
    /// Relative to the DAV root, without trailing slash: "calendars/tim/work".
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

    /// Last path segment (the calendar's URI on Nextcloud).
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
enum CalendarProperty: String, CaseIterable, Sendable {
    case name, color, order, sections, labels

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

/// The CalDAV operations sync needs. `CalDAVClient` implements them against Nextcloud; tests
/// use an in-memory server. Paths are relative to the DAV root and not percent-encoded.
protocol CalDAVServer: Sendable {
    /// "calendars/<user>".
    var home: String { get }
    /// The user's own calendars that hold only VTODOs (shared, subscribed and event calendars
    /// are left out).
    func calendars() async throws -> [RemoteCalendar]
    /// Changes in `calendar` since `token` (RFC 6578 sync-collection, with calendar data); with a
    /// nil or rejected token, the full content.
    func changes(in calendar: String, since token: String?) async throws -> CalendarChanges
    /// MKCALENDAR with a VTODO-only component set.
    func createCalendar(_ path: String, name: String, color: String, order: String) async throws
    /// PROPPATCH; a nil value removes the property.
    func setProperties(_ path: String, _ values: [CalendarProperty: String?]) async throws
    func deleteCalendar(_ path: String) async throws
    /// Shares a calendar read-write with another user (Nextcloud sharing).
    func share(_ path: String, with user: String) async throws
    /// PUT a calendar object: `ifMatch` nil creates it (`If-None-Match: *`). Returns the new ETag if reported.
    func put(_ path: String, ics: String, ifMatch: String?) async throws -> String?
    /// MOVE a calendar object to another calendar (`If-Match` on the source).
    func move(_ path: String, to destination: String, ifMatch: String?) async throws
    /// DELETE a calendar object; succeeds if it is already gone.
    func delete(_ path: String, ifMatch: String?) async throws
}

/// CalDAV over `WebDAVClient`, for Nextcloud (`docs/caldav.md`). Server data is validated:
/// paths must be direct children of the calendar home / calendar, and responses are bounded.
final class CalDAVClient: CalDAVServer {
    static let todotimNS = "https://todotim.app/ns"
    private static let caldavNS = "urn:ietf:params:xml:ns:caldav"

    let dav: WebDAVClient
    let username: String
    let home: String
    /// Pages of a sync-collection REPORT followed before giving up.
    static let maxPages = 100

    init(dav: WebDAVClient, username: String) {
        self.dav = dav
        self.username = username
        self.home = "calendars/\(username)"
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
        <d:propfind xmlns:d="DAV:" xmlns:c="\(Self.caldavNS)" xmlns:oc="http://owncloud.org/ns"><d:prop>\
        <d:resourcetype/><c:supported-calendar-component-set/><d:sync-token/><oc:owner-principal/>\(props)\
        </d:prop></d:propfind>
        """
        let doc = try await multistatus("PROPFIND", home, collection: true, depth: "1", body: body)
        var out: [RemoteCalendar] = []
        for r in doc.responses {
            guard let path = dav.relativePath(ofHref: r.href), isChild(path, of: home),
                  r.properties["DAV:|resourcetype"]?.children.contains("\(Self.caldavNS)|calendar") == true,
                  r.properties["\(Self.caldavNS)|supported-calendar-component-set"]?.children == ["\(Self.caldavNS)|comp=VTODO"]
            else { continue }
            // Calendars shared by other users also appear in the home (Nextcloud names them
            // "<uri>_shared_by_<owner>"); only the user's own are synced. Calendars that Nextcloud
            // apps generate (such as Deck boards, "app-generated--…") are read-only.
            if path.split(separator: "/").last?.hasPrefix("app-generated--") == true { continue }
            if let owner = r.text("http://owncloud.org/ns|owner-principal"),
               owner.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != "principals/users/\(username)" { continue }
            func value(_ p: CalendarProperty) -> String? { r.text("\(p.element.ns)|\(p.element.name)") }
            out.append(RemoteCalendar(path: path, name: value(.name), color: value(.color), order: value(.order),
                                      sections: value(.sections), labels: value(.labels),
                                      syncToken: r.text("DAV:|sync-token").flatMap { $0.isEmpty ? nil : $0 }))
        }
        return out
    }

    func changes(in calendar: String, since token: String?) async throws -> CalendarChanges {
        var result = CalendarChanges(syncToken: token, changed: [], removed: [], isFull: token == nil)
        var seen: [String: Int] = [:]
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
            } catch let error as SyncError where result.syncToken != nil {
                // valid-sync-token precondition failed (RFC 6578 §3.2, 403 or 409): start over.
                switch error {
                case .forbidden, .conflict:
                    result = CalendarChanges(syncToken: nil, changed: [], removed: [], isFull: true)
                    seen = [:]
                    continue
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
                guard isChild(path, of: calendar) else { continue }
                if r.status == 404 {
                    result.removed.append(path)
                    if let i = seen.removeValue(forKey: path) { result.changed[i].ics = "" }
                } else if let ics = r.text("\(Self.caldavNS)|calendar-data"), !ics.isEmpty {
                    let res = RemoteResource(path: path, etag: WebDAVClient.normalizeETag(r.text("DAV:|getetag")), ics: ics)
                    result.removed.removeAll { $0 == path }
                    if let i = seen[path] { result.changed[i] = res } else {
                        seen[path] = result.changed.count
                        result.changed.append(res)
                    }
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
        result.changed.removeAll { $0.ics.isEmpty }
        guard result.changed.count <= SyncLimits.maxTasks else {
            throw SyncError.limitExceeded("more than \(SyncLimits.maxTasks) tasks in “\(calendar)”")
        }
        return result
    }

    func createCalendar(_ path: String, name: String, color: String, order: String) async throws {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <c:mkcalendar xmlns:d="DAV:" xmlns:c="\(Self.caldavNS)" xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop>\
        <d:displayname>\(xmlEscape(name))</d:displayname><a:calendar-color>\(xmlEscape(color))</a:calendar-color>\
        <a:calendar-order>\(xmlEscape(order))</a:calendar-order>\
        <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>\
        </d:prop></d:set></c:mkcalendar>
        """
        let r = try await dav.send("MKCALENDAR", path, collection: true, headers: xmlHeaders, body: Data(body.utf8))
        switch r.status {
        case 200...299: return
        case 405: throw SyncError.calendarExists(path)
        default: throw WebDAVClient.error(status: r.status, path: path)
        }
    }

    func setProperties(_ path: String, _ values: [CalendarProperty: String?]) async throws {
        guard !values.isEmpty else { return }
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
        // A 207 reports a status per property; any failure fails the whole update (RFC 4918 §9.2).
        if r.status == 207, let text = String(data: r.data, encoding: .utf8),
           text.range(of: #"HTTP/1\.[01] [45]\d\d"#, options: .regularExpression) != nil {
            throw SyncError.http(status: 424, path: path)
        }
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
        guard (200...299).contains(r.status) else { throw WebDAVClient.error(status: r.status, path: path) }
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

    private func isChild(_ path: String, of parent: String) -> Bool {
        path.hasPrefix(parent + "/") && !path.dropFirst(parent.count + 1).contains("/")
    }
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
