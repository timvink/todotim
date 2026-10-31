import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TodoCore

/// Discovery of the calendar home (RFC 6764, RFC 4791) on the layouts of several servers, over a
/// stub URLProtocol that answers as `FakeDAVLayout` describes.
final class CalDAVDiscoveryTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func discover(_ layout: FakeDAVLayout, serverURL: String? = nil, password: String = "pw") async throws -> CalendarHome {
        StubURLProtocol.handler = { layout.respond(to: $0) }
        return try await CalDAVDiscovery.discover(serverURL: serverURL ?? layout.serverURL, username: layout.user,
                                                  password: password, session: session())
    }

    private var requestedURLs: [String] { StubURLProtocol.requests.map { $0.url!.absoluteString } }

    func testNextcloudHomeIsTheOneUsedBeforeDiscovery() async throws {
        let layout = FakeDAVLayout.nextcloud()
        let home = try await discover(layout)
        XCTAssertEqual(home, CalendarHome(url: "https://cloud.example.com/remote.php/dav/calendars/tim/",
                                          principal: "https://cloud.example.com/remote.php/dav/principals/users/tim/"))
        XCTAssertEqual(requestedURLs, ["https://cloud.example.com/remote.php/dav/",
                                       "https://cloud.example.com/remote.php/dav/principals/users/tim/"])
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.httpMethod == "PROPFIND" && $0.value(forHTTPHeaderField: "Depth") == "0" })
        // Same paths as before discovery, so existing sync state stays valid.
        let client = try CalDAVClient(serverURL: layout.serverURL, username: "tim", password: "pw", home: home)
        XCTAssertEqual(client.home, "calendars/tim")
        XCTAssertEqual(client.dav.baseURL.absoluteString, "https://cloud.example.com/remote.php/dav/")
        XCTAssertEqual(home.url, CalDAVDiscovery.legacyHome(root: client.dav.baseURL, username: "tim"))
    }

    func testRadicaleAndXandikosLayouts() async throws {
        let radicale = try await discover(.radicale())
        XCTAssertEqual(radicale, CalendarHome(url: "http://localhost:5232/tim/", principal: "http://localhost:5232/tim/"))
        let r = try CalDAVClient(serverURL: "http://localhost:5232/", username: "tim", password: "pw", home: radicale)
        XCTAssertEqual(r.home, "tim")
        XCTAssertEqual(r.dav.baseURL.absoluteString, "http://localhost:5232/")

        let xandikos = try await discover(.xandikos)
        XCTAssertEqual(xandikos, CalendarHome(url: "http://localhost:8080/user/calendars/", principal: "http://localhost:8080/user/"))
        let x = try CalDAVClient(serverURL: "http://localhost:8080/", username: "tim", password: "pw", home: xandikos)
        XCTAssertEqual(x.home, "user/calendars")
    }

    #if !canImport(FoundationNetworking)  // the Linux URLSession cannot redirect from a URLProtocol stub
    /// A server that speaks WebDAV only below /dav/ is found through /.well-known/caldav. The
    /// redirect is followed as a PROPFIND, and percent-encoded hrefs are understood.
    func testWellKnownRedirectOnTheSameServer() async throws {
        let layout = FakeDAVLayout.hosted
        let home = try await discover(layout)
        XCTAssertEqual(home, CalendarHome(url: "https://caldav.example.com/dav/calendars/user/tim@example.com/",
                                          principal: "https://caldav.example.com/dav/principals/user/tim@example.com/"))
        XCTAssertEqual(requestedURLs, ["https://caldav.example.com/", "https://caldav.example.com/.well-known/caldav",
                                       "https://caldav.example.com/dav/",
                                       "https://caldav.example.com/dav/principals/user/tim%40example.com/"])
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.httpMethod == "PROPFIND" })
        let client = try CalDAVClient(serverURL: layout.serverURL, username: layout.user, password: "pw", home: home)
        XCTAssertEqual(client.home, "dav/calendars/user/tim@example.com")
    }

    /// A redirect to another origin (another host, or plain http) is not followed.
    func testRedirectToAnotherServerIsRefused() async throws {
        for target in ["https://dav.elsewhere.example/dav/", "http://caldav.example.com/dav/"] {
            StubURLProtocol.requests = []
            var layout = FakeDAVLayout.hosted
            layout.wellKnown = target
            do {
                _ = try await discover(layout)
                XCTFail("expected otherServer for \(target)")
            } catch {
                guard case .otherServer(let url)? = error as? SyncError else { return XCTFail("\(error)") }
                XCTAssertEqual(url + "/", target)
            }
            XCTAssertEqual(requestedURLs, ["https://caldav.example.com/", "https://caldav.example.com/.well-known/caldav"])
        }
    }
    #endif

    /// The user entered their principal URL: the home is outside the server URL, so requests are
    /// confined to the home itself.
    func testHomeOutsideTheServerURL() async throws {
        let layout = FakeDAVLayout.hosted
        let serverURL = "https://caldav.example.com/dav/principals/user/tim@example.com/"
        let home = try await discover(layout, serverURL: serverURL)
        XCTAssertEqual(home.url, "https://caldav.example.com/dav/calendars/user/tim@example.com/")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let client = try CalDAVClient(serverURL: serverURL, username: layout.user, password: "pw", home: home)
        XCTAssertEqual(client.home, "")
        XCTAssertEqual(client.dav.baseURL.absoluteString, home.url)
        XCTAssertEqual(client.dav.relativePath(ofHref: "/dav/calendars/user/tim%40example.com/work/"), "work")
        XCTAssertNil(client.dav.relativePath(ofHref: "/dav/principals/user/tim%40example.com/"), "outside the home")
    }

    /// Servers without `current-user-principal`, or a principal without a calendar home, get the
    /// SabreDAV layout below the server URL.
    func testFallsBackToCalendarsUsername() async throws {
        var layout = FakeDAVLayout.nextcloud()
        layout.principal = nil
        layout.wellKnown = nil
        let home = try await discover(layout)
        XCTAssertEqual(home, CalendarHome(url: "https://cloud.example.com/remote.php/dav/calendars/tim/"))
        XCTAssertEqual(requestedURLs, ["https://cloud.example.com/remote.php/dav/", "https://cloud.example.com/.well-known/caldav"])

        StubURLProtocol.requests = []
        layout.principal = "remote.php/dav/principals/users/tim"
        layout.home = nil
        let withoutHome = try await discover(layout)
        XCTAssertEqual(withoutHome, CalendarHome(url: "https://cloud.example.com/remote.php/dav/calendars/tim/",
                                                 principal: "https://cloud.example.com/remote.php/dav/principals/users/tim/"))
    }

    /// iCloud names a calendar home on another host (pNN-caldav): refused, and never contacted.
    func testHomeOnAnotherServerIsRefused() async throws {
        let layout = FakeDAVLayout(origin: "https://caldav.example.com", root: "", davArea: "", principal: "123/principal",
                                   home: "123/calendars", homeOrigin: "https://p42-caldav.example.com:443")
        do {
            _ = try await discover(layout)
            XCTFail("expected otherServer")
        } catch {
            guard case .otherServer(let url)? = error as? SyncError else { return XCTFail("\(error)") }
            XCTAssertTrue(url.hasPrefix("https://p42-caldav.example.com"), url)
            XCTAssertTrue((error as? SyncError)?.errorDescription?.contains("another server") == true)
        }
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.url?.host == "caldav.example.com" })

        // A home kept from earlier is checked the same way.
        let elsewhere = CalendarHome(url: "https://p42-caldav.example.com/123/calendars/")
        XCTAssertThrowsError(try CalDAVClient(serverURL: "https://caldav.example.com/", username: "tim", password: "pw",
                                              home: elsewhere)) {
            guard case .otherServer? = $0 as? SyncError else { return XCTFail("\($0)") }
        }
    }

    func testWrongPasswordAndServerErrorsStopDiscovery() async throws {
        var layout = FakeDAVLayout.radicale()
        layout.password = "right"
        do {
            _ = try await discover(layout, password: "wrong")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? SyncError, .unauthorized)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let home = try await discover(layout, password: "right")
        XCTAssertEqual(home.url, "http://localhost:5232/tim/")

        // A server error is not "nothing found" (whose fallback would then be kept).
        StubURLProtocol.handler = { _ in (503, [:], Data()) }
        do {
            _ = try await CalDAVDiscovery.discover(serverURL: "https://cloud.example.com/remote.php/dav/", username: "tim",
                                                   password: "pw", session: session())
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? SyncError, .http(status: 503, path: "/remote.php/dav/"))
        }
    }

    /// Discovery, then the listing of a Radicale-style home over HTTP. The scheduling inbox and
    /// outbox are recognized by their resource type, whatever they are called.
    func testListsTheCalendarsOfADiscoveredHome() async throws {
        var layout = FakeDAVLayout.radicale()
        layout.collections = [
            .init(name: "todotim-inbox", types: ["d:collection", "c:calendar"], components: ["VTODO"]),
            .init(name: "work", types: ["d:collection", "c:calendar"], components: ["VTODO"]),
            .init(name: "events", types: ["d:collection", "c:calendar"], components: ["VEVENT", "VTODO"]),
            .init(name: "invitations", types: ["d:collection", "c:calendar", "c:schedule-inbox"], components: ["VTODO"]),
            .init(name: "outbox", types: ["d:collection", "c:schedule-outbox"]),
            .init(name: "contacts", types: ["d:collection"]),
        ]
        StubURLProtocol.handler = { layout.respond(to: $0) }
        let client = try await CalDAVClient.connect(serverURL: layout.serverURL, username: "tim", password: "pw",
                                                    cached: nil, session: session())
        let calendars = try await client.calendars()
        XCTAssertEqual(calendars.map(\.path).sorted(), ["tim/todotim-inbox", "tim/work"])
        XCTAssertEqual(requestedURLs.last, "http://localhost:5232/tim/")
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Depth"), "1")

        // With the home known, connecting sends nothing.
        StubURLProtocol.requests = []
        let again = try await CalDAVClient.connect(serverURL: layout.serverURL, username: "tim", password: "pw",
                                                   cached: client.calendarHome, session: session())
        XCTAssertEqual(again.home, "tim")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}
