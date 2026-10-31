import XCTest
@testable import TodoCore

/// Sync against a real CalDAV server (Nextcloud, Radicale, …), found by discovery. Opt-in, and
/// destructive for the account's task lists: use a throwaway user.
///
///     TODOTIM_LIVE_URL=http://localhost:8080/remote.php/dav/ TODOTIM_LIVE_USER=todotim-test \
///     TODOTIM_LIVE_PASSWORD=<app password> [TODOTIM_LIVE_SHARE_WITH=<other user>] swift test --filter LiveCalDAVTests
///
/// `TODOTIM_LIVE_SHARE_WITH` needs Nextcloud's sharing.
@MainActor
final class LiveCalDAVTests: XCTestCase {
    private var server: CalDAVClient!
    private var shareWith: [String] = []

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["TODOTIM_LIVE_URL"], let user = env["TODOTIM_LIVE_USER"], let password = env["TODOTIM_LIVE_PASSWORD"]
        else { throw XCTSkip("set TODOTIM_LIVE_URL, TODOTIM_LIVE_USER and TODOTIM_LIVE_PASSWORD to run") }
        server = try await CalDAVClient.connect(serverURL: url, username: user, password: password, cached: nil)
        shareWith = env["TODOTIM_LIVE_SHARE_WITH"].map { [$0] } ?? []
        try await removeAllLists()
    }

    override func tearDown() async throws {
        if server != nil { try await removeAllLists() }
    }

    /// Removes the account's lists for good (a list in Nextcloud's trash bin blocks a new one at
    /// its path), and first their properties (which Nextcloud would otherwise keep, also for a
    /// new list at the same path).
    private func removeAllLists() async throws {
        var paths = Set(try await server.calendars().map(\.path))
        paths.insert(davPath(server.home, CalDAVSync.inboxURI))
        for path in paths {
            try? await server.setProperties(path, [.sections: nil, .labels: nil])
            _ = try await server.dav.send("DELETE", path, collection: true, headers: ["X-NC-CalDAV-No-Trashbin": "1"])
        }
    }

    @MainActor final class Device {
        let store: TodoStore
        var state = CalDAVState(account: "live")
        init() { store = TodoStore() }

        @discardableResult
        func sync(_ server: CalDAVServer, shareWith: [String] = [], previous: Database? = nil) async throws -> SyncResult {
            let r = try await CalDAVSync.sync(local: store.db, state: state, server: server, shareWith: shareWith, previous: previous)
            store.replaceDatabase(r.merged)
            state = r.state
            return r
        }
    }

    private func object(_ path: String) async throws -> RemoteResource? { try await Self.object(server, path) }

    nonisolated private static func object(_ server: CalDAVServer, _ path: String) async throws -> RemoteResource? {
        let cal = String(path[..<path.lastIndex(of: "/")!])
        return try await server.changes(in: cal, since: nil).changed.first { $0.path == path }
    }

    func testRoundTrip() async throws {
        let home = server.home
        let a = Device()
        let s = a.store
        let p = s.addProject(name: "Home", color: "green")
        let other = s.addProject(name: "Errands", color: "orange")
        let sec = s.addSection(projectId: p.id, name: "Garden \"front\"")
        let parent = s.addTask(content: "Prune roses; carefully", projectId: p.id, sectionId: sec.id, description: "Line 1\nLine 2",
                               priority: .p1, due: DueDate(date: "2026-11-03"), labels: ["outside", "weekend"])
        let child = s.addTask(content: "Buy shears", projectId: p.id, parentId: parent.id, priority: .p3)
        let inboxTask = s.addTask(content: "Call mum", projectId: TodoStore.inboxID, priority: .p2)
        s.updateTask(parent.id) { $0.collapsed = true }

        // 1. First sync uploads everything (the migration of an existing database).
        let first = try await a.sync(server, shareWith: shareWith)
        XCTAssertEqual(first.warnings, [], "sharing works")
        let calendars = try await server.calendars()
        XCTAssertEqual(Set(calendars.map(\.uri)), ["todotim-inbox", p.id, other.id])
        let inboxCal = try XCTUnwrap(calendars.first { $0.uri == "todotim-inbox" })
        XCTAssertEqual(inboxCal.name, "Inbox")
        XCTAssertEqual(inboxCal.labels.flatMap(PropertyList.decode)?.map(\.name).sorted(), ["outside", "weekend"])
        let homeCal = try XCTUnwrap(calendars.first { $0.uri == p.id })
        XCTAssertEqual(homeCal.color.flatMap(ProjectColor.key(hex:)), "green")
        XCTAssertEqual(homeCal.sections.flatMap(PropertyList.decode)?.map(\.name), ["Garden \"front\""])
        let parentPath = davPath(home, "\(p.id)/\(parent.id).ics")
        let parentObject = try await object(parentPath)
        let parentICS = try XCTUnwrap(parentObject?.ics).unfolded
        XCTAssertTrue(parentICS.contains("SUMMARY:Prune roses\\; carefully"))
        XCTAssertTrue(parentICS.contains("X-OC-HIDESUBTASKS:1"))
        XCTAssertTrue(parentICS.contains("X-TODOTIM-SECTION;X-NAME=Garden ^'front^';X-ORDER=1:\(sec.id)"), parentICS)

        // 2. Idempotent: an immediate second sync writes nothing; an idle one only lists.
        let second = try await a.sync(server)
        XCTAssertEqual(second.writes, 0)
        let idle = try await a.sync(server, previous: s.db)
        XCTAssertEqual(idle.writes, 0)

        // 3. A second device gets the same tasks.
        let b = Device()
        try await b.sync(server)
        for id in [parent.id, child.id, inboxTask.id] { XCTAssertEqual(b.store.task(id), s.task(id), id) }
        XCTAssertEqual(b.store.sections(in: p.id).map(\.name), ["Garden \"front\""])
        XCTAssertEqual(b.store.project(p.id)?.color, "green")

        // 4. Another client edits the parent and adds an alarm; TodoTim picks up the edit, and
        //    its own later edit keeps the alarm.
        let foreign = try XCTUnwrap(parentObject).ics
            .replacingOccurrences(of: "SUMMARY:Prune roses\\; carefully", with: "SUMMARY:Prune roses (edited elsewhere)")
            .replacingOccurrences(of: "END:VTODO", with: "BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:x\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VTODO")
            .replacingOccurrences(of: #"LAST-MODIFIED:\d{8}T\d{6}Z"#, with: "LAST-MODIFIED:\(ICalendar.utcString(Date()))", options: .regularExpression)
        _ = try await server.put(parentPath, ics: foreign, ifMatch: parentObject?.etag)
        try await a.sync(server)
        XCTAssertEqual(s.task(parent.id)?.content, "Prune roses (edited elsewhere)")
        s.updateTask(parent.id) { $0.priority = .p2 }
        try await a.sync(server)
        let afterEdit = try await object(parentPath)
        XCTAssertTrue(afterEdit!.ics.contains("TRIGGER:-PT15M"), "the alarm survives")
        XCTAssertTrue(afterEdit!.ics.contains("PRIORITY:5"))

        // 5. Conflict: another client writes between our listing and our PUT. Nextcloud answers
        //    the PUT with 412; the next pass re-fetches and merges (the other edit is newer).
        let inboxPath = davPath(home, "todotim-inbox/\(inboxTask.id).ics")
        let direct: CalDAVServer = server
        let racing = Racing(direct)
        await racing.setBefore(inboxPath) {
            let current = try! await Self.object(direct, inboxPath)!
            let edited = current.ics.replacingOccurrences(of: "SUMMARY:Call mum", with: "SUMMARY:Call mum (phone)")
                .replacingOccurrences(of: #"LAST-MODIFIED:\d{8}T\d{6}Z"#, with: "LAST-MODIFIED:20991231T000000Z", options: .regularExpression)
            _ = try! await direct.put(inboxPath, ics: edited, ifMatch: current.etag)
        }
        s.updateTask(inboxTask.id) { $0.content = "Call mum (a)" }
        let raced = try await a.sync(racing)
        let puts = await racing.puts
        XCTAssertGreaterThanOrEqual(puts, 1)
        XCTAssertEqual(s.task(inboxTask.id)?.content, "Call mum (phone)", "the newer edit wins after the 412")
        XCTAssertEqual(raced.warnings, [])

        // 6. Moving a task to another list (DAV MOVE), renaming the section (rewrites its tasks).
        s.moveTask(inboxTask.id, projectId: other.id, sectionId: nil, parentId: nil)
        s.updateSection(sec.id) { $0.name = "Garden" }
        try await a.sync(server)
        let moved = try await object(davPath(home, "\(other.id)/\(inboxTask.id).ics"))
        XCTAssertNotNil(moved)
        let oldPlace = try await object(davPath(home, "todotim-inbox/\(inboxTask.id).ics"))
        XCTAssertNil(oldPlace)
        let renamed = try await object(parentPath)
        XCTAssertTrue(renamed!.ics.unfolded.contains("X-NAME=Garden;"))
        try await b.sync(server)
        XCTAssertEqual(b.store.task(inboxTask.id)?.projectId, other.id)
        XCTAssertEqual(b.store.sections(in: p.id).map(\.name), ["Garden"])

        // 7. A repeating task with a time from another client: completing it moves it on.
        let rid = "repeat-\(UUID().uuidString.prefix(8))"
        let repeating = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Other//EN", "BEGIN:VTODO", "UID:\(rid)",
                         "DTSTAMP:20261020T100000Z", "SUMMARY:Pills", "DTSTART:20261101T070000Z", "DUE:20261101T080000Z",
                         "RRULE:FREQ=DAILY;INTERVAL=2", "END:VTODO", "END:VCALENDAR", ""].joined(separator: "\r\n")
        _ = try await server.put(davPath(home, "\(other.id)/\(rid).ics"), ics: repeating, ifMatch: nil)
        try await a.sync(server)
        s.toggleComplete(rid)
        try await a.sync(server)
        let advanced = try await object(davPath(home, "\(other.id)/\(rid).ics"))
        XCTAssertTrue(advanced!.ics.contains("DUE:20261103T080000Z"), advanced!.ics)
        XCTAssertTrue(advanced!.ics.contains("DTSTART:20261103T070000Z"))
        XCTAssertFalse(advanced!.ics.contains("STATUS:COMPLETED"))

        // 8. Deletes: a task, then a whole list.
        s.deleteTask(child.id)
        try await a.sync(server)
        let deletedChild = try await object(davPath(home, "\(p.id)/\(child.id).ics"))
        XCTAssertNil(deletedChild)
        s.deleteProject(other.id)
        try await a.sync(server)
        let remaining = try await server.calendars().map(\.uri)
        XCTAssertFalse(remaining.contains(other.id))
        try await b.sync(server)
        XCTAssertNil(b.store.task(child.id).flatMap { $0.deleted ? nil : $0 })
        XCTAssertFalse(b.store.projects.contains { $0.id == other.id })

        // 9. Converged.
        func live(_ db: Database) -> [EntityID: TodoTask] { db.tasks.filter { !$0.value.deleted } }
        XCTAssertEqual(live(a.store.db), live(b.store.db))
    }
}

/// Passes requests to a real server, running a hook once before the PUT of a given path.
private actor Racing: CalDAVServer {
    nonisolated let home: String
    nonisolated let calendarHome: CalendarHome
    let base: CalDAVServer
    private var hooks: [String: @Sendable () async -> Void] = [:]
    private(set) var puts = 0

    init(_ base: CalDAVServer) { self.base = base; home = base.home; calendarHome = base.calendarHome }

    func setBefore(_ path: String, _ hook: @escaping @Sendable () async -> Void) { hooks[path] = hook }

    func calendars() async throws -> [RemoteCalendar] { try await base.calendars() }
    func changes(in calendar: String, since token: String?) async throws -> CalendarChanges {
        try await base.changes(in: calendar, since: token)
    }
    func createCalendar(_ path: String, name: String, color: String, order: String) async throws {
        try await base.createCalendar(path, name: name, color: color, order: order)
    }
    func setProperties(_ path: String, _ values: [CalendarProperty: String?]) async throws {
        try await base.setProperties(path, values)
    }
    func deleteCalendar(_ path: String) async throws { try await base.deleteCalendar(path) }
    func share(_ path: String, with user: String) async throws { try await base.share(path, with: user) }
    func put(_ path: String, ics: String, ifMatch: String?) async throws -> String? {
        if let hook = hooks.removeValue(forKey: path) { await hook() }
        puts += 1
        return try await base.put(path, ics: ics, ifMatch: ifMatch)
    }
    func move(_ path: String, to destination: String, ifMatch: String?) async throws {
        try await base.move(path, to: destination, ifMatch: ifMatch)
    }
    func delete(_ path: String, ifMatch: String?) async throws { try await base.delete(path, ifMatch: ifMatch) }
}
