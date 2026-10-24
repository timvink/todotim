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
        let entries = try XCTUnwrap(MultistatusParser.parse(Data(nextcloudPropfind.utf8)))
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[1], .init(href: "/remote.php/dav/files/tim%20v/To%20Do/index.json",
                                         etag: "\"0a1b2c3d4e5f60718293a4b5c6d7e8f9\"", isCollection: false))
        XCTAssertTrue(entries[2].isCollection)
        XCTAssertNil(entries[3].etag, "getetag in a 404 propstat is ignored")

        let base = try WebDAVClient.normalizedBaseURL("https://cloud.example.com/remote.php/dav/files/tim%20v")
        let items = WebDAVClient.items(from: entries, baseURL: base, listedPath: "To Do")
        XCTAssertEqual(items.map(\.path), ["To Do/index.json", "To Do/projects", "To Do/café notes.json"])
        XCTAssertEqual(items.map(\.name), ["index.json", "projects", "café notes.json"])
        XCTAssertEqual(items.map(\.isCollection), [false, true, false])
    }

    func testRejectsNonMultistatus() {
        XCTAssertNil(MultistatusParser.parse(Data("<html><body>Nextcloud</body></html>".utf8)))
        XCTAssertNil(MultistatusParser.parse(Data("not xml".utf8)))
    }

    func testBaseURLNormalizationAndPathEncoding() throws {
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL(""))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("ftp://x/"))
        XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL("cloud.example.com"))
        let client = try WebDAVClient(serverURL: "  https://cloud.example.com/remote.php/dav/files/tim ", username: "tim", password: "pw")
        XCTAssertEqual(client.baseURL.absoluteString, "https://cloud.example.com/remote.php/dav/files/tim/")
        XCTAssertEqual(client.url(for: "To Do/projects/a#b?.json").absoluteString,
                       "https://cloud.example.com/remote.php/dav/files/tim/To%20Do/projects/a%23b%3F.json")
        XCTAssertEqual(client.url(for: "/TodoTim/", collection: true).absoluteString,
                       "https://cloud.example.com/remote.php/dav/files/tim/TodoTim/")
        XCTAssertEqual(client.url(for: "", collection: true).absoluteString,
                       "https://cloud.example.com/remote.php/dav/files/tim/")
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
        let items = try await makeClient().list("To Do")
        XCTAssertEqual(items.map(\.path), ["To Do/index.json", "To Do/projects", "To Do/café notes.json"])
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
        let (data, etag) = try await client.get("TodoTim/index.json")
        XCTAssertEqual(String(data: data, encoding: .utf8), "hi")
        XCTAssertEqual(etag, "\"e1\"")

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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
