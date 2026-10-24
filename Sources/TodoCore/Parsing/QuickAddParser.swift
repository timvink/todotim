import Foundation

/// Result of parsing a Todoist-style quick-add line such as
/// "Buy milk tomorrow p1 @errands #Shopping /Groceries".
public struct ParsedTask: Equatable, Sendable {
    /// Task title with all recognised tokens removed.
    public var content: String
    public var priority: Priority?
    public var due: DueDate?
    public var labels: [String]
    /// Project name after '#'. When it matches one of the `projectNames` passed to the parser
    /// (case-insensitively), this is that name as given; otherwise the single word as typed.
    public var projectName: String?
    /// Section name after '/'. Same matching rules as `projectName`, against `sectionNames`.
    public var sectionName: String?
    /// True when the line contained "no date" / "no due date" (the due date was explicitly cleared).
    public var noDate: Bool

    public init(content: String, priority: Priority? = nil, due: DueDate? = nil, labels: [String] = [],
                projectName: String? = nil, sectionName: String? = nil, noDate: Bool = false) {
        self.content = content; self.priority = priority; self.due = due; self.labels = labels
        self.projectName = projectName; self.sectionName = sectionName; self.noDate = noDate
    }
}

/// A recognised token in a quick-add line, for highlighting while typing.
public struct ParsedToken: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case priority, label, project, section, date
    }

    /// Range in the original text. For `.date` it includes a leading "on"/"by"/"due".
    public var range: Range<String.Index>
    public var kind: Kind

    public init(range: Range<String.Index>, kind: Kind) {
        self.range = range; self.kind = kind
    }
}

/// Todoist-style quick-add parsing (English).
///
/// Tokens may appear anywhere in the line:
/// - `p1`...`p4` as a whole word (case-insensitive). The last one wins; all are removed.
/// - `@label`: the non-space characters after '@'. All labels are kept (deduplicated).
/// - `#Project`, `/Section`: the longest name from `projectNames`/`sectionNames` that matches
///   case-insensitively (may contain spaces) and ends at a space or the end of the line;
///   otherwise the single word after the sigil. The last one wins; all are removed.
/// - A date phrase (see `DateParser`). Only the last date phrase is used and removed; earlier
///   ones stay in the content. A directly preceding "on", "by", "due", "due on" or "due by"
///   is removed with it.
///
/// Sigils ('@', '#', '/') only start a token at the start of the line or after whitespace, so
/// "a@b.com" and "and/or" are left alone.
///
/// False-positive rules for dates: phrases match whole words only; a bare number ("chapter 5")
/// or a bare month name ("about may") is never a date. Words that are also common words or
/// names ("tom", "tod", "sat", "sun", "wed", "weekend") only count as a date when typed in
/// lowercase and either at the end of the line (ignoring other tokens) or introduced by
/// "on"/"by"/"due".
public enum QuickAddParser {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current,
                             projectNames: [String] = [], sectionNames: [String] = []) -> ParsedTask {
        let a = analyse(text, now: now, calendar: calendar, projectNames: projectNames, sectionNames: sectionNames)
        return a.task
    }

    /// Recognised tokens in `text`, sorted by position. Consistent with `parse`: exactly these
    /// ranges are removed from the content.
    public static func tokens(in text: String, now: Date = Date(), calendar: Calendar = .current,
                              projectNames: [String] = [], sectionNames: [String] = []) -> [ParsedToken] {
        analyse(text, now: now, calendar: calendar, projectNames: projectNames, sectionNames: sectionNames).tokens
    }

    // MARK: - Implementation

    private struct Analysis {
        var task: ParsedTask
        var tokens: [ParsedToken]
    }

    private static func analyse(_ text: String, now: Date, calendar: Calendar,
                                projectNames: [String], sectionNames: [String]) -> Analysis {
        var tokens: [ParsedToken] = []
        var labels: [String] = []
        var projectName: String?
        var sectionName: String?
        var priority: Priority?

        // 1. Sigil tokens.
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let atWordStart = i == text.startIndex || text[text.index(before: i)].isWhitespace
            let after = text.index(after: i)
            if (c == "@" || c == "#" || c == "/"), atWordStart, after < text.endIndex, !text[after].isWhitespace {
                let known = c == "#" ? projectNames : (c == "/" ? sectionNames : [])
                let end: String.Index
                let value: String
                if let m = longestKnownName(in: text, from: after, names: known) {
                    end = m.end; value = m.name
                } else {
                    end = text[after...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                    value = String(text[after..<end])
                }
                switch c {
                case "@":
                    tokens.append(ParsedToken(range: i..<end, kind: .label))
                    if !labels.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { labels.append(value) }
                case "#":
                    tokens.append(ParsedToken(range: i..<end, kind: .project)); projectName = value
                default:
                    tokens.append(ParsedToken(range: i..<end, kind: .section)); sectionName = value
                }
                i = end
                continue
            }
            i = after
        }

        // 2. Words outside sigil tokens; priorities.
        let sigilRanges = tokens.map(\.range)
        var free: [Bool] = []
        let words = DateWord.split(text)
        for w in words {
            let consumed = sigilRanges.contains { $0.overlaps(w.range) }
            if !consumed, w.lower.count == 2, w.lower.first == "p", let n = Int(w.lower.dropFirst()),
               let p = Priority(rawValue: n) {
                tokens.append(ParsedToken(range: w.range, kind: .priority))
                priority = p
                free.append(false)
            } else {
                free.append(!consumed)
            }
        }

        // 3. Date phrases within runs of consecutive free words; the last one wins.
        var runs: [[DateWord]] = []
        var current: [DateWord] = []
        for (w, isFree) in zip(words, free) {
            if isFree { current.append(w) } else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty { runs.append(current) }

        let ctx = DateParser.DateContext(now: now, calendar: calendar)
        var chosen: (range: Range<String.Index>, result: DateParseResult)?
        for (r, run) in runs.enumerated() {
            var k = 0
            while k < run.count {
                guard let m = DateParser.match(run, at: k, ctx: ctx) else { k += 1; continue }
                let connector = connectorStart(run, before: k)
                if m.count == 1, DateParser.ambiguousSingleWords.contains(run[k].lower) {
                    let isLast = r == runs.count - 1 && k == run.count - 1
                    guard run[k].original == run[k].lower, isLast || connector != nil else { k += 1; continue }
                }
                let start = connector.map { run[$0].range.lowerBound } ?? run[k].range.lowerBound
                chosen = (start..<run[k + m.count - 1].range.upperBound, m.result)
                k += m.count
            }
        }
        var due: DueDate?
        var noDate = false
        if let chosen {
            tokens.append(ParsedToken(range: chosen.range, kind: .date))
            switch chosen.result {
            case .date(let d): due = d
            case .noDate: noDate = true
            }
        }

        tokens.sort { $0.range.lowerBound < $1.range.lowerBound }
        let task = ParsedTask(content: content(of: text, removing: tokens.map(\.range)), priority: priority,
                              due: due, labels: labels, projectName: projectName, sectionName: sectionName,
                              noDate: noDate)
        return Analysis(task: task, tokens: tokens)
    }

    /// Index of a connector ("on", "by", "due", "due on", "due by") directly before `run[k]`.
    private static func connectorStart(_ run: [DateWord], before k: Int) -> Int? {
        guard k > 0, !run[k - 1].hasTrailingPunct, DateParser.connectors.contains(run[k - 1].lower) else { return nil }
        if run[k - 1].lower != "due", k > 1, run[k - 2].lower == "due", !run[k - 2].hasTrailingPunct { return k - 2 }
        return k - 1
    }

    private static func longestKnownName(in text: String, from start: String.Index,
                                         names: [String]) -> (end: String.Index, name: String)? {
        var best: (end: String.Index, name: String)?
        for name in names where !name.isEmpty {
            guard let r = text.range(of: name, options: [.caseInsensitive, .anchored], range: start..<text.endIndex),
                  r.upperBound == text.endIndex || text[r.upperBound].isWhitespace else { continue }
            if best == nil || r.upperBound > best!.end { best = (r.upperBound, name) }
        }
        return best
    }

    private static func content(of text: String, removing ranges: [Range<String.Index>]) -> String {
        var kept = ""
        var cursor = text.startIndex
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where r.lowerBound >= cursor {
            kept += text[cursor..<r.lowerBound]
            kept += " "
            cursor = r.upperBound
        }
        kept += text[cursor...]
        var s = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Punctuation left behind by a removed token: "Pay rent tomorrow." → "Pay rent."
        s = s.replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s,;:]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\s,;:]+$"#, with: "", options: .regularExpression)
        return s
    }
}
