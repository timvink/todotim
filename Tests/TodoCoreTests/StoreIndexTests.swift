import Observation
import XCTest
@testable import TodoCore

@MainActor
final class StoreIndexTests: XCTestCase {
    private var inbox: EntityID { TodoStore.inboxID }

    // MARK: - Index consistency

    /// Compares every indexed query against a brute-force scan of `store.db`.
    private func assertIndexMatchesScan(_ store: TodoStore, file: StaticString = #filePath, line: UInt = #line) {
        let db = store.db
        let live = db.tasks.values.filter { !$0.deleted }
        func sorted(_ ts: [TodoTask]) -> [EntityID] { ts.sorted(by: TodoStore.taskOrder).map(\.id) }

        let areas = Set(live.map { AreaKey(projectId: $0.projectId, sectionId: $0.sectionId) })
            .union(db.sections.values.map { AreaKey(projectId: $0.projectId, sectionId: $0.id) })
        for a in areas {
            for includeCompleted in [false, true] {
                let expected = sorted(live.filter {
                    $0.projectId == a.projectId && $0.sectionId == a.sectionId && $0.parentId == nil
                        && (includeCompleted || !$0.isCompleted)
                })
                XCTAssertEqual(store.tasks(projectId: a.projectId, sectionId: a.sectionId, includeCompleted: includeCompleted).map(\.id),
                               expected, "area \(a)", file: file, line: line)
                XCTAssertEqual(store.taskIDs(projectId: a.projectId, sectionId: a.sectionId, includeCompleted: includeCompleted),
                               expected, file: file, line: line)
            }
            XCTAssertEqual(store.openTaskCount(projectId: a.projectId, sectionId: a.sectionId),
                           store.tasks(projectId: a.projectId, sectionId: a.sectionId).count, file: file, line: line)
        }
        for t in db.tasks.values {
            for includeCompleted in [false, true] {
                let expected = sorted(live.filter { $0.parentId == t.id && (includeCompleted || !$0.isCompleted) })
                XCTAssertEqual(store.subtasks(of: t.id, includeCompleted: includeCompleted).map(\.id), expected, file: file, line: line)
                XCTAssertEqual(store.subtaskIDs(of: t.id, includeCompleted: includeCompleted), expected, file: file, line: line)
            }
            let kids = live.filter { $0.parentId == t.id }
            let progress = store.subtaskProgress(of: t.id)
            XCTAssertEqual(progress.total, kids.count, file: file, line: line)
            XCTAssertEqual(progress.done, kids.filter(\.isCompleted).count, file: file, line: line)

            var expectedDesc = Set<EntityID>()
            var queue = [t.id]
            while let cur = queue.popLast() {
                for k in live where k.parentId == cur && expectedDesc.insert(k.id).inserted { queue.append(k.id) }
            }
            expectedDesc.remove(t.id)
            let desc = store.descendantIDs(of: t.id)
            XCTAssertEqual(Set(desc), expectedDesc, file: file, line: line)
            XCTAssertEqual(desc.count, expectedDesc.count, "no duplicates", file: file, line: line)
        }
        for pid in Set(db.projects.keys).union(live.map(\.projectId)) {
            XCTAssertEqual(store.openTaskCount(projectId: pid), live.filter { $0.projectId == pid && !$0.isCompleted }.count,
                           file: file, line: line)
        }
        for name in Set(live.flatMap(\.labels)).union(store.labels.map(\.name)) {
            let expected = sorted(live.filter { !$0.isCompleted && $0.labels.contains(name) })
            XCTAssertEqual(store.tasks(withLabel: name).map(\.id), expected, file: file, line: line)
            XCTAssertEqual(store.openTaskCount(label: name), expected.count, file: file, line: line)
        }
        for p in db.projects.values {
            XCTAssertEqual(store.sections(in: p.id).map(\.id),
                           db.sections.values.filter { $0.projectId == p.id && !$0.deleted }.sorted(by: TodoStore.byOrder).map(\.id),
                           file: file, line: line)
        }
        XCTAssertEqual(store.projects.map(\.id),
                       db.projects.values.filter { !$0.deleted && !$0.isInbox }.sorted(by: TodoStore.byOrder).map(\.id),
                       file: file, line: line)
        XCTAssertEqual(store.labels.map(\.id), db.labels.values.filter { !$0.deleted }.sorted(by: TodoStore.byOrder).map(\.id),
                       file: file, line: line)
    }

    func testRandomMutationsKeepIndexConsistent() {
        var rng = SeededRNG(seed: 42)
        let store = TodoStore()
        let p1 = store.addProject(name: "P1"), p2 = store.addProject(name: "P2")
        let s1 = store.addSection(projectId: p1.id, name: "S1"), s2 = store.addSection(projectId: p2.id, name: "S2")
        let areas: [(EntityID, EntityID?)] = [(inbox, nil), (p1.id, nil), (p1.id, s1.id), (p2.id, nil), (p2.id, s2.id)]
        let labelNames = ["a", "b", "c"]
        for _ in 0..<40 {
            let (pid, sid) = areas.randomElement(using: &rng)!
            store.addTask(content: "t", projectId: pid, sectionId: sid, labels: rng.next() % 2 == 0 ? [labelNames.randomElement(using: &rng)!] : [])
        }
        for step in 0..<600 {
            let ids = store.db.tasks.values.filter { !$0.deleted }.map(\.id).sorted()
            guard let id = ids.randomElement(using: &rng) else { break }
            switch rng.next() % 12 {
            case 0:
                let (pid, sid) = areas.randomElement(using: &rng)!
                store.addTask(content: "n\(step)", projectId: pid, sectionId: sid, at: Int(rng.next() % 5))
            case 1: store.addTask(content: "sub\(step)", projectId: inbox, parentId: id, at: Int(rng.next() % 3))
            case 2: store.toggleComplete(id)
            case 3: store.indentTask(id)
            case 4: store.outdentTask(id)
            case 5: store.shiftTask(id, by: rng.next() % 2 == 0 ? 1 : -1)
            case 6:
                let (pid, sid) = areas.randomElement(using: &rng)!
                store.moveTask(id, projectId: pid, sectionId: sid, parentId: nil, at: Int(rng.next() % 4))
            case 7: store.moveTask(id, projectId: inbox, sectionId: nil, parentId: ids.randomElement(using: &rng))
            case 8: store.updateTask(id) { $0.labels = rng.next() % 2 == 0 ? [] : [labelNames.randomElement(using: &rng)!] }
            case 9: store.updateTask(id) { $0.content = "edit \(step)" }
            case 10: if rng.next() % 4 == 0 { store.deleteTask(id) }
            default:
                // A sync-style replacement: flip a few tasks behind the store's back.
                var db = store.db
                for tid in ids.prefix(3) {
                    db.tasks[tid]?.isCompleted.toggle()
                    db.tasks[tid]?.order = Double(rng.next() % 10)
                }
                if let victim = ids.last, rng.next() % 3 == 0 { db.tasks[victim] = nil }
                store.replaceDatabase(db)
            }
            if step % 50 == 0 { assertIndexMatchesScan(store) }
        }
        assertIndexMatchesScan(store)
        store.updateLabel(store.labels.first { $0.name == "a" }!.id) { $0.name = "renamed" }
        store.deleteLabel(store.labels.first { $0.name == "b" }!.id)
        store.deleteSection(s1.id)
        store.deleteProject(p2.id)
        assertIndexMatchesScan(store)
    }

    func testIndexFromLoadedDatabase() {
        // A slice of the benchmark fixture (the brute-force check is quadratic).
        var db = PerformanceTests.fixture()
        let keep: Set<EntityID> = ["project-0", "project-1", "project-2"]
        db.tasks = db.tasks.filter { keep.contains($0.value.projectId) }
        db.sections = db.sections.filter { keep.contains($0.value.projectId) }
        let store = TodoStore(db: db)
        assertIndexMatchesScan(store)
    }

    func testDescendantIDsSurvivesCycles() {
        var db = Database()
        db.tasks["a"] = TodoTask(id: "a", projectId: inbox, parentId: "b", content: "a", order: 1)
        db.tasks["b"] = TodoTask(id: "b", projectId: inbox, parentId: "a", content: "b", order: 1)
        db.tasks["c"] = TodoTask(id: "c", projectId: inbox, parentId: "b", content: "c", order: 2)
        let store = TodoStore(db: db)
        XCTAssertEqual(Set(store.descendantIDs(of: "a")), ["b", "c"])
        store.toggleComplete("c")
        store.toggleComplete("c")  // uncomplete walks ancestors through the cycle
        XCTAssertEqual(store.task("c")?.isCompleted, false)
    }

    func testSubtaskProgressAndCounts() {
        let store = TodoStore()
        let p = store.addProject(name: "P")
        let s = store.addSection(projectId: p.id, name: "S")
        let parent = store.addTask(content: "parent", projectId: p.id, sectionId: s.id, labels: ["x"])
        let c1 = store.addTask(content: "c1", projectId: p.id, parentId: parent.id, labels: ["x"])
        store.addTask(content: "c2", projectId: p.id, parentId: parent.id)
        store.toggleComplete(c1.id)
        XCTAssertTrue(store.subtaskProgress(of: parent.id) == (1, 2))
        XCTAssertEqual(store.openTaskCount(projectId: p.id), 2)
        XCTAssertEqual(store.openTaskCount(projectId: p.id, sectionId: s.id), 1)
        XCTAssertEqual(store.openTaskCount(projectId: p.id, sectionId: nil), 0)
        XCTAssertEqual(store.openTaskCount(label: "x"), 1)
        store.deleteTask(parent.id)
        XCTAssertTrue(store.subtaskProgress(of: parent.id) == (0, 0))
        XCTAssertEqual(store.openTaskCount(projectId: p.id), 0)
        XCTAssertEqual(store.openTaskCount(label: "x"), 0)
    }

    // MARK: - Observation granularity

    /// Whether `read` (as a view body would) is invalidated by `mutate`.
    private func invalidates(_ read: () -> Void, _ mutate: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.fired = true }
        mutate()
        return flag.fired
    }

    func testTitleEditOnlyInvalidatesReadersOfThatTask() {
        let store = TodoStore()
        let p = store.addProject(name: "P"), other = store.addProject(name: "O")
        let s = store.addSection(projectId: p.id, name: "S")
        let t = store.addTask(content: "t", projectId: p.id, labels: ["x"])
        let sibling = store.addTask(content: "sibling", projectId: p.id)
        store.addTask(content: "elsewhere", projectId: other.id)
        func edit() { store.updateTask(t.id) { $0.content += "!" } }

        XCTAssertFalse(invalidates({ _ = store.openTaskCount(projectId: p.id) }, edit))
        XCTAssertFalse(invalidates({ _ = store.openTaskCount(label: "x") }, edit))
        XCTAssertFalse(invalidates({ _ = store.projects; _ = store.labels; _ = store.sections(in: p.id) }, edit))
        XCTAssertFalse(invalidates({ _ = store.tasks(projectId: other.id, sectionId: nil) }, edit))
        XCTAssertFalse(invalidates({ _ = store.tasks(projectId: p.id, sectionId: s.id) }, edit))
        XCTAssertFalse(invalidates({ _ = store.task(sibling.id) }, edit))
        XCTAssertFalse(invalidates({ _ = store.subtaskProgress(of: t.id); _ = store.structureVersion }, edit))

        XCTAssertFalse(invalidates({ _ = store.taskIDs(projectId: p.id, sectionId: nil); _ = store.subtaskIDs(of: t.id) }, edit))
        XCTAssertTrue(invalidates({ _ = store.taskIDs(projectId: p.id, sectionId: nil) }, { store.toggleComplete(sibling.id) }))

        XCTAssertTrue(invalidates({ _ = store.task(t.id) }, edit))
        XCTAssertTrue(invalidates({ _ = store.tasks(projectId: p.id, sectionId: nil) }, edit))
        XCTAssertTrue(invalidates({ _ = store.tasks(withLabel: "x") }, edit))
        XCTAssertTrue(invalidates({ _ = store.search("t") }, edit))
        XCTAssertTrue(invalidates({ _ = store.db }, edit))
    }

    func testStructuralChangesInvalidateCounts() {
        let store = TodoStore()
        let p = store.addProject(name: "P")
        let t = store.addTask(content: "t", projectId: p.id)
        XCTAssertTrue(invalidates({ _ = store.openTaskCount(projectId: p.id) }, { store.toggleComplete(t.id) }))
        XCTAssertTrue(invalidates({ _ = store.tasks(projectId: p.id, sectionId: nil) }, {
            store.addTask(content: "u", projectId: p.id)
        }))
        XCTAssertTrue(invalidates({ _ = store.projects }, { store.updateProject(p.id) { $0.name = "Q" } }))
        XCTAssertFalse(invalidates({ _ = store.openTaskCount(projectId: p.id) }, { store.updateProject(p.id) { $0.name = "R" } }))
    }

    func testBatchNotifiesOnce() {
        let store = TodoStore()
        var changes = 0
        store.onLocalChange = { changes += 1 }
        let a = store.addTask(content: "a", projectId: inbox)
        let b = store.addTask(content: "b", projectId: inbox)
        changes = 0
        store.performBatch {
            store.updateTask(a.id) { $0.content = "A" }
            store.updateTask(b.id) { $0.content = "B" }
            store.toggleComplete(a.id)
        }
        XCTAssertEqual(changes, 1)
        store.updateTask(b.id) { $0.content = "B" }  // no-op edit
        XCTAssertEqual(changes, 1)
    }

    func testReplaceDatabaseOnlyInvalidatesChangedTasks() {
        let store = TodoStore()
        let a = store.addTask(content: "a", projectId: inbox)
        let b = store.addTask(content: "b", projectId: inbox)
        var db = store.db
        db.tasks[a.id]?.content = "remote edit"
        XCTAssertFalse(invalidates({ _ = store.task(b.id); _ = store.openTaskCount(projectId: inbox) }, { store.replaceDatabase(db) }))
        XCTAssertEqual(store.task(a.id)?.content, "remote edit")
    }

    // MARK: - Timestamps and ordering

    func testMutationTimestampsHaveMillisecondPrecision() {
        let store = TodoStore()
        let t = store.addTask(content: "t", projectId: inbox)
        store.updateTask(t.id) { $0.completedAt = Date(timeIntervalSince1970: 1_700_000_000.123_456) }
        let stored = store.task(t.id)!
        for d in [stored.createdAt, stored.updatedAt, stored.completedAt!] {
            XCTAssertEqual(d, TodoStore.millisecondPrecision(d))
        }
        // The same Double a decoded file produces, so local and round-tripped copies are ==.
        let decoded = try! JSONCoding.decoder.decode(TodoTask.self, from: JSONCoding.encoder.encode(stored))
        XCTAssertEqual(decoded, stored)
    }

    func testRepeatedMidpointInsertsRebalance() {
        let store = TodoStore()
        store.addTask(content: "first", projectId: inbox)
        store.addTask(content: "last", projectId: inbox)
        for i in 0..<200 { store.addTask(content: "\(i)", projectId: inbox, at: 1) }
        let contents = store.tasks(projectId: inbox, sectionId: nil).map(\.content)
        XCTAssertEqual(contents, ["first"] + (0..<200).reversed().map(String.init) + ["last"])
        let orders = store.tasks(projectId: inbox, sectionId: nil).map(\.order)
        XCTAssertEqual(Set(orders).count, orders.count)
    }

    func testRebalanceKeepsCompletedSiblingsInPlace() {
        let store = TodoStore()
        let a = store.addTask(content: "a", projectId: inbox)
        let done = store.addTask(content: "done", projectId: inbox)
        store.addTask(content: "z", projectId: inbox)
        store.toggleComplete(done.id)
        for i in 0..<100 { store.addTask(content: "\(i)", projectId: inbox, at: 1) }
        let all = store.tasks(projectId: inbox, sectionId: nil, includeCompleted: true).map(\.content)
        XCTAssertEqual(all.first, a.content)
        XCTAssertEqual(all.last, "z")
        XCTAssertEqual(Set(all.map { $0 }).count, all.count)
        XCTAssertEqual(store.tasks(projectId: inbox, sectionId: nil).map(\.content),
                       ["a"] + (0..<100).reversed().map(String.init) + ["z"])
    }

    func testRepeatedSectionAndProjectMovesRebalance() {
        let store = TodoStore()
        let ps = (0..<3).map { store.addProject(name: "P\($0)") }
        for _ in 0..<120 {
            let last = store.projects.last!
            store.moveProject(last.id, to: 1)
        }
        XCTAssertEqual(Set(store.projects.map(\.order)).count, 3)
        XCTAssertEqual(Set(store.projects.map(\.id)), Set(ps.map(\.id)))
        let p = ps[0]
        store.addSection(projectId: p.id, name: "a")
        store.addSection(projectId: p.id, name: "z")
        for i in 0..<120 { store.addSection(projectId: p.id, name: "\(i)", at: 1) }
        let names = store.sections(in: p.id).map(\.name)
        XCTAssertEqual(names, ["a"] + (0..<120).reversed().map(String.init) + ["z"])
    }
}

/// Deterministic generator for randomized tests (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
