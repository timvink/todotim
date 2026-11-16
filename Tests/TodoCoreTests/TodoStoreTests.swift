import XCTest
@testable import TodoCore

@MainActor
final class TodoStoreTests: XCTestCase {
    private var store: TodoStore!
    private var inbox: EntityID { TodoStore.inboxID }

    override func setUp() async throws { store = TodoStore() }

    private func contents(_ tasks: [TodoTask]) -> [String] { tasks.map(\.content) }

    func testInboxExists() {
        XCTAssertEqual(store.inbox.id, inbox)
        XCTAssertTrue(store.projects.isEmpty)
    }

    func testAddTaskOrderAndLabels() {
        var changes = 0
        store.onLocalChange = { changes += 1 }
        store.addTask(content: "b", projectId: inbox)
        store.addTask(content: "c", projectId: inbox)
        store.addTask(content: "a", projectId: inbox, at: 0, labels: ["home"])
        store.addTask(content: "mid", projectId: inbox, at: 2)
        XCTAssertEqual(contents(store.tasks(projectId: inbox, sectionId: nil)), ["a", "b", "mid", "c"])
        XCTAssertEqual(store.labels.map(\.name), ["home"])
        XCTAssertEqual(store.tasks(withLabel: "home").map(\.content), ["a"])
        XCTAssertEqual(changes, 4)
    }

    func testSubtaskInheritsProjectAndSection() {
        let p = store.addProject(name: "P")
        let s = store.addSection(projectId: p.id, name: "S")
        let parent = store.addTask(content: "parent", projectId: p.id, sectionId: s.id)
        let child = store.addTask(content: "child", projectId: inbox, parentId: parent.id)
        XCTAssertEqual(child.projectId, p.id)
        XCTAssertEqual(child.sectionId, s.id)
        XCTAssertEqual(contents(store.subtasks(of: parent.id)), ["child"])
    }

    func testIndentAndOutdent() {
        let a = store.addTask(content: "a", projectId: inbox)
        let b = store.addTask(content: "b", projectId: inbox)
        let c = store.addTask(content: "c", projectId: inbox)

        store.indentTask(a.id)  // first task cannot be indented
        XCTAssertNil(store.task(a.id)?.parentId)

        store.indentTask(b.id)
        XCTAssertEqual(store.task(b.id)?.parentId, a.id)
        store.indentTask(c.id)
        XCTAssertEqual(store.task(c.id)?.parentId, a.id)
        XCTAssertEqual(contents(store.subtasks(of: a.id)), ["b", "c"])
        store.indentTask(c.id)
        XCTAssertEqual(store.task(c.id)?.parentId, b.id)

        store.outdentTask(c.id)
        XCTAssertEqual(contents(store.subtasks(of: a.id)), ["b", "c"])
        store.outdentTask(b.id)
        XCTAssertEqual(contents(store.tasks(projectId: inbox, sectionId: nil)), ["a", "b"])
        XCTAssertEqual(contents(store.subtasks(of: a.id)), ["c"])
    }

    func testShiftTask() {
        let a = store.addTask(content: "a", projectId: inbox)
        store.addTask(content: "b", projectId: inbox)
        let c = store.addTask(content: "c", projectId: inbox)
        store.shiftTask(a.id, by: 1)
        XCTAssertEqual(contents(store.tasks(projectId: inbox, sectionId: nil)), ["b", "a", "c"])
        store.shiftTask(c.id, by: -2)
        XCTAssertEqual(contents(store.tasks(projectId: inbox, sectionId: nil)), ["c", "b", "a"])
        store.shiftTask(c.id, by: -1)  // already first
        XCTAssertEqual(contents(store.tasks(projectId: inbox, sectionId: nil)), ["c", "b", "a"])
    }

    func testToggleCompleteCascades() {
        let p = store.addTask(content: "p", projectId: inbox)
        let c = store.addTask(content: "c", projectId: inbox, parentId: p.id)
        let g = store.addTask(content: "g", projectId: inbox, parentId: c.id)

        store.toggleComplete(p.id)
        XCTAssertTrue([p, c, g].allSatisfy { store.task($0.id)!.isCompleted })
        XCTAssertNotNil(store.task(g.id)?.completedAt)
        XCTAssertTrue(store.tasks(projectId: inbox, sectionId: nil).isEmpty)

        // Uncompleting a grandchild reopens its ancestors only.
        store.toggleComplete(g.id)
        XCTAssertFalse(store.task(g.id)!.isCompleted)
        XCTAssertFalse(store.task(c.id)!.isCompleted)
        XCTAssertFalse(store.task(p.id)!.isCompleted)
    }

    func testDeleteTaskCascadesAsTombstones() {
        let p = store.addTask(content: "p", projectId: inbox)
        let c = store.addTask(content: "c", projectId: inbox, parentId: p.id)
        let before = store.db.tasks[c.id]!.updatedAt
        store.deleteTask(p.id)
        XCTAssertNil(store.task(p.id))
        XCTAssertNil(store.task(c.id))
        XCTAssertEqual(store.db.tasks[c.id]?.deleted, true)
        XCTAssertGreaterThanOrEqual(store.db.tasks[c.id]!.updatedAt, before)
    }

    func testDeleteProjectAndSectionCascade() {
        let p = store.addProject(name: "P")
        let s = store.addSection(projectId: p.id, name: "S")
        let inSection = store.addTask(content: "x", projectId: p.id, sectionId: s.id)
        let top = store.addTask(content: "y", projectId: p.id)
        store.deleteSection(s.id)
        XCTAssertNil(store.task(inSection.id))
        XCTAssertNotNil(store.task(top.id))
        store.deleteProject(p.id)
        XCTAssertNil(store.project(p.id))
        XCTAssertNil(store.task(top.id))
        store.deleteProject(inbox)  // the inbox cannot be deleted
        XCTAssertNotNil(store.project(inbox))
    }

    func testMoveTaskBetweenProjectsMovesSubtasks() {
        let p = store.addProject(name: "P")
        let s = store.addSection(projectId: p.id, name: "S")
        let parent = store.addTask(content: "parent", projectId: inbox)
        let child = store.addTask(content: "child", projectId: inbox, parentId: parent.id)
        store.moveTask(parent.id, projectId: p.id, sectionId: s.id, parentId: nil)
        XCTAssertEqual(store.task(parent.id)?.projectId, p.id)
        XCTAssertEqual(store.task(child.id)?.projectId, p.id)
        XCTAssertEqual(store.task(child.id)?.sectionId, s.id)
        XCTAssertEqual(store.task(child.id)?.parentId, parent.id)
        XCTAssertEqual(store.openTaskCount(projectId: p.id), 2)
        XCTAssertEqual(store.openTaskCount(projectId: inbox), 0)

        // A task cannot become its own descendant.
        store.moveTask(parent.id, projectId: p.id, sectionId: s.id, parentId: child.id)
        XCTAssertNil(store.task(parent.id)?.parentId)
    }

    func testRenameLabelUpdatesTasks() {
        let t = store.addTask(content: "x", projectId: inbox, labels: ["old"])
        let l = store.labels.first!
        store.updateLabel(l.id) { $0.name = "new" }
        XCTAssertEqual(store.task(t.id)?.labels, ["new"])
        store.deleteLabel(l.id)
        XCTAssertEqual(store.task(t.id)?.labels, [])
    }

    func testLabelsMatchIgnoringCase() {
        store.addLabel(name: "Work")
        let t = store.addTask(content: "x", projectId: inbox, labels: ["work", "WORK", "new"])
        XCTAssertEqual(store.task(t.id)?.labels, ["Work", "new"], "takes the existing spelling, once")
        store.updateTask(t.id) { $0.labels.append("NEW") }
        XCTAssertEqual(store.task(t.id)?.labels, ["Work", "new"])
        XCTAssertEqual(store.labels.map(\.name), ["Work", "new"])
    }

    func testRenamingLabelOntoAnotherMergesThem() {
        let home = store.addLabel(name: "Home")
        let work = store.addLabel(name: "Work")
        let a = store.addTask(content: "a", projectId: inbox, labels: ["Home"])
        let b = store.addTask(content: "b", projectId: inbox, labels: ["Home", "Work"])
        let merged = store.updateLabel(home.id) { $0.name = "work" }
        XCTAssertEqual(merged?.id, work.id)
        XCTAssertEqual(store.labels.map(\.name), ["Work"])
        XCTAssertEqual(store.task(a.id)?.labels, ["Work"])
        XCTAssertEqual(store.task(b.id)?.labels, ["Work"])
        // Deleting the remaining label leaves no duplicate behind.
        store.deleteLabel(work.id)
        XCTAssertEqual(store.task(b.id)?.labels, [])
        XCTAssertNil(store.updateLabel(home.id) { $0.name = "back" }, "a deleted label stays deleted")
    }

    func testMutationsIgnoreDeletedEntities() {
        let p = store.addProject(name: "P")
        let s = store.addSection(projectId: p.id, name: "S")
        let t = store.addTask(content: "t", projectId: inbox)
        let other = store.addTask(content: "other", projectId: inbox)
        store.deleteTask(t.id)
        let before = store.db.tasks[t.id]
        var changes = 0
        store.onLocalChange = { changes += 1 }
        store.updateTask(t.id) { $0.content = "edited" }
        store.toggleComplete(t.id)
        store.moveTask(t.id, projectId: p.id, sectionId: nil, parentId: nil)
        store.deleteTask(t.id)
        XCTAssertEqual(store.db.tasks[t.id], before)
        XCTAssertEqual(changes, 0)

        store.deleteSection(s.id)
        let deletedSection = store.db.sections[s.id]
        store.updateSection(s.id) { $0.name = "renamed" }
        XCTAssertEqual(store.db.sections[s.id], deletedSection)
        // No move into a deleted section, project or parent.
        store.moveTask(other.id, projectId: p.id, sectionId: s.id, parentId: nil)
        store.moveTask(other.id, projectId: p.id, sectionId: nil, parentId: t.id)
        store.deleteProject(p.id)
        store.moveTask(other.id, projectId: p.id, sectionId: nil, parentId: nil)
        XCTAssertEqual(store.task(other.id)?.projectId, inbox)
        XCTAssertNil(store.task(other.id)?.parentId)
        XCTAssertNil(store.task(other.id)?.sectionId)
    }

    func testRestoreTasksSkipsDeletedPlaces() {
        let p = store.addProject(name: "P")
        let parent = store.addTask(content: "parent", projectId: inbox)
        let child = store.addTask(content: "child", projectId: inbox, parentId: parent.id)
        let inP = store.addTask(content: "in P", projectId: p.id)
        store.deleteTask(parent.id)
        store.restoreTasks([parent.id, child.id])
        XCTAssertEqual(contents(store.subtasks(of: parent.id)), ["child"])
        // A task whose project was deleted since stays deleted, and so does a sub-task of a
        // deleted parent.
        store.deleteTask(inP.id)
        store.deleteProject(p.id)
        store.deleteTask(parent.id)
        store.restoreTasks([inP.id, child.id])
        XCTAssertNil(store.task(inP.id))
        XCTAssertNil(store.task(child.id))
    }

    func testMoveCountingCompletedSiblings() {
        store.addTask(content: "a", projectId: inbox)
        let done = store.addTask(content: "done", projectId: inbox)
        store.addTask(content: "b", projectId: inbox)
        let moved = store.addTask(content: "moved", projectId: inbox)
        store.toggleComplete(done.id)
        // Dropped right after the completed task (index 2 among a, done, b).
        store.moveTask(moved.id, projectId: inbox, sectionId: nil, parentId: nil, at: 2, countingCompleted: true)
        XCTAssertEqual(contents(store.tasks(projectId: inbox, sectionId: nil, includeCompleted: true)),
                       ["a", "done", "moved", "b"])
        // Right before it.
        store.moveTask(moved.id, projectId: inbox, sectionId: nil, parentId: nil, at: 1, countingCompleted: true)
        XCTAssertEqual(contents(store.tasks(projectId: inbox, sectionId: nil, includeCompleted: true)),
                       ["a", "moved", "done", "b"])
    }

    func testReplaceDatabaseKeepsInboxAndSkipsOnLocalChange() {
        var changes = 0
        store.onLocalChange = { changes += 1 }
        store.replaceDatabase(Database())
        XCTAssertEqual(store.inbox.id, inbox)
        XCTAssertEqual(changes, 0)
    }
}
