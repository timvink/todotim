import XCTest
@testable import TodoCore

@MainActor
final class TodoistImportTests: XCTestCase {
    private typealias F = TodoistFixtures

    private func snapshot() throws -> TodoistSnapshot {
        try TodoistSnapshot.decode(Data(F.snapshotJSON.utf8))
    }

    private func tid(_ kind: TodoistImport.Kind, _ id: String) -> EntityID { TodoistImport.entityID(kind, id) }

    // MARK: - Decoding

    func testDecodesV1Fixture() throws {
        let s = try snapshot()
        XCTAssertEqual(s.projects.count, 6)
        XCTAssertEqual(s.sections.count, 4)
        XCTAssertEqual(s.tasks.count, 10)
        XCTAssertEqual(s.labels.count, 2)
        XCTAssertEqual(s.invalidEntries, 0)
        let inbox = try XCTUnwrap(s.projects.first)
        XCTAssertTrue(inbox.isInbox)
        XCTAssertNil(inbox.parentId)
        XCTAssertEqual(s.projects[3].parentId, "6XGgm6PHrGgMpCFX")
        XCTAssertEqual(s.sections[0].sectionOrder, 2)
        let t = s.tasks[0]
        XCTAssertEqual(t.priority, 4)
        XCTAssertEqual(t.labels, ["priority", "Errand"])
        XCTAssertEqual(t.due?.date, "2025-02-12")
        XCTAssertTrue(t.isCollapsed)
        XCTAssertEqual(t.description, "Draft in **Markdown**\nwith two lines")
        XCTAssertTrue(s.tasks[1].due?.isRecurring == true)
        XCTAssertTrue(s.tasks[4].checked)
        XCTAssertEqual(s.labels[0].order, 12)
    }

    func testDecodesV2NamesNumericIDsAndColors() throws {
        let json = """
        {"projects": [{"id": 2203306141, "name": "Inbox", "is_inbox_project": true, "order": 0, "color": 47},
                      {"id": "220474322", "name": "Shopping", "order": 2, "color": "mint_green"}],
         "sections": [{"id": 7025, "project_id": 220474322, "name": "Groceries", "order": 1}],
         "items": [{"id": "2995104339", "project_id": "220474322", "section_id": "7025", "content": "Milk",
                    "is_completed": true, "order": 3, "collapsed": 1,
                    "due": {"date": "2016-09-01", "datetime": "2016-09-01T12:00:00.000000Z", "recurring": false}}],
         "labels": [{"id": 2156154810, "name": "Food", "color": 30, "item_order": 4}]}
        """
        let s = try TodoistSnapshot.decode(Data(json.utf8))
        XCTAssertEqual(s.projects[0].id, "2203306141")
        XCTAssertTrue(s.projects[0].isInbox)
        XCTAssertEqual(s.projects[0].color, "charcoal")
        XCTAssertEqual(s.projects[1].childOrder, 2)
        XCTAssertEqual(s.sections[0].projectId, "220474322")
        XCTAssertEqual(s.sections[0].sectionOrder, 1)
        XCTAssertEqual(s.tasks.count, 1)
        XCTAssertTrue(s.tasks[0].checked)
        XCTAssertTrue(s.tasks[0].isCollapsed)
        XCTAssertEqual(s.tasks[0].childOrder, 3)
        XCTAssertEqual(s.tasks[0].priority, 1, "missing priority is normal")
        XCTAssertEqual(s.labels[0].color, "berry_red")
        XCTAssertEqual(s.labels[0].order, 4)
    }

    func testSkipsInvalidEntriesAndMissingArrays() throws {
        let json = """
        {"projects": [{"name": "no id"}, 42, null, {"id": "p1", "name": "OK"}, [1, 2]],
         "tasks": [{"id": "t1", "project_id": "p1", "content": "fine", "due": {"string": "no date"}}]}
        """
        let s = try TodoistSnapshot.decode(Data(json.utf8))
        XCTAssertEqual(s.projects.map(\.id), ["p1"])
        XCTAssertEqual(s.invalidEntries, 4)
        XCTAssertTrue(s.sections.isEmpty)
        XCTAssertTrue(s.labels.isEmpty)
        XCTAssertEqual(s.tasks.count, 1)
        XCTAssertNil(s.tasks[0].due, "a due without a date is dropped, not fatal")
        XCTAssertThrowsError(try TodoistSnapshot.decode(Data("[1,2]".utf8)))
    }

    func testEncodeRoundTrip() throws {
        let s = try snapshot()
        let again = try TodoistSnapshot.decode(s.encoded())
        XCTAssertEqual(again, s)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: s.encoded()) as? [String: Any])
        let task = try XCTUnwrap((obj["tasks"] as? [[String: Any]])?.first)
        XCTAssertNotNil(task["child_order"], "encodes v1 names")
        XCTAssertNotNil(task["checked"])
    }

    func testDueDay() {
        XCTAssertEqual(TodoistDue(date: "2025-02-12").day, "2025-02-12")
        XCTAssertEqual(TodoistDue(date: "2025-03-01T09:30:00Z").day, "2025-03-01")
        XCTAssertEqual(TodoistDue(date: "2025-03-01T09:30:00").day, "2025-03-01")
        XCTAssertNil(TodoistDue(date: "tomorrow").day)
        XCTAssertNil(TodoistDue(date: "2025-13-01").day)
        XCTAssertNil(TodoistDue(date: "2025-03-01 garbage").day)
    }

    func testColorMapping() {
        for name in TodoistColors.names { XCTAssertEqual(TodoistColors.paletteKey(name), name) }
        XCTAssertEqual(TodoistColors.names.count, 20)
        XCTAssertEqual(TodoistColors.paletteKey("Olive Green"), "olive_green")
        XCTAssertEqual(TodoistColors.paletteKey("gray"), "grey")
        XCTAssertEqual(TodoistColors.paletteKey("mint"), "mint_green")
        XCTAssertEqual(TodoistColors.paletteKey("#ff0000"), "charcoal")
        XCTAssertEqual(TodoistColors.paletteKey(nil), "charcoal")
    }

    // MARK: - IDs

    func testEntityIDsAreDeterministicValidUUIDv5() {
        // RFC 4122 test vector: uuid5(NAMESPACE_DNS, "python.org").
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(TodoistImport.uuidV5(namespace: dns, name: "python.org"), "886313e1-3b8a-5372-9b90-0c9aee199e5d")

        let a = tid(.project, "6XGgm6PHrGgMpCFX")
        XCTAssertEqual(a, tid(.project, "6XGgm6PHrGgMpCFX"))
        XCTAssertNotEqual(a, tid(.task, "6XGgm6PHrGgMpCFX"), "kinds do not collide")
        XCTAssertTrue(isValidEntityID(a))
        XCTAssertEqual(a, a.lowercased())
        XCTAssertEqual(a.count, 36)
    }

    // MARK: - Apply

    func testImportMapsEverything() throws {
        let store = TodoStore()
        var changes = 0
        store.onLocalChange = { changes += 1 }
        let report = TodoistImport.apply(try snapshot(), to: store)
        XCTAssertEqual(changes, 1, "one batch")

        XCTAssertEqual(report.projects, .init(created: 4, skipped: 1))
        XCTAssertEqual(report.sections, .init(created: 3, skipped: 1))
        XCTAssertEqual(report.tasks, .init(created: 8, skipped: 2))
        XCTAssertEqual(report.labels, .init(created: 3))
        XCTAssertEqual(report.warnings.count, 1)
        XCTAssertTrue(report.warnings[0].contains("recurring"))

        // Projects: flat, "Parent / Child", depth-first in child_order, palette colors.
        XCTAssertEqual(store.projects.map(\.name), ["Home", "Work", "Work / Launch", "Work / Launch / Press"])
        XCTAssertEqual(store.projects.map(\.color), ["lime_green", "berry_red", "sky_blue", "charcoal"])
        XCTAssertEqual(store.inbox.name, "Inbox")
        let work = tid(.project, "6XGgm6PHrGgMpCFX")
        XCTAssertNotNil(store.project(work))

        // Sections in section_order; the inbox gets its section.
        XCTAssertEqual(store.sections(in: work).map(\.name), ["Backlog", "Doing"])
        XCTAssertEqual(store.sections(in: TodoStore.inboxID).map(\.name), ["Someday"])

        // Tasks.
        let doing = tid(.section, "6fFPHV272WWh3gpW")
        XCTAssertEqual(store.tasks(projectId: work, sectionId: doing).map(\.content), ["Monthly report", "Write launch post"])
        let post = try XCTUnwrap(store.task(tid(.task, "6XGgmFVcrG5RRjVr")))
        XCTAssertEqual(post.priority, .p1)
        XCTAssertEqual(post.due, DueDate(date: "2025-02-12"))
        XCTAssertEqual(post.labels, ["Priority", "errand"], "label names follow the label list, case-insensitively")
        XCTAssertEqual(post.description, "Draft in **Markdown**\nwith two lines")
        XCTAssertTrue(post.collapsed)
        XCTAssertEqual(post.createdAt, ISO8601DateFormatter().date(from: "2025-01-15T10:30:00Z"))
        XCTAssertFalse(post.isCompleted)
        XCTAssertEqual(store.subtasks(of: post.id).map(\.content), ["Outline", "Get screenshots"])
        XCTAssertEqual(store.subtasks(of: post.id).map(\.priority), [.p4, .p3])
        XCTAssertTrue(store.subtasks(of: post.id).allSatisfy { $0.projectId == work && $0.sectionId == doing })

        let monthly = try XCTUnwrap(store.task(tid(.task, "6XGgmH3vKq8Jt2Wc")))
        XCTAssertEqual(monthly.priority, .p2)
        XCTAssertEqual(monthly.due, DueDate(date: "2025-03-01"), "date part only")

        // A task in an archived section lands in the project's top area.
        XCTAssertEqual(store.tasks(projectId: work, sectionId: nil).map(\.content), ["In archived section"])
        // Completed and archived-project tasks are skipped.
        XCTAssertNil(store.task(tid(.task, "6XGgmP5zTu8Pa4Wf")))
        XCTAssertNil(store.task(tid(.task, "6XGgmX9hBc2Vg8Aj")))

        // Inbox tasks go to the TodoTim inbox.
        XCTAssertEqual(store.tasks(projectId: TodoStore.inboxID, sectionId: nil).map(\.content), ["Buy milk"])
        XCTAssertEqual(store.tasks(projectId: TodoStore.inboxID, sectionId: tid(.section, "6fFPHc9Rw3Jm7NvB")).map(\.content),
                       ["Learn Swift macros"])

        // Labels, including one only referenced by a task.
        XCTAssertEqual(Set(store.labels.map(\.name)), ["Priority", "errand", "shared-label"])
        XCTAssertEqual(store.labels.first { $0.name == "Priority" }?.color, "berry_red")
        XCTAssertEqual(store.tasks(withLabel: "Priority").count, 2)

        // Everything the import wrote is valid for sync.
        let db = store.db
        for id in Array(db.projects.keys) + Array(db.sections.keys) + Array(db.tasks.keys) + Array(db.labels.keys) {
            XCTAssertTrue(isValidEntityID(id), id)
        }
        var repaired = db
        SyncEngine.repairStructure(&repaired)
        XCTAssertEqual(repaired, db)
    }

    func testReimportIsIdempotent() throws {
        let store = TodoStore()
        TodoistImport.apply(try snapshot(), to: store)
        let first = store.db
        var changes = 0
        store.onLocalChange = { changes += 1 }

        let report = TodoistImport.apply(try snapshot(), to: store)
        XCTAssertEqual(store.db, first, "nothing changes, not even updatedAt")
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(report.hasChanges)
        XCTAssertEqual(report.projects, .init(unchanged: 4, skipped: 1))
        XCTAssertEqual(report.sections, .init(unchanged: 3, skipped: 1))
        XCTAssertEqual(report.tasks, .init(unchanged: 8, skipped: 2))
        XCTAssertEqual(report.labels, .init(unchanged: 3))
    }

    func testReimportUpdatesChangedEntitiesOnly() throws {
        let store = TodoStore()
        TodoistImport.apply(try snapshot(), to: store)
        let postID = tid(.task, "6XGgmFVcrG5RRjVr")
        let before = try XCTUnwrap(store.db.tasks[postID])
        let untouched = try XCTUnwrap(store.db.tasks[tid(.task, "6XGgmT3dXy5Td6Yh")])
        // TodoTim-only state survives a re-import.
        store.updateTask(postID) { $0.collapsed = false }
        store.moveProject(tid(.project, "6XGgm6PHrGgMpCFX"), to: 0)

        var s = try snapshot()
        s.tasks[0].content = "Write launch post v2"
        s.tasks[0].priority = 1
        s.projects[1].name = "Job"
        // Todoist renames a label on its tasks too.
        s.labels[0].name = "Urgent"
        s.tasks[0].labels = ["Urgent", "Errand"]
        s.tasks[2].labels = ["Urgent"]
        // Completed in Todoist after the first import.
        s.tasks[2].checked = true
        s.tasks[2].completedAt = "2025-02-01T08:00:00Z"
        let report = TodoistImport.apply(s, to: store)

        XCTAssertEqual(report.tasks.updated, 2, "content and completion")
        XCTAssertEqual(report.tasks.created, 0)
        XCTAssertEqual(report.projects.updated, 3, "Work and both sub-project names")
        XCTAssertEqual(report.labels.updated, 1)

        let post = try XCTUnwrap(store.task(postID))
        XCTAssertEqual(post.content, "Write launch post v2")
        XCTAssertEqual(post.priority, .p4)
        XCTAssertEqual(post.labels, ["Urgent", "errand"])
        XCTAssertFalse(post.collapsed, "local collapsed state kept")
        XCTAssertEqual(post.createdAt, before.createdAt)
        // Timestamps have millisecond precision, so a re-import in the same millisecond can tie.
        XCTAssertGreaterThanOrEqual(post.updatedAt, before.updatedAt)
        XCTAssertEqual(store.db.tasks[untouched.id], untouched)

        XCTAssertEqual(store.projects.map(\.name), ["Job", "Home", "Job / Launch", "Job / Launch / Press"],
                       "local project order kept")
        let shots = try XCTUnwrap(store.db.tasks[tid(.task, "6XGgmK7nPr4Lw9Xd")])
        XCTAssertTrue(shots.isCompleted)
        XCTAssertEqual(shots.completedAt, ISO8601DateFormatter().date(from: "2025-02-01T08:00:00Z"))
        XCTAssertEqual(shots.labels, ["Urgent"])
        XCTAssertEqual(store.labels.map(\.name).sorted(), ["Urgent", "errand", "shared-label"])
    }

    func testLocalProjectNamedInboxDoesNotCollide() throws {
        let store = TodoStore()
        let mine = store.addProject(name: "Inbox", color: "red")
        let task = store.addTask(content: "mine", projectId: mine.id)
        TodoistImport.apply(try snapshot(), to: store)
        XCTAssertEqual(store.project(mine.id)?.name, "Inbox")
        XCTAssertEqual(store.tasks(projectId: mine.id, sectionId: nil).map(\.id), [task.id])
        XCTAssertEqual(store.projects.first?.id, mine.id, "imported projects go after existing ones")
        XCTAssertEqual(store.projects.count, 5)
    }

    func testExistingLabelIsReusedByName() throws {
        let store = TodoStore()
        let mine = store.addLabel(name: "PRIORITY", color: "green")
        let report = TodoistImport.apply(try snapshot(), to: store)
        XCTAssertEqual(report.labels, .init(created: 2, unchanged: 1))
        XCTAssertEqual(store.labels.filter { $0.name.lowercased() == "priority" }.map(\.id), [mine.id])
        XCTAssertEqual(store.label(named: "PRIORITY")?.color, "green")
        XCTAssertEqual(store.task(tid(.task, "6XGgmFVcrG5RRjVr"))?.labels, ["PRIORITY", "errand"])
    }

    func testIncludeCompleted() throws {
        let store = TodoStore()
        let report = TodoistImport.apply(try snapshot(), to: store, options: .init(includeCompleted: true))
        XCTAssertEqual(report.tasks, .init(created: 9, skipped: 1))
        let done = try XCTUnwrap(store.task(tid(.task, "6XGgmP5zTu8Pa4Wf")))
        XCTAssertTrue(done.isCompleted)
        XCTAssertEqual(done.completedAt, ISO8601DateFormatter().date(from: "2025-01-20T12:00:00Z"))
    }

    func testDeletedLocallyIsRestoredOrSkipped() throws {
        let store = TodoStore()
        TodoistImport.apply(try snapshot(), to: store)
        let milk = tid(.task, "6XGgmT3dXy5Td6Yh")
        let home = tid(.project, "6XGgmC7hQpRw3m2v")
        store.deleteTask(milk)
        store.deleteProject(home)

        var report = TodoistImport.apply(try snapshot(), to: store, options: .init(restoreDeleted: false))
        XCTAssertEqual(report.tasks.skipped, 3)
        XCTAssertEqual(report.projects.skipped, 2)
        XCTAssertNil(store.task(milk))
        XCTAssertNil(store.project(home))

        report = TodoistImport.apply(try snapshot(), to: store)
        XCTAssertEqual(report.tasks.updated, 1)
        XCTAssertEqual(report.projects.updated, 1)
        XCTAssertNotNil(store.task(milk))
        XCTAssertNotNil(store.project(home))
    }

    func testSubtaskOfSkippedParentBecomesTopLevelAndCyclesAreBroken() throws {
        let s = TodoistSnapshot(
            projects: [TodoistProject(id: "p", name: "P"),
                       TodoistProject(id: "a", name: "A", parentId: "b"),
                       TodoistProject(id: "b", name: "B", parentId: "a")],
            tasks: [TodoistTask(id: "parent", projectId: "p", content: "parent", checked: true),
                    TodoistTask(id: "child", projectId: "p", parentId: "parent", content: "child"),
                    TodoistTask(id: "x", projectId: "p", parentId: "y", content: "x"),
                    TodoistTask(id: "y", projectId: "p", parentId: "x", content: "y"),
                    TodoistTask(id: "self", projectId: "p", parentId: "self", content: "self"),
                    TodoistTask(id: "nowhere", projectId: "missing", content: "nowhere")])
        let store = TodoStore()
        let report = TodoistImport.apply(s, to: store)
        XCTAssertEqual(report.tasks, .init(created: 4, skipped: 2))
        XCTAssertEqual(Set(store.projects.map(\.name)), ["P", "A", "B"], "cyclic project parents become roots")
        let p = tid(.project, "p")
        let top = store.tasks(projectId: p, sectionId: nil).map(\.content)
        XCTAssertTrue(top.contains("child"))
        XCTAssertTrue(top.contains("self"))
        XCTAssertEqual(store.task(tid(.task, "x"))?.parentId == nil || store.task(tid(.task, "y"))?.parentId == nil, true)
    }

    func testLongTextIsClipped() throws {
        let s = TodoistSnapshot(tasks: [TodoistTask(id: "t", projectId: "i",
                                                    content: String(repeating: "x", count: SyncLimits.maxContentLength + 5),
                                                    labels: (0..<150).map { "l\($0)" })],
                                labels: [])
        var snap = s
        snap.projects = [TodoistProject(id: "i", name: "Inbox", isInbox: true)]
        let store = TodoStore()
        TodoistImport.apply(snap, to: store)
        let t = try XCTUnwrap(store.task(tid(.task, "t")))
        XCTAssertEqual(t.content.count, SyncLimits.maxContentLength)
        XCTAssertEqual(t.labels.count, SyncLimits.maxLabelsPerTask)
        XCTAssertEqual(t.projectId, TodoStore.inboxID)
    }

    func testReportSummary() {
        var r = ImportReport()
        r.tasks = .init(created: 2, updated: 1, unchanged: 0, skipped: 3)
        r.warnings = ["w"]
        XCTAssertTrue(r.summary.contains("Tasks: 2 created, 1 updated, 0 unchanged, 3 skipped"))
        XCTAssertTrue(r.summary.hasSuffix("w"))
        XCTAssertTrue(r.hasChanges)
    }
}

private extension TodoStore {
    func label(named name: String) -> Label? { labels.first { $0.name == name } }
}
