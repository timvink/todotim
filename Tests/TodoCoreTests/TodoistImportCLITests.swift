import XCTest
@testable import TodoCore

/// One-off command-line import into a db.json while the app is not running:
///
///     TODOTIM_IMPORT_SNAPSHOT=/path/snapshot.json \
///     TODOTIM_IMPORT_DB="$HOME/Library/Application Support/TodoTim/db.json" \
///     swift test --filter TodoistImportCLI
///
/// Optional: TODOTIM_IMPORT_COMPLETED=1 also imports completed tasks; TODOTIM_IMPORT_DRY_RUN=1
/// prints the report without saving. Skipped unless both paths are set. Refuses to run when the
/// db file is missing or corrupt (a corrupt file is moved aside by `loadChecked`, never
/// overwritten). Quit TodoTim first: the running app would overwrite the file on its next save.
@MainActor
final class TodoistImportCLITests: XCTestCase {
    func testImportSnapshotIntoDatabaseFile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let snapshotPath = env["TODOTIM_IMPORT_SNAPSHOT"], let dbPath = env["TODOTIM_IMPORT_DB"] else {
            throw XCTSkip("Set TODOTIM_IMPORT_SNAPSHOT and TODOTIM_IMPORT_DB to run a one-off import.")
        }
        let dbURL = URL(fileURLWithPath: (dbPath as NSString).expandingTildeInPath)
        let snapshotURL = URL(fileURLWithPath: (snapshotPath as NSString).expandingTildeInPath)
        try TodoistImportCLI.run(snapshot: snapshotURL, db: dbURL,
                                 options: .init(includeCompleted: env["TODOTIM_IMPORT_COMPLETED"] == "1"),
                                 dryRun: env["TODOTIM_IMPORT_DRY_RUN"] == "1",
                                 log: { print($0) })
    }

    // MARK: - Tests of the CLI path itself

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("todoist-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeSnapshot() throws -> URL {
        let url = dir.appendingPathComponent("snapshot.json")
        try Data(TodoistFixtures.snapshotJSON.utf8).write(to: url)
        return url
    }

    func testRunImportsAndSaves() throws {
        let dbURL = dir.appendingPathComponent("db.json")
        try LocalPersistence.save(Database(), to: dbURL)
        var lines: [String] = []
        try TodoistImportCLI.run(snapshot: writeSnapshot(), db: dbURL, log: { lines.append($0) })
        let db = try LocalPersistence.loadChecked(from: dbURL)
        XCTAssertEqual(db.tasks.values.filter { !$0.deleted }.count, 8)
        XCTAssertTrue(lines.joined().contains("Tasks: 8 created"))

        // Second run: nothing changes, file not rewritten.
        let before = try Data(contentsOf: dbURL)
        try TodoistImportCLI.run(snapshot: writeSnapshot(), db: dbURL, log: { _ in })
        XCTAssertEqual(try Data(contentsOf: dbURL), before)
    }

    func testDryRunDoesNotSave() throws {
        let dbURL = dir.appendingPathComponent("db.json")
        try LocalPersistence.save(Database(), to: dbURL)
        let before = try Data(contentsOf: dbURL)
        try TodoistImportCLI.run(snapshot: writeSnapshot(), db: dbURL, dryRun: true, log: { _ in })
        XCTAssertEqual(try Data(contentsOf: dbURL), before)
    }

    func testRefusesMissingDatabase() throws {
        let dbURL = dir.appendingPathComponent("missing.json")
        XCTAssertThrowsError(try TodoistImportCLI.run(snapshot: writeSnapshot(), db: dbURL, log: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), "no database is created")
    }

    func testRefusesCorruptDatabase() throws {
        let dbURL = dir.appendingPathComponent("db.json")
        try Data("{ not json".utf8).write(to: dbURL)
        XCTAssertThrowsError(try TodoistImportCLI.run(snapshot: writeSnapshot(), db: dbURL, log: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), "nothing is written in its place")
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("db.corrupt-") }
        XCTAssertEqual(backups.count, 1, "the corrupt file is kept aside")
    }
}
