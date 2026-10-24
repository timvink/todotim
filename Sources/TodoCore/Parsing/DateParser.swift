import Foundation

/// Outcome of recognising a date phrase.
public enum DateParseResult: Equatable, Sendable {
    /// A concrete calendar date.
    case date(DueDate)
    /// The phrase "no date" / "no due date": the user explicitly asked for no due date.
    case noDate

    public var dueDate: DueDate? {
        if case .date(let d) = self { return d }
        return nil
    }
}

/// English, date-only natural-language date grammar modelled on Todoist quick add.
///
/// Recognised phrases (case-insensitive, whole words only):
/// - `today`/`tod`, `tomorrow`/`tom`/`tmr`/`tmrw`, `yesterday`, `day after tomorrow`
/// - weekday names and abbreviations (`mon`, `monday`, `tue`, `tues`, ...): the next occurrence,
///   where today counts ("monday" on a Monday is today). `this friday` is the same.
/// - `next week` = Monday of next week; `next <weekday>` = that weekday in next week
///   (weeks start on Monday); `weekend`/`this weekend` = the upcoming Saturday (today on a
///   Saturday or Sunday); `next weekend` = Saturday of next week; `next month` = the 1st of
///   next month; `next year` = January 1st of next year.
/// - `in 3 days`, `in 2 weeks`, `in a month`, `in one year` (number words one–twelve, a/an).
/// - `jan 5`, `january 5th`, `5 jan`, `5th of january`, optionally followed by a 4-digit year
///   (`jan 5 2027`, `jan 5, 2027`). Without a year, a date before today rolls over to next year.
/// - `5/1` and `5/1/2027` (or `/27`): the order of day and month follows the calendar's locale
///   (`calendar.locale`, falling back to `Locale.current`); en_US reads month/day, en_GB day/month.
///   Without a year, a date before today rolls over to next year.
/// - ISO `2026-11-03`.
/// - `no date`, `no due date` → `.noDate`.
///
/// A bare month name ("may") or a bare number ("5") is never a date.
public enum DateParser {
    /// Parses `text` as a whole date phrase (for a "set due date" field). Returns nil when the
    /// text is not entirely a date phrase, and also for "no date" (use `parsePhrase` to see that).
    /// A leading "on", "by" or "due" is allowed ("on friday").
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> DueDate? {
        parsePhrase(text, now: now, calendar: calendar)?.dueDate
    }

    /// Like `parse`, but distinguishes "no date" from unparseable text (nil).
    public static func parsePhrase(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> DateParseResult? {
        var words = DateWord.split(text)
        guard !words.isEmpty else { return nil }
        if words.count > 1, words[0].lower == "due" { words.removeFirst() }
        if words.count > 1, words[0].lower == "on" || words[0].lower == "by" { words.removeFirst() }
        let ctx = DateContext(now: now, calendar: calendar)
        guard let m = match(words, at: 0, ctx: ctx), m.count == words.count else { return nil }
        return m.result
    }

    // MARK: - Internal grammar (shared with QuickAddParser)

    /// Words that may introduce a date phrase in quick add and are removed with it.
    static let connectors: Set<String> = ["on", "by", "due"]

    /// Single-word phrases that are also common English words or names. In quick add they only
    /// count as a date when typed in lowercase and either at the end of the line or introduced by
    /// "on"/"by"/"due" ("call tom" → tomorrow, "Call Tom" → no date, "buy sun cream" → no date).
    static let ambiguousSingleWords: Set<String> = ["tom", "tod", "sat", "sun", "wed", "weekend"]

    struct DateContext {
        let today: Date
        let calendar: Calendar
        init(now: Date, calendar: Calendar) {
            self.calendar = calendar
            self.today = calendar.startOfDay(for: now)
        }
    }

    struct Match {
        let count: Int
        let result: DateParseResult
    }

    /// Longest date phrase starting at `words[start]`. Phrases never extend across a word with
    /// trailing punctuation, except a comma before a year ("jan 5, 2027").
    static func match(_ words: [DateWord], at start: Int, ctx: DateContext) -> Match? {
        func lw(_ k: Int) -> String? {
            let j = start + k
            guard j < words.count else { return nil }
            if k > 0 && words[j - 1].hasTrailingPunct { return nil }
            return words[j].lower
        }
        /// Like lw, but allows the previous word to end in a comma (for "jan 5, 2027").
        func lwAfterComma(_ k: Int) -> String? {
            let j = start + k
            guard j < words.count, k > 0 else { return nil }
            let prev = words[j - 1]
            if prev.hasTrailingPunct && prev.trailingPunct != "," { return nil }
            return words[j].lower
        }

        guard let w0 = lw(0), !w0.isEmpty else { return nil }
        let cal = ctx.calendar
        var best: Match?
        func consider(_ count: Int, _ date: Date?) {
            guard let date else { return }
            consider(count, .date(DueDate(date, calendar: cal)))
        }
        func consider(_ count: Int, _ result: DateParseResult) {
            if best == nil || count > best!.count { best = Match(count: count, result: result) }
        }
        func addDays(_ n: Int, to d: Date = ctx.today) -> Date? { cal.date(byAdding: .day, value: n, to: d) }
        let todayWeekday = cal.component(.weekday, from: ctx.today) // 1 = Sunday ... 7 = Saturday
        func upcoming(_ weekday: Int) -> Date? { addDays((weekday - todayWeekday + 7) % 7) }
        func mondayOfNextWeek() -> Date? {
            var d = (2 - todayWeekday + 7) % 7
            if d == 0 { d = 7 }
            return addDays(d)
        }
        func upcomingWeekend() -> Date? {
            todayWeekday == 1 ? ctx.today : upcoming(7)
        }

        // no date
        if w0 == "no" {
            if lw(1) == "date" { consider(2, .noDate) }
            if lw(1) == "due", lw(2) == "date" { consider(3, .noDate) }
        }

        switch w0 {
        case "today", "tod": consider(1, ctx.today)
        case "tomorrow", "tom", "tmr", "tmrw": consider(1, addDays(1))
        case "yesterday": consider(1, addDays(-1))
        case "overmorrow": consider(1, addDays(2))
        case "weekend": consider(1, upcomingWeekend())
        default: break
        }
        if w0 == "day", lw(1) == "after", lw(2) == "tomorrow" { consider(3, addDays(2)) }

        if let wd = weekday(w0) { consider(1, upcoming(wd)) }

        if w0 == "this", let w1 = lw(1) {
            if let wd = weekday(w1) { consider(2, upcoming(wd)) }
            if w1 == "weekend" { consider(2, upcomingWeekend()) }
        }

        if w0 == "next", let w1 = lw(1) {
            if let wd = weekday(w1), let monday = mondayOfNextWeek() {
                consider(2, addDays((wd - 2 + 7) % 7, to: monday))
            }
            switch w1 {
            case "week": consider(2, mondayOfNextWeek())
            case "weekend": consider(2, mondayOfNextWeek().flatMap { addDays(5, to: $0) })
            case "month":
                let c = cal.dateComponents([.year, .month], from: ctx.today)
                consider(2, cal.date(byAdding: .month, value: 1,
                                     to: cal.date(from: DateComponents(year: c.year, month: c.month, day: 1))!))
            case "year":
                let y = cal.component(.year, from: ctx.today)
                consider(2, makeDate(year: y + 1, month: 1, day: 1, cal))
            default: break
            }
        }

        if w0 == "in", let w1 = lw(1), let n = count(w1), let w2 = lw(2), let unit = unit(w2) {
            switch unit {
            case .day: consider(3, addDays(n))
            case .week: consider(3, addDays(7 * n))
            case .month: consider(3, cal.date(byAdding: .month, value: n, to: ctx.today))
            case .year: consider(3, cal.date(byAdding: .year, value: n, to: ctx.today))
            }
        }

        // month day [year]
        if let m = month(w0), let d = lw(1).flatMap(dayNumber) {
            if let y = lwAfterComma(2).flatMap(year) {
                consider(3, makeDate(year: y, month: m, day: d, cal))
            }
            consider(2, futureDate(month: m, day: d, ctx))
        }
        // day month [year], day "of" month [year]
        if let d = dayNumber(w0) {
            var k = 1
            if lw(1) == "of" { k = 2 }
            if let m = lw(k).flatMap(month) {
                if let y = lwAfterComma(k + 1).flatMap(year) {
                    consider(k + 2, makeDate(year: y, month: m, day: d, cal))
                }
                consider(k + 1, futureDate(month: m, day: d, ctx))
            }
        }

        // ISO yyyy-mm-dd
        if let p = numericParts(w0, separator: "-"), p.count == 3, p[0].digits == 4 {
            consider(1, makeDate(year: p[0].value, month: p[1].value, day: p[2].value, cal))
        }
        // d/m or m/d, optional year
        if let p = numericParts(w0, separator: "/"), p.count == 2 || p.count == 3,
           p[0].digits <= 2, p[1].digits <= 2 {
            let dayFirst = isDayFirst(cal)
            let m = dayFirst ? p[1].value : p[0].value
            let d = dayFirst ? p[0].value : p[1].value
            if p.count == 3 {
                let y: Int? = p[2].digits == 4 ? p[2].value : (p[2].digits == 2 ? 2000 + p[2].value : nil)
                if let y { consider(1, makeDate(year: y, month: m, day: d, cal)) }
            } else {
                consider(1, futureDate(month: m, day: d, ctx))
            }
        }

        return best
    }

    /// True when the calendar's locale writes numeric dates day-first ("5/1" = 5 January).
    public static func isDayFirst(_ calendar: Calendar) -> Bool {
        let locale = calendar.locale ?? .current
        let format = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: locale) ?? "M/d"
        guard let d = format.firstIndex(of: "d"), let m = format.firstIndex(of: "M") else { return false }
        return d < m
    }

    // MARK: - Vocabulary

    private static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7,
    ]

    private static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
        "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    private enum Unit { case day, week, month, year }

    private static func weekday(_ w: String) -> Int? { weekdays[w] }
    private static func month(_ w: String) -> Int? { months[w] }

    private static func count(_ w: String) -> Int? {
        if let n = numberWords[w] { return n }
        guard w.count <= 4, w.allSatisfy(\.isASCIIDigit), let n = Int(w), n > 0 else { return nil }
        return n
    }

    private static func unit(_ w: String) -> Unit? {
        switch w {
        case "day", "days": return .day
        case "week", "weeks", "wk", "wks": return .week
        case "month", "months": return .month
        case "year", "years", "yr", "yrs": return .year
        default: return nil
        }
    }

    /// "5", "5th", "1st", "22nd", "3rd" → 1...31.
    private static func dayNumber(_ w: String) -> Int? {
        var s = Substring(w)
        for suffix in ["st", "nd", "rd", "th"] where s.hasSuffix(suffix) {
            s = s.dropLast(2)
            break
        }
        guard (1...2).contains(s.count), s.allSatisfy(\.isASCIIDigit), let n = Int(s), (1...31).contains(n) else { return nil }
        return n
    }

    private static func year(_ w: String) -> Int? {
        guard w.count == 4, w.allSatisfy(\.isASCIIDigit), let n = Int(w), (1900...2999).contains(n) else { return nil }
        return n
    }

    private static func numericParts(_ w: String, separator: Character) -> [(value: Int, digits: Int)]? {
        let parts = w.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var out: [(Int, Int)] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 4, p.allSatisfy(\.isASCIIDigit), let v = Int(p) else { return nil }
            out.append((v, p.count))
        }
        return out
    }

    /// Valid date only (no rollover: "feb 30" is nil).
    private static func makeDate(year: Int, month: Int, day: Int, _ cal: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day),
              let d = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: d)
        guard c.year == year, c.month == month, c.day == day else { return nil }
        return d
    }

    /// This year's month/day, or next year's when that is before today.
    private static func futureDate(month: Int, day: Int, _ ctx: DateContext) -> Date? {
        let y = ctx.calendar.component(.year, from: ctx.today)
        if let d = makeDate(year: y, month: month, day: day, ctx.calendar), d >= ctx.today { return d }
        // Feb 29 may be invalid this year but valid in a later one; try a few years ahead.
        for offset in 1...4 {
            if let d = makeDate(year: y + offset, month: month, day: day, ctx.calendar) { return d }
        }
        return nil
    }
}

/// A whitespace-separated word, with trailing punctuation split off for matching.
struct DateWord {
    /// Range of the word without trailing punctuation.
    let range: Range<String.Index>
    let original: String
    let lower: String
    /// Trailing punctuation that was removed (",", "." ...), or nil.
    let trailingPunct: Character?

    var hasTrailingPunct: Bool { trailingPunct != nil }

    private static let punctuation: Set<Character> = [",", ".", ";", ":", "!", "?", ")"]

    static func split(_ text: String) -> [DateWord] {
        text.split(whereSeparator: \.isWhitespace).map { make($0) }
    }

    static func make(_ sub: Substring) -> DateWord {
        var end = sub.endIndex
        while end > sub.startIndex {
            let prev = sub.index(before: end)
            guard punctuation.contains(sub[prev]) else { break }
            end = prev
        }
        if end == sub.startIndex { // all punctuation: keep as an unmatched word
            return DateWord(range: sub.startIndex..<sub.endIndex, original: String(sub), lower: "", trailingPunct: nil)
        }
        let core = sub[sub.startIndex..<end]
        // Report the first removed punctuation character (the one adjacent to the word).
        let first: Character? = end < sub.endIndex ? sub[end] : nil
        return DateWord(range: sub.startIndex..<end, original: String(core), lower: core.lowercased(), trailingPunct: first)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
