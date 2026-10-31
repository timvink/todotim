import Foundation

/// `text.localizedCaseInsensitiveContains(query)` (a case-insensitive search in `locale`), with a
/// fast path for the common case: a printable-ASCII query in ASCII text is matched by ASCII case
/// folding, which gives the same result except in Turkish and Azeri, where i and I fold
/// differently (those locales always take the localized search). Locale-aware search ignores
/// collation contractions (Czech "ch", Danish "aa"), so they need no exception.
struct TextMatcher {
    let query: String
    let locale: Locale
    /// The query lowercased, when the fast path applies.
    private let asciiQuery: [UInt8]?

    init(_ query: String, locale: Locale = .current) {
        self.query = query
        self.locale = locale
        let language = locale.language.languageCode?.identifier
        let bytes = Array(query.utf8)
        if language != "tr", language != "az", !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
            asciiQuery = bytes.map(Self.lower)
        } else {
            asciiQuery = nil
        }
    }

    func matches(_ text: String) -> Bool {
        if let q = asciiQuery, let found = text.utf8.withContiguousStorageIfAvailable({ Self.asciiContains($0, q) }) ?? nil {
            return found
        }
        return text.range(of: query, options: .caseInsensitive, range: nil, locale: locale) != nil
    }

    /// Case-insensitive search of the lowercased `q` in ASCII text; nil when `t` is not ASCII.
    private static func asciiContains(_ t: UnsafeBufferPointer<UInt8>, _ q: [UInt8]) -> Bool? {
        var high: UInt8 = 0
        for b in t { high |= b }
        guard high < 0x80 else { return nil }
        let n = t.count, m = q.count
        guard m <= n else { return false }
        let first = q[0]
        var s = 0
        while s <= n - m {
            if lower(t[s]) == first {
                var k = 1
                while k < m, lower(t[s + k]) == q[k] { k += 1 }
                if k == m { return true }
            }
            s += 1
        }
        return false
    }

    @inline(__always) private static func lower(_ b: UInt8) -> UInt8 {
        b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") ? b | 0x20 : b
    }
}
