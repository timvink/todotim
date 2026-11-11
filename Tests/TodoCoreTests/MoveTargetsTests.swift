import XCTest
@testable import TodoCore

@MainActor
final class MoveTargetsTests: XCTestCase {
    private var store: TodoStore!
    private var work: Project!, home: Project!
    private var meetings: TodoCore.Section!, admin: TodoCore.Section!, garden: TodoCore.Section!
    private var task: TodoTask!, child: TodoTask!, other: TodoTask!

    override func setUp() async throws {
        store = TodoStore()
        work = store.addProject(name: "Work")
        home = store.addProject(name: "Home")
        meetings = store.addSection(projectId: work.id, name: "Meetings")
        admin = store.addSection(projectId: work.id, name: "Admin")
        garden = store.addSection(projectId: home.id, name: "Garden")
        task = store.addTask(content: "Write report", projectId: work.id, sectionId: meetings.id)
        child = store.addTask(content: "Report outline", projectId: work.id, sectionId: meetings.id, parentId: task.id)
        other = store.addTask(content: "Mow the lawn", projectId: home.id, sectionId: garden.id)
    }

    private func ids(_ query: String, _ taskIDs: [EntityID]? = nil) -> [String] {
        store.moveTargets(for: taskIDs ?? [task.id], query: query).map(\.id)
    }

    func testEmptyQueryListsHomeProjectAndSectionsThenProjects() {
        let targets = store.moveTargets(for: [task.id], query: "")
        XCTAssertEqual(targets.map(\.id), ["p:" + work.id, "s:" + meetings.id, "s:" + admin.id, "p:inbox", "p:" + home.id])
        XCTAssertEqual(targets.map(\.group), [.currentProject, .currentProject, .currentProject, .projects, .projects])
        XCTAssertEqual(targets.filter(\.isCurrent).map(\.id), ["s:" + meetings.id])
    }

    func testQueryGroupsSectionsProjectsTasksAlphabetically() {
        store.addSection(projectId: home.id, name: "Errands")
        let e = store.addTask(content: "Email", projectId: home.id)
        // "e": current-project sections (Meetings), other sections (Errands, Garden), projects
        // (Home, Inbox?), tasks.
        let targets = store.moveTargets(for: [task.id], query: "e")
        let groups = targets.map(\.group)
        XCTAssertEqual(groups, groups.sorted())
        XCTAssertEqual(targets.filter { $0.group == .currentProject }.map(\.title), ["Meetings"])
        XCTAssertEqual(targets.filter { $0.group == .sections }.map(\.title), ["Errands", "Garden"])
        XCTAssertEqual(targets.filter { $0.group == .projects }.map(\.title), ["Home"])
        XCTAssertEqual(targets.filter { $0.group == .tasks }.map(\.title), ["Email", "Mow the lawn"])
        XCTAssertEqual(targets.last?.parentId, other.id)
        XCTAssertTrue(ids("e").contains("t:" + e.id))
    }

    func testWordsMatchContextButOneMustMatchTheTitle() {
        XCTAssertEqual(ids("work meet"), ["s:" + meetings.id])
        XCTAssertEqual(ids("home lawn"), ["t:" + other.id])
        // "work" matches the project, not every section and task in it.
        XCTAssertEqual(ids("work"), ["p:" + work.id])
    }

    func testMovedTasksAndSubtasksAndCompletedTasksAreNotTargets() {
        XCTAssertFalse(ids("report").contains("t:" + task.id))
        XCTAssertFalse(ids("report").contains("t:" + child.id))
        XCTAssertEqual(ids("report", [other.id]), ["t:" + child.id, "t:" + task.id])
        store.toggleComplete(other.id)
        XCTAssertEqual(ids("lawn"), [])
    }

    func testCurrentParentIsMarked() {
        let t = store.moveTargets(for: [child.id], query: "write")
        XCTAssertEqual(t.map(\.id), ["t:" + task.id])
        XCTAssertTrue(t[0].isCurrent)
        XCTAssertEqual(t[0].sectionName, "Meetings")
        XCTAssertEqual(t[0].projectName, "Work")
    }

    func testCaseAndDiacriticsFollowTheSearch() {
        XCTAssertEqual(ids("GARDEN"), ["s:" + garden.id])
    }
}
