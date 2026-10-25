import XCTest
@testable import TodoCore

/// Heavy-user benchmark: 5,000 tasks across 50 projects (+ inbox), with sections and subtasks.
/// Prints median timings; run in release for meaningful numbers:
///
///     swift test -c release -Xswiftc -enable-testing --filter PerformanceTests
///
/// The core scenarios use only the original public API, so the file also runs against the
/// pre-index TodoCore for before/after comparisons with `-Xswiftc -DBENCH_BEFORE`.
@MainActor
final class PerformanceTests: XCTestCase {
    static let projectCount = 50
    static let tasksPerProject = 100
    static let labelNames = (0..<10).map { "label\($0)" }

    /// Deterministic fixture. Per project: 3 sections; top-level tasks spread over the top area and
    /// the sections; roughly 40% subtasks (some two levels deep); about 10% completed.
    static func fixture() -> Database {
        var db = Database()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        // Millisecond precision, like every date loaded from disk or the server.
        func date(_ i: Int) -> Date { Date(timeIntervalSince1970: Double(Int64(base.timeIntervalSince1970) * 1000 + Int64(i) * 731) / 1000) }
        for l in labelNames.indices {
            let label = Label(id: "label-\(l)", name: labelNames[l], order: Double(l), updatedAt: date(l))
            db.labels[label.id] = label
        }
        var n = 0
        for p in 0..<projectCount {
            let pid = "project-\(p)"
            db.projects[pid] = Project(id: pid, name: "Project \(p)", order: Double(p), updatedAt: date(p))
            let sectionIDs = (0..<3).map { "section-\(p)-\($0)" }
            for (i, sid) in sectionIDs.enumerated() {
                db.sections[sid] = Section(id: sid, projectId: pid, name: "Section \(i)", order: Double(i), updatedAt: date(i))
            }
            var topLevel: [(id: EntityID, section: EntityID?)] = []
            var children: [EntityID] = []
            for i in 0..<tasksPerProject {
                n += 1
                let id = "task-\(p)-\(i)"
                var parent: (id: EntityID, section: EntityID?)?
                if i % 5 == 1 || i % 5 == 3, let last = topLevel.last { parent = last }
                if i % 10 == 4, let c = children.last, let owner = db.tasks[c] { parent = (c, owner.sectionId) }
                let section: EntityID?
                if let parent { section = parent.section } else { section = i % 4 == 0 ? nil : sectionIDs[i % 3] }
                let done = i % 10 == 7 && parent == nil
                let t = TodoTask(id: id, projectId: pid, sectionId: section, parentId: parent?.id,
                                 content: "Task \(n) with a reasonably long title for realism",
                                 description: i % 3 == 0 ? "Some notes about task \(n).\nSecond line." : "",
                                 priority: Priority(rawValue: 1 + i % 4)!,
                                 due: i % 6 == 0 ? DueDate(date: "2026-11-\(String(format: "%02d", 1 + i % 28))") : nil,
                                 labels: i % 3 == 0 ? [labelNames[(i + p) % labelNames.count]] : [],
                                 isCompleted: done, completedAt: done ? date(n) : nil, order: Double(i),
                                 createdAt: date(n), updatedAt: date(n))
                db.tasks[id] = t
                if parent == nil { if !done { topLevel.append((id, section)) } } else { children.append(id) }
            }
        }
        return db
    }

    /// Median wall time in milliseconds over `runs` runs (after one warm-up run).
    @discardableResult
    func time(_ name: String, runs: Int = 15, _ body: () throws -> Void) rethrows -> Double {
        try body()
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            let d = ContinuousClock.now - start
            samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        let median = samples.sorted()[samples.count / 2]
        print(String(format: "BENCH %-44@ %10.4f ms", name as NSString, median))
        return median
    }

    func timeAsync(_ name: String, runs: Int = 7, _ body: () async throws -> Void) async rethrows -> Double {
        try await body()
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try await body()
            let d = ContinuousClock.now - start
            samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        let median = samples.sorted()[samples.count / 2]
        print(String(format: "BENCH %-44@ %10.4f ms", name as NSString, median))
        return median
    }

    /// Mirrors `AppModel.rows`/`appendTree`/`rowItem` in the app: (id, depth, done, total) per row.
    func buildRows(_ store: TodoStore, projectId: EntityID) -> [(EntityID, Int, Int, Int)] {
        var out: [(EntityID, Int, Int, Int)] = []
        func append(_ t: TodoTask, depth: Int) {
            let all = store.subtasks(of: t.id, includeCompleted: true)
            out.append((t.id, depth, all.filter(\.isCompleted).count, all.count))
            if !t.collapsed {
                for c in store.subtasks(of: t.id) { append(c, depth: depth + 1) }
            }
        }
        for t in store.tasks(projectId: projectId, sectionId: nil) { append(t, depth: 0) }
        for s in store.sections(in: projectId) {
            for t in store.tasks(projectId: projectId, sectionId: s.id) { append(t, depth: 0) }
        }
        return out
    }

    /// Mirrors the sidebar: project badges, label badges, plus section header counts of one project.
    func sidebarCounts(_ store: TodoStore, projectId: EntityID) -> Int {
        var total = store.openTaskCount(projectId: store.inbox.id)
        for p in store.projects { total += store.openTaskCount(projectId: p.id) }
        for l in store.labels { total += store.tasks(withLabel: l.name).count }
        for s in store.sections(in: projectId) { total += store.tasks(projectId: projectId, sectionId: s.id).count }
        return total
    }

    #if !BENCH_BEFORE
    func buildRowsWithProgress(_ store: TodoStore, projectId: EntityID) -> [(EntityID, Int, Int, Int)] {
        var out: [(EntityID, Int, Int, Int)] = []
        func append(_ t: TodoTask, depth: Int) {
            let p = store.subtaskProgress(of: t.id)
            out.append((t.id, depth, p.done, p.total))
            if !t.collapsed, p.total > p.done {
                for c in store.subtasks(of: t.id) { append(c, depth: depth + 1) }
            }
        }
        for t in store.tasks(projectId: projectId, sectionId: nil) { append(t, depth: 0) }
        for s in store.sections(in: projectId) {
            for t in store.tasks(projectId: projectId, sectionId: s.id) { append(t, depth: 0) }
        }
        return out
    }
    #endif

    func testHeavyUserBenchmarks() async throws {
        let db = Self.fixture()
        XCTAssertEqual(db.tasks.count, Self.projectCount * Self.tasksPerProject)
        let store = TodoStore(db: db)
        let pid = "project-7"
        let rows = buildRows(store, projectId: pid)
        print("BENCH fixture: \(db.tasks.count) tasks, \(db.projects.count) projects, \(rows.count) open rows in \(pid)")
        XCTAssertGreaterThan(rows.count, 80)

        time("build rows of one project (\(rows.count) rows)") { _ = buildRows(store, projectId: pid) }
        time("all sidebar counts") { _ = sidebarCounts(store, projectId: pid) }

        var k = 0
        time("title edit + rows + sidebar counts") {
            k += 1
            store.updateTask("task-7-10") { $0.content = "Edited \(k)" }
            _ = buildRows(store, projectId: pid)
            _ = sidebarCounts(store, projectId: pid)
        }
        time("title edit only") {
            k += 1
            store.updateTask("task-7-10") { $0.content = "Edited \(k)" }
        }
        time("toggle complete + rows + counts") {
            store.toggleComplete("task-7-12")
            _ = buildRows(store, projectId: pid)
            _ = sidebarCounts(store, projectId: pid)
        }

        // New APIs (not available before): counts from the index, progress without fetching children.
        #if !BENCH_BEFORE
        do {
            time("all sidebar counts (count APIs)") {
                var total = store.openTaskCount(projectId: store.inbox.id)
                for p in store.projects { total += store.openTaskCount(projectId: p.id) }
                for l in store.labels { total += store.openTaskCount(label: l.name) }
                for s in store.sections(in: pid) { total += store.openTaskCount(projectId: pid, sectionId: s.id) }
                XCTAssertGreaterThan(total, 0)
            }
            time("build rows (subtaskProgress API)") { _ = buildRowsWithProgress(store, projectId: pid) }
        }
        #endif

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("todotim-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("db.json")
        let snapshot = store.db
        try time("LocalPersistence.save (sync encode+write)", runs: 7) { try LocalPersistence.save(snapshot, to: url) }
        time("load + decode db", runs: 7) { _ = LocalPersistence.load(from: url) }
        #if !BENCH_BEFORE
        do {
            let writer = PersistenceWriter(url: url, delay: 0)
            time("PersistenceWriter.save (main-thread cost)") { writer.save(snapshot) }
            time("PersistenceWriter.flush (encode + write)", runs: 7) { writer.save(snapshot); writer.flush() }
        }
        #endif

        let server = FakeCalDAVServer()
        let upload = try await CalDAVSync.sync(local: store.db, state: CalDAVState(account: "bench"), server: server)
        // The next sync reads back this device's own uploads once; after that it is idle.
        let first = try await CalDAVSync.sync(local: upload.merged, state: upload.state, server: server)
        let local = first.merged
        try await timeAsync("full merge, nothing to write") {
            let r = try await CalDAVSync.sync(local: local, state: first.state, server: server)
            XCTAssertEqual(r.writes, 0)
        }
        try await timeAsync("idle sync (nothing changed)") {
            let r = try await CalDAVSync.sync(local: local, state: first.state, server: server, previous: local)
            XCTAssertEqual(r.writes, 0)
        }
        var edited = local
        edited.tasks["task-7-10"]?.content = "Changed for sync"
        edited.tasks["task-7-10"]?.updatedAt = Date()
        var state = first.state
        try await timeAsync("sync with one edited task", runs: 3) {
            let r = try await CalDAVSync.sync(local: edited, state: state, server: server)
            state = r.state
            edited = r.merged
            edited.tasks["task-7-10"]?.content = "Changed \(UUID())"
            edited.tasks["task-7-10"]?.updatedAt = Date()
        }
    }
}
