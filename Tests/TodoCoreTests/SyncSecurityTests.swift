import XCTest
@testable import TodoCore

/// Remote data validation and resource limits.
@MainActor
final class SyncSecurityTests: XCTestCase {
    let now = Date()

    func testEntityIDValidation() {
        for ok in ["inbox", newID(), "a", "A_b-9", String(repeating: "x", count: 64)] {
            XCTAssertTrue(isValidEntityID(ok), ok)
        }
        for bad in ["", "..", ".", "a/b", "../../outside", "a.b", "a b", "a\n", "é", String(repeating: "x", count: 65)] {
            XCTAssertFalse(isValidEntityID(bad), bad)
        }
    }

    func testLongTextIsTruncatedDeterministically() {
        var db = Database()
        var t = TodoTask(id: "t", projectId: "inbox", content: String(repeating: "é", count: 20_000), order: 0)
        t.description = String(repeating: "d", count: 200_000)
        t.labels = (0..<500).map { "l\($0)" } + [String(repeating: "x", count: 5_000)]
        t.due = DueDate(date: String(repeating: "9", count: 100))
        db.tasks["t"] = t
        let updatedAt = t.updatedAt
        let merged = lwwMerge([db], now: now)
        let out = merged.tasks["t"]!
        XCTAssertEqual(out.content.count, SyncLimits.maxContentLength)
        XCTAssertEqual(out.description.count, SyncLimits.maxDescriptionLength)
        XCTAssertEqual(out.labels.count, SyncLimits.maxLabelsPerTask)
        XCTAssertNil(out.due)
        XCTAssertEqual(out.updatedAt, updatedAt)
        XCTAssertEqual(lwwMerge([merged], now: now), merged, "idempotent")
    }

    func testDeepHierarchyIsCapped() {
        var db = Database()
        let n = 100
        for i in 0..<n {
            db.tasks["t\(i)"] = TodoTask(id: "t\(i)", projectId: "inbox", parentId: i == 0 ? nil : "t\(i - 1)",
                                         content: "\(i)", order: Double(i), updatedAt: now)
        }
        let merged = lwwMerge([db], now: now)
        // Depth of each task in the result.
        func depth(_ id: EntityID) -> Int {
            var d = 0, cur = id
            while let p = merged.tasks[cur]?.parentId { d += 1; cur = p }
            return d
        }
        XCTAssertLessThanOrEqual(merged.tasks.keys.map(depth).max()!, SyncLimits.maxTaskDepth)
        XCTAssertNil(merged.tasks["t33"]?.parentId)
        XCTAssertNil(merged.tasks["t66"]?.parentId)
        XCTAssertNil(merged.tasks["t99"]?.parentId)
        XCTAssertEqual(merged.tasks["t32"]?.parentId, "t31")
        XCTAssertEqual(merged.tasks["t34"]?.parentId, "t33")
        XCTAssertTrue(merged.tasks.values.allSatisfy { $0.updatedAt == now })
        XCTAssertEqual(lwwMerge([merged], now: now), merged, "idempotent")
    }
}

final class PersistencePermissionTests: XCTestCase {
    func testDatabaseFilesArePrivate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("todotim-perm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("data/db.json")
        try LocalPersistence.save(Database(), to: url)
        func mode(_ u: URL) throws -> Int { (try fm.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
        try LocalPersistence.save(Database(), to: url)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["db.json"], "no temp files left")

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try Data("garbage".utf8).write(to: url)
        XCTAssertThrowsError(try LocalPersistence.loadChecked(from: url)) { error in
            guard case .corrupt(let backup, _)? = error as? PersistenceError else { return XCTFail("\(error)") }
            XCTAssertEqual(try? mode(URL(fileURLWithPath: backup)), 0o600)
        }
    }
}
