import Foundation

/// Result of parsing a Todoist-style quick-add line such as
/// "Buy milk tomorrow p1 @errands #Shopping /Groceries".
public struct ParsedTask: Equatable, Sendable {
    /// Task title with all recognised tokens removed.
    public var content: String
    public var priority: Priority?
    public var due: DueDate?
    public var labels: [String]
    /// Name as typed after '#', matched case-insensitively against projects by the caller.
    public var projectName: String?
    /// Name as typed after '/', matched against sections of the chosen project by the caller.
    public var sectionName: String?

    public init(content: String, priority: Priority? = nil, due: DueDate? = nil, labels: [String] = [],
                projectName: String? = nil, sectionName: String? = nil) {
        self.content = content; self.priority = priority; self.due = due; self.labels = labels
        self.projectName = projectName; self.sectionName = sectionName
    }
}

public enum QuickAddParser {
    /// STUB — replaced by the parsing agent.
    /// `projectNames`/`sectionNames` let multi-word names ("#Big Project") be matched greedily.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current,
                             projectNames: [String] = [], sectionNames: [String] = []) -> ParsedTask {
        ParsedTask(content: text.trimmingCharacters(in: .whitespaces))
    }
}

public enum DateParser {
    /// STUB — replaced by the parsing agent. Parses phrases like "today", "tomorrow",
    /// "mon", "next week", "in 3 days", "jan 5", "5/1", "2026-11-03".
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> DueDate? {
        nil
    }
}

extension DueDate {
    /// STUB — replaced by the parsing agent. Todoist-style label: "Today", "Tomorrow",
    /// "Yesterday", weekday name within the next 6 days, "Nov 3", or "Nov 3 2027" for other years.
    public func displayString(now: Date = Date(), calendar: Calendar = .current) -> String { date }

    /// STUB. True if the date is before today.
    public func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool { false }
}
