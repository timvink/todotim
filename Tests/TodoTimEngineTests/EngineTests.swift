import Foundation
import XCTest
import TodoCore
@testable import TodoTimEngine

/// The engine's line protocol, end to end: requests in, events and replies out.
/// Test methods are `async` because Linux XCTest cannot run synchronous @MainActor test methods.
@MainActor
final class EngineTests: XCTestCase {
    private var dir: URL!
    private var lines: [String] = []
    private var engine: Engine!
    private var nextID = 1
    // Thursday 2026-11-05, noon UTC.
    private let now = Date(timeIntervalSince1970: 1_793_880_000)
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        lines = []
        nextID = 1
        engine = makeEngine()
    }

    override func tearDown() async throws {
        engine.flush()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeEngine() -> Engine {
        let fixedNow = now
        return Engine(paths: EnginePaths(dataDir: dir), credentials: InMemoryCredentialStore(), config: nil,
                      configPath: "/nonexistent", startSyncing: false, calendar: calendar, now: { fixedNow },
                      output: { [unowned self] line in self.lines.append(line) })
    }

    /// Sends one request; returns the reply and the events sent before it.
    @discardableResult
    private func send(_ cmd: String, _ args: [String: JSON] = [:]) throws -> (reply: JSON, events: [JSON]) {
        var request = args
        request["req"] = .int(nextID)
        request["cmd"] = .string(cmd)
        nextID += 1
        let start = lines.count
        engine.handle(JSON.object(request).serialized())
        let out = try lines[start...].map { try JSON.parse($0) }
        let replies = out.filter { $0["re"] != nil }
        XCTAssertEqual(replies.count, 1, "one reply to \(cmd)")
        return (replies.last ?? .null, out.filter { $0["event"] != nil })
    }

    private func result(_ cmd: String, _ args: [String: JSON] = [:]) throws -> JSON {
        let reply = try send(cmd, args).reply
        XCTAssertEqual(reply["ok"], true, "\(cmd): \(reply["error"]?.string ?? "")")
        return reply["result"] ?? .null
    }

    private var lastRows: [JSON] {
        let rows = lines.reversed().compactMap { try? JSON.parse($0) }.first { $0["event"]?.string == "rows" }
        return rows?["rows"]?.array ?? []
    }

    private var lastSidebar: JSON {
        lines.reversed().compactMap { try? JSON.parse($0) }.first { $0["event"]?.string == "sidebar" }?["sidebar"] ?? .null
    }

    private func taskRows() -> [JSON] { lastRows.filter { $0["type"]?.string == "task" } }

    // MARK: - Protocol

    func testHelloPushesSidebarAndRowsBeforeReply() async throws {
        let (reply, events) = try send("hello")
        XCTAssertEqual(reply["ok"], true)
        XCTAssertEqual(reply["result"]?["version"]?.string, Engine.version)
        XCTAssertEqual(reply["result"]?["palette"]?.array?.count, ProjectColor.entries.count)
        XCTAssertEqual(events.compactMap { $0["event"]?.string }, ["sync", "sidebar", "rows"])
        XCTAssertEqual(lastSidebar["inbox"]?["id"], "inbox")
    }

    func testInvalidRequests() async throws {
        engine.handle("not json")
        XCTAssertEqual(try JSON.parse(lines.last!)["event"], "error")
        let unknown = try send("nope").reply
        XCTAssertEqual(unknown["ok"], false)
        XCTAssertEqual(unknown["error"]?.string, "Unknown command nope")
        let missing = try send("getTask", ["id": "missing"]).reply
        XCTAssertEqual(missing["error"]?.string, "The task no longer exists")
    }

    func testJSONSerializationEscapes() async throws {
        let value: JSON = ["text": .string("a\"b\\c\nd\u{1}e\u{2028}f é 🎉"), "n": 1.5, "i": 3, "list": [true, nil]]
        let line = value.serialized()
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(line, #"{"i":3,"list":[true,null],"n":1.5,"text":"a\"b\\c\nd\u0001e"# + "\\" + #"u2028f é 🎉"}"#)
        XCTAssertEqual(try JSON.parse(line), value)
    }

    // MARK: - Quick Add

    func testQuickAddResolvesProjectSectionAndTokens() async throws {
        let work = try result("addProject", ["name": "Work", "color": "blue"])["id"]!.string!
        let planning = try result("addSection", ["projectId": .string(work), "name": "Planning"])["id"]!.string!
        let text = "🎉 Buy milk tomorrow p1 @errands #Work /Planning"
        let preview = try result("parseQuickAdd", ["text": .string(text)])
        XCTAssertEqual(preview["content"], "🎉 Buy milk")
        XCTAssertEqual(preview["project"]?["id"]?.string, work)
        XCTAssertEqual(preview["section"]?["id"]?.string, planning)
        XCTAssertEqual(preview["due"]?["date"], "2026-11-06")
        XCTAssertEqual(preview["due"]?["label"], "Tomorrow")
        XCTAssertEqual(preview["priority"], 1)
        // Offsets are UTF-16 (QML string indices): the emoji counts as two.
        let tokens = preview["tokens"]!.array!
        let utf16 = Array(text.utf16)
        let texts = tokens.map { t in String(decoding: utf16[t["start"]!.int!..<t["end"]!.int!], as: UTF16.self) }
        XCTAssertEqual(texts, ["tomorrow", "p1", "@errands", "#Work", "/Planning"])

        let added = try result("quickAdd", ["text": .string(text), "description": "  2 litres  "])
        XCTAssertEqual(added["projectId"]?.string, work)
        let task = try result("getTask", ["id": added["taskId"]!])
        XCTAssertEqual(task["content"], "🎉 Buy milk")
        XCTAssertEqual(task["description"], "2 litres")
        XCTAssertEqual(task["sectionId"]?.string, planning)
        XCTAssertEqual(task["labels"]?.array?.first?["name"], "errands")
        XCTAssertEqual(lastSidebar["labels"]?.array?.first?["name"], "errands", "new labels are created")
    }

    func testQuickAddUsesContextUntilTheLineNamesAProject() async throws {
        let home = try result("addProject", ["name": "Home"])["id"]!.string!
        let garden = try result("addSection", ["projectId": .string(home), "name": "Garden"])["id"]!.string!
        let parent = try result("quickAdd", ["text": "Plant bulbs", "projectId": .string(home), "sectionId": .string(garden)])
        XCTAssertEqual(try result("getTask", ["id": parent["taskId"]!])["sectionId"]?.string, garden)
        // A sub-task from the task view.
        let sub = try result("quickAdd", ["text": "Buy tulips", "projectId": .string(home), "parentId": parent["taskId"]!])
        let subTask = try result("getTask", ["id": sub["taskId"]!])
        XCTAssertEqual(subTask["parentId"], parent["taskId"])
        XCTAssertEqual(subTask["sectionId"]?.string, garden)
        // Naming a project drops the context.
        let moved = try result("quickAdd", ["text": "Call mum #inbox", "projectId": .string(home), "parentId": parent["taskId"]!])
        let movedTask = try result("getTask", ["id": moved["taskId"]!])
        XCTAssertEqual(movedTask["projectId"], "inbox")
        XCTAssertEqual(movedTask["parentId"], .null)
        // Unknown names are reported.
        let preview = try result("parseQuickAdd", ["text": "x #Nowhere /Nothing"])
        XCTAssertEqual(preview["unknownProject"], "Nowhere")
        XCTAssertEqual(try send("quickAdd", ["text": "   p1"]).reply["error"], "Type a task name")
    }

    // MARK: - Editing, undo

    func testCompleteDeleteAndUndo() async throws {
        let parent = try result("quickAdd", ["text": "Groceries"])["taskId"]!
        try result("quickAdd", ["text": "Milk", "parentId": parent])
        try result("setView", ["view": ["kind": "project", "id": "inbox"]])
        XCTAssertEqual(taskRows().count, 2)
        XCTAssertEqual(taskRows()[1]["depth"], 1)

        let done = try result("toggleComplete", ["id": parent])
        XCTAssertEqual(done["toast"]?["message"], "2 tasks completed")
        XCTAssertEqual(done["toast"]?["undo"], true)
        XCTAssertTrue(taskRows().isEmpty)
        XCTAssertEqual(lastRows.first?["type"], "empty")
        try result("undo")
        XCTAssertEqual(taskRows().count, 2)

        let deleted = try result("deleteTask", ["id": parent])
        XCTAssertEqual(deleted["toast"]?["message"], "2 tasks deleted")
        XCTAssertTrue(taskRows().isEmpty)
        try result("undo")
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Groceries", "Milk"])
        XCTAssertEqual(try send("undo").reply["error"], "Nothing to undo")
    }

    func testCompleteSeveralTasksAndUndo() async throws {
        let a = try result("quickAdd", ["text": "Bread"])["taskId"]!
        let b = try result("quickAdd", ["text": "Butter"])["taskId"]!
        let child = try result("quickAdd", ["text": "Salted", "parentId": b])["taskId"]!
        try result("quickAdd", ["text": "Jam"])
        try result("setView", ["view": ["kind": "project", "id": "inbox"]])

        // The sub-task goes with its parent and is counted once.
        let selection: JSON = ["cursor": b, "anchor": a, "ids": [a, b, child]]
        let done = try result("completeTasks", ["ids": [a, b, child], "selection": selection])
        XCTAssertEqual(done["toast"]?["message"], "3 tasks completed")
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Jam"])
        // One undo step brings all of them back, with the selection it was given.
        let undone = try result("undo")
        XCTAssertEqual(undone["selection"], selection)
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Bread", "Butter", "Salted", "Jam"])
        XCTAssertEqual(try send("undo").reply["error"], "Nothing to undo")
        XCTAssertEqual(try send("completeTasks", ["ids": []]).reply["error"], "Missing ids")
    }

    func testUpdateTaskFields() async throws {
        let id = try result("quickAdd", ["text": "Read a book"])["taskId"]!
        var task = try result("updateTask", ["id": id, "priority": 2, "dueText": "next friday", "labels": ["a", "A", " b "]])
        XCTAssertEqual(task["priority"], 2)
        XCTAssertEqual(task["due"]?["date"], "2026-11-13")
        XCTAssertEqual(task["labels"]?.array?.compactMap { $0["name"]?.string }, ["a", "b"])
        task = try result("updateTask", ["id": id, "due": nil, "content": " Read two books ", "description": "Slowly"])
        XCTAssertEqual(task["due"], .null)
        XCTAssertEqual(task["content"], "Read two books")
        XCTAssertEqual(task["description"], "Slowly")
        XCTAssertEqual(try send("updateTask", ["id": id, "priority": 7]).reply["error"], "Invalid priority")
        XCTAssertEqual(try send("updateTask", ["id": id, "dueText": "someday maybe"]).reply["ok"], false)
        XCTAssertEqual(try send("updateTask", ["id": id, "content": "  "]).reply["error"], "Type a task name")
        XCTAssertEqual(try result("parseDate", ["text": "no date"])["noDate"], true)
        XCTAssertEqual(try result("parseDate", ["text": "today"])["due"]?["kind"], "today")
        XCTAssertEqual(try result("parseDate", ["text": "banana"]), .null)
    }

    func testMoveIndentAndShift() async throws {
        let work = try result("addProject", ["name": "Work"])["id"]!.string!
        let a = try result("quickAdd", ["text": "A"])["taskId"]!
        let b = try result("quickAdd", ["text": "B"])["taskId"]!
        try result("setView", ["view": ["kind": "project", "id": "inbox"]])
        try result("indentTask", ["id": b])
        XCTAssertEqual(try result("getTask", ["id": b])["parentId"], a)
        try result("outdentTask", ["id": b])
        try result("shiftTask", ["id": b, "delta": -1])
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["B", "A"])
        let moved = try result("moveTask", ["id": a, "projectId": .string(work), "sectionId": nil])
        XCTAssertEqual(moved["projectName"], "Work")
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["B"])
        XCTAssertEqual(try send("moveTask", ["id": b, "projectId": "nope"]).reply["error"], "Unknown project")
    }

    func testMoveTaskRejectsInvalidParents() async throws {
        let a = try result("quickAdd", ["text": "A"])["taskId"]!
        let child = try result("quickAdd", ["text": "Child", "parentId": a])["taskId"]!
        let done = try result("quickAdd", ["text": "Done"])["taskId"]!
        let gone = try result("quickAdd", ["text": "Gone"])["taskId"]!
        try result("toggleComplete", ["id": done])
        try result("deleteTask", ["id": gone])
        func move(_ parent: JSON) throws -> JSON { try send("moveTask", ["id": a, "projectId": "inbox", "parentId": parent]).reply }
        XCTAssertEqual(try move("nope")["error"], "Unknown parent task")
        XCTAssertEqual(try move(gone)["error"], "Unknown parent task")
        XCTAssertEqual(try move(done)["error"], "A task cannot be moved under a completed task")
        XCTAssertEqual(try move(a)["error"], "A task cannot be moved under itself")
        XCTAssertEqual(try move(child)["error"], "A task cannot be moved under itself")
        XCTAssertEqual(try result("getTask", ["id": a])["parentId"], .null)
    }

    /// A project with sections and tasks for the move dialog: Inbox (Alpha, Beta, Gamma), Work
    /// (section Meetings with "Write report"), Home.
    private func moveFixture() throws -> (work: String, meetings: String, home: String, alpha: JSON, beta: JSON,
                                         gamma: JSON, report: JSON) {
        let work = try result("addProject", ["name": "Work", "color": "blue"])["id"]!.string!
        let meetings = try result("addSection", ["projectId": .string(work), "name": "Meetings"])["id"]!.string!
        let home = try result("addProject", ["name": "Home"])["id"]!.string!
        let report = try result("quickAdd", ["text": "Write report", "projectId": .string(work),
                                             "sectionId": .string(meetings)])["taskId"]!
        let alpha = try result("quickAdd", ["text": "Alpha"])["taskId"]!
        let beta = try result("quickAdd", ["text": "Beta"])["taskId"]!
        let gamma = try result("quickAdd", ["text": "Gamma"])["taskId"]!
        try result("setView", ["view": ["kind": "project", "id": "inbox"]])
        return (work, meetings, home, alpha, beta, gamma, report)
    }

    func testMoveTargetsAreRankedWithMatchRanges() async throws {
        let f = try moveFixture()
        // Empty query: the task's own project first (it is there already), then the other projects.
        var targets = try result("moveTargets", ["ids": [f.beta], "query": ""]).array!
        XCTAssertEqual(targets.map { $0["title"]!.string! }, ["Inbox", "Work", "Home"])
        XCTAssertEqual(targets[0]["group"], "currentProject")
        XCTAssertEqual(targets[0]["isCurrent"], true)
        XCTAssertEqual(targets[0]["projectIsInbox"], true)
        XCTAssertEqual(targets[0]["projectColor"], .null)
        XCTAssertEqual(targets[1]["projectColor"], .string(ProjectColor.hex("blue")))
        XCTAssertEqual(targets[1]["id"], .string("p:" + f.work))

        // Words match in the title or its context; tasks only while typing.
        targets = try result("moveTargets", ["ids": [f.beta], "query": "work mee"]).array!
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0]["kind"], "section")
        XCTAssertEqual(targets[0]["group"], "sections")
        XCTAssertEqual(targets[0]["sectionId"], .string(f.meetings))
        XCTAssertEqual(targets[0]["projectName"], "Work")
        XCTAssertEqual(targets[0]["matches"], [[0, 3]])

        targets = try result("moveTargets", ["ids": [f.beta], "query": "r"]).array!
        let report = try XCTUnwrap(targets.first { $0["kind"]?.string == "task" })
        XCTAssertEqual(report["title"], "Write report")
        XCTAssertEqual(report["group"], "tasks")
        XCTAssertEqual(report["parentId"], f.report)
        XCTAssertEqual(report["sectionName"], "Meetings")
        XCTAssertEqual(report["matches"], [[1, 2], [6, 7], [10, 11]])
        XCTAssertFalse(targets.contains { $0["parentId"] == f.beta }, "never the moved task itself")
        XCTAssertEqual(try result("moveTargets", ["ids": [f.beta], "query": "zzz"]), [])
        XCTAssertEqual(try send("moveTargets", ["ids": []]).reply["error"], "Missing ids")
    }

    func testMatchRangesAreUTF16Offsets() async throws {
        // "🎉" is two UTF-16 units, "é" one; the match is found case- and width-correctly.
        XCTAssertEqual(Engine.matchRanges(of: ["café"], in: "🎉 Le CAFÉ du coin").map { [$0.start, $0.end] }, [[6, 10]])
        XCTAssertEqual(Engine.matchRanges(of: ["ab", "bc"], in: "abc abc").map { [$0.start, $0.end] }, [[0, 3], [4, 7]])
        XCTAssertTrue(Engine.matchRanges(of: [], in: "abc").isEmpty)
    }

    func testMoveTasksToSectionProjectAndTaskWithUndo() async throws {
        let f = try moveFixture()
        let selection: JSON = ["cursor": f.beta, "ids": []]
        var moved = try result("moveTasks", ["ids": [f.beta], "selection": selection,
                                             "target": ["kind": "section", "projectId": .string(f.work), "sectionId": .string(f.meetings)]])
        XCTAssertEqual(moved["toast"]?["message"], "Moved to Work / Meetings")
        XCTAssertEqual(moved["toast"]?["undo"], true)
        XCTAssertEqual(moved["ids"], [f.beta])
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Alpha", "Gamma"])
        var beta = try result("getTask", ["id": f.beta])
        XCTAssertEqual(beta["projectId"], .string(f.work))
        XCTAssertEqual(beta["sectionId"], .string(f.meetings))

        // Undo puts the middle task back in its place and hands back the selection.
        let undone = try result("undo")
        XCTAssertEqual(undone["selection"], selection)
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Alpha", "Beta", "Gamma"])

        // Under a task: a sub-task, in that task's project and section.
        moved = try result("moveTasks", ["ids": [f.beta], "target": ["kind": "task", "parentId": f.report]])
        XCTAssertEqual(moved["toast"]?["message"], "Made a sub-task of “Write report”")
        beta = try result("getTask", ["id": f.beta])
        XCTAssertEqual(beta["parentId"], f.report)
        XCTAssertEqual(beta["sectionId"], .string(f.meetings))
        try result("undo")
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(try result("getTask", ["id": f.beta])["parentId"], .null)

        // Several tasks, with a sub-task that goes along with its parent: one step, one undo.
        let child = try result("quickAdd", ["text": "Alpha child", "parentId": f.alpha])["taskId"]!
        moved = try result("moveTasks", ["ids": [f.alpha, child, f.gamma],
                                         "target": ["kind": "project", "projectId": .string(f.home)]])
        XCTAssertEqual(moved["toast"]?["message"], "3 tasks moved to Home")
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Beta"])
        try result("setView", ["view": ["kind": "project", "id": .string(f.home)]])
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Alpha", "Alpha child", "Gamma"])
        XCTAssertEqual(taskRows()[1]["depth"], 1)
        try result("undo")
        XCTAssertTrue(taskRows().isEmpty)
        try result("setView", ["view": ["kind": "project", "id": "inbox"]])
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Alpha", "Alpha child", "Beta", "Gamma"])
        XCTAssertEqual(try result("getTask", ["id": child])["parentId"], f.alpha)
    }

    func testMoveTasksUndoRecollapsesTheParent() async throws {
        let f = try moveFixture()
        try result("quickAdd", ["text": "Draft", "parentId": f.report, "projectId": .string(f.work), "sectionId": .string(f.meetings)])
        try result("setTaskCollapsed", ["id": f.report, "collapsed": true])
        try result("moveTasks", ["ids": [f.beta], "target": ["kind": "task", "parentId": f.report]])
        try result("setView", ["view": ["kind": "project", "id": .string(f.work)]])
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Write report", "Draft", "Beta"], "the parent opens")
        try result("undo")
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Write report"])
        XCTAssertEqual(taskRows()[0]["expanded"], false)
    }

    func testMoveTasksRejectsInvalidTargets() async throws {
        let f = try moveFixture()
        let child = try result("quickAdd", ["text": "Beta child", "parentId": f.beta])["taskId"]!
        let done = try result("quickAdd", ["text": "Done"])["taskId"]!
        try result("toggleComplete", ["id": done])
        func move(_ ids: [JSON], _ target: JSON) throws -> JSON {
            try send("moveTasks", ["ids": .array(ids), "target": target]).reply
        }
        XCTAssertEqual(try move([f.beta], ["kind": "task", "parentId": child])["error"], "The tasks cannot be moved there")
        XCTAssertEqual(try move([f.beta], ["kind": "task", "parentId": f.beta])["error"], "The tasks cannot be moved there")
        XCTAssertEqual(try move([f.beta], ["kind": "task", "parentId": done])["error"], "The tasks cannot be moved there")
        XCTAssertEqual(try move([f.beta], ["kind": "task", "parentId": "nope"])["error"], "The task no longer exists")
        XCTAssertEqual(try move([f.beta], ["kind": "section", "projectId": .string(f.home), "sectionId": .string(f.meetings)])["error"],
                       "Unknown section")
        XCTAssertEqual(try move([f.beta], ["kind": "project", "projectId": "nope"])["error"], "Unknown project")
        XCTAssertEqual(try move([f.beta], ["kind": "galaxy"])["error"], "Unknown move target")
        XCTAssertEqual(try move(["nope"], ["kind": "project", "projectId": .string(f.home)])["error"], "The tasks cannot be moved there")
        // Nothing moved, so nothing was pushed: the last undo step is still the completion.
        XCTAssertEqual(try result("undo")["message"], "1 task completed")
        XCTAssertEqual(try result("getTask", ["id": f.beta])["projectId"], "inbox")
    }

    // MARK: - Views

    func testSectionsCollapseAndCompletedTasks() async throws {
        let p = try result("addProject", ["name": "Home"])["id"]!.string!
        let s = try result("addSection", ["projectId": .string(p), "name": "Garden"])["id"]!.string!
        try result("quickAdd", ["text": "Top", "projectId": .string(p)])
        let rake = try result("quickAdd", ["text": "Rake", "projectId": .string(p), "sectionId": .string(s)])["taskId"]!
        try result("setView", ["view": ["kind": "project", "id": .string(p)]])
        XCTAssertEqual(lastRows.compactMap { $0["type"]?.string }, ["task", "add", "section", "task", "add"])
        try result("setSectionCollapsed", ["id": .string(s), "collapsed": true])
        XCTAssertEqual(lastRows.compactMap { $0["type"]?.string }, ["task", "add", "section"])
        try result("setSectionCollapsed", ["id": .string(s), "collapsed": false])

        try result("toggleComplete", ["id": rake])
        XCTAssertEqual(taskRows().count, 1)
        try result("setShowCompleted", ["projectId": .string(p), "show": true])
        XCTAssertEqual(taskRows().count, 2)
        XCTAssertEqual(taskRows().last?["completed"], true)

        // Kept per device in ui.json.
        let ui = try JSON.parse(String(contentsOf: dir.appendingPathComponent("ui.json"), encoding: .utf8))
        XCTAssertEqual(ui["showCompleted"]?.array, [.string(p)])
    }

    func testLabelAndSearchViewsGroupByProject() async throws {
        try result("addProject", ["name": "Work"])
        try result("quickAdd", ["text": "Email Ann @calls"])
        try result("quickAdd", ["text": "Email Bob @calls #Work"])
        try result("setView", ["view": ["kind": "label", "name": "calls"]])
        XCTAssertEqual(lastRows.compactMap { $0["type"]?.string }, ["group", "task", "group", "task"])
        XCTAssertEqual(lastRows.first?["name"], "Inbox")
        XCTAssertEqual(lastRows.last?["project"]?["name"], "Work")
        try result("setView", ["view": ["kind": "search", "query": "bob"]])
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Email Bob"])
        try result("setView", ["view": ["kind": "search", "query": "zzz"]])
        XCTAssertEqual(lastRows.first?["type"], "message")
    }

    func testDeletedProjectFallsBackToInbox() async throws {
        let p = try result("addProject", ["name": "Temp"])["id"]!.string!
        try result("setView", ["view": ["kind": "project", "id": .string(p)]])
        try result("deleteProject", ["id": .string(p)])
        let view = lines.reversed().compactMap { try? JSON.parse($0) }.first { $0["event"]?.string == "rows" }?["view"]
        XCTAssertEqual(view?["id"], "inbox")
        XCTAssertEqual(try send("deleteProject", ["id": "inbox"]).reply["ok"], false)
    }

    // MARK: - Files

    func testDatabaseAndSettingsArePersisted() async throws {
        try result("quickAdd", ["text": "Keep me"])
        let sync = try result("configureSync", ["serverURL": "https://dav.example.com/", "username": "tim",
                                                "password": "secret", "enabled": false])
        XCTAssertEqual(sync["serverURL"], "https://dav.example.com/")
        engine.flush()
        let settings = try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertTrue(settings.contains("dav.example.com"))
        XCTAssertFalse(settings.contains("secret"), "the password never lands in a file")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("db.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // A new engine on the same folder sees both.
        engine = makeEngine()
        try result("setView", ["view": ["kind": "project", "id": "inbox"]])
        XCTAssertEqual(taskRows().map { $0["content"]!.string! }, ["Keep me"])
        let loaded = try result("getSyncSettings")
        XCTAssertEqual(loaded["username"], "tim")
        XCTAssertEqual(loaded["enabled"], false)
    }

    func testPathsFollowXDG() async throws {
        XCTAssertEqual(EnginePaths.resolve(explicit: nil, environment: ["HOME": "/home/t"]).dataDir.path,
                       "/home/t/.local/share/todotim")
        XCTAssertEqual(EnginePaths.resolve(explicit: nil, environment: ["HOME": "/home/t", "XDG_DATA_HOME": "/data"]).dataDir.path,
                       "/data/todotim")
        XCTAssertEqual(EnginePaths.resolve(explicit: nil, environment: ["HOME": "/home/t", "XDG_DATA_HOME": "relative"]).dataDir.path,
                       "/home/t/.local/share/todotim", "a relative XDG_DATA_HOME is ignored")
        XCTAssertEqual(EnginePaths.resolve(explicit: nil, environment: ["TODOTIM_DATA_DIR": "/tmp/x"]).dataDir.path, "/tmp/x")
        XCTAssertEqual(EnginePaths.resolve(explicit: "/y", environment: ["TODOTIM_DATA_DIR": "/tmp/x"]).dataDir.path, "/y")
    }

    func testMidnightRefreshesDateLabels() async throws {
        var clock = now
        engine = Engine(paths: EnginePaths(dataDir: dir), credentials: InMemoryCredentialStore(), startSyncing: false,
                        calendar: calendar, now: { clock }, output: { [unowned self] line in self.lines.append(line) })
        try result("quickAdd", ["text": "Pay rent tomorrow"])
        try result("setView", ["view": ["kind": "project", "id": "inbox"]])
        XCTAssertEqual(taskRows().first?["due"]?["label"], "Tomorrow")
        clock = now.addingTimeInterval(86_400)
        engine.tick()
        XCTAssertEqual(taskRows().first?["due"]?["label"], "Today")
    }
}

/// The libsecret store, against a fake `secret-tool` that keeps secrets in files.
final class SecretToolCredentialStoreTests: XCTestCase {
    func testStoreLookupClear() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("secret-tool")
        try """
        #!/bin/sh
        # args: store --label=… application todotim account ACCOUNT | lookup … | clear …
        cmd="$1"; shift
        [ "$cmd" = store ] && shift
        f="\(dir.path)/$(echo "$2-$4" | tr '/@:' '___')"
        case "$cmd" in
          store) cat > "$f" ;;
          lookup) [ -f "$f" ] && cat "$f" || exit 1 ;;
          clear) rm -f "$f" ;;
        esac
        """.write(to: tool, atomically: true, encoding: .utf8)
        chmod(tool.path, 0o755)

        let store = SecretToolCredentialStore(executable: tool.path)
        XCTAssertNil(store.password(for: "tim@dav.example.com"))
        try store.savePassword("s3cret with spaces", for: "tim@dav.example.com")
        XCTAssertEqual(store.password(for: "tim@dav.example.com"), "s3cret with spaces")
        XCTAssertNil(store.password(for: "tim@other.example.com"))
        try store.savePassword(nil, for: "tim@dav.example.com")
        XCTAssertNil(store.password(for: "tim@dav.example.com"))

        let missing = SecretToolCredentialStore(executable: dir.appendingPathComponent("nope").path)
        XCTAssertThrowsError(try missing.savePassword("x", for: "a@b"))
        XCTAssertNil(missing.password(for: "a@b"))
    }
}
