import XCTest
@testable import TodoCore

/// The fast `db.json` decoder must read every file exactly like `JSONDecoder`, or decline (nil) so
/// that `JSONDecoder` decides.
final class DatabaseDecoderTests: XCTestCase {
    private func viaJSONDecoder(_ data: Data) -> Database? {
        try? JSONCoding.decoder.decode(Database.self, from: data)
    }

    /// The fast decoder either declines or returns what `JSONDecoder` returns.
    private func assertAgrees(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        guard let fast = DatabaseDecoder.decode(data) else { return }
        guard let slow = viaJSONDecoder(data) else {
            let dump = FileManager.default.temporaryDirectory.appendingPathComponent("todotim-decoder-mismatch-\(UUID().uuidString).json")
            try? data.write(to: dump)
            return XCTFail("fast decoder accepted what JSONDecoder rejects (saved to \(dump.path))", file: file, line: line)
        }
        XCTAssertEqual(fast, slow, "fast decoder differs from JSONDecoder", file: file, line: line)
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    /// JSON `\uXXXX` escape (built from parts so the source has no such sequence).
    private func u(_ hex: String) -> String { "\\" + "u" + hex }

    // MARK: Generated databases

    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        mutating func chance(_ percent: UInt64) -> Bool { next() % 100 < percent }
    }

    static let awkwardStrings = [
        "", "plain", "with \"quotes\"", "back\\slash", "https://example.com/a/b?x=1&y=2#frag", "tab\there\nnew line\r\n",
        "control \u{1}\u{8}\u{C}\u{1F}", "NUL \u{0} inside", "DEL \u{7F}", "emoji 🎉 family 👩‍👩‍👧 flag 🇳🇱",
        "accents café naïve Ærø", "combining e\u{301} a\u{308}", "CJK 漢字かな", "RTL שלום مرحبا", "line sep \u{2028} para \u{2029}",
        "  spaces around  ", "\\u0041 not an escape", "/", "\"", "\\", String(repeating: "long ", count: 300),
    ]

    static let awkwardNumbers: [Double] = [
        0, -0.0, 1, 2, 14, -3, 0.5, 0.1, 1.0 / 3, 1e-9, -3.5, 1e300, -1e-300, 123_456_789.123, 9_007_199_254_740_993,
        Double.leastNormalMagnitude, Double.greatestFiniteMagnitude, 1_000_000_000_000_000, 4.9e-324,
    ]

    /// A deterministic database with awkward content in every field.
    static func generated(tasks: Int, seed: UInt64) -> Database {
        var rng = RNG(state: seed)
        func date() -> Date {
            TodoStore.millisecondPrecision(Date(timeIntervalSince1970: Double(rng.next() % 4_000_000_000) + Double(rng.next() % 1000) / 1000))
        }
        func number() -> Double {
            if rng.chance(50) { return rng.pick(awkwardNumbers) }
            let d = Double(bitPattern: rng.next())
            return d.isFinite ? d : 7
        }
        func id() -> String {
            rng.chance(5) ? rng.pick(["inbox", "a", "x_y-Z"]) : String(rng.next(), radix: 16) + "-" + String(rng.next() % 100_000)
        }
        var db = Database()
        var projectIDs = [TodoStore.inboxID]
        for _ in 0..<5 {
            let p = Project(id: id(), name: rng.pick(awkwardStrings), color: rng.pick(["red", "blue", ""]), order: number(),
                            isInbox: rng.chance(10), updatedAt: date(), deleted: rng.chance(10))
            db.projects[p.id] = p
            projectIDs.append(p.id)
        }
        var sectionIDs: [EntityID] = []
        for _ in 0..<8 {
            let s = Section(id: id(), projectId: rng.pick(projectIDs), name: rng.pick(awkwardStrings), order: number(),
                            updatedAt: date(), deleted: rng.chance(10))
            db.sections[s.id] = s
            sectionIDs.append(s.id)
        }
        for _ in 0..<4 {
            let l = Label(id: id(), name: rng.pick(awkwardStrings), color: "green", order: number(), updatedAt: date(),
                          deleted: rng.chance(20))
            db.labels[l.id] = l
        }
        var taskIDs: [EntityID] = []
        for _ in 0..<tasks {
            let completed = rng.chance(20)
            let t = TodoTask(id: id(), projectId: rng.pick(projectIDs), sectionId: rng.chance(50) ? rng.pick(sectionIDs + ["gone"]) : nil,
                             parentId: rng.chance(30) && !taskIDs.isEmpty ? rng.pick(taskIDs) : nil,
                             content: rng.pick(awkwardStrings), description: rng.chance(50) ? rng.pick(awkwardStrings) : "",
                             priority: Priority(rawValue: Int(1 + rng.next() % 4))!,
                             due: rng.chance(40) ? DueDate(date: rng.pick(["2026-11-01", "1999-12-31", "not a date"])) : nil,
                             labels: (0..<Int(rng.next() % 4)).map { _ in rng.pick(awkwardStrings) },
                             isCompleted: completed, completedAt: completed && rng.chance(90) ? date() : nil, order: number(),
                             collapsed: rng.chance(20), recurrence: rng.chance(20) ? "FREQ=WEEKLY;INTERVAL=2" : nil,
                             createdAt: date(), updatedAt: date(), deleted: rng.chance(10))
            db.tasks[t.id] = t
            taskIDs.append(t.id)
        }
        return db
    }

    func testGeneratedDatabasesDecodeLikeJSONDecoder() throws {
        for seed in 0..<20 as Range<UInt64> {
            let db = Self.generated(tasks: 60, seed: seed)
            for encoder in [JSONCoding.compactEncoder, JSONCoding.encoder] {
                let data = try encoder.encode(db)
                let fast = try XCTUnwrap(DatabaseDecoder.decode(data), "seed \(seed)")
                XCTAssertEqual(fast, viaJSONDecoder(data), "seed \(seed)")
                XCTAssertEqual(fast, db, "seed \(seed)")
            }
        }
    }

    func testEmptyAndMinimalDatabases() throws {
        XCTAssertEqual(DatabaseDecoder.decode(try JSONCoding.compactEncoder.encode(Database())), Database())
        let minimal = json(#" {"projects":{},"sections":{},"tasks":{},"labels":{}} "#)
        XCTAssertEqual(DatabaseDecoder.decode(minimal), Database())
        assertAgrees(minimal)
    }

    // MARK: Hand-written JSON

    private func taskJSON(_ fields: String) -> Data {
        json(#"{"projects":{},"sections":{},"labels":{},"tasks":{"t":{"# + fields + "}}}")
    }

    private let requiredTaskFields = #""id":"t","projectId":"inbox","content":"c","description":"","priority":4,"labels":[],"isCompleted":false,"order":1,"collapsed":false,"createdAt":"2026-01-02T03:04:05.006","updatedAt":"2026-01-02T03:04:05.007","deleted":false"#

    func testEscapesUnknownKeysNullsAndWhitespace() throws {
        let text = """
        {
          "schemaVersion" : 3,
          "extra" : { "a" : [1, -2.5e3, {"b": null}, [true, false]], "c" : "x\\"y" },
          "projects" : {}, "sections" : {}, "labels" : {},
          "tasks" : {
            "t" : {
              \(requiredTaskFields.replacingOccurrences(of: #""content":"c""#,
                                                         with: #""content":""# + u("d83c") + u("df89") + " " + u("00e9") + u("0041") + #"\n\t\/\\\"""#)),
              "sectionId" : null, "parentId" : null, "due" : null, "completedAt" : null, "recurrence" : null,
              "future" : {"nested": [[[]]], "n": 0}
            }
          }
        }
        """
        let data = json(text)
        let fast = try XCTUnwrap(DatabaseDecoder.decode(data))
        XCTAssertEqual(fast, viaJSONDecoder(data))
        XCTAssertEqual(fast.tasks["t"]?.content, "🎉 éA\n\t/\\\"")
        XCTAssertNil(fast.tasks["t"]?.sectionId)
        XCTAssertNil(fast.tasks["t"]?.due)
    }

    func testOptionalFieldsPresent() throws {
        let data = taskJSON(requiredTaskFields + #","sectionId":"s","parentId":"p","due":{"date":"2026-11-01","x":1},"completedAt":"2026-01-02T03:04:05","recurrence":"FREQ=DAILY""#)
        let fast = try XCTUnwrap(DatabaseDecoder.decode(data))
        XCTAssertEqual(fast, viaJSONDecoder(data))
        XCTAssertEqual(fast.tasks["t"]?.due, DueDate(date: "2026-11-01"))
        XCTAssertEqual(fast.tasks["t"]?.completedAt, Date(timeIntervalSince1970: 1_767_323_045))
    }

    /// Inputs the fast path leaves to JSONDecoder (which rejects most of them).
    func testDeclinesWhatItDoesNotReadExactly() {
        let cases: [(String, Data)] = [
            ("empty object", json("{}")),
            ("missing labels", json(#"{"projects":{},"sections":{},"tasks":{}}"#)),
            ("null dictionary", json(#"{"projects":null,"sections":{},"tasks":{},"labels":{}}"#)),
            ("missing content", taskJSON(requiredTaskFields.replacingOccurrences(of: #""content":"c","#, with: ""))),
            ("priority 5", taskJSON(requiredTaskFields.replacingOccurrences(of: #""priority":4"#, with: #""priority":5"#))),
            ("priority 0", taskJSON(requiredTaskFields.replacingOccurrences(of: #""priority":4"#, with: #""priority":0"#))),
            ("priority 4.0", taskJSON(requiredTaskFields.replacingOccurrences(of: #""priority":4"#, with: #""priority":4.0"#))),
            ("priority string", taskJSON(requiredTaskFields.replacingOccurrences(of: #""priority":4"#, with: #""priority":"4""#))),
            ("order string", taskJSON(requiredTaskFields.replacingOccurrences(of: #""order":1"#, with: #""order":"1""#))),
            ("order leading zero", taskJSON(requiredTaskFields.replacingOccurrences(of: #""order":1"#, with: #""order":01"#))),
            ("order 1.", taskJSON(requiredTaskFields.replacingOccurrences(of: #""order":1"#, with: #""order":1."#))),
            ("order .5", taskJSON(requiredTaskFields.replacingOccurrences(of: #""order":1"#, with: #""order":.5"#))),
            ("order +1", taskJSON(requiredTaskFields.replacingOccurrences(of: #""order":1"#, with: #""order":+1"#))),
            ("order overflow", taskJSON(requiredTaskFields.replacingOccurrences(of: #""order":1"#, with: #""order":1e400"#))),
            ("order underflow", taskJSON(requiredTaskFields.replacingOccurrences(of: #""order":1"#, with: #""order":1e-400"#))),
            ("bool as number", taskJSON(requiredTaskFields.replacingOccurrences(of: #""deleted":false"#, with: #""deleted":0"#))),
            ("null required", taskJSON(requiredTaskFields.replacingOccurrences(of: #""content":"c""#, with: #""content":null"#))),
            ("duplicate field", taskJSON(requiredTaskFields + #","content":"again""#)),
            ("duplicate id", json(#"{"projects":{},"sections":{},"labels":{},"tasks":{"t":{"# + requiredTaskFields + #"},"t":{"# + requiredTaskFields + "}}}")),
            ("duplicate top-level key", json(#"{"projects":{},"projects":{},"sections":{},"tasks":{},"labels":{}}"#)),
            ("trailing comma", json(#"{"projects":{},"sections":{},"tasks":{},"labels":{},}"#)),
            ("trailing garbage", json(#"{"projects":{},"sections":{},"tasks":{},"labels":{}} x"#)),
            ("unterminated", json(#"{"projects":{},"sections":{},"tasks":{"#)),
            ("lone high surrogate", taskJSON(requiredTaskFields.replacingOccurrences(of: #""content":"c""#, with: #""content":"\ud800""#))),
            ("lone low surrogate", taskJSON(requiredTaskFields.replacingOccurrences(of: #""content":"c""#, with: #""content":"\udc00x""#))),
            ("bad escape", taskJSON(requiredTaskFields.replacingOccurrences(of: #""content":"c""#, with: #""content":"\q""#))),
            ("raw control character", taskJSON(requiredTaskFields.replacingOccurrences(of: #""content":"c""#, with: "\"content\":\"a\u{1}b\""))),
            ("date with zone", taskJSON(requiredTaskFields.replacingOccurrences(of: #"05.006""#, with: #"05Z""#))),
            ("escaped field name", taskJSON(requiredTaskFields.replacingOccurrences(of: #""content":"c""#, with: "\"" + u("0063") + #"ontent":"c""#))),
            ("deep unknown value", json(#"{"projects":{},"sections":{},"tasks":{},"labels":{},"x":"# + String(repeating: "[", count: 100) + String(repeating: "]", count: 100) + "}")),
        ]
        for (name, data) in cases {
            XCTAssertNil(DatabaseDecoder.decode(data), name)
            assertAgrees(data)
        }
        var invalidUTF8 = Array(taskJSON(requiredTaskFields))
        invalidUTF8[invalidUTF8.firstIndex(of: UInt8(ascii: "c"))!] = 0xFF
        XCTAssertNil(DatabaseDecoder.decode(Data(invalidUTF8)))
        // Also in the name of a field that would be skipped as unknown.
        var invalidKey = Array(taskJSON(requiredTaskFields + #","futureKey":1"#))
        invalidKey[invalidKey.firstIndex(of: UInt8(ascii: "K"))!] = 0xFF
        XCTAssertNil(DatabaseDecoder.decode(Data(invalidKey)))
        XCTAssertNil(viaJSONDecoder(Data(invalidKey)))
    }

    /// Files the fast path declines but JSONDecoder reads still load, through the fallback.
    func testLoadCheckedFallsBackToJSONDecoder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("todotim-decoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("db.json")
        for data in [taskJSON(requiredTaskFields.replacingOccurrences(of: #"05.006""#, with: #"05Z""#)),
                     taskJSON(requiredTaskFields.replacingOccurrences(of: #""content":"c""#, with: "\"" + u("0063") + #"ontent":"x""#))] {
            XCTAssertNil(DatabaseDecoder.decode(data))
            let expected = try XCTUnwrap(viaJSONDecoder(data))
            try data.write(to: url)
            XCTAssertEqual(try LocalPersistence.loadChecked(from: url), expected)
        }
        // And a regular file takes the fast path with the same result.
        let db = Self.generated(tasks: 40, seed: 99)
        try LocalPersistence.save(db, to: url)
        XCTAssertEqual(try LocalPersistence.loadChecked(from: url), db)
    }

    /// Random byte edits of a valid file: the fast decoder may decline, but whatever it accepts
    /// JSONDecoder must accept with the same result.
    func testMutatedFilesNeverDecodeDifferently() throws {
        let bases = try (1...6 as ClosedRange<UInt64>).map { Array(try JSONCoding.compactEncoder.encode(Self.generated(tasks: 6, seed: $0))) }
        var rng = RNG(state: 12345)
        let alphabet = Array(#"{}[]:,"\ 0123456789.eE+-truefalsnul/ubdx"#.utf8) + [0x00, 0x1F, 0x7F, 0xC3, 0xA9, 0xFF]
        var accepted = 0
        for n in 0..<6000 {
            var bytes = bases[n % bases.count]
            for _ in 0..<Int(1 + rng.next() % 3) {
                let at = Int(rng.next() % UInt64(bytes.count))
                switch rng.next() % 3 {
                case 0: bytes[at] = rng.pick(alphabet)
                case 1: bytes.insert(rng.pick(alphabet), at: at)
                default: bytes.remove(at: at)
                }
            }
            let data = Data(bytes)
            if DatabaseDecoder.decode(data) != nil { accepted += 1 }
            assertAgrees(data)
        }
        XCTAssertGreaterThan(accepted, 100, "some mutations (inside strings) stay valid")
    }
}
