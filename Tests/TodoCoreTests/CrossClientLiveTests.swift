import XCTest
@testable import TodoCore

/// The Mac's steps of the cross-client test with the Android sync (`android/core`, `CrossClientLiveTest`), against
/// a real CalDAV server. Run by `scripts/live-interop.sh`, which alternates the Mac's and the phone's steps; each
/// step is one process, so state goes through the server and JSON files in `TODOTIM_CROSS_DIR`. Destructive for the
/// account's task lists: use a throwaway user.
///
///     TODOTIM_LIVE_URL=… TODOTIM_LIVE_USER=… TODOTIM_LIVE_PASSWORD=… scripts/live-interop.sh
///
/// Steps: `a` the Mac makes the data (and another client adds a property and an alarm), `c` the Mac checks the
/// phone's changes and completes a repeating task without syncing, `d2` the Mac completes another repeating task
/// and syncs, `d4` the Mac checks each repeating task advanced once and agrees with the phone's tasks.
@MainActor
final class CrossClientLiveTests: XCTestCase {
    private var server: CalDAVClient!
    private var dir: URL!
    private var step = ""

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let step = env["TODOTIM_CROSS_STEP"], let dir = env["TODOTIM_CROSS_DIR"],
              let url = env["TODOTIM_LIVE_URL"], let user = env["TODOTIM_LIVE_USER"], let password = env["TODOTIM_LIVE_PASSWORD"]
        else { throw XCTSkip("run by scripts/live-interop.sh") }
        self.step = step
        self.dir = URL(fileURLWithPath: dir)
        server = try await CalDAVClient.connect(serverURL: url, username: user, password: password, cached: nil)
    }

    // MARK: - State between steps

    @MainActor private final class Mac {
        let store: TodoStore
        var state: CalDAVState
        init(db: Database = Database(), state: CalDAVState = CalDAVState(account: "cross")) {
            store = TodoStore(db: db)
            self.state = state
        }

        @discardableResult
        func sync(_ server: CalDAVServer) async throws -> SyncResult {
            let r = try await CalDAVSync.sync(local: store.db, state: state, server: server)
            store.replaceDatabase(r.merged)
            state = r.state
            return r
        }
    }

    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func save(_ mac: Mac) throws {
        try JSONEncoder().encode(mac.store.db).write(to: file("mac-db.json"))
        try JSONEncoder().encode(mac.state).write(to: file("mac-state.json"))
    }

    private func load() throws -> Mac {
        let db = try JSONDecoder().decode(Database.self, from: Data(contentsOf: file("mac-db.json")))
        let state = try JSONDecoder().decode(CalDAVState.self, from: Data(contentsOf: file("mac-state.json")))
        return Mac(db: db, state: state)
    }

    private func readJSON(_ name: String) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file(name)))
    }

    private func object(_ path: String) async throws -> RemoteResource? {
        let cal = String(path[..<path.lastIndex(of: "/")!])
        return try await server.changes(in: cal, since: nil).changed.first { $0.path == path }
    }

    private func need(_ path: String) async throws -> RemoteResource {
        let found = try await object(path)
        return try XCTUnwrap(found, path)
    }

    private func path(_ calendar: String, _ id: String) -> String {
        davPath(server.home, "\(calendar == TodoStore.inboxID ? CalDAVSync.inboxURI : calendar)/\(id).ics")
    }

    /// The lines another client added, as the server serves them (folded, unchanged; Radicale moves them around):
    /// the X-OTHER-CLIENT property and the alarm. Line ends as served: a REPORT's XML turns CRLF into LF.
    private static func foreign(_ ics: String) -> String {
        var out: [String] = []
        var inAlarm = false
        var keep = false
        for line in ics.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if keep { out.append(line) }
                continue
            }
            if line == "BEGIN:VALARM" { inAlarm = true }
            keep = inAlarm || line.hasPrefix("X-OTHER-CLIENT")
            if keep { out.append(line) }
            if line == "END:VALARM" { inAlarm = false }
        }
        return out.joined(separator: "\n")
    }

    static let macTitle = String(repeating: "Café ☕️ — 日本語 ", count: 6)
    static let macDescription = "a,b;c\\d\nline 2: \"quoted\""
    static let phoneTitle = String(repeating: "Ünïcødé ✅ ", count: 9)
    static let phoneDescription = "x;y,z\\\n🙂"
    static let gardenName = "Garden; \"yard\": 1,2 ^"

    func testStep() async throws {
        switch step {
        case "a": try await stepA()
        case "c": try await stepC()
        case "d2": try await stepD2()
        case "d4": try await stepD4()
        case "e": try await stepE()
        case "f1": try await stepF1()
        case "f3": try await stepF3()
        default: throw XCTSkip("step \(step) is the phone's")
        }
    }

    // MARK: - Steps

    /// The Mac makes projects, sections, labels and tasks; another client adds a property and an alarm.
    private func stepA() async throws {
        var paths = Set(try await server.calendars().map(\.path))
        paths.insert(davPath(server.home, CalDAVSync.inboxURI))
        for path in paths {
            _ = try? await server.setProperties(path, [.sections: nil, .labels: nil])
            _ = try await server.dav.send("DELETE", path, collection: true, headers: ["X-NC-CalDAV-No-Trashbin": "1"])
        }

        let mac = Mac()
        let s = mac.store
        let home = s.addProject(name: "Home", color: "green")
        let errands = s.addProject(name: "Errands", color: "orange")
        let garden = s.addSection(projectId: home.id, name: "Garden")
        let indoors = s.addSection(projectId: home.id, name: "Indoors")
        let outside = s.addLabel(name: "outside", color: "red")
        let weekend = s.addLabel(name: "weekend", color: "blue")
        let prune = s.addTask(content: "Prune roses", projectId: home.id, sectionId: garden.id, description: "Line 1\nLine 2",
                              priority: .p1, due: DueDate(date: "2026-11-03"), labels: ["outside"])
        let shears = s.addTask(content: "Buy shears", projectId: home.id, parentId: prune.id, priority: .p3)
        let water = s.addTask(content: "Water plants", projectId: home.id, due: DueDate(date: "2026-11-02"))
        s.updateTask(water.id) { $0.recurrence = "FREQ=WEEKLY;COUNT=10" }
        let bins = s.addTask(content: "Take out bins", projectId: errands.id, due: DueDate(date: "2026-11-04"))
        s.updateTask(bins.id) { $0.recurrence = "FREQ=WEEKLY" }
        let gym = s.addTask(content: "Gym", projectId: errands.id, due: DueDate(date: "2026-11-05"))
        s.updateTask(gym.id) { $0.recurrence = "FREQ=DAILY;INTERVAL=2" }
        let mum = s.addTask(content: "Call mum", projectId: TodoStore.inboxID, priority: .p2, labels: ["weekend"])
        let vacuum = s.addTask(content: "Vacuum", projectId: home.id, sectionId: indoors.id)
        let passport = s.addTask(content: "Renew passport", projectId: TodoStore.inboxID)
        // Text that needs escaping, and a title long enough to fold inside multi-byte characters.
        let unicode = s.addTask(content: Self.macTitle, projectId: TodoStore.inboxID, description: Self.macDescription,
                                labels: ["errand, quick"])
        let fence = s.addTask(content: "Paint fence", projectId: home.id, sectionId: garden.id)
        let paint = s.addTask(content: "Buy paint", projectId: home.id, parentId: fence.id)
        let trip = s.addTask(content: "Plan trip", projectId: TodoStore.inboxID)
        let hotel = s.addTask(content: "Book hotel", projectId: TodoStore.inboxID, parentId: trip.id, due: DueDate(date: "2026-12-01"))
        let done = s.addTask(content: "Done already", projectId: TodoStore.inboxID)
        s.toggleComplete(done.id)

        let first = try await mac.sync(server)
        XCTAssertTrue(first.isComplete)
        XCTAssertEqual(first.warnings, [])

        // Another client adds its own property and an alarm to the passport task.
        let passportPath = path(TodoStore.inboxID, passport.id)
        let original = try await need(passportPath)
        let edited = original.ics
            .replacingOccurrences(of: "END:VTODO", with: "X-OTHER-CLIENT;X-P=\"a,b\":keep me\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\n"
                + "DESCRIPTION:Passport\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VTODO")
            .replacingOccurrences(of: #"LAST-MODIFIED:\d{8}T\d{6}Z"#, with: "LAST-MODIFIED:\(ICalendar.utcString(Date()))",
                                  options: .regularExpression)
        _ = try await server.put(passportPath, ics: edited, ifMatch: original.etag)
        let served = try await need(passportPath).ics
        XCTAssertTrue(Self.foreign(served).contains("TRIGGER:-PT15M"), served)

        // Another client's task whose UID is not an id, with a DATE-TIME due in a timezone, and another client's
        // list whose URI is not an id: both sides must derive the same ids.
        let other = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Other//EN", "BEGIN:VTODO", "UID:x@other.example",
                     "DTSTAMP:20261020T100000Z", "LAST-MODIFIED:20261020T100000Z", "SUMMARY:Foreign uid",
                     "DUE;TZID=Europe/Amsterdam:20261120T183000", "END:VTODO", "END:VCALENDAR", ""].joined(separator: "\r\n")
        _ = try await server.put(davPath(server.home, "\(CalDAVSync.inboxURI)/x other@ex.ics"), ics: other, ifMatch: nil)
        // DATE-TIME dues that fall on another day here (the script sets TZ=Europe/Amsterdam): in UTC with a DTSTART,
        // and in New York.
        for (uid, lines) in [("late-utc", ["DTSTART:20261120T220000Z", "DUE:20261120T233000Z"]),
                             ("ny", ["DUE;TZID=America/New_York:20261120T200000"])] {
            let ics = (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Other//EN", "BEGIN:VTODO", "UID:\(uid)",
                        "DTSTAMP:20261020T100000Z", "LAST-MODIFIED:20261020T100000Z", "SUMMARY:Timed \(uid)"]
                       + lines + ["END:VTODO", "END:VCALENDAR", ""]).joined(separator: "\r\n")
            _ = try await server.put(davPath(server.home, "\(CalDAVSync.inboxURI)/\(uid).ics"), ics: ics, ifMatch: nil)
        }
        let otherList = davPath(server.home, "other list.1")
        _ = try await server.createCalendar(otherList, name: "Other list", color: "#FF0000", order: "5")
        let inOther = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Other//EN", "BEGIN:VTODO", "UID:t1",
                       "DTSTAMP:20261020T100000Z", "LAST-MODIFIED:20261020T100000Z", "SUMMARY:In other list", "END:VTODO",
                       "END:VCALENDAR", ""].joined(separator: "\r\n")
        _ = try await server.put("\(otherList)/t1.ics", ics: inOther, ifMatch: nil)

        let second = try await mac.sync(server)
        XCTAssertTrue(second.isComplete)
        let foreignUid = try XCTUnwrap(s.db.tasks.values.first { $0.content == "Foreign uid" })
        XCTAssertEqual(foreignUid.due, DueDate(date: "2026-11-20"))
        let otherProject = try XCTUnwrap(s.db.projects.values.first { $0.name == "Other list" })
        XCTAssertEqual(s.task("t1")?.projectId, otherProject.id)
        XCTAssertEqual(s.task("late-utc")?.due, DueDate(date: "2026-11-21"))
        XCTAssertEqual(s.task("ny")?.due, DueDate(date: "2026-11-21"))

        let ids = ["home": home.id, "errands": errands.id, "garden": garden.id, "indoors": indoors.id,
                   "outside": outside.id, "weekend": weekend.id, "prune": prune.id, "shears": shears.id, "water": water.id,
                   "bins": bins.id, "gym": gym.id, "mum": mum.id, "vacuum": vacuum.id, "passport": passport.id,
                   "unicode": unicode.id, "fence": fence.id, "paint": paint.id, "trip": trip.id, "hotel": hotel.id,
                   "foreignUid": foreignUid.id, "otherList": otherProject.id, "done": done.id,
                   "foreign": Self.foreign(served)]
        try JSONEncoder().encode(ids).write(to: file("ids.json"))
        try save(mac)
    }

    /// The Mac sees the phone's changes; then it completes "Gym" without syncing (the phone completes it too).
    private func stepC() async throws {
        let ids = try readJSON("ids.json")
        let phone = try readJSON("phone-ids.json")
        let mac = try load()
        let r = try await mac.sync(server)
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.warnings, [])
        let s = mac.store
        func task(_ key: String) -> TodoTask? { s.task(ids[key] ?? phone[key]!).flatMap { $0.deleted ? nil : $0 } }

        XCTAssertEqual(task("passport")?.content, "Renew passport (phone)")
        XCTAssertEqual(task("prune")?.due, DueDate(date: "2026-11-10"))
        XCTAssertEqual(task("water")?.due, DueDate(date: "2026-11-09"))
        XCTAssertEqual(task("water")?.recurrence, "FREQ=WEEKLY;COUNT=9")
        XCTAssertEqual(task("water")?.isCompleted, false)
        XCTAssertNil(task("vacuum"))
        XCTAssertEqual(task("mum")?.projectId, ids["errands"])
        XCTAssertEqual(task("mum")?.labels, ["weekend", "outside"])
        XCTAssertEqual(task("shears")?.isCompleted, true)
        XCTAssertEqual(task("prune")?.description, "")
        XCTAssertEqual(task("fence")?.isCompleted, true)
        XCTAssertEqual(task("paint")?.isCompleted, true, "completing the parent on the phone completes its subtask")
        XCTAssertEqual(task("trip")?.projectId, ids["errands"])
        XCTAssertEqual(task("trip")?.collapsed, true)
        XCTAssertEqual(task("hotel")?.projectId, ids["errands"])
        XCTAssertEqual(task("hotel")?.parentId, ids["trip"])
        let phoneTask = try XCTUnwrap(task("phoneUnicode"))
        XCTAssertEqual(phoneTask.content, Self.phoneTitle)
        XCTAssertEqual(phoneTask.description, Self.phoneDescription)
        XCTAssertEqual(phoneTask.labels, ["phone, label", "outside"])
        XCTAssertEqual(task("pruneChild")?.parentId, ids["prune"])
        XCTAssertEqual(task("pruneChild")?.sectionId, ids["garden"])
        XCTAssertEqual(Set(s.db.labels.values.filter { !$0.deleted }.map(\.name)), ["outside", "weekend", "errand, quick", "phone, label"])
        XCTAssertEqual(task("foreignUid")?.content, "Foreign uid (phone)")
        XCTAssertEqual(task("foreignUid")?.due, DueDate(date: "2026-11-20"))
        XCTAssertEqual(s.task("t1")?.projectId, ids["errands"])
        XCTAssertEqual(s.task("t1")?.parentId, ids["trip"])
        XCTAssertEqual(task("shears")?.parentId, nil)
        XCTAssertEqual(task("shears")?.sectionId, nil)
        XCTAssertEqual(task("shears")?.projectId, ids["home"])
        XCTAssertEqual(task("mum")?.priority, .p4)
        XCTAssertNil(task("hotel")?.due)
        XCTAssertEqual(task("unicode")?.labels, [])
        XCTAssertLessThan(try XCTUnwrap(task("gate")).order, try XCTUnwrap(task("fence")).order, "the phone moved Fix gate up")

        let gate = try XCTUnwrap(task("gate"))
        XCTAssertEqual(gate.content, "Fix gate")
        XCTAssertEqual(gate.projectId, ids["home"])
        XCTAssertEqual(gate.sectionId, ids["garden"])
        XCTAssertEqual(gate.priority, .p2)
        let hinge = try XCTUnwrap(task("hinge"))
        XCTAssertEqual(hinge.parentId, gate.id)
        XCTAssertEqual(hinge.sectionId, ids["garden"])
        XCTAssertEqual(s.sections(in: ids["home"]!).map(\.name), ["Garden", "Indoors"])

        // On the server: the phone's section line, the advanced repeat, and the other client's lines unchanged.
        let gateICS = try await need(path(ids["home"]!, gate.id)).ics.unfolded
        let gardenOrder = s.sections(in: ids["home"]!).first!.order
        XCTAssertTrue(gateICS.contains("X-TODOTIM-SECTION;X-NAME=Garden;X-ORDER=\(VTodo.format(gardenOrder)):\(ids["garden"]!)"), gateICS)
        let hingeICS = try await need(path(ids["home"]!, hinge.id)).ics.unfolded
        XCTAssertTrue(hingeICS.contains("RELATED-TO;RELTYPE=PARENT:\(gate.id)"), hingeICS)
        XCTAssertTrue(hingeICS.contains(":\(ids["garden"]!)"), hingeICS)
        let waterICS = try await need(path(ids["home"]!, ids["water"]!)).ics.unfolded
        XCTAssertTrue(waterICS.contains("DUE;VALUE=DATE:20261109"), waterICS)
        XCTAssertTrue(waterICS.contains("RRULE:FREQ=WEEKLY;COUNT=9"), waterICS)
        XCTAssertFalse(waterICS.contains("STATUS:COMPLETED"))
        let passportICS = try await need(path(TodoStore.inboxID, ids["passport"]!)).ics
        XCTAssertEqual(Self.foreign(passportICS), ids["foreign"], "the other client's lines survive byte for byte")
        XCTAssertTrue(passportICS.unfolded.contains("SUMMARY:Renew passport (phone)"))
        let pruneICS = try await need(path(ids["home"]!, ids["prune"]!)).ics.unfolded
        XCTAssertTrue(pruneICS.contains("DUE;VALUE=DATE:20261110"), pruneICS)
        let vacuumObject = try await object(path(ids["home"]!, ids["vacuum"]!))
        XCTAssertNil(vacuumObject)
        let mumObject = try await object(path(ids["errands"]!, ids["mum"]!))
        XCTAssertNotNil(mumObject)
        let hotelObject = try await object(path(ids["errands"]!, ids["hotel"]!))
        XCTAssertNotNil(hotelObject, "the subtask moved along")
        XCTAssertFalse(pruneICS.contains("DESCRIPTION"), pruneICS)
        let foreignUidICS = try await need(davPath(server.home, "\(CalDAVSync.inboxURI)/x other@ex.ics")).ics.unfolded
        XCTAssertTrue(foreignUidICS.contains("UID:x@other.example"), foreignUidICS)
        XCTAssertEqual(s.task("late-utc")?.due, DueDate(date: "2026-11-23"))
        XCTAssertEqual(s.task("ny")?.due, DueDate(date: "2026-11-22"))
        let lateICS = try await need(davPath(server.home, "\(CalDAVSync.inboxURI)/late-utc.ics")).ics.unfolded
        XCTAssertTrue(lateICS.contains("DUE:20261122T233000Z"), lateICS)
        XCTAssertTrue(lateICS.contains("DTSTART:20261122T220000Z"), lateICS)
        let nyICS = try await need(davPath(server.home, "\(CalDAVSync.inboxURI)/ny.ics")).ics.unfolded
        XCTAssertTrue(nyICS.contains("DUE;TZID=America/New_York:20261121T200000"), nyICS)
        let inboxObjects = try await server.changes(in: davPath(server.home, CalDAVSync.inboxURI), since: nil).changed
        XCTAssertEqual(inboxObjects.filter { $0.ics.contains("UID:x@other.example") }.count, 1, "edited in place")
        XCTAssertEqual(task("done")?.isCompleted, false, "reopened on the phone")
        let doneICS = try await need(path(TodoStore.inboxID, ids["done"]!)).ics.unfolded
        XCTAssertFalse(doneICS.contains("COMPLETED:"), doneICS)
        XCTAssertFalse(doneICS.contains("PERCENT-COMPLETE"), doneICS)
        XCTAssertTrue(doneICS.contains("STATUS:NEEDS-ACTION"), doneICS)
        XCTAssertTrue(foreignUidICS.contains("DUE;TZID=Europe/Amsterdam:20261120T183000"), foreignUidICS)
        let hotelICS = try await need(path(ids["errands"]!, ids["hotel"]!)).ics.unfolded
        XCTAssertFalse(hotelICS.contains("DUE"), hotelICS)
        let shearsICS = try await need(path(ids["home"]!, ids["shears"]!)).ics.unfolded
        XCTAssertFalse(shearsICS.contains("RELATED-TO"), shearsICS)
        XCTAssertFalse(shearsICS.contains("X-TODOTIM-SECTION"), shearsICS)

        // A Mac edit of the passport task keeps the other client's lines too.
        s.updateTask(ids["passport"]!) { $0.priority = .p3 }
        let edit = try await mac.sync(server)
        XCTAssertTrue(edit.isComplete)
        let afterMac = try await need(path(TodoStore.inboxID, ids["passport"]!)).ics
        XCTAssertEqual(Self.foreign(afterMac), ids["foreign"])

        // A label renamed on the Mac (its tasks are rewritten); the phone checks it in step d1.
        s.updateLabel(ids["weekend"]!) { $0.name = "week end" }
        let renamed = try await mac.sync(server)
        XCTAssertTrue(renamed.isComplete)
        XCTAssertEqual(s.task(ids["mum"]!)?.labels, ["week end", "outside"])

        // Lists and sections changed on the Mac; the phone files tasks into them in step d1.
        s.updateSection(ids["garden"]!) { $0.name = Self.gardenName }
        let shed = s.addSection(projectId: ids["home"]!, name: "Shed")
        s.deleteSection(ids["indoors"]!)
        s.updateProject(ids["errands"]!) { $0.name = "Errands & shops" }
        s.deleteProject(ids["otherList"]!)
        let restructured = try await mac.sync(server)
        XCTAssertTrue(restructured.isComplete, "\(restructured.warnings)")
        var macIds = try readJSON("ids.json")
        macIds["shed"] = shed.id
        try JSONEncoder().encode(macIds).write(to: file("ids.json"))

        // Settled: nothing more to write.
        let settled = try await mac.sync(server)
        XCTAssertEqual(settled.writes, 0)

        // Unsynced Mac changes that meet the phone's in step d1: "Gym" completed on both, "Renew passport" edited
        // here and deleted there, "Prune roses" moved here and edited there.
        s.toggleComplete(ids["gym"]!)
        XCTAssertEqual(s.task(ids["gym"]!)?.due, DueDate(date: "2026-11-07"))
        s.updateTask(ids["passport"]!) { $0.content = "Renew passport (mac)" }
        s.moveTask(ids["prune"]!, projectId: ids["errands"]!, sectionId: nil, parentId: nil)
        try save(mac)
    }

    /// The Mac completes "Take out bins" (the phone did too, unsynced) and syncs; "Gym" meets the phone's copy.
    private func stepD2() async throws {
        let ids = try readJSON("ids.json")
        let mac = try load()
        mac.store.toggleComplete(ids["bins"]!)
        let r = try await mac.sync(server)
        XCTAssertTrue(r.isComplete, "\(r.warnings)")
        try save(mac)
    }

    /// Each repeating task advanced once, and the Mac and the phone agree on every task.
    private func stepD4() async throws {
        let ids = try readJSON("ids.json")
        let mac = try load()
        let r = try await mac.sync(server)
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.writes, 0)
        let s = mac.store
        XCTAssertEqual(s.task(ids["bins"]!)?.due, DueDate(date: "2026-11-11"))
        XCTAssertEqual(s.task(ids["bins"]!)?.recurrence, "FREQ=WEEKLY")
        XCTAssertEqual(s.task(ids["gym"]!)?.due, DueDate(date: "2026-11-07"))
        XCTAssertEqual(s.task(ids["gym"]!)?.recurrence, "FREQ=DAILY;INTERVAL=2")
        for (key, due) in [("bins", "20261111"), ("gym", "20261107")] {
            let ics = try await need(path(ids["errands"]!, ids[key]!)).ics.unfolded
            XCTAssertTrue(ics.contains("DUE;VALUE=DATE:\(due)"), ics)
            XCTAssertFalse(ics.contains("STATUS:COMPLETED"), ics)
        }

        // The phone filed tasks into the renamed section and the new one, with the section lines the Mac writes.
        let phoneIds = try readJSON("phone-ids-d1.json")
        let home = ids["home"]!
        XCTAssertEqual(s.task(phoneIds["oil"]!)?.sectionId, ids["garden"])
        XCTAssertEqual(s.task(phoneIds["sweep"]!)?.sectionId, ids["shed"])
        XCTAssertEqual(s.sections(in: home).map(\.name), [Self.gardenName, "Shed"])
        func sectionLine(_ id: String) async throws -> String? {
            try await need(path(home, id)).ics.unfolded.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n").first { $0.hasPrefix("X-TODOTIM-SECTION") }
        }
        let macGarden = try await sectionLine(ids["fence"]!)
        XCTAssertNotNil(macGarden)
        let phoneGarden = try await sectionLine(phoneIds["oil"]!)
        XCTAssertEqual(phoneGarden, macGarden)
        let gateLine = try await sectionLine(phoneIds["gate"]!)
        XCTAssertEqual(gateLine, macGarden)
        let shed = try XCTUnwrap(s.db.sections[ids["shed"]!])
        let sweepLine = try await sectionLine(phoneIds["sweep"]!)
        XCTAssertEqual(sweepLine, "X-TODOTIM-SECTION;X-NAME=Shed;X-ORDER=\(VTodo.format(shed.order)):\(shed.id)")

        try compareWithPhone(s)
    }

    /// Edits and syncs while the phone does the same, at the same time (the script runs both steps at once).
    private func stepE() async throws {
        let ids = try readJSON("ids.json")
        let mac = try load()
        let s = mac.store
        try Data().write(to: file("ready-mac"))
        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: file("ready-phone").path) {
            guard Date() < deadline else { return XCTFail("the phone step did not start") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for i in 0..<12 {
            s.updateTask(ids["mum"]!) { $0.content = "mac \(i)" }
            if i % 2 == 0 { s.updateTask(ids["fence"]!) { $0.priority = $0.priority == .p1 ? .p4 : .p1 } }
            if i % 4 == 0 { s.toggleComplete(ids["water"]!) }
            if i == 5 { s.addTask(content: "Mac during the race", projectId: ids["home"]!, sectionId: ids["shed"]) }
            _ = try await mac.sync(server)
            try await Task.sleep(nanoseconds: UInt64.random(in: 0...150_000_000))
        }
        try save(mac)
    }

    /// After the race: the Mac syncs what is left.
    private func stepF1() async throws {
        let mac = try load()
        let r = try await mac.sync(server)
        XCTAssertTrue(r.isComplete, "\(r.warnings)")
        try save(mac)
    }

    /// The Mac agrees with the phone, with nothing left to write, and the race left no duplicates.
    private func stepF3() async throws {
        let mac = try load()
        let r = try await mac.sync(server)
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.writes, 0)
        let s = mac.store
        let live = s.db.tasks.values.filter { !$0.deleted }
        XCTAssertEqual(live.filter { $0.content == "Mac during the race" }.count, 1)
        XCTAssertEqual(live.filter { $0.content == "Phone during the race" }.count, 1)
        var objects = 0
        for cal in try await server.calendars() { objects += try await server.changes(in: cal.path, since: nil).changed.count }
        XCTAssertEqual(objects, live.count, "one object per task")
        try compareWithPhone(s)
    }

    /// The Mac's tasks, lists, sections and labels equal the phone's (`phone-tasks.json`, `phone-meta.json`).
    private func compareWithPhone(_ s: TodoStore) throws {
        struct PhoneTask: Decodable, Equatable {
            var projectId: String, sectionId: String?, parentId: String?, content: String, description: String
            var priority: Int, due: String?, labels: [String], isCompleted: Bool, recurrence: String?, order: Double
        }
        let phone = try JSONDecoder().decode([String: PhoneTask].self, from: Data(contentsOf: file("phone-tasks.json")))
        var mine: [String: PhoneTask] = [:]
        for t in s.db.tasks.values where !t.deleted {
            mine[t.id] = PhoneTask(projectId: t.projectId, sectionId: t.sectionId, parentId: t.parentId, content: t.content,
                                   description: t.description, priority: t.priority.rawValue, due: t.due?.date, labels: t.labels,
                                   isCompleted: t.isCompleted, recurrence: t.recurrence, order: t.order)
        }
        XCTAssertEqual(Set(mine.keys), Set(phone.keys))
        for (id, t) in mine { XCTAssertEqual(t, phone[id], id) }

        // Lists, sections and labels: same ids and names (labels derived from a name get the same id on both).
        let meta = try readJSON("phone-meta.json")
        var macMeta: [String: String] = [:]
        for p in s.db.projects.values where !p.deleted { macMeta["project:\(p.id)"] = "\(p.name)|\(p.color)" }
        for x in s.db.sections.values where !x.deleted { macMeta["section:\(x.id)"] = "\(x.projectId)|\(x.name)|\(VTodo.format(x.order))" }
        for l in s.db.labels.values where !l.deleted { macMeta["label:\(l.id)"] = "\(l.name)|\(l.color)" }
        XCTAssertEqual(macMeta, meta)
    }
}
