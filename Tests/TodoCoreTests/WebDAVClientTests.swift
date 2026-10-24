import XCTest
@testable import TodoCore

/// Realistic Nextcloud response to PROPFIND Depth 1 on the sync folder.
private let nextcloudPropfind = """
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/tim%20v/To%20Do/</d:href>
  <d:propstat>
   <d:prop>
    <d:getetag>&quot;6717a5c0e1f3a&quot;</d:getetag>
    <d:resourcetype><d:collection/></d:resourcetype>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/files/tim%20v/To%20Do/index.json</d:href>
  <d:propstat>
   <d:prop>
    <d:getetag>&quot;0a1b2c3d4e5f60718293a4b5c6d7e8f9&quot;</d:getetag>
    <d:resourcetype/>
    <d:getcontentlength>1234</d:getcontentlength>
    <d:getlastmodified>Sat, 24 Oct 2026 18:20:05 GMT</d:getlastmodified>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/files/tim%20v/To%20Do/projects/</d:href>
  <d:propstat>
   <d:prop>
    <d:getetag>&quot;6717a5c0d2b11&quot;</d:getetag>
    <d:resourcetype><d:collection/></d:resourcetype>
   </d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/files/tim%20v/To%20Do/caf%C3%A9%20notes.json</d:href>
  <d:propstat>
   <d:prop><d:resourcetype/></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status>
  </d:propstat>
  <d:propstat>
   <d:prop><d:getetag/></d:prop>
   <d:status>HTTP/1.1 404 Not Found</d:status>
  </d:propstat>
 </d:response>
</d:multistatus>
"""

final class WebDAVClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    func testParsesNextcloudMultistatus() throws {
        let entries = try XCTUnwrap(try MultistatusParser.parse(Data(nextcloudPropfind.utf8)))
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[1], .init(href: "/remote.php/dav/files/tim%20v/To%20Do/index.json",
                                         etag: "\"0a1b2c3d4e5f60718293a4b5c6d7e8f9\"", isCollection: false,
                                         size: 1234, modified: Date(timeIntervalSince1970: 1_792_866_005)))
        XCTAssertTrue(entries[2].isCollection)
        XCTAssertNil(entries[3].etag, "getetag in a 404 propstat is ignored")

        let base = try WebDAVClient.normalizedBaseURL("https://cloud.example.com/remote.php/dav/files/tim%20v")
        let items = WebDAVClient.items(from: entries, baseURL: base, listedPath: "To Do")
        XCTAssertEqual(items.map(\.path), ["To Do/index.json", "To Do/projects", "To Do/café notes.json"])
        XCTAssertEqual(items.map(\.name), ["index.json", "projects", "café notes.json"])
        XCTAssertEqual(items.map(\.isCollection), [false, true, false])
        XCTAssertEqual(items[0].size, 1234)
        XCTAssertEqual(items[0].modified, Date(timeIntervalSince1970: 1_792_866_005))
        XCTAssertNil(items[2].size)
    }

    func testParsesHTTPDates() {
        XCTAssertEqual(WebDAVClient.httpDate("Sat, 24 Oct 2026 18:20:05 GMT"), Date(timeIntervalSince1970: 1_792_866_005))
        XCTAssertEqual(WebDAVClient.httpDate("Sun, 06 Nov 1994 08:49:37 GMT"), Date(timeIntervalSince1970: 784_111_777))
        XCTAssertNil(WebDAVClient.httpDate("yesterday"))
        XCTAssertNil(WebDAVClient.httpDate(""))
        XCTAssertNil(WebDAVClient.httpDate(nil))
    }

    func testRejectsNonMultistatus() throws {
        XCTAssertNil(try MultistatusParser.parse(Data("<html><body>Nextcloud</body></html>".utf8)))
        XCTAssertNil(try MultistatusParser.parse(Data("not xml".utf8)))
    }

    func testBaseURLNormalizationAndPathEncoding() throws {
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("https://tim:pw@cloud.example.com/dav/"))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("https://cloud.example.com/dav/?x=1"))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL(""))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("ftp://x/"))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("cloud.example.com"))
        let client = try WebDAVClient(serverURL: "  https://cloud.example.com/remote.php/dav/files/tim ", username: "tim", password: "pw")
        XCTAssertEqual(client.baseURL.absoluteString, "https://cloud.example.com/remote.php/dav/files/tim/")
        XCTAssertEqual(try client.url(for: "To Do/projects/a#b?.json").absoluteString,
                       "https://cloud.example.com/remote.php/dav/files/tim/To%20Do/projects/a%23b%3F.json")
        XCTAssertEqual(try client.url(for: "/TodoTim/", collection: true).absoluteString,
                       "https://cloud.example.com/remote.php/dav/files/tim/TodoTim/")
        XCTAssertEqual(try client.url(for: "", collection: true).absoluteString,
                       "https://cloud.example.com/remote.php/dav/files/tim/")
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
        for bad in ["a/../b", "..", "TodoTim/projects/../../outside.json", "./x", "a//b", "a/./b"] {
            XCTAssertThrowsError(try client.url(for: bad), bad) { XCTAssertEqual($0 as? SyncError, .invalidPath(bad)) }
        }
        StubURLProtocol.handler = { _ in (200, [:], Data()) }
        do {
            _ = try await client.get("TodoTim/projects/../../outside.json")
            XCTFail("expected invalidPath")
        } catch {
            XCTAssertEqual(error as? SyncError, .invalidPath("TodoTim/projects/../../outside.json"))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no request is sent for an unsafe path")
        // Dots inside a name are fine.
        XCTAssertEqual(try client.url(for: "a/..b/c..json").absoluteString,
                       "https://cloud.example.com/remote.php/dav/files/tim/a/..b/c..json")
    }

    func testItemsKeepOnlyDirectChildrenOnSameServer() throws {
        let base = try WebDAVClient.normalizedBaseURL("https://cloud.example.com/remote.php/dav/files/tim/")
        let entries: [MultistatusParser.Entry] = [
            .init(href: "/remote.php/dav/files/tim/T/", etag: nil, isCollection: true),
            .init(href: "/remote.php/dav/files/tim/T/ok.json", etag: nil, isCollection: false),
            .init(href: "https://cloud.example.com/remote.php/dav/files/tim/T/abs.json", etag: nil, isCollection: false),
            .init(href: "https://evil.example.com/remote.php/dav/files/tim/T/evil.json", etag: nil, isCollection: false),
            .init(href: "https://cloud.example.com:8443/remote.php/dav/files/tim/T/port.json", etag: nil, isCollection: false),
            .init(href: "/remote.php/dav/files/tim/T/sub/nested.json", etag: nil, isCollection: false),
            .init(href: "/remote.php/dav/files/tim/T/../outside.json", etag: nil, isCollection: false),
            .init(href: "/remote.php/dav/files/other/T/x.json", etag: nil, isCollection: false),
            .init(href: "/remote.php/dav/files/tim/T/%2E%2E", etag: nil, isCollection: false),
        ]
        XCTAssertEqual(WebDAVClient.items(from: entries, baseURL: base, listedPath: "T").map(\.path),
                       ["T/ok.json", "T/abs.json"])
    }

    func testParserRefusesDTDAndCapsEntries() throws {
        let xxe = """
        <?xml version="1.0"?>
        <!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>&x;</d:href></d:response></d:multistatus>
        """
        XCTAssertThrowsError(try MultistatusParser.parse(Data(xxe.utf8)))
        XCTAssertThrowsError(try MultistatusParser.parse(Data(nextcloudPropfind.utf8), maxEntries: 3)) {
            guard case MultistatusParser.Failure.tooManyEntries = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try MultistatusParser.parse(Data(nextcloudPropfind.utf8), maxEntries: 4)?.count, 4)
    }

    func testResponseBodyIsCapped() async throws {
        let client = try makeClient()
        client.maxResponseBytes = 100_000
        // No Content-Length: the limit is enforced while reading.
        StubURLProtocol.handler = { _ in (200, [:], Data(count: 300_000)) }
        do {
            _ = try await client.get("TodoTim/index.json")
            XCTFail("expected limitExceeded")
        } catch {
            guard case .limitExceeded? = error as? SyncError else { return XCTFail("\(error)") }
        }
        StubURLProtocol.handler = { _ in (200, [:], Data(count: 90_000)) }
        let data = try await client.get("TodoTim/index.json").data
        XCTAssertEqual(data.count, 90_000)
    }

    func testRedirectsOutsideBaseAreRefused() async throws {
        let client = try makeClient()
        for target in ["https://evil.example.com/remote.php/dav/files/tim/TodoTim/index.json",
                       "http://cloud.example.com/remote.php/dav/files/tim/TodoTim/index.json",
                       "https://cloud.example.com:8443/remote.php/dav/files/tim/TodoTim/index.json",
                       "https://cloud.example.com/remote.php/dav/files/other/index.json"] {
            StubURLProtocol.requests = []
            StubURLProtocol.handler = { req in
                req.url!.absoluteString == target ? (200, [:], Data("leaked".utf8)) : (307, ["Location": target], Data())
            }
            do {
                _ = try await client.get("TodoTim/index.json")
                XCTFail("expected redirectRejected for \(target)")
            } catch {
                guard case .redirectRejected? = error as? SyncError else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "redirect to \(target) is not followed")
        }
        // A redirect inside the base URL is followed.
        let inside = "https://cloud.example.com/remote.php/dav/files/tim/TodoTim/moved.json"
        StubURLProtocol.handler = { req in
            req.url!.absoluteString == inside ? (200, [:], Data("ok".utf8)) : (307, ["Location": inside], Data())
        }
        let data = try await client.get("TodoTim/index.json").data
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
    }

    func testErrorMessages() {
        XCTAssertEqual(WebDAVClient.error(status: 401, path: "x").errorDescription, "Wrong username or app password")
        XCTAssertEqual(WebDAVClient.error(status: 404, path: ""), .baseNotFound)
        XCTAssertTrue(WebDAVClient.error(status: 404, path: "").errorDescription!.hasPrefix("Server URL not found"))
        XCTAssertEqual(WebDAVClient.error(status: 404, path: "a/b"), .notFound("a/b"))
        XCTAssertEqual(WebDAVClient.error(status: 412, path: "a"), .preconditionFailed("a"))
        XCTAssertEqual(WebDAVClient.error(status: 507, path: "a"), .insufficientStorage)
    }

    // MARK: - Requests via a stub URLProtocol (no network)

    private func makeClient() throws -> WebDAVClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return try WebDAVClient(serverURL: "https://cloud.example.com/remote.php/dav/files/tim/",
                                username: "tim", password: "app-pass", session: URLSession(configuration: config))
    }

    func testListSendsPropfindAndMapsItems() async throws {
        StubURLProtocol.handler = { req in
            let body = nextcloudPropfind.replacingOccurrences(of: "tim%20v", with: "tim")
            return (207, [:], Data(body.utf8))
        }
        let listing = try await makeClient().listing("To Do")
        XCTAssertEqual(listing.items.map(\.path), ["To Do/index.json", "To Do/projects", "To Do/café notes.json"])
        XCTAssertNil(listing.serverDate)
        let req = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(req.httpMethod, "PROPFIND")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(req.url?.absoluteString, "https://cloud.example.com/remote.php/dav/files/tim/To%20Do/")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("tim:app-pass".utf8).base64EncodedString())
    }

    func testPutConditionsAndETag() async throws {
        StubURLProtocol.handler = { _ in (201, ["ETag": "\"new\""], Data()) }
        let client = try makeClient()
        let etag = try await client.put("TodoTim/index.json", data: Data("{}".utf8), condition: .ifMatch("\"old\""))
        XCTAssertEqual(etag, "\"new\"")
        _ = try await client.put("TodoTim/index.json", data: Data(), condition: .ifNoneMatch)
        let reqs = StubURLProtocol.requests
        XCTAssertEqual(reqs[0].httpMethod, "PUT")
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "If-Match"), "\"old\"")
        XCTAssertEqual(reqs[1].value(forHTTPHeaderField: "If-None-Match"), "*")

        StubURLProtocol.handler = { _ in (412, [:], Data()) }
        do {
            try await client.put("TodoTim/index.json", data: Data(), condition: .ifMatch("\"x\""))
            XCTFail("expected 412")
        } catch {
            XCTAssertEqual(error as? SyncError, .preconditionFailed("TodoTim/index.json"))
        }
    }

    func testMkcolTreats405AsSuccessAndGetReturnsETag() async throws {
        StubURLProtocol.handler = { _ in (405, [:], Data()) }
        let client = try makeClient()
        try await client.makeCollection("TodoTim")
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "MKCOL")

        StubURLProtocol.handler = { _ in (200, ["ETag": "\"e1\""], Data("hi".utf8)) }
        let file = try await client.get("TodoTim/index.json")
        XCTAssertEqual(String(data: file.data, encoding: .utf8), "hi")
        XCTAssertEqual(file.etag, "\"e1\"")
        XCTAssertNil(file.modified)

        StubURLProtocol.handler = { _ in
            (200, ["ETag": "\"e2-gzip\"", "Last-Modified": "Sat, 24 Oct 2026 18:20:05 GMT",
                   "Date": "Sat, 24 Oct 2026 18:20:06 GMT"], Data("hi".utf8))
        }
        let dated = try await client.get("TodoTim/index.json")
        XCTAssertEqual(dated.etag, "\"e2\"")
        XCTAssertEqual(dated.modified, Date(timeIntervalSince1970: 1_792_866_005))
        XCTAssertEqual(dated.serverDate, Date(timeIntervalSince1970: 1_792_866_006))

        StubURLProtocol.handler = { _ in (401, [:], Data()) }
        do {
            _ = try await client.list("")
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual((error as? SyncError)?.errorDescription, "Wrong username or app password")
        }
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

final class WebDAVListingDateTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    func testPropfindAsksForSizeAndTimeAndReportsServerDate() async throws {
        StubURLProtocol.handler = { _ in
            let body = nextcloudPropfind.replacingOccurrences(of: "tim%20v", with: "tim")
            return (207, ["Date": "Sat, 24 Oct 2026 18:20:06 GMT"], Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = try WebDAVClient(serverURL: "https://cloud.example.com/remote.php/dav/files/tim/",
                                      username: "tim", password: "pw", session: URLSession(configuration: config))
        let listing = try await client.listing("To Do")
        XCTAssertEqual(listing.serverDate, Date(timeIntervalSince1970: 1_792_866_006))
        XCTAssertEqual(listing.items.first?.size, 1234)
        let body = try XCTUnwrap(StubURLProtocol.requests.first.flatMap(Self.body))
        XCTAssertTrue(body.contains("getcontentlength") && body.contains("getlastmodified") && body.contains("getetag"), body)
    }

    /// URLProtocol sees the body as a stream.
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
