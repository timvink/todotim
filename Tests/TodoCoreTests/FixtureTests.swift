import Foundation
import XCTest
@testable import TodoCore

/// Runs the shared golden cases in `fixtures/` (format: fixtures/README.md) against the reference
/// implementation. The Kotlin port checks the same files.
final class FixtureTests: XCTestCase {
    private let zone = "Europe/Amsterdam"
    private var savedTimeZone: TimeZone!

    override func setUp() {
        super.setUp()
        // `VTodo.patch` moves due dates in `Calendar.current`.
        savedTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: zone)!
    }

    override func tearDown() {
        NSTimeZone.default = savedTimeZone
        super.tearDown()
    }

    // MARK: - recurrence.json

    func testRecurrence() throws {
        let json = try Fixtures.json("recurrence.json")
        let cal = Fixtures.calendar(zone: json.str("zone")!)
        for c in json["advance"]!.array {
            let rule = c.str("rrule")!
            let due = DueDate(date: c.str("due") ?? c.str("today")!)
            let message = "\(rule) from \(due.date) (\(c.str("note") ?? ""))"
            let got = Recurrence.advance(rule, from: due, calendar: cal)
            let expected = c["expected"]!
            if expected.string == "complete" {
                XCTAssertNil(got, message)
            } else {
                XCTAssertEqual(got?.due.date, expected.str("due"), message)
                XCTAssertEqual(got?.rule, expected.str("rrule"), message)
            }
        }
        for c in json["summary"]!.array {
            XCTAssertEqual(Recurrence.summary(c.str("rrule")!), c.str("expected"), c.str("rrule")!)
        }
    }

    // MARK: - quickadd.json

    func testQuickAdd() throws {
        let json = try Fixtures.json("quickadd.json")
        try checkWeekday(json)
        for c in json["cases"]!.array {
            let input = c.str("input")!
            let cal = Fixtures.calendar(locale: c.str("locale") ?? json.str("locale")!)
            let now = Fixtures.noon(c.str("today") ?? json.str("today")!, cal)
            let projects = c["projects"]?.strings ?? [], sections = c["sections"]?.strings ?? []
            let t = QuickAddParser.parse(input, now: now, calendar: cal, projectNames: projects, sectionNames: sections)
            let e = c["expected"]!
            let m = "'\(input)'"
            XCTAssertEqual(t.content, e.str("content"), m)
            XCTAssertEqual(t.due?.date, e.str("due"), m)
            XCTAssertEqual(t.priority?.rawValue, e["priority"]?.int, m)
            XCTAssertEqual(t.labels, e["labels"]?.strings ?? [], m)
            XCTAssertEqual(t.projectName, e.str("project"), m)
            XCTAssertEqual(t.sectionName, e.str("section"), m)
            XCTAssertEqual(t.noDate, e["noDate"]?.bool ?? false, m)
            if let tokens = c["tokens"] {
                let got = QuickAddParser.tokens(in: input, now: now, calendar: cal, projectNames: projects, sectionNames: sections)
                    .map { "\($0.kind.rawValue):\(input[$0.range])" }
                XCTAssertEqual(got, tokens.array.map { "\($0.str("kind")!):\($0.str("text")!)" }, m)
            }
        }
    }

    private func checkWeekday(_ json: FixtureJSON) throws {
        let cal = Fixtures.calendar()
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let today = Fixtures.noon(json.str("today")!, cal)
        XCTAssertEqual(names[cal.component(.weekday, from: today) - 1], json.str("todayWeekday"))
    }

    // MARK: - dates.json

    func testDates() throws {
        let json = try Fixtures.json("dates.json")
        try checkWeekday(json)
        let today = json.str("today")!
        for c in json["parse"]!.array {
            let input = c.str("input")!
            let locale = c.str("locale") ?? json.str("locale")!
            let cal = Fixtures.calendar(locale: locale)
            let got = DateParser.parsePhrase(input, now: Fixtures.noon(c.str("today") ?? today, cal), calendar: cal)
            let expected: DateParseResult? = switch c["expected"]!.string {
            case nil: nil
            case "noDate": .noDate
            case let d?: .date(DueDate(date: d))
            }
            XCTAssertEqual(got, expected, "'\(input)' (\(locale))")
        }
        for c in json["dayFirst"]!.array {
            let locale = c.str("locale")!
            XCTAssertEqual(DateParser.isDayFirst(Fixtures.calendar(locale: locale)), c["expected"]!.bool, locale)
        }
        let cal = Fixtures.calendar(locale: json.str("locale")!)
        for c in json["display"]!.array {
            let d = c.str("date")!
            XCTAssertEqual(DueDate(date: d).displayString(now: Fixtures.noon(c.str("today") ?? today, cal), calendar: cal),
                           c.str("expected"), d)
        }
        let now = Fixtures.noon(today, cal)
        for c in json["relative"]!.array {
            let d = DueDate(date: c.str("date")!)
            XCTAssertEqual(d.daysFromToday(now: now, calendar: cal), c["days"]!.int, d.date)
            XCTAssertEqual(d.isOverdue(now: now, calendar: cal), c["overdue"]!.bool, d.date)
        }
    }

    // MARK: - palette.json

    func testPalette() throws {
        let json = try Fixtures.json("palette.json")
        XCTAssertEqual(ProjectColor.entries.map { "\($0.key) \($0.name) \(String(format: "#%06X", $0.hex))" },
                       json["entries"]!.array.map { "\($0.str("key")!) \($0.str("name")!) \($0.str("hex")!)" })
        for c in json["lookup"]!.array {
            let input = c.str("input")!
            XCTAssertEqual(ProjectColor.entry(input).key, c.str("key"), input)
            XCTAssertEqual(ProjectColor.hex(input), c.str("hex"), input)
        }
        for c in json["nearest"]!.array {
            XCTAssertEqual(ProjectColor.key(hex: c.str("hex")!), c.str("key"), c.str("hex")!)
        }
    }

    // MARK: - urls.json

    func testURLs() throws {
        let json = try Fixtures.json("urls.json")
        let base = json["baseURL"]!
        for c in base["valid"]!.array {
            let input = c.str("input")!
            // Foundation keeps the spelling of scheme and host ("HTTP://LOCALHOST/"), OkHttp lowercases them;
            // both compare origins case-insensitively, so compare in lowercase here.
            XCTAssertEqual(lowercasedOrigin(try WebDAVClient.normalizedBaseURL(input)), c.str("normalized"), input)
        }
        for input in base["insecure"]!.strings {
            XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL(input), input) { error in
                guard case SyncError.insecureURL = error else { return XCTFail("\(input): \(error)") }
            }
        }
        for input in base["invalid"]!.strings {
            XCTAssertThrowsError(try WebDAVClient.normalizedBaseURL(input), input) { error in
                guard case SyncError.invalidURL = error else { return XCTFail("\(input): \(error)") }
            }
        }

        let request = json["requestPath"]!
        let client = try WebDAVClient(serverURL: request.str("base")!, username: "tim", password: "pw")
        for c in request["encoded"]!.array {
            let path = c.str("path")!
            XCTAssertEqual(try client.url(for: path, collection: c["collection"]!.bool!).absoluteString, c.str("url"), path)
        }
        for path in request["refused"]!.strings {
            XCTAssertThrowsError(try client.url(for: path), path) { error in
                guard case SyncError.invalidPath = error else { return XCTFail("\(path): \(error)") }
            }
        }

        let href = json["href"]!
        let hrefClient = try WebDAVClient(serverURL: href.str("base")!, username: "tim", password: "pw")
        for c in href["cases"]!.array {
            XCTAssertEqual(hrefClient.relativePath(ofHref: c.str("href")!), c.str("path"), c.str("href")!)
        }
    }

    private func lowercasedOrigin(_ url: URL) -> String? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        return c.url?.absoluteString
    }

    // MARK: - vtodo/

    func testVTodoNumberFormat() throws {
        for c in try Fixtures.json("vtodo/numbers.json")["format"]!.array {
            let value = c.str("value")!
            XCTAssertEqual(VTodo.format(Double(value)!), c.str("text"), value)
        }
    }

    private let patchNow = "2027-01-15T08:00:00Z"

    func testVTodoRead() throws {
        let cal = Fixtures.calendar(zone: zone)
        let cases = try Fixtures.files("vtodo/read", suffix: ".ics")
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for name in cases {
            let base = String(name.dropLast(4))
            let expected = try Fixtures.json("vtodo/read/\(base).json")
            let got = VTodo.read(try Fixtures.text("vtodo/read/\(name)"), projectId: "p", calendar: cal)
            if expected.isNull {
                XCTAssertNil(got, name)
                continue
            }
            guard let got else { XCTFail("\(name): not read"); continue }
            var actual = taskJSON(got.task)
            actual["uid"] = .string(got.uid)
            actual["sectionName"] = got.sectionName.map(FixtureJSON.string) ?? .null
            actual["sectionOrder"] = got.sectionOrder.map(FixtureJSON.number) ?? .null
            XCTAssertEqual(Set(actual.keys), Set(expected.object.keys), "\(name): keys")
            for (k, v) in expected.object {
                XCTAssertEqual(actual[k], v, "\(name): \(k)")
            }
        }
    }

    func testVTodoPatch() throws {
        let cal = Fixtures.calendar(zone: zone)
        let cases = try Fixtures.files("vtodo/patch", suffix: ".edit.json")
        XCTAssertFalse(cases.isEmpty)
        for file in cases {
            let name = String(file.dropLast(".edit.json".count))
            let before = try Fixtures.text("vtodo/patch/\(name).before.ics")
            let edit = try Fixtures.json("vtodo/patch/\(file)")
            guard let old = VTodo.read(before, projectId: "p", calendar: cal) else {
                XCTFail("\(name): before not readable"); continue
            }
            var task = old.task
            task.updatedAt = Fixtures.time(patchNow)
            apply(edit["set"]?.object ?? [:], to: &task)
            let parentUID = edit["parentUid"].map(\.string) ?? task.parentId
            let section: TodoCore.Section? = if let s = edit["section"] {
                self.section(s)
            } else {
                task.sectionId.map { Section(id: $0, projectId: task.projectId, name: old.sectionName ?? "", order: old.sectionOrder ?? 0) }
            }
            let out = VTodo.patch(before, old: old, to: task, parentUID: parentUID, section: section)
            if edit["unchanged"]?.bool == true {
                XCTAssertNil(out, name)
                continue
            }
            XCTAssertEqual(out, try Fixtures.text("vtodo/patch/\(name).after.ics"), name)
            // What was written reads back as the edited task (times in whole seconds).
            guard let out, let back = VTodo.read(out, projectId: "p", calendar: cal)?.task else {
                XCTFail("\(name): result not readable"); continue
            }
            task.parentId = parentUID.map(VTodo.taskID(forUID:))
            task.sectionId = section?.id
            task.createdAt = back.createdAt; task.updatedAt = back.updatedAt; task.completedAt = back.completedAt
            XCTAssertEqual(back, task, name)
        }
    }

    func testVTodoMake() throws {
        let cases = try Fixtures.files("vtodo/make", suffix: ".json")
        XCTAssertFalse(cases.isEmpty)
        for file in cases {
            let spec = try Fixtures.json("vtodo/make/\(file)")
            let t = spec["task"]!
            var task = TodoTask(id: t.str("id")!, projectId: t.str("projectId")!, content: "", order: 0,
                                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
            apply(t.object.filter { $0.key != "id" && $0.key != "projectId" }, to: &task)
            let out = VTodo.make(task, uid: spec.str("uid")!, parentUID: spec.str("parentUid"), section: section(spec["section"]!))
            XCTAssertEqual(out, try Fixtures.text("vtodo/make/\(file.dropLast(5)).ics"), file)
        }
    }

    // MARK: - Task JSON

    private func section(_ json: FixtureJSON) -> TodoCore.Section? {
        guard !json.isNull else { return nil }
        return Section(id: json.str("id")!, projectId: "p", name: json.str("name")!, order: json["order"]!.number!)
    }

    private func apply(_ set: [String: FixtureJSON], to t: inout TodoTask) {
        for (k, v) in set {
            switch k {
            case "sectionId": t.sectionId = v.string
            case "parentId": t.parentId = v.string
            case "content": t.content = v.string!
            case "description": t.description = v.string!
            case "priority": t.priority = Priority(rawValue: v.int!)!
            case "due": t.due = v.string.map { DueDate(date: $0) }
            case "labels": t.labels = v.strings
            case "isCompleted": t.isCompleted = v.bool!
            case "completedAt": t.completedAt = v.string.map(Fixtures.time)
            case "order": t.order = v.number!
            case "collapsed": t.collapsed = v.bool!
            case "recurrence": t.recurrence = v.string
            case "createdAt": t.createdAt = Fixtures.time(v.string!)
            case "updatedAt": t.updatedAt = Fixtures.time(v.string!)
            default: XCTFail("unknown task field \(k)")
            }
        }
    }

    private func taskJSON(_ t: TodoTask) -> [String: FixtureJSON] {
        func opt(_ s: String?) -> FixtureJSON { s.map(FixtureJSON.string) ?? .null }
        return [
            "id": .string(t.id), "projectId": .string(t.projectId),
            "sectionId": opt(t.sectionId), "parentId": opt(t.parentId),
            "content": .string(t.content), "description": .string(t.description),
            "priority": .number(Double(t.priority.rawValue)), "due": opt(t.due?.date),
            "labels": .array(t.labels.map(FixtureJSON.string)), "isCompleted": .bool(t.isCompleted),
            "completedAt": opt(t.completedAt.map(Fixtures.timeString)), "order": .number(t.order),
            "collapsed": .bool(t.collapsed), "recurrence": opt(t.recurrence),
            "createdAt": .string(Fixtures.timeString(t.createdAt)), "updatedAt": .string(Fixtures.timeString(t.updatedAt)),
        ]
    }
}
