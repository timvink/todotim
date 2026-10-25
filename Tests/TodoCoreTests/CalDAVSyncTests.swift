import XCTest
@testable import TodoCore

@MainActor
final class CalDAVSyncTests: XCTestCase {
    let home = "calendars/tim"
    var inbox: String { "\(home)/todotim-inbox" }

    /// A device: a store plus its sync state, syncing against `server`.
    @MainActor final class Device {
        let store: TodoStore
        var state = CalDAVState(account: "test")
        var last: SyncResult?
        init(_ db: Database = Database()) { store = TodoStore(db: db) }

        @discardableResult
        func sync(_ server: FakeCalDAVServer, shareWith: [String] = [], previous: Database? = nil) async throws -> SyncResult {
            let r = try await CalDAVSync.sync(local: store.db, state: state, server: server, shareWith: shareWith, previous: previous)
            store.replaceDatabase(r.merged)
            state = r.state
            last = r
            return r
        }
    }

    // MARK: - Migration

    func testFirstSyncUploadsEverythingAndIsIdempotent() async throws {
        let server = FakeCalDAVServer()
        let device = Device()
        let s = device.store
        let p = s.addProject(name: "Home", color: "red")
        let sec = s.addSection(projectId: p.id, name: "Garden")
        let parent = s.addTask(content: "Parent", projectId: p.id, sectionId: sec.id, priority: .p1,
                               due: DueDate(date: "2026-11-03"), labels: ["errands"])
        s.addTask(content: "Child", projectId: p.id, parentId: parent.id)
        s.addTask(content: "In inbox", projectId: TodoStore.inboxID, description: "line 1\nline 2, with; punctuation")

        let r = try await device.sync(server, shareWith: ["tasks-agent"])
        let mkcalendars = await server.count("MKCALENDAR")
        XCTAssertEqual(mkcalendars, 2)
        let calendars = await server.calendarsByPath
        XCTAssertEqual(Set(calendars.keys), [inbox, "\(home)/\(p.id)"])
        XCTAssertEqual(calendars[inbox]?.props.name, "Inbox")
        XCTAssertEqual(calendars["\(home)/\(p.id)"]?.props.color, "#DB4035")
        let sections = try XCTUnwrap(calendars["\(home)/\(p.id)"]?.props.sections.flatMap(PropertyList.decode))
        XCTAssertEqual(sections.map(\.name), ["Garden"])
        let labels = try XCTUnwrap(calendars[inbox]?.props.labels.flatMap(PropertyList.decode))
        XCTAssertEqual(labels.map(\.name), ["errands"])
        XCTAssertEqual(labels.first?.color, "#808080")
        let shares = await server.shares
        XCTAssertEqual(shares.map(\.user), ["tasks-agent", "tasks-agent"])
        let homePaths = await server.paths(in: "\(home)/\(p.id)")
        XCTAssertEqual(homePaths.count, 2)
        let parentStored = await server.ics("\(home)/\(p.id)/\(parent.id).ics")
        let parentICS = try XCTUnwrap(parentStored).unfolded
        XCTAssertTrue(parentICS.contains("PRIORITY:1"))
        XCTAssertTrue(parentICS.contains("DUE;VALUE=DATE:20261103"))
        XCTAssertTrue(parentICS.contains("CATEGORIES:errands"))
        XCTAssertTrue(parentICS.contains("X-TODOTIM-SECTION;X-NAME=Garden;X-ORDER=1:\(sec.id)"), parentICS)
        let childID = s.subtasks(of: parent.id).first!.id
        let childStored = await server.ics("\(home)/\(p.id)/\(childID).ics")
        let childICS = try XCTUnwrap(childStored).unfolded
        XCTAssertTrue(childICS.contains("RELATED-TO;RELTYPE=PARENT:\(parent.id)"))
        XCTAssertTrue(childICS.contains("X-TODOTIM-SECTION"), "subtasks carry the section too")
        XCTAssertTrue(r.warnings.isEmpty)

        // Second run: nothing to write, and the store is unchanged.
        let before = s.db
        await server.resetCounts()
        let r2 = try await device.sync(server)
        XCTAssertEqual(r2.writes, 0)
        XCTAssertEqual(s.db, before)

        // The same data synced again from scratch (state lost) creates no duplicates.
        device.state = CalDAVState(account: "test")
        let r3 = try await device.sync(server)
        XCTAssertEqual(r3.writes, 0)
        let after = await server.paths(in: "\(home)/\(p.id)")
        XCTAssertEqual(after.count, 2)

        // Idle sync with `previous`: one PROPFIND.
        await server.resetCounts()
        try await device.sync(server, previous: s.db)
        let requests = await server.requests
        XCTAssertEqual(requests, ["PROPFIND": 1])
    }

    func testSecondDeviceGetsEverything() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let p = a.store.addProject(name: "Work", color: "blue")
        let sec = a.store.addSection(projectId: p.id, name: "Now")
        let t = a.store.addTask(content: "Write report", projectId: p.id, sectionId: sec.id, priority: .p2, labels: ["deep"])
        a.store.addTask(content: "Sub", projectId: p.id, parentId: t.id)
        a.store.updateTask(t.id) { $0.collapsed = true }
        try await a.sync(server)

        let b = Device()
        try await b.sync(server)
        func live(_ db: Database) -> Database {
            var d = db
            d.tasks = d.tasks.filter { !$0.value.deleted }
            return d
        }
        let ta = a.store.db.tasks[t.id]!, tb = try XCTUnwrap(b.store.db.tasks[t.id])
        XCTAssertEqual(tb, ta)
        XCTAssertEqual(b.store.project(p.id)?.name, "Work")
        XCTAssertEqual(b.store.project(p.id)?.color, "blue")
        XCTAssertEqual(b.store.sections(in: p.id).map(\.name), ["Now"])
        XCTAssertEqual(b.store.labels.map(\.name), ["deep"])
        XCTAssertEqual(Set(live(b.store.db).tasks.keys), Set(live(a.store.db).tasks.keys))
    }

    // MARK: - Changes in both directions

    func testRemoteEditLocalEditAndConflicts() async throws {
        let server = FakeCalDAVServer()
        let a = Device(), b = Device()
        let t1 = a.store.addTask(content: "one", projectId: TodoStore.inboxID)
        let t2 = a.store.addTask(content: "two", projectId: TodoStore.inboxID)
        try await a.sync(server)
        try await b.sync(server)

        // b edits t1; a edits t2: both survive.
        b.store.updateTask(t1.id) { $0.content = "one (b)" }
        try await b.sync(server)
        a.store.updateTask(t2.id) { $0.content = "two (a)" }
        try await a.sync(server)
        try await b.sync(server)
        XCTAssertEqual(a.store.task(t1.id)?.content, "one (b)")
        XCTAssertEqual(b.store.task(t2.id)?.content, "two (a)")

        // Both edit t1: the later edit wins on both devices.
        a.store.updateTask(t1.id) { $0.content = "one (a, earlier)" }
        try await Task.sleep(for: .milliseconds(1100))
        b.store.updateTask(t1.id) { $0.content = "one (b, later)" }
        try await b.sync(server)
        try await a.sync(server)
        try await b.sync(server)
        XCTAssertEqual(a.store.task(t1.id)?.content, "one (b, later)")
        XCTAssertEqual(b.store.task(t1.id)?.content, "one (b, later)")
    }

    func testDeletesBothWays() async throws {
        let server = FakeCalDAVServer()
        let a = Device(), b = Device()
        let t1 = a.store.addTask(content: "delete here", projectId: TodoStore.inboxID)
        let t2 = a.store.addTask(content: "delete remotely", projectId: TodoStore.inboxID)
        let p = a.store.addProject(name: "Doomed")
        a.store.addTask(content: "in doomed", projectId: p.id)
        try await a.sync(server)
        try await b.sync(server)

        a.store.deleteTask(t1.id)
        try await a.sync(server)
        let gone = await server.ics("\(inbox)/\(t1.id).ics")
        XCTAssertNil(gone)
        XCTAssertEqual(a.store.db.tasks[t1.id]?.deleted, true, "tombstone kept locally")

        await server.remove("\(inbox)/\(t2.id).ics")
        try await a.sync(server)
        XCTAssertNil(a.store.task(t2.id).flatMap { $0.deleted ? nil : $0 })
        try await b.sync(server)
        XCTAssertEqual(b.store.db.tasks[t1.id]?.deleted ?? true, true)
        XCTAssertEqual(b.store.db.tasks[t2.id]?.deleted ?? true, true)

        // Deleting a project deletes its calendar; the other device drops it.
        b.store.deleteProject(p.id)
        try await b.sync(server)
        let cals = await server.calendarsByPath
        XCTAssertNil(cals["\(home)/\(p.id)"])
        try await a.sync(server)
        XCTAssertNil(a.store.projects.first { $0.id == p.id })
    }

    func testMoveBetweenListsUsesMove() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let p = a.store.addProject(name: "Target")
        let t = a.store.addTask(content: "move me", projectId: TodoStore.inboxID)
        try await a.sync(server)
        await server.resetCounts()
        a.store.moveTask(t.id, projectId: p.id, sectionId: nil, parentId: nil)
        try await a.sync(server)
        let moves = await server.count("MOVE")
        XCTAssertEqual(moves, 1)
        let inInbox = await server.paths(in: inbox), inTarget = await server.paths(in: "\(home)/\(p.id)")
        XCTAssertEqual(inInbox, [])
        XCTAssertEqual(inTarget, ["\(home)/\(p.id)/\(t.id).ics"])
        let b = Device()
        try await b.sync(server)
        XCTAssertEqual(b.store.task(t.id)?.projectId, p.id)
    }

    func testSectionRenameRewritesItsTasks() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let p = a.store.addProject(name: "P")
        let sec = a.store.addSection(projectId: p.id, name: "Old")
        let t = a.store.addTask(content: "t", projectId: p.id, sectionId: sec.id)
        try await a.sync(server)
        a.store.updateSection(sec.id) { $0.name = "New \"quoted\"" }
        try await a.sync(server)
        let stored = await server.ics("\(home)/\(p.id)/\(t.id).ics")
        let ics = try XCTUnwrap(stored).unfolded
        XCTAssertTrue(ics.contains("X-NAME=New ^'quoted^';X-ORDER=1:"), ics)
        // A device that cannot read the sections property (a sharee) still sees the section.
        await server.setProperty("\(home)/\(p.id)", .sections, nil)
        let b = Device()
        try await b.sync(server)
        XCTAssertEqual(b.store.sections(in: p.id).map(\.name), ["New \"quoted\""])
        XCTAssertEqual(b.store.task(t.id)?.sectionId, sec.id)
    }

    func testForeignTaskIsPreservedAndTagsBecomeLabels() async throws {
        let server = FakeCalDAVServer()
        await server.addCalendar("groceries", name: "Groceries", color: "#FF0000AA")
        let path = "\(home)/groceries/foreign.ics"
        await server.store(path, """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        PRODID:-//Other//EN\r
        BEGIN:VTODO\r
        UID:Foreign UID with spaces\r
        DTSTAMP:20261020T100000Z\r
        CREATED:20261020T100000Z\r
        LAST-MODIFIED:20261020T100000Z\r
        SUMMARY:Milk\r
        PRIORITY:3\r
        DTSTART;TZID=Europe/Amsterdam:20261101T080000\r
        DUE;TZID=Europe/Amsterdam:20261101T090000\r
        RRULE:FREQ=WEEKLY;COUNT=3\r
        CATEGORIES:shop,dairy\r
        X-OTHER-CLIENT:keep me\r
        BEGIN:VALARM\r
        ACTION:DISPLAY\r
        TRIGGER:-PT15M\r
        END:VALARM\r
        END:VTODO\r
        END:VCALENDAR\r

        """)
        let a = Device()
        try await a.sync(server)
        let id = VTodo.taskID(forUID: "Foreign UID with spaces")
        let t = try XCTUnwrap(a.store.task(id))
        XCTAssertEqual(t.projectId, "groceries")
        XCTAssertEqual(a.store.project(t.projectId)?.color, "red")
        XCTAssertEqual(t.priority, .p1)
        XCTAssertEqual(t.recurrence, "FREQ=WEEKLY;COUNT=3")
        XCTAssertEqual(Set(a.store.labels.map(\.name)), ["shop", "dairy"])
        // Reading changed nothing on the server except the labels list.
        let untouched = await server.ics(path)
        XCTAssertTrue(untouched!.contains("PRIORITY:3"))

        // Completing the repeating task moves it a week ahead, keeping the time, DTSTART and alarm.
        a.store.toggleComplete(id, calendar: Calendar.amsterdam)
        XCTAssertEqual(a.store.task(id)?.due?.date, "2026-11-08")
        XCTAssertEqual(a.store.task(id)?.isCompleted, false)
        try await a.sync(server)
        let stored = await server.ics(path)
        let ics = try XCTUnwrap(stored).unfolded
        XCTAssertTrue(ics.contains("DUE;TZID=Europe/Amsterdam:20261108T090000"), ics)
        XCTAssertTrue(ics.contains("DTSTART;TZID=Europe/Amsterdam:20261108T080000"), ics)
        XCTAssertTrue(ics.contains("RRULE:FREQ=WEEKLY;COUNT=2"), ics)
        XCTAssertTrue(ics.contains("X-OTHER-CLIENT:keep me"))
        XCTAssertTrue(ics.contains("TRIGGER:-PT15M"))
        XCTAssertTrue(ics.contains("PRIORITY:3"), "unchanged fields keep their foreign values")
        XCTAssertTrue(ics.contains("UID:Foreign UID with spaces"))
    }

    func testLocalRepairIsNotWrittenToOtherClientsTasks() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        try await a.sync(server)
        let path = "\(inbox)/orphan.ics"
        await server.store(path, "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:orphan\r\nSUMMARY:Sub\r\n"
            + "RELATED-TO:parent-elsewhere\r\nX-TODOTIM-SECTION;X-NAME=Gone;X-ORDER=3:gone-section\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        await server.resetCounts()
        try await a.sync(server)
        try await a.sync(server)
        XCTAssertNil(a.store.task("orphan")?.parentId, "shown as a top-level task")
        XCTAssertNil(a.store.task("orphan")?.sectionId)
        var puts = await server.count("PUT")
        XCTAssertEqual(puts, 0, "the repair stays local")

        // A real edit is written, and keeps the relation and section TodoTim cannot see.
        a.store.updateTask("orphan") { $0.content = "Sub (edited)" }
        try await a.sync(server)
        puts = await server.count("PUT")
        XCTAssertEqual(puts, 1)
        let ics = await server.ics(path)!
        XCTAssertTrue(ics.contains("SUMMARY:Sub (edited)"))
        XCTAssertTrue(ics.contains("RELATED-TO:parent-elsewhere"))
        XCTAssertTrue(ics.contains("X-TODOTIM-SECTION;X-NAME=Gone;X-ORDER=3:gone-section"))
        try await a.sync(server)
        let again = await server.count("PUT")
        XCTAssertEqual(again, 1, "converged")
    }

    func testListIsNotDeletedWhileATaskStillHasToMoveOutOfIt() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let doomed = a.store.addProject(name: "Doomed"), keep = a.store.addProject(name: "Keep")
        try await a.sync(server)
        let path = "\(home)/\(doomed.id)/foreign.ics"
        await server.store(path, "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:foreign\r\nSUMMARY:Rescue me\r\n"
            + "BEGIN:VALARM\r\nTRIGGER:-PT5M\r\nEND:VALARM\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        try await a.sync(server)
        a.store.moveTask("foreign", projectId: keep.id, sectionId: nil, parentId: nil)
        a.store.deleteProject(doomed.id)
        await server.setFailMoves(true)
        let r = try await a.sync(server)
        XCTAssertFalse(r.isComplete)
        let still = await server.ics(path)
        XCTAssertNotNil(still, "the list (and the object) survive the failed MOVE")
        await server.setFailMoves(false)
        try await a.sync(server)
        let moved = await server.ics("\(home)/\(keep.id)/foreign.ics")
        XCTAssertTrue(moved?.contains("TRIGGER:-PT5M") == true, "moved with its alarm")
        let cals = await server.calendarsByPath
        XCTAssertNil(cals["\(home)/\(doomed.id)"], "then the list is deleted")
    }

    func testMoveIntoAListThatCannotBeCreatedYetIsNotUndone() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let t = a.store.addTask(content: "t", projectId: TodoStore.inboxID)
        try await a.sync(server)
        let later = a.store.addProject(name: "Later")
        a.store.moveTask(t.id, projectId: later.id, sectionId: nil, parentId: nil)
        a.store.updateTask(t.id) { $0.content = "t (edited)" }
        await server.setRateLimitedCreates(["\(home)/\(later.id)"])
        try await a.sync(server)
        try await a.sync(server)
        XCTAssertEqual(a.store.task(t.id)?.projectId, later.id, "the move is kept while the list waits")
        XCTAssertEqual(a.store.task(t.id)?.content, "t (edited)")
        await server.setRateLimitedCreates([])
        try await a.sync(server)
        let moved = await server.ics("\(home)/\(later.id)/\(t.id).ics")
        XCTAssertTrue(moved?.contains("SUMMARY:t (edited)") == true)
        let old = await server.paths(in: inbox)
        XCTAssertEqual(old, [])
    }

    func testUnreadableObjectIsNotTakenForADelete() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        try await a.sync(server)
        let path = "\(inbox)/x.ics"
        let good = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:x\r\nSUMMARY:Keep me\r\nLAST-MODIFIED:20200101T000000Z\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
        await server.store(path, good)
        try await a.sync(server)
        XCTAssertEqual(a.store.task("x")?.content, "Keep me")
        // Another client writes something TodoTim can't read (here: only an override).
        await server.store(path, good.replacingOccurrences(of: "UID:x", with: "UID:x\r\nRECURRENCE-ID:20261101T000000Z"))
        await server.resetCounts()
        try await a.sync(server)
        try await a.sync(server)
        XCTAssertEqual(a.store.task("x")?.deleted, false, "not deleted locally")
        var deletes = await server.count("DELETE"), puts = await server.count("PUT")
        XCTAssertEqual(deletes + puts, 0, "and not written")
        // Readable again (with its old LAST-MODIFIED): nothing is lost.
        await server.store(path, good)
        try await a.sync(server)
        deletes = await server.count("DELETE"); puts = await server.count("PUT")
        XCTAssertEqual(deletes + puts, 0)
        XCTAssertEqual(a.store.task("x")?.content, "Keep me")
        let still = await server.ics(path)
        XCTAssertNotNil(still)
    }

    func testEventCalendarsAndSharedCalendarsAreIgnored() async throws {
        let server = FakeCalDAVServer()
        await server.addCalendar("personal", components: ["VEVENT", "VTODO"])
        await server.addCalendar("theirs_shared_by_bob", sharedBy: "bob")
        await server.store("\(home)/personal/x.ics", "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:x\r\nSUMMARY:hidden\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        let a = Device()
        try await a.sync(server)
        XCTAssertNil(a.store.task("x"))
        XCTAssertEqual(a.store.projects.map(\.id), [])
    }

    func testBrokenRemoteObjectsAreSkipped() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        try await a.sync(server)
        await server.store("\(inbox)/bad1.ics", "not a calendar")
        await server.store("\(inbox)/bad2.ics", "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nSUMMARY:no uid\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        await server.store("\(inbox)/deep.ics", String(repeating: "BEGIN:X\r\n", count: 50) + "END:X\r\n")
        await server.store("\(inbox)/ok.ics", "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:ok\r\nSUMMARY:fine\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        try await a.sync(server)
        XCTAssertEqual(a.store.tasks(projectId: TodoStore.inboxID, sectionId: nil).map(\.content), ["fine"])
        let bad = await server.ics("\(inbox)/bad1.ics")
        XCTAssertEqual(bad, "not a calendar", "unreadable objects are left alone")
    }

    func testConflictDuringWriteIsMergedInTheNextPass() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let t = a.store.addTask(content: "base", projectId: TodoStore.inboxID)
        try await a.sync(server)
        let path = "\(inbox)/\(t.id).ics"
        a.store.updateTask(t.id) { $0.priority = .p1 }
        // Another client changes the title just before our PUT: the PUT fails with 412 and the
        // next pass merges again; the other edit is newer, so it wins (last writer per task).
        let original = await server.ics(path)!
        await server.setBeforePut { [server] p in
            guard p == path else { return }
            await server.setBeforePut(nil)
            let changed = original.replacingOccurrences(of: "SUMMARY:base", with: "SUMMARY:from phone")
                .replacingOccurrences(of: #"LAST-MODIFIED:\d+T\d+Z"#, with: "LAST-MODIFIED:20991231T000000Z", options: .regularExpression)
            await server.store(path, changed)
        }
        try await a.sync(server)
        XCTAssertEqual(a.store.task(t.id)?.content, "from phone")
        let ics = await server.ics(path)!
        XCTAssertTrue(ics.contains("SUMMARY:from phone"))
    }

    func testShareFailureIsAWarning() async throws {
        let server = FakeCalDAVServer()
        await server.setFailShares(true)
        let a = Device()
        a.store.addTask(content: "x", projectId: TodoStore.inboxID)
        let r = try await a.sync(server, shareWith: ["tasks-agent"])
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertTrue(r.warnings[0].contains("tasks-agent"))
        let paths = await server.paths(in: inbox)
        XCTAssertEqual(paths.count, 1, "sync went on")
    }

    func testListThatCannotBeCreatedWaitsWithoutBlockingTheRest() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let blocked = a.store.addProject(name: "Blocked")
        let t = a.store.addTask(content: "waits", projectId: blocked.id)
        a.store.addTask(content: "goes", projectId: TodoStore.inboxID)
        await server.setRateLimitedCreates(["\(home)/\(blocked.id)"])
        let r = try await a.sync(server)
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertTrue(r.warnings[0].contains("10 new lists per hour"), r.warnings[0])
        let inInbox = await server.paths(in: inbox)
        XCTAssertEqual(inInbox.count, 1)
        XCTAssertNotNil(a.store.task(t.id), "the local task stays")
        XCTAssertFalse(r.isComplete)
        // Once the server allows it, the list and its task follow (an incomplete sync is never
        // treated as idle).
        await server.setRateLimitedCreates([])
        let r2 = try await a.sync(server, previous: a.store.db)
        XCTAssertEqual(r2.warnings, [])
        let created = await server.paths(in: "\(home)/\(blocked.id)")
        XCTAssertEqual(created, ["\(home)/\(blocked.id)/\(t.id).ics"])
    }

    func testProjectOrderIsRenumberedToIntegers() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let p1 = a.store.addProject(name: "1"), p2 = a.store.addProject(name: "2"), p3 = a.store.addProject(name: "3")
        try await a.sync(server)
        a.store.moveProject(p3.id, to: 1)  // between p1 and p2: order 1.5
        try await a.sync(server)
        XCTAssertEqual(a.store.projects.map(\.id), [p1.id, p3.id, p2.id])
        XCTAssertTrue(a.store.projects.allSatisfy { $0.order == $0.order.rounded() })
        let b = Device()
        try await b.sync(server)
        XCTAssertEqual(b.store.projects.map(\.id), [p1.id, p3.id, p2.id])
    }

    func testRemoteRenameAndColorAndLabelChanges() async throws {
        let server = FakeCalDAVServer()
        let a = Device()
        let p = a.store.addProject(name: "Before", color: "green")
        a.store.addLabel(name: "x", color: "red")
        try await a.sync(server)
        await server.setProperty("\(home)/\(p.id)", .name, "After")
        await server.setProperty("\(home)/\(p.id)", .color, "#4073FF")
        try await a.sync(server)
        XCTAssertEqual(a.store.project(p.id)?.name, "After")
        XCTAssertEqual(a.store.project(p.id)?.color, "blue")
    }
}

extension String {
    /// Calendar data with folded lines joined, for content checks.
    var unfolded: String { replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "") }
}

extension Calendar {
    static var amsterdam: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }
}
