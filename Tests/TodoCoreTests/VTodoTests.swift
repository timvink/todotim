import XCTest
@testable import TodoCore

final class ICalendarTests: XCTestCase {
    func testParsesFoldedLinesParamsAndEscapes() throws {
        let text = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:1\r\nSUMMARY:Long line that is\r\n  folded\r\n"
            + "DESCRIPTION:a\\nb\\, c\\; d\\\\\r\nX-TODOTIM-SECTION;X-NAME=\"a:b;c\";X-ORDER=2:s1\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
        let root = try ICalendar.parse(text)
        let todo = try XCTUnwrap(root.components.first)
        XCTAssertEqual(todo.first("SUMMARY")?.value, "Long line that is folded")
        XCTAssertEqual(ICalendar.unescapeText(todo.first("DESCRIPTION")!.value), "a\nb, c; d\\")
        let section = try XCTUnwrap(todo.first("X-TODOTIM-SECTION"))
        XCTAssertEqual(section.param("X-NAME"), "a:b;c")
        XCTAssertEqual(section.param("X-ORDER"), "2")
        XCTAssertEqual(section.value, "s1")
        // Bare LF line endings (as in XML responses) work too.
        XCTAssertEqual(try ICalendar.parse(text.replacingOccurrences(of: "\r\n", with: "\n")), root)
    }

    func testSerializeFoldsAt75OctetsAndRoundTrips() throws {
        let long = String(repeating: "é", count: 100)
        let todo = ICalComponent("VTODO", properties: [ICalProperty("SUMMARY", value: long),
                                                      ICalProperty("X-A", params: [("X-NAME", "say \"hi\"\n")], value: "v")])
        let text = ICalendar.serialize(ICalComponent("VCALENDAR", components: [todo]))
        for line in text.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 75) }
        XCTAssertTrue(text.contains("X-A;X-NAME=say ^'hi^'^n:v"), text)
        let back = try ICalendar.parse(text)
        XCTAssertEqual(back.components.first?.first("SUMMARY")?.value, long)
        XCTAssertEqual(back.components.first?.first("X-A")?.param("X-NAME"), "say \"hi\"\n")
    }

    func testFoldingBeforeACombiningCodePointRoundTrips() throws {
        // A fold may fall just before U+FE0F (emoji presentation), a ZWJ or a combining accent;
        // as `Character`s the continuation line would not start with a space.
        for tail in ["❤️", "👨‍👩‍👧", "é", "👍🏽"] {
            for pad in 60...76 {
                let summary = String(repeating: "a", count: pad) + tail + " end"
                let t = TodoTask(id: "t", projectId: "p", content: summary, order: 1)
                let ics = VTodo.make(t, uid: "t", parentUID: nil, section: nil)
                XCTAssertEqual(VTodo.read(ics, projectId: "p")?.task.content, summary, "\(pad) \(tail)")
            }
        }
    }

    func testHostileDatesAndParametersDoNotCrashOrChange() throws {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:x\r\nDUE:20261103T١٢٣٤٥٦Z\r\nCREATED:20261103T１２３４５６\r\n"
            + "ATTENDEE;MEMBER=\"mailto:a@x\",\"mailto:b@x\";CN=A:mailto:c@x\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
        let v = try XCTUnwrap(VTodo.read(ics, projectId: "p"))
        XCTAssertNil(v.task.due)
        var t = v.task
        t.content = "changed"
        let patched = try XCTUnwrap(VTodo.patch(ics, old: v, to: t, parentUID: nil, section: nil))
        XCTAssertTrue(patched.contains("ATTENDEE;MEMBER=\"mailto:a@x\",\"mailto:b@x\";CN=A:mailto:c@x"), patched)
    }

    func testRejectsMalformedAndOversizedInput() {
        for bad in ["BEGIN:VCALENDAR\r\n", "END:VCALENDAR\r\n", "BEGIN:A\r\nEND:B\r\n", "SUMMARY:x\r\n",
                    "BEGIN:A\r\nnovalue\r\nEND:A\r\n", "BEGIN:A\r\nX;P=\"open:x\r\nEND:A\r\n"] {
            XCTAssertThrowsError(try ICalendar.parse(bad), bad)
        }
        XCTAssertThrowsError(try ICalendar.parse(String(repeating: "BEGIN:X\r\n", count: 20) + String(repeating: "END:X\r\n", count: 20)))
        XCTAssertThrowsError(try ICalendar.parse(String(repeating: "x", count: ICalendar.maxBytes + 1)))
        XCTAssertThrowsError(try ICalendar.parse("BEGIN:A\r\n" + String(repeating: "X:1\r\n", count: ICalendar.maxLines) + "END:A\r\n"))
    }

    func testTextListsAndDates() {
        XCTAssertEqual(ICalendar.splitTextList("a,b\\,c,d"), ["a", "b,c", "d"])
        XCTAssertEqual(ICalendar.utcString(Date(timeIntervalSince1970: 1_792_866_005.7)), "20261024T182005Z")
        let p = ICalProperty("DUE", params: [("TZID", "America/New_York")], value: "20261103T220000")
        let v = ICalendar.DateValue(p)!
        XCTAssertFalse(v.isDate)
        XCTAssertEqual(v.localDate(calendar: .amsterdam).date, "2026-11-04", "converted to the local date")
        XCTAssertEqual(v.shifted(days: 30).property("DUE", keeping: p).value, "20261203T220000")
        XCTAssertNil(ICalendar.DateValue(ICalProperty("DUE", value: "2026-11-03")))
    }
}

final class VTodoTests: XCTestCase {
    private func vtodo(_ lines: String) -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\n" + lines.replacingOccurrences(of: "\n", with: "\r\n")
            + "\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
    }

    func testReadsForeignTask() throws {
        let ics = vtodo("""
        UID:abc
        SUMMARY:Buy milk
        PRIORITY:5
        DUE:20261103T230000Z
        STATUS:COMPLETED
        COMPLETED:20261101T120000Z
        RELATED-TO:parent-uid
        RELATED-TO;RELTYPE=SIBLING:other
        CATEGORIES:a,b
        CATEGORIES:c
        X-OC-HIDESUBTASKS:1
        X-APPLE-SORT-ORDER:12
        CREATED:20261001T000000Z
        LAST-MODIFIED:20261002T000000Z
        """)
        let v = try XCTUnwrap(VTodo.read(ics, projectId: "p", calendar: .amsterdam))
        let t = v.task
        XCTAssertEqual(t.id, "abc")
        XCTAssertEqual(t.content, "Buy milk")
        XCTAssertEqual(t.priority, .p2)
        XCTAssertEqual(t.due?.date, "2026-11-04", "a UTC time is read as its local date")
        XCTAssertTrue(t.isCompleted)
        XCTAssertEqual(t.completedAt, Date(timeIntervalSince1970: 1_793_534_400))
        XCTAssertEqual(t.parentId, "parent-uid")
        XCTAssertEqual(t.labels, ["a", "b", "c"])
        XCTAssertTrue(t.collapsed)
        XCTAssertEqual(t.order, 12)
        XCTAssertEqual(t.updatedAt, Date(timeIntervalSince1970: 1_790_899_200))
    }

    func testPriorityMapping() {
        XCTAssertEqual((0...9).map { VTodo.priority(String($0)) },
                       [.p4, .p1, .p1, .p1, .p1, .p2, .p3, .p3, .p3, .p3])
        XCTAssertEqual(VTodo.priority(nil), .p4)
        XCTAssertEqual(Priority.allCases.map(VTodo.icalPriority), ["1", "5", "9", "0"])
    }

    func testOrderRules() throws {
        func order(_ lines: String) -> Double { VTodo.read(vtodo("UID:x\n" + lines), projectId: "p")!.task.order }
        XCTAssertEqual(order("X-TODOTIM-ORDER:2.5\nX-APPLE-SORT-ORDER:2"), 2.5)
        XCTAssertEqual(order("X-TODOTIM-ORDER:2.5"), 2.5, "no Apple order: trust ours")
        XCTAssertEqual(order("X-TODOTIM-ORDER:2.5\nX-APPLE-SORT-ORDER:7"), 7, "another client reordered")
        XCTAssertEqual(order("X-TODOTIM-ORDER:-0.5\nX-APPLE-SORT-ORDER:-1"), -0.5, "floor, not truncation")
        XCTAssertEqual(order("CREATED:20010101T000100Z"), 60, "no order: seconds since 2001")
    }

    func testInvalidUIDGetsStableDerivedIDAndBadSectionIsDropped() throws {
        let v = try XCTUnwrap(VTodo.read(vtodo("UID:a/b c\nX-TODOTIM-SECTION;X-NAME=x:../bad\nRELATED-TO:also/bad"), projectId: "p"))
        XCTAssertTrue(isValidEntityID(v.task.id))
        XCTAssertEqual(v.task.id, VTodo.taskID(forUID: "a/b c"))
        XCTAssertEqual(v.uid, "a/b c")
        XCTAssertNil(v.task.sectionId)
        XCTAssertEqual(v.task.parentId, VTodo.taskID(forUID: "also/bad"))
        XCTAssertNil(VTodo.read(vtodo("SUMMARY:no uid"), projectId: "p"))
        XCTAssertNil(VTodo.read("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:e\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", projectId: "p"))
    }

    func testMakeRoundTrips() throws {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let section = Section(id: "s1", projectId: "p", name: "Name, with: \"quotes\"", order: 1.5)
        let t = TodoTask(id: "t1", projectId: "p", sectionId: "s1", parentId: "t0", content: "Title; with, commas\\",
                         description: "Line 1\nLine 2", priority: .p3, due: DueDate(date: "2026-11-03"),
                         labels: ["a,b", "c"], isCompleted: true, completedAt: created.addingTimeInterval(60), order: 0.25,
                         collapsed: true, recurrence: "FREQ=DAILY", createdAt: created, updatedAt: created.addingTimeInterval(60))
        let ics = VTodo.make(t, uid: "t1", parentUID: "t0", section: section)
        XCTAssertTrue(ics.contains("DUE;VALUE=DATE:20261103"))
        XCTAssertTrue(ics.contains("X-APPLE-SORT-ORDER:0"))
        XCTAssertTrue(ics.contains("X-TODOTIM-ORDER:0.25"))
        XCTAssertTrue(ics.contains("PERCENT-COMPLETE:100"))
        let back = try XCTUnwrap(VTodo.read(ics, projectId: "p"))
        XCTAssertEqual(back.task, t)
        XCTAssertEqual(back.sectionName, section.name)
        XCTAssertEqual(back.sectionOrder, 1.5)
        XCTAssertNil(VTodo.patch(ics, old: back, to: t, parentUID: "t0", section: section), "nothing to write")
    }

    func testPatchTouchesOnlyChangedProperties() throws {
        let ics = vtodo("""
        UID:x
        SUMMARY:Old
        PRIORITY:3
        DTSTART;VALUE=DATE:20261101
        DUE;VALUE=DATE:20261102
        X-FOREIGN;P=1:keep
        BEGIN:VALARM
        TRIGGER:-PT5M
        END:VALARM
        """)
        let old = try XCTUnwrap(VTodo.read(ics, projectId: "p"))
        var t = old.task
        t.content = "New"
        t.due = DueDate(date: "2026-11-05")
        t.isCompleted = true
        t.completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        t.updatedAt = t.completedAt!
        let patched = try XCTUnwrap(VTodo.patch(ics, old: old, to: t, parentUID: nil, section: nil))
        XCTAssertTrue(patched.contains("SUMMARY:New"))
        XCTAssertTrue(patched.contains("PRIORITY:3"), "unchanged priority keeps its value")
        XCTAssertTrue(patched.contains("DUE;VALUE=DATE:20261105"))
        XCTAssertTrue(patched.contains("DTSTART;VALUE=DATE:20261104"), "start moves with the due date")
        XCTAssertTrue(patched.contains("X-FOREIGN;P=1:keep"))
        XCTAssertTrue(patched.contains("BEGIN:VALARM\r\nTRIGGER:-PT5M\r\nEND:VALARM"))
        XCTAssertTrue(patched.contains("STATUS:COMPLETED\r\n"))
        XCTAssertTrue(patched.contains("COMPLETED:20270115T080000Z"))
        XCTAssertTrue(patched.contains("LAST-MODIFIED:20270115T080000Z"))
        XCTAssertEqual(VTodo.read(patched, projectId: "p")?.task.content, "New")

        // Reopening removes COMPLETED; removing the due date removes DUE.
        var reopened = VTodo.read(patched, projectId: "p")!.task
        reopened.isCompleted = false
        reopened.completedAt = nil
        reopened.due = nil
        let again = try XCTUnwrap(VTodo.patch(patched, old: VTodo.read(patched, projectId: "p")!, to: reopened, parentUID: nil, section: nil))
        XCTAssertTrue(again.contains("STATUS:NEEDS-ACTION"))
        XCTAssertFalse(again.contains("COMPLETED:"))
        XCTAssertFalse(again.contains("DUE"))
    }

    func testNewDueDateFitsAForeignStartAndDuration() throws {
        let ics = vtodo("UID:x\nDTSTART;TZID=Europe/Amsterdam:20261110T090000\nDURATION:PT1H")
        let old = try XCTUnwrap(VTodo.read(ics, projectId: "p"))
        var t = old.task
        t.due = DueDate(date: "2026-11-05")
        let patched = try XCTUnwrap(VTodo.patch(ics, old: old, to: t, parentUID: nil, section: nil))
        XCTAssertTrue(patched.contains("DUE:20261105T235959\r\n"), "a DATE-TIME like DTSTART: \(patched)")
        XCTAssertTrue(patched.contains("DTSTART;TZID=Europe/Amsterdam:20261105T090000"), "the start is not after the due date")
        XCTAssertFalse(patched.contains("DURATION"), "DUE and DURATION exclude each other")
        XCTAssertEqual(VTodo.read(patched, projectId: "p")?.task.due?.date, "2026-11-05")

        // A DATE start keeps the DATE due.
        let dateStart = vtodo("UID:y\nDTSTART;VALUE=DATE:20261101")
        let o2 = try XCTUnwrap(VTodo.read(dateStart, projectId: "p"))
        var t2 = o2.task
        t2.due = DueDate(date: "2026-11-05")
        XCTAssertTrue(VTodo.patch(dateStart, old: o2, to: t2, parentUID: nil, section: nil)!.contains("DUE;VALUE=DATE:20261105"))
    }

    func testOverrideOnlyObjectIsNotATask() {
        let ics = vtodo("UID:x\nRECURRENCE-ID:20261101T090000Z\nSUMMARY:One occurrence")
        XCTAssertNil(VTodo.read(ics, projectId: "p"))
        let master = ics.replacingOccurrences(of: "END:VCALENDAR", with: "BEGIN:VTODO\r\nUID:x\r\nSUMMARY:Series\r\nEND:VTODO\r\nEND:VCALENDAR")
        XCTAssertEqual(VTodo.read(master, projectId: "p")?.task.content, "Series", "the master, not the override")
    }

    func testRecurrenceAdvance() {
        let cal = Calendar.amsterdam
        func next(_ rule: String, _ due: String) -> String? {
            Recurrence.advance(rule, from: DueDate(date: due), calendar: cal).map { "\($0.due.date) \($0.rule)" }
        }
        XCTAssertEqual(next("FREQ=DAILY", "2026-10-31"), "2026-11-01 FREQ=DAILY")
        XCTAssertEqual(next("FREQ=WEEKLY;INTERVAL=2;WKST=MO", "2026-10-25"), "2026-11-08 FREQ=WEEKLY;INTERVAL=2;WKST=MO")
        XCTAssertEqual(next("FREQ=MONTHLY", "2026-01-31"), "2026-03-31 FREQ=MONTHLY", "February 31 is skipped, not clamped")
        XCTAssertEqual(next("FREQ=MONTHLY;INTERVAL=1", "2026-03-31"), "2026-05-31 FREQ=MONTHLY;INTERVAL=1")
        XCTAssertEqual(next("FREQ=YEARLY", "2028-02-29"), "2032-02-29 FREQ=YEARLY", "leap day stays a leap day")
        XCTAssertEqual(next("FREQ=MONTHLY", "2026-01-15"), "2026-02-15 FREQ=MONTHLY")
        XCTAssertEqual(next("FREQ=YEARLY;COUNT=3", "2026-03-01"), "2027-03-01 FREQ=YEARLY;COUNT=2")
        XCTAssertNil(next("FREQ=YEARLY;COUNT=1", "2026-03-01"), "last occurrence: complete")
        XCTAssertEqual(next("FREQ=DAILY;UNTIL=20261102", "2026-11-01"), "2026-11-02 FREQ=DAILY;UNTIL=20261102")
        XCTAssertNil(next("FREQ=DAILY;UNTIL=20261102T000000Z", "2026-11-02"))
        // A DATE-TIME UNTIL bounds the start time, which a date-only task doesn't know: advance
        // only with two days to spare.
        XCTAssertNil(next("FREQ=DAILY;UNTIL=20261102T100000Z", "2026-11-01"))
        XCTAssertNil(next("FREQ=DAILY;UNTIL=20261104T100000Z", "2026-11-02"))
        XCTAssertEqual(next("FREQ=DAILY;UNTIL=20261104T100000Z", "2026-11-01"), "2026-11-02 FREQ=DAILY;UNTIL=20261104T100000Z")
        XCTAssertNil(next("FREQ=DAILY;UNTIL=garbage", "2026-11-01"))
        XCTAssertNil(next("FREQ=WEEKLY;BYDAY=MO,WE", "2026-11-02"), "unsupported parts: complete")
        XCTAssertNil(next("FREQ=HOURLY", "2026-11-02"))
        XCTAssertEqual(Recurrence.summary("FREQ=WEEKLY;INTERVAL=2"), "Every 2 weeks")
        XCTAssertEqual(Recurrence.summary("FREQ=DAILY"), "Every day")
        XCTAssertEqual(Recurrence.summary("FREQ=WEEKLY;BYDAY=MO"), "Repeats")
    }

    @MainActor
    func testCompletingARepeatingTaskAdvancesIt() {
        let store = TodoStore()
        let t = store.addTask(content: "Water plants", projectId: TodoStore.inboxID, due: DueDate(date: "2026-11-01"))
        store.updateTask(t.id) { $0.recurrence = "FREQ=DAILY;COUNT=2" }
        store.toggleComplete(t.id, calendar: .amsterdam)
        XCTAssertEqual(store.task(t.id)?.due?.date, "2026-11-02")
        XCTAssertEqual(store.task(t.id)?.recurrence, "FREQ=DAILY;COUNT=1")
        XCTAssertEqual(store.task(t.id)?.isCompleted, false)
        store.toggleComplete(t.id, calendar: .amsterdam)
        XCTAssertEqual(store.task(t.id)?.isCompleted, true, "the series ended")
    }

    func testColorMapping() {
        XCTAssertEqual(ProjectColor.hex("red"), "#DB4035")
        XCTAssertEqual(ProjectColor.key(hex: "#DB4035"), "red")
        XCTAssertEqual(ProjectColor.key(hex: "#db4035ff"), "red")
        XCTAssertEqual(ProjectColor.key(hex: "#4174FE"), "blue")
        XCTAssertNil(ProjectColor.key(hex: "red"))
        XCTAssertNil(ProjectColor.key(hex: "#12345"))
    }
}
