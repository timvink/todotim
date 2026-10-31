import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TodoCore

/// Realistic Nextcloud response to PROPFIND Depth 1 on a calendar home (trimmed).
private let calendarHome = """
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:response><d:href>/remote.php/dav/calendars/tim/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/todotim-inbox/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
   <d:sync-token>http://sabre.io/ns/sync/7</d:sync-token>
   <oc:owner-principal>principals/users/tim</oc:owner-principal>
   <d:displayname>Inbox</d:displayname>
   <x1:calendar-color xmlns:x1="http://apple.com/ns/ical/">#808080</x1:calendar-color>
   <x2:labels xmlns:x2="https://todotim.app/ns">[{&quot;id&quot;:&quot;l1&quot;,&quot;name&quot;:&quot;A &amp; B&quot;,&quot;order&quot;:1}]</x2:labels>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  <d:propstat><d:prop><x2:sections xmlns:x2="https://todotim.app/ns"/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/personal/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VEVENT"/><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
   <oc:owner-principal>principals/users/tim</oc:owner-principal>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/list_shared_by_bob/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
   <oc:owner-principal>principals/users/bob</oc:owner-principal>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/inbox/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/><cal:schedule-inbox/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>https://evil.example.com/remote.php/dav/calendars/tim/evil/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>
"""

private let syncCollection = """
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
 <d:response><d:href>/remote.php/dav/calendars/tim/work/a.ics</d:href>
  <d:propstat><d:prop><d:getetag>&quot;e1&quot;</d:getetag><cal:calendar-data>BEGIN:VCALENDAR
BEGIN:VTODO
UID:a
END:VTODO
END:VCALENDAR
</cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/work/gone.ics</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/work/sub/nested.ics</d:href>
  <d:propstat><d:prop><cal:calendar-data>x</cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/work/%2E%2E</d:href>
  <d:propstat><d:prop><cal:calendar-data>x</cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:sync-token>http://sabre.io/ns/sync/9</d:sync-token>
</d:multistatus>
"""

final class WebDAVClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    func testParsesMultistatusProperties() throws {
        let doc = try XCTUnwrap(try Multistatus.parse(Data(calendarHome.utf8)))
        XCTAssertEqual(doc.responses.count, 6)
        let inbox = doc.responses[1]
        XCTAssertEqual(inbox.text("DAV:|displayname"), "Inbox")
        XCTAssertEqual(inbox.properties["DAV:|resourcetype"]?.children, ["DAV:|collection", "urn:ietf:params:xml:ns:caldav|calendar"])
        XCTAssertEqual(inbox.properties["urn:ietf:params:xml:ns:caldav|supported-calendar-component-set"]?.children,
                       ["urn:ietf:params:xml:ns:caldav|comp=VTODO"])
        XCTAssertEqual(inbox.text("https://todotim.app/ns|labels"), #"[{"id":"l1","name":"A & B","order":1}]"#)
        XCTAssertNil(inbox.properties["https://todotim.app/ns|sections"], "properties in a 404 propstat are ignored")

        let changes = try XCTUnwrap(try Multistatus.parse(Data(syncCollection.utf8)))
        XCTAssertEqual(changes.syncToken, "http://sabre.io/ns/sync/9")
        XCTAssertEqual(changes.responses[1].status, 404)
        XCTAssertTrue(changes.responses[0].text("urn:ietf:params:xml:ns:caldav|calendar-data")!.contains("UID:a"))
    }

    func testRejectsNonMultistatus() throws {
        XCTAssertNil(try Multistatus.parse(Data("<html><body>Nextcloud</body></html>".utf8)))
        XCTAssertNil(try Multistatus.parse(Data("not xml".utf8)))
    }

    func testParserRefusesDTDAndCapsEntries() throws {
        let xxe = """
        <?xml version="1.0"?>
        <!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>&x;</d:href></d:response></d:multistatus>
        """
        XCTAssertThrowsError(try Multistatus.parse(Data(xxe.utf8)))
        XCTAssertThrowsError(try Multistatus.parse(Data(calendarHome.utf8), maxEntries: 3)) {
            guard case Multistatus.Failure.tooManyEntries = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Multistatus.parse(Data(calendarHome.utf8), maxEntries: 6)?.responses.count, 6)
    }

    func testBaseURLNormalizationAndPathEncoding() throws {
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("https://tim:pw@cloud.example.com/dav/"))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("https://cloud.example.com/dav/?x=1"))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL(""))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("ftp://x/"))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("cloud.example.com"))
        let client = try WebDAVClient(serverURL: "  https://cloud.example.com/remote.php/dav ", username: "tim", password: "pw")
        XCTAssertEqual(client.baseURL.absoluteString, "https://cloud.example.com/remote.php/dav/")
        XCTAssertEqual(try client.url(for: "calendars/tim v/a#b?.ics").absoluteString,
                       "https://cloud.example.com/remote.php/dav/calendars/tim%20v/a%23b%3F.ics")
        XCTAssertEqual(try client.url(for: "/calendars/tim/", collection: true).absoluteString,
                       "https://cloud.example.com/remote.php/dav/calendars/tim/")
    }

    func testDAVRootFromServerURL() throws {
        XCTAssertEqual(try CalDAVClient.davRoot("https://c.example.com/remote.php/dav").absoluteString,
                       "https://c.example.com/remote.php/dav/")
        XCTAssertEqual(try CalDAVClient.davRoot("https://c.example.com/remote.php/dav/files/tim/").absoluteString,
                       "https://c.example.com/remote.php/dav/", "an old files URL still works")
        XCTAssertThrowsError(try CalDAVClient.davRoot("http://c.example.com/remote.php/dav/"))
    }

    func testPlainHTTPOnlyForLocalhost() throws {
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("http://cloud.example.com/dav/")) { error in
            XCTAssertEqual(error as? SyncError, .insecureURL("http://cloud.example.com/dav/"))
            XCTAssertTrue((error as? SyncError)?.errorDescription?.contains("https://") == true)
        }
        for ok in ["http://localhost:8080/dav/", "http://127.0.0.1/dav/", "http://[::1]:8080/dav/", "HTTP://LOCALHOST/"] {
            XCTAssertNoThrow(try WebDAVClient.normalizedBaseURL(ok), ok)
        }
    }

    func testRefusesDotAndEmptySegments() async throws {
        let client = try makeClient()
        for bad in ["a/../b", "..", "calendars/tim/../../outside", "./x", "a//b", "a/./b"] {
            XCTAssertThrowsError(try client.url(for: bad), bad) { XCTAssertEqual($0 as? SyncError, .invalidPath(bad)) }
        }
        StubURLProtocol.handler = { _ in (200, [:], Data()) }
        do {
            _ = try await client.send("GET", "calendars/../../outside")
            XCTFail("expected invalidPath")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalidPath("calendars/../../outside"))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no request is sent for an unsafe path")
        XCTAssertEqual(try client.url(for: "a/..b/c..ics").absoluteString,
                       "https://cloud.example.com/remote.php/dav/a/..b/c..ics")
    }

    func testRelativePathOfHrefStaysInsideBase() throws {
        let client = try makeClient()
        XCTAssertEqual(client.relativePath(ofHref: "/remote.php/dav/calendars/tim/work/a%20b.ics"), "calendars/tim/work/a b.ics")
        XCTAssertEqual(client.relativePath(ofHref: "https://cloud.example.com/remote.php/dav/calendars/tim/"), "calendars/tim")
        for bad in ["https://evil.example.com/remote.php/dav/calendars/tim/x.ics",
                    "https://cloud.example.com:8443/remote.php/dav/calendars/tim/x.ics",
                    "/remote.php/other/x.ics", "/remote.php/dav/../x",
                    "/remote.php/dav/calendars/tim/%2E%2E/x", "/remote.php/dav/calendars/tim/a%2Fb.ics"] {
            XCTAssertNil(client.relativePath(ofHref: bad), bad)
        }
    }

    /// Xandikos answers 423 (Locked) to a write while it writes another one: sent again.
    func testLockedRequestsAreSentAgain() async throws {
        let client = try makeClient()
        client.lockedRetryDelay = .milliseconds(1)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            return calls < 3 ? (423, [:], Data()) : (204, ["ETag": "\"e2\""], Data())
        }
        let r = try await client.send("PUT", "calendars/tim/work/a.ics", headers: ["If-Match": "\"e1\""], body: Data("x".utf8))
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-Match") == "\"e1\"" })

        StubURLProtocol.requests = []
        StubURLProtocol.handler = { _ in (423, [:], Data()) }
        let locked = try await client.send("PUT", "calendars/tim/work/a.ics")
        XCTAssertEqual(locked.status, 423, "a lasting lock is reported")
        XCTAssertEqual(StubURLProtocol.requests.count, 1 + WebDAVClient.lockedRetries)
    }

    func testResponseBodyIsCapped() async throws {
        let client = try makeClient()
        client.maxResponseBytes = 100_000
        // No Content-Length: the limit is enforced while reading.
        StubURLProtocol.handler = { _ in (200, [:], Data(count: 300_000)) }
        do {
            _ = try await client.send("GET", "calendars/tim/x.ics")
            XCTFail("expected limitExceeded")
        } catch {
            guard case .limitExceeded? = error as? SyncError else { return XCTFail("\(error)") }
        }
        StubURLProtocol.handler = { _ in (200, [:], Data(count: 90_000)) }
        let data = try await client.send("GET", "calendars/tim/x.ics").data
        XCTAssertEqual(data.count, 90_000)
    }

    #if !canImport(FoundationNetworking)  // the Linux URLSession cannot redirect from a URLProtocol stub
    func testRedirectsOutsideBaseAreRefused() async throws {
        let client = try makeClient()
        for target in ["https://evil.example.com/remote.php/dav/calendars/tim/x.ics",
                       "http://cloud.example.com/remote.php/dav/calendars/tim/x.ics",
                       "https://cloud.example.com:8443/remote.php/dav/calendars/tim/x.ics",
                       "https://cloud.example.com/remote.php/other/x.ics"] {
            StubURLProtocol.requests = []
            StubURLProtocol.handler = { req in
                req.url!.absoluteString == target ? (200, [:], Data("leaked".utf8)) : (307, ["Location": target], Data())
            }
            do {
                _ = try await client.send("GET", "calendars/tim/x.ics")
                XCTFail("expected redirectRejected for \(target)")
            } catch {
                guard case .redirectRejected? = error as? SyncError else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "redirect to \(target) is not followed")
        }
        // A redirect inside the base URL is followed.
        let inside = "https://cloud.example.com/remote.php/dav/calendars/tim/moved.ics"
        StubURLProtocol.handler = { req in
            req.url!.absoluteString == inside ? (200, [:], Data("ok".utf8)) : (307, ["Location": inside], Data())
        }
        let data = try await client.send("GET", "calendars/tim/x.ics").data
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
    }
    #endif

    func testErrorMessages() {
        XCTAssertEqual(WebDAVClient.error(status: 401, path: "x").errorDescription, "Wrong username or app password")
        XCTAssertEqual(WebDAVClient.error(status: 404, path: ""), .baseNotFound)
        XCTAssertTrue(WebDAVClient.error(status: 404, path: "").errorDescription!.hasPrefix("Server URL not found"))
        XCTAssertEqual(WebDAVClient.error(status: 404, path: "a/b"), .notFound("a/b"))
        XCTAssertEqual(WebDAVClient.error(status: 412, path: "a"), .preconditionFailed("a"))
        XCTAssertEqual(WebDAVClient.error(status: 507, path: "a"), .insufficientStorage)
    }

    // MARK: - CalDAV requests via a stub URLProtocol (no network)

    private func makeClient() throws -> WebDAVClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return try WebDAVClient(serverURL: "https://cloud.example.com/remote.php/dav/",
                                username: "tim", password: "app-pass", session: URLSession(configuration: config))
    }

    func testListsOnlyOwnTaskCalendars() async throws {
        StubURLProtocol.handler = { _ in (207, [:], Data(calendarHome.utf8)) }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        let calendars = try await caldav.calendars()
        XCTAssertEqual(calendars, [RemoteCalendar(path: "calendars/tim/todotim-inbox", name: "Inbox", color: "#808080",
                                                  labels: #"[{"id":"l1","name":"A & B","order":1}]"#,
                                                  syncToken: "http://sabre.io/ns/sync/7")])
        let req = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(req.httpMethod, "PROPFIND")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(req.url?.absoluteString, "https://cloud.example.com/remote.php/dav/calendars/tim/")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("tim:app-pass".utf8).base64EncodedString())
    }

    /// Nextcloud with a login name that is not the user id (LDAP, e-mail login): the calendars'
    /// owner-principal is the user id, which the discovered principal names.
    func testOwnCalendarsAreRecognizedByTheDiscoveredPrincipal() async throws {
        StubURLProtocol.handler = { _ in (207, [:], Data(calendarHome.utf8)) }
        let principal = CalendarHome(url: "https://cloud.example.com/remote.php/dav/calendars/tim/",
                                     principal: "https://cloud.example.com/remote.php/dav/principals/users/tim/")
        let discovered = CalDAVClient(dav: try makeClient(), username: "tim@example.com", home: "calendars/tim", calendarHome: principal)
        let listed = try await discovered.calendars()
        XCTAssertEqual(listed.map(\.uri), ["todotim-inbox"], "the calendar shared by bob stays out")
        let guessed = CalDAVClient(dav: try makeClient(), username: "tim@example.com", home: "calendars/tim")
        let none = try await guessed.calendars()
        XCTAssertEqual(none, [], "without the principal, the login name does not match the owner")
    }

    func testPathsAreComparedDecodedAndHomeCanBeTheRoot() throws {
        let client = try WebDAVClient(serverURL: "https://dav.example.com/dav/calendars/user/tim@example.com/",
                                      username: "tim@example.com", password: "pw")
        XCTAssertEqual(client.relativePath(ofHref: "/dav/calendars/user/tim%40example.com/work/"), "work")
        XCTAssertEqual(client.relativePath(ofHref: "https://dav.example.com/dav/calendars/user/tim@example.com/"), "")
        XCTAssertNil(client.relativePath(ofHref: "/dav/calendars/user/bob%40example.com/work/"))
        XCTAssertTrue(CalDAVClient.isChild("work", of: ""))
        XCTAssertFalse(CalDAVClient.isChild("", of: ""))
        XCTAssertFalse(CalDAVClient.isChild("work/a.ics", of: ""))
        XCTAssertTrue(CalDAVClient.isChild("work/a.ics", of: "work"))
        XCTAssertFalse(CalDAVClient.isChild("work2/a.ics", of: "work"))
        XCTAssertEqual(davPath("", "work"), "work")
        XCTAssertEqual(davPath("tim", "work"), "tim/work")
    }

    func testSyncCollectionKeepsOnlyDirectChildren() async throws {
        StubURLProtocol.handler = { _ in (207, [:], Data(syncCollection.utf8)) }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        let changes = try await caldav.changes(in: "calendars/tim/work", since: "http://sabre.io/ns/sync/3")
        XCTAssertEqual(changes.changed.map(\.path), ["calendars/tim/work/a.ics"])
        XCTAssertEqual(changes.changed.first?.etag, "\"e1\"")
        XCTAssertEqual(changes.removed, ["calendars/tim/work/gone.ics"])
        XCTAssertEqual(changes.syncToken, "http://sabre.io/ns/sync/9")
        XCTAssertFalse(changes.isFull)
        let body = try XCTUnwrap(StubURLProtocol.requests.first.flatMap(Self.body))
        XCTAssertTrue(body.contains("<d:sync-token>http://sabre.io/ns/sync/3</d:sync-token>"), body)

        // A rejected token (403 valid-sync-token) falls back to a full listing.
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (403, [:], Data()) : (207, [:], Data(syncCollection.utf8))
        }
        let full = try await caldav.changes(in: "calendars/tim/work", since: "stale")
        XCTAssertTrue(full.isFull)
        XCTAssertEqual(full.changed.count, 1)
    }

    /// A server without sync-collection (RFC 6578 is optional in CalDAV): the getctag serves as the
    /// sync token, and a calendar-query lists the whole calendar.
    func testServerWithoutSyncCollectionIsListedByCalendarQuery() async throws {
        let listing = """
        <d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">
         <d:response><d:href>/remote.php/dav/calendars/tim/work/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
          <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
          <cs:getctag>42</cs:getctag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          <d:propstat><d:prop><d:sync-token/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        let query = syncCollection.replacingOccurrences(of: " <d:sync-token>http://sabre.io/ns/sync/9</d:sync-token>\n", with: "")
        StubURLProtocol.handler = { req in
            if req.httpMethod == "PROPFIND" { return (207, [:], Data(listing.utf8)) }
            return Self.body(req)?.contains("sync-collection") == true ? (501, [:], Data()) : (207, [:], Data(query.utf8))
        }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        let calendars = try await caldav.calendars()
        XCTAssertEqual(calendars.map(\.syncToken), ["ctag:42"])

        let changes = try await caldav.changes(in: "calendars/tim/work", since: "ctag:41")
        XCTAssertEqual(changes.changed.map(\.path), ["calendars/tim/work/a.ics"])
        XCTAssertEqual(changes.removed, [])
        XCTAssertTrue(changes.isFull)
        XCTAssertNil(changes.syncToken)
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertTrue(Self.body(request)?.contains("<c:calendar-query") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")

        // Before any token is stored, a refused sync-collection falls back to calendar-query.
        StubURLProtocol.requests = []
        let first = try await caldav.changes(in: "calendars/tim/work", since: nil)
        XCTAssertEqual(first.changed.map(\.path), ["calendars/tim/work/a.ics"])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    /// Xandikos answers sync-collection with ETags but no calendar data (calendar-data 404): the
    /// objects are fetched with calendar-multiget. An object it cannot return fails the listing
    /// instead of looking deleted.
    func testObjectsWithoutDataAreFetchedWithMultiget() async throws {
        func response(_ name: String, data: Bool) -> String {
            """
            <d:response><d:href>/remote.php/dav/calendars/tim/work/\(name)</d:href>\
            <d:propstat><d:prop><d:getetag>"e-\(name)"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>\
            <d:propstat><d:prop><cal:calendar-data\(data ? ">BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:\(name)\nEND:VTODO\nEND:VCALENDAR\n</cal:calendar-data>" : "/>")\
            </d:prop><d:status>HTTP/1.1 \(data ? "200 OK" : "404 Not Found")</d:status></d:propstat></d:response>
            """
        }
        func multistatus(_ responses: String) -> Data {
            Data("""
            <d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">\(responses)\
            <d:sync-token>http://example.com/sync/2</d:sync-token></d:multistatus>
            """.utf8)
        }
        let gone = "<d:response><d:href>/remote.php/dav/calendars/tim/work/b.ics</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
        var omit = false
        StubURLProtocol.handler = { req in
            let body = Self.body(req) ?? ""
            if body.contains("sync-collection") { return (207, [:], multistatus(response("a.ics", data: false) + response("b.ics", data: false))) }
            return (207, [:], multistatus((omit ? "" : response("a.ics", data: true)) + gone))
        }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        let changes = try await caldav.changes(in: "calendars/tim/work", since: nil)
        XCTAssertEqual(changes.changed.map(\.path), ["calendars/tim/work/a.ics"])
        XCTAssertTrue(changes.changed[0].ics.contains("UID:a.ics"))
        XCTAssertEqual(changes.changed[0].etag, "\"e-a.ics\"")
        XCTAssertEqual(changes.removed, ["calendars/tim/work/b.ics"], "gone since the listing")
        XCTAssertEqual(changes.syncToken, "http://example.com/sync/2")
        let multiget = try XCTUnwrap(StubURLProtocol.requests.last.flatMap(Self.body))
        XCTAssertTrue(multiget.contains("<c:calendar-multiget"), multiget)
        XCTAssertTrue(multiget.contains("<d:href>/remote.php/dav/calendars/tim/work/a.ics</d:href>"), multiget)

        omit = true
        do {
            _ = try await caldav.changes(in: "calendars/tim/work", since: nil)
            XCTFail("expected badRemoteData")
        } catch {
            guard case .badRemoteData? = error as? SyncError else { return XCTFail("\(error)") }
        }
    }

    /// An object listed with failed properties (neither data nor ETag) is fetched with
    /// calendar-multiget too. If that fails as well, the full listing fails: leaving the object out
    /// would make its task look deleted.
    func testObjectWithFailedPropertiesIsFetchedOrFailsTheListing() async throws {
        let failed = """
        <d:response><d:href>/remote.php/dav/calendars/tim/work/b.ics</d:href><d:propstat><d:prop><d:getetag/>\
        <cal:calendar-data/></d:prop><d:status>HTTP/1.1 500 Internal Server Error</d:status></d:propstat></d:response>
        """
        let readable = """
        <d:response><d:href>/remote.php/dav/calendars/tim/work/b.ics</d:href><d:propstat><d:prop><d:getetag>"e-b"</d:getetag>\
        <cal:calendar-data>BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:b\nEND:VTODO\nEND:VCALENDAR\n</cal:calendar-data></d:prop>\
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        """
        func multistatus(_ responses: String) -> Data {
            Data(("<d:multistatus xmlns:d=\"DAV:\" xmlns:cal=\"urn:ietf:params:xml:ns:caldav\">" + responses
                  + "<d:sync-token>http://example.com/sync/2</d:sync-token></d:multistatus>").utf8)
        }
        var hasSyncCollection = true, multigetReads = true
        StubURLProtocol.handler = { req in
            let body = Self.body(req) ?? ""
            if body.contains("sync-collection") { return hasSyncCollection ? (207, [:], multistatus(failed)) : (501, [:], Data()) }
            if body.contains("calendar-query") { return (207, [:], multistatus(failed)) }
            return (207, [:], multistatus(multigetReads ? readable : failed))
        }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        for syncCollection in [true, false] {
            hasSyncCollection = syncCollection
            multigetReads = true
            let changes = try await caldav.changes(in: "calendars/tim/work", since: nil)
            XCTAssertTrue(changes.isFull)
            XCTAssertEqual(changes.changed.map(\.path), ["calendars/tim/work/b.ics"], "sync-collection: \(syncCollection)")
            multigetReads = false
            do {
                _ = try await caldav.changes(in: "calendars/tim/work", since: nil)
                XCTFail("expected badRemoteData, sync-collection: \(syncCollection)")
            } catch {
                guard case .badRemoteData? = error as? SyncError else { return XCTFail("\(error)") }
            }
        }
    }

    /// A property the server will not store comes back 403; atomic servers fail the rest with 424
    /// (sent again without it), others apply the rest at once (Xandikos).
    func testRefusedOptionalPropertiesAreReportedAndTheRestIsSet() async throws {
        func reply(_ statuses: [(String, String)]) -> Data {
            let propstats = statuses.map { "<d:propstat><d:prop>\($0.0)</d:prop><d:status>HTTP/1.1 \($0.1)</d:status></d:propstat>" }
            return Data("""
            <d:multistatus xmlns:d="DAV:" xmlns:t="https://todotim.app/ns"><d:response><d:href>/remote.php/dav/calendars/tim/w/</d:href>\
            \(propstats.joined())</d:response></d:multistatus>
            """.utf8)
        }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (207, [:], reply([("<d:displayname/>", "424 Failed Dependency"), ("<t:sections/>", "403 Forbidden")]))
                : (207, [:], reply([("<d:displayname/>", "200 OK")]))
        }
        let refused = try await caldav.setProperties("calendars/tim/w", [.name: "New", .sections: "[]"])
        XCTAssertEqual(refused, [.sections])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let retry = try XCTUnwrap(StubURLProtocol.requests.last.flatMap(Self.body))
        XCTAssertTrue(retry.contains("displayname") && !retry.contains("sections"), retry)

        StubURLProtocol.requests = []
        StubURLProtocol.handler = { _ in (207, [:], reply([("<d:displayname/>", "200 OK"), ("<t:sections/>", "403 Forbidden")])) }
        let partial = try await caldav.setProperties("calendars/tim/w", [.name: "New", .sections: "[]"])
        XCTAssertEqual(partial, [.sections])
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "already applied")
    }

    func testCalendarIsCreatedWithoutPropertiesTheServerRefuses() async throws {
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            return calls == 1 ? (403, [:], Data()) : (201, [:], Data())
        }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        let leftOut = try await caldav.createCalendar("calendars/tim/w", name: "W", color: "#DB4035", order: "1")
        XCTAssertEqual(leftOut, [.color, .order])
        let bodies = StubURLProtocol.requests.compactMap(Self.body)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("calendar-color"))
        XCTAssertFalse(bodies[1].contains("calendar-color"))
        XCTAssertTrue(bodies[1].contains("<c:comp name=\"VTODO\"/>"))

        StubURLProtocol.handler = { _ in (405, [:], Data()) }
        do {
            _ = try await caldav.createCalendar("calendars/tim/w", name: "W", color: "#DB4035", order: "1")
            XCTFail("expected calendarExists")
        } catch {
            XCTAssertEqual(error as? SyncError, .calendarExists("calendars/tim/w"))
        }
    }

    func testSharingOnAServerWithoutItFailsClearly() async throws {
        StubURLProtocol.handler = { _ in (405, [:], Data()) }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        do {
            try await caldav.share("calendars/tim/w", with: "bob")
            XCTFail("expected sharingUnsupported")
        } catch {
            XCTAssertEqual(error as? SyncError, .sharingUnsupported)
            XCTAssertTrue((error as? SyncError)?.errorDescription?.contains("Nextcloud") == true)
        }
    }

    func testEndlessPagingFailsInsteadOfReturningAPartialListing() async throws {
        let truncated = syncCollection.replacingOccurrences(of: " <d:sync-token>", with: """
         <d:response><d:href>/remote.php/dav/calendars/tim/work/</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status></d:response>
         <d:sync-token>
        """)
        StubURLProtocol.handler = { _ in (207, [:], Data(truncated.utf8)) }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        do {
            _ = try await caldav.changes(in: "calendars/tim/work", since: nil)
            XCTFail("expected limitExceeded")
        } catch {
            guard case .limitExceeded? = error as? SyncError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(StubURLProtocol.requests.count, CalDAVClient.maxPages)
    }

    func testWritesAreConditional() async throws {
        StubURLProtocol.handler = { _ in (201, ["ETag": "\"new-gzip\""], Data()) }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        let etag = try await caldav.put("calendars/tim/work/a.ics", ics: "X", ifMatch: "\"old\"")
        XCTAssertEqual(etag, "\"new\"")
        _ = try await caldav.put("calendars/tim/work/b.ics", ics: "X", ifMatch: nil)
        try await caldav.move("calendars/tim/work/a.ics", to: "calendars/tim/home/a.ics", ifMatch: "\"new\"")
        try await caldav.delete("calendars/tim/home/a.ics", ifMatch: "\"new\"")
        let reqs = StubURLProtocol.requests
        XCTAssertEqual(reqs.map(\.httpMethod), ["PUT", "PUT", "MOVE", "DELETE"])
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "If-Match"), "\"old\"")
        XCTAssertEqual(reqs[1].value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(reqs[2].value(forHTTPHeaderField: "Destination"), "https://cloud.example.com/remote.php/dav/calendars/tim/home/a.ics")
        XCTAssertEqual(reqs[2].value(forHTTPHeaderField: "If-Match"), "\"new\"")
        XCTAssertEqual(reqs[3].value(forHTTPHeaderField: "If-Match"), "\"new\"")

        StubURLProtocol.handler = { _ in (412, [:], Data()) }
        do {
            _ = try await caldav.put("calendars/tim/work/a.ics", ics: "X", ifMatch: "\"x\"")
            XCTFail("expected 412")
        } catch {
            XCTAssertEqual(error as? SyncError, .preconditionFailed("calendars/tim/work/a.ics"))
        }
    }

    func testProppatchFailureIsReported() async throws {
        StubURLProtocol.handler = { _ in
            (207, [:], Data("""
            <d:multistatus xmlns:d="DAV:"><d:response><d:href>/remote.php/dav/calendars/tim/w/</d:href>
            <d:propstat><d:prop><d:displayname/></d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response></d:multistatus>
            """.utf8))
        }
        let caldav = CalDAVClient(dav: try makeClient(), username: "tim")
        do {
            try await caldav.setProperties("calendars/tim/w", [.name: "x"])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? SyncError, .http(status: 424, path: "calendars/tim/w"))
        }
        let body = try XCTUnwrap(StubURLProtocol.requests.first.flatMap(Self.body))
        XCTAssertTrue(body.contains("<x:displayname xmlns:x=\"DAV:\">x</x:displayname>"), body)
    }

    /// URLProtocol may see the body as a stream.
    static func body(_ req: URLRequest) -> String? {
        if let data = req.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, headers, body) = Self.handler?(request) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if (300...399).contains(status), let location = headers["Location"], let target = URL(string: location) {
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ETagNormalizationTests: XCTestCase {
    func testStripsProxyCompressionMarkers() {
        XCTAssertEqual(WebDAVClient.normalizeETag("\"abc-gzip\""), "\"abc\"")
        XCTAssertEqual(WebDAVClient.normalizeETag("\"abc-br\""), "\"abc\"")
        XCTAssertEqual(WebDAVClient.normalizeETag("W/\"abc\""), "\"abc\"")
        XCTAssertEqual(WebDAVClient.normalizeETag("\"abc\""), "\"abc\"")
        XCTAssertEqual(WebDAVClient.normalizeETag("abc"), "\"abc\"")
        XCTAssertNil(WebDAVClient.normalizeETag(""))
        XCTAssertNil(WebDAVClient.normalizeETag(nil))
    }
}
