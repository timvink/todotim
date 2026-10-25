import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TodoCore

/// Serves canned responses for https://api.todoist.com requests.
final class TodoistStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, headers, body) = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler?(request) ?? (500, [:], Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TodoistStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class TodoistImportAPITests: XCTestCase {
    override func tearDown() {
        TodoistStubURLProtocol.handler = nil
        TodoistStubURLProtocol.requests = []
        super.tearDown()
    }

    private func api(_ token: String = "secret-token") throws -> TodoistAPI {
        try TodoistAPI(token: token, session: TodoistStubURLProtocol.session())
    }

    private static func query(_ req: URLRequest, _ name: String) -> String? {
        URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func testFetchSnapshotFromDocumentedResponses() async throws {
        TodoistStubURLProtocol.handler = { req in
            let body: String
            switch req.url!.path {
            case "/api/v1/projects": body = TodoistFixtures.projectsPage
            case "/api/v1/sections": body = TodoistFixtures.sectionsPage
            case "/api/v1/tasks": body = TodoistFixtures.tasksPage
            case "/api/v1/labels": body = TodoistFixtures.labelsPage
            default: return (404, [:], Data())
            }
            return (200, ["Content-Type": "application/json"], Data(body.utf8))
        }
        let snapshot = try await api("  secret-token\n").fetchSnapshot()
        let expected = try TodoistSnapshot.decode(Data(TodoistFixtures.snapshotJSON.utf8))
        XCTAssertEqual(snapshot, expected)

        let reqs = TodoistStubURLProtocol.requests
        XCTAssertEqual(reqs.map { $0.url!.path }, ["/api/v1/projects", "/api/v1/sections", "/api/v1/tasks", "/api/v1/labels"])
        for r in reqs {
            XCTAssertEqual(r.url?.scheme, "https")
            XCTAssertEqual(r.url?.host, "api.todoist.com")
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(r.httpMethod, "GET")
            XCTAssertEqual(Self.query(r, "limit"), "200")
            XCTAssertNil(Self.query(r, "cursor"))
        }
    }

    func testFollowsNextCursor() async throws {
        TodoistStubURLProtocol.handler = { req in
            guard req.url!.path == "/api/v1/tasks" else { return (200, [:], Data(#"{"results": [], "next_cursor": null}"#.utf8)) }
            switch Self.query(req, "cursor") {
            case nil:
                return (200, [:], Data(#"{"results": [{"id": "1", "project_id": "p", "content": "a"}], "next_cursor": "c2.x+y/z"}"#.utf8))
            case "c2.x+y/z":
                return (200, [:], Data(#"{"results": [{"id": "2", "project_id": "p", "content": "b"}], "next_cursor": ""}"#.utf8))
            default:
                return (400, [:], Data())
            }
        }
        final class Steps: @unchecked Sendable {
            let lock = NSLock()
            var list: [String] = []
            func add(_ s: String) { lock.withLock { list.append(s) } }
        }
        let steps = Steps()
        let s = try await api().fetchSnapshot { step, _ in steps.add(step) }
        XCTAssertEqual(s.tasks.map(\.content), ["a", "b"])
        XCTAssertEqual(TodoistStubURLProtocol.requests.filter { $0.url!.path == "/api/v1/tasks" }.count, 2)
        XCTAssertEqual(steps.list, ["projects", "sections", "tasks", "tasks", "labels"])
    }

    func testRepeatedCursorIsRejected() async throws {
        TodoistStubURLProtocol.handler = { _ in (200, [:], Data(#"{"results": [], "next_cursor": "same"}"#.utf8)) }
        do {
            _ = try await api().fetchSnapshot()
            XCTFail("expected an error")
        } catch let e as TodoistAPIError {
            XCTAssertEqual(e, .invalidResponse("repeated page cursor"))
        }
    }

    func testHTTPErrors() async throws {
        let cases: [(Int, [String: String], TodoistAPIError)] = [
            (401, [:], .unauthorized),
            (403, [:], .unauthorized),
            (429, ["Retry-After": "30"], .rateLimited(retryAfter: 30)),
            (500, [:], .http(status: 500)),
        ]
        for (status, headers, expected) in cases {
            TodoistStubURLProtocol.handler = { _ in (status, headers, Data("{}".utf8)) }
            do {
                _ = try await api().fetchSnapshot()
                XCTFail("expected \(expected)")
            } catch let e as TodoistAPIError {
                XCTAssertEqual(e, expected)
            }
        }
    }

    func testInvalidJSONIsReported() async throws {
        TodoistStubURLProtocol.handler = { _ in (200, [:], Data("<html>".utf8)) }
        do {
            _ = try await api().fetchSnapshot()
            XCTFail("expected an error")
        } catch TodoistAPIError.invalidResponse {
        }
    }

    func testResponseSizeCap() async throws {
        var client = try api()
        client.maxResponseBytes = 100_000
        TodoistStubURLProtocol.handler = { _ in (200, [:], Data(count: 300_000)) }
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("expected an error")
        } catch let e as TodoistAPIError {
            guard case .limitExceeded = e else { return XCTFail("\(e)") }
        }
    }

    func testEntityCap() async throws {
        var client = try api()
        client.maxEntities = 1
        TodoistStubURLProtocol.handler = { _ in
            (200, [:], Data(#"{"results": [{"id": "1", "name": "a"}, {"id": "2", "name": "b"}], "next_cursor": null}"#.utf8))
        }
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("expected an error")
        } catch let e as TodoistAPIError {
            guard case .limitExceeded = e else { return XCTFail("\(e)") }
        }
    }

    func testRequiresHTTPSAndToken() {
        XCTAssertThrowsError(try TodoistAPI(token: "t", baseURL: URL(string: "http://api.todoist.com/api/v1/")!)) {
            XCTAssertEqual($0 as? TodoistAPIError, .insecureURL)
        }
        XCTAssertThrowsError(try TodoistAPI(token: "  \n")) { XCTAssertEqual($0 as? TodoistAPIError, .missingToken) }
        XCTAssertEqual(TodoistAPI.defaultBaseURL.absoluteString, "https://api.todoist.com/api/v1/")
    }

    func testErrorMessagesNeverContainToken() {
        let all: [TodoistAPIError] = [.missingToken, .insecureURL, .unauthorized, .rateLimited(retryAfter: nil),
                                       .http(status: 502), .redirectRejected, .limitExceeded("x"),
                                       .invalidResponse("x"), .network("x")]
        for e in all { XCTAssertFalse(e.localizedDescription.isEmpty) }
    }
}
