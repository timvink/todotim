import XCTest
@testable import TodoCore

final class TextMatcherTests: XCTestCase {
    private func localized(_ text: String, _ query: String, _ locale: Locale) -> Bool {
        text.range(of: query, options: .caseInsensitive, range: nil, locale: locale) != nil
    }

    /// The fast path must give exactly the localized search's answer.
    func testMatchesTheLocalizedSearch() {
        var state: UInt64 = 42
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        let printable = (0x20...0x7E).map { Character(Unicode.Scalar(UInt8($0))) }
        let other: [Character] = ["\u{0}", "\u{1}", "\t", "\n", "\u{7F}", "é", "É", "ß", "İ", "ı", "ﬁ", "e\u{301}", "🎉", "Ä"]
        let textAlphabet = printable + printable + other
        let queryAlphabet = printable + printable + printable + other
        func random(_ alphabet: [Character], _ length: Int) -> String {
            String((0..<length).map { _ in alphabet[next() % alphabet.count] })
        }
        for id in ["en_US", "nl_NL", "cs_CZ", "da_DK", "de_DE", "lt_LT", "tr_TR", "az_AZ"] {
            let locale = Locale(identifier: id)
            for _ in 0..<2000 {
                let text = random(textAlphabet, next() % 14)
                let query = random(queryAlphabet, 1 + next() % 3)
                XCTAssertEqual(TextMatcher(query, locale: locale).matches(text), localized(text, query, locale),
                               "\(text.debugDescription) ~ \(query.debugDescription) in \(id)")
            }
            // Substrings of the text itself, in other cases, so many searches do match.
            for _ in 0..<1000 {
                let text = random(printable, 1 + next() % 20)
                let chars = Array(text)
                let start = next() % chars.count, end = min(chars.count, start + 1 + next() % 4)
                let query = String(chars[start..<end]).uppercased()
                XCTAssertEqual(TextMatcher(query, locale: locale).matches(text), localized(text, query, locale),
                               "\(text.debugDescription) ~ \(query.debugDescription) in \(id)")
            }
        }
    }

    func testTurkishCasingTakesTheLocalizedSearch() {
        XCTAssertTrue(TextMatcher("i", locale: Locale(identifier: "en_US")).matches("ISTANBUL"))
        let turkish = Locale(identifier: "tr_TR")
        XCTAssertEqual(TextMatcher("i", locale: turkish).matches("ISTANBUL"), localized("ISTANBUL", "i", turkish))
        XCTAssertEqual(TextMatcher("I", locale: turkish).matches("istanbul"), localized("istanbul", "I", turkish))
    }
}

@MainActor
final class StoreSearchTests: XCTestCase {
    private func reference(_ store: TodoStore, _ query: String) -> [EntityID] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return store.db.tasks.values.filter {
            !$0.deleted && !$0.isCompleted
                && ($0.content.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q))
        }.sorted(by: TodoStore.taskOrder).map(\.id)
    }

    func testSearchMatchesTheLocalizedSearchAndFollowsEdits() async {
        let store = TodoStore()
        let inbox = TodoStore.inboxID
        for (content, notes) in [("Review report", ""), ("réview the draft", ""), ("REVIEWED", ""), ("naïve plan", ""),
                                 ("plain", "notes\nreview later"), ("Tab\there", ""), ("Straße", ""), ("İstanbul trip", "")] {
            store.addTask(content: content, projectId: inbox, description: notes)
        }
        let done = store.addTask(content: "review done", projectId: inbox)
        store.toggleComplete(done.id)
        let gone = store.addTask(content: "review deleted", projectId: inbox)
        store.deleteTask(gone.id)

        for q in ["review", "REV", "é", "ïve", "tab", " review ", "x", "strasse", "İstanbul", "i", "  "] {
            XCTAssertEqual(store.search(q).map(\.id), reference(store, q), q)
            XCTAssertEqual(store.search(q).map(\.id), reference(store, q), "\(q), asked again")
        }

        // Edits, completions and new tasks show up although the same query was asked before.
        let plain = store.search("plain")
        XCTAssertEqual(plain.count, 1)
        store.updateTask(plain[0].id) { $0.content = "changed" }
        XCTAssertEqual(store.search("plain").count, 0)
        XCTAssertEqual(store.search("review").map(\.id), reference(store, "review"))
        let first = store.search("review")[0]
        store.toggleComplete(first.id)
        XCTAssertFalse(store.search("review").contains { $0.id == first.id })
        let added = store.addTask(content: "another review", projectId: inbox)
        XCTAssertTrue(store.search("review").contains { $0.id == added.id })
        XCTAssertEqual(store.search("review").map(\.id), reference(store, "review"))
    }
}
