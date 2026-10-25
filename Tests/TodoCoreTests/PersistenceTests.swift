import XCTest
@testable import TodoCore

final class PersistenceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("todotim-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleDB() -> Database {
        var db = Database()
        let t = TodoTask(id: "t", projectId: "inbox", content: "hello", order: 1,
                         createdAt: Date(timeIntervalSince1970: 1_700_000_000.123), updatedAt: Date(timeIntervalSince1970: 1_700_000_001.5))
        db.tasks[t.id] = t
        return db
    }

    func testMissingFileIsEmptyDatabase() throws {
        XCTAssertEqual(try LocalPersistence.loadChecked(from: dir.appendingPathComponent("db.json")), Database())
    }

    func testRoundTrip() throws {
        let url = dir.appendingPathComponent("db.json")
        try LocalPersistence.save(sampleDB(), to: url)
        XCTAssertEqual(try LocalPersistence.loadChecked(from: url), sampleDB())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("\n"), "local file is compact JSON")
    }

    func testCorruptFileIsMovedAsideAndReported() throws {
        let url = dir.appendingPathComponent("db.json")
        let garbage = Data("{\"tasks\": [oops".utf8)
        try garbage.write(to: url)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertThrowsError(try LocalPersistence.loadChecked(from: url, now: now)) { error in
            guard case .corrupt(let backupPath, _)? = error as? PersistenceError else { return XCTFail("\(error)") }
            XCTAssertTrue((backupPath as NSString).lastPathComponent.hasPrefix("db.corrupt-"))
            XCTAssertEqual(FileManager.default.contents(atPath: backupPath), garbage)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // The convenience API also preserves the original instead of returning it for overwrite.
        try garbage.write(to: url)
        XCTAssertEqual(LocalPersistence.load(from: url), Database())
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("db.corrupt-") }
        XCTAssertEqual(backups.count, 2)
    }

    func testWriterCoalescesAndFlushes() throws {
        let url = dir.appendingPathComponent("db.json")
        let writer = PersistenceWriter(url: url, delay: 0.2)
        var db = sampleDB()
        for i in 0..<100 {
            db.tasks["t"]?.content = "v\(i)"
            writer.save(db)
        }
        writer.flush()
        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(try LocalPersistence.loadChecked(from: url).tasks["t"]?.content, "v99")
        writer.flush()  // nothing pending
        XCTAssertEqual(writer.writeCount, 1)
    }

    func testWriterWritesAfterDelayWithoutFlush() throws {
        let url = dir.appendingPathComponent("db.json")
        let writer = PersistenceWriter(url: url, delay: 0.01)
        writer.save(sampleDB())
        let deadline = Date().addingTimeInterval(5)
        while writer.writeCount == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(try LocalPersistence.loadChecked(from: url), sampleDB())
    }

    func testWriterReportsErrors() {
        let blocker = dir.appendingPathComponent("file")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        let failed = expectation(description: "error")
        let writer = PersistenceWriter(url: blocker.appendingPathComponent("db.json"), delay: 0) { _ in failed.fulfill() }
        writer.save(sampleDB())
        XCTAssertFalse(writer.flush(), "flush reports that the database is not on disk")
        wait(for: [failed], timeout: 2)
        let good = PersistenceWriter(url: dir.appendingPathComponent("ok.json"), delay: 0)
        good.save(sampleDB())
        XCTAssertTrue(good.flush())
    }

    // MARK: - Date codec

    /// The previous FormatStyle-based encoder, as an oracle for byte compatibility.
    private func legacyFormat(_ date: Date) -> String {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (ms / 1000).rounded(.down)
        let whole = Date(timeIntervalSince1970: seconds).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        return whole + String(format: ".%03d", Int(ms - seconds * 1000))
    }

    func testFastDateFormatMatchesLegacyFormat() {
        var rng = SeededRNG(seed: 7)
        var dates = [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 951_782_400.9995),  // leap day
                     Date(timeIntervalSince1970: 1_700_000_000.0996), Date(timeIntervalSince1970: 4_102_444_799.999)]
        for _ in 0..<5000 { dates.append(Date(timeIntervalSince1970: Double(rng.next() % 4_000_000_000_000) / 1000 + Double(rng.next() % 1000) / 1e6)) }
        for d in dates {
            let s = MillisecondDate.format(d)
            XCTAssertEqual(s, legacyFormat(d))
            let parsed = MillisecondDate.parse(s)!
            XCTAssertEqual(parsed, TodoStore.millisecondPrecision(d))
            XCTAssertEqual(MillisecondDate.format(parsed), s)
        }
    }

    func testDecoderAcceptsOtherISOForms() throws {
        struct Box: Codable { var d: Date }
        for s in ["2023-11-14T22:13:20Z", "2023-11-14T22:13:20.1", "2023-11-14T22:13:20.12", "2023-11-14T22:13:20"] {
            let box = try JSONCoding.decoder.decode(Box.self, from: Data("{\"d\":\"\(s)\"}".utf8))
            XCTAssertEqual(box.d.timeIntervalSince1970, 1_700_000_000, accuracy: 0.2, s)
        }
        XCTAssertNil(MillisecondDate.parse("2023-13-14T22:13:20.000"))
        XCTAssertThrowsError(try JSONCoding.decoder.decode(Box.self, from: Data(#"{"d":"yesterday"}"#.utf8)))
    }
}
