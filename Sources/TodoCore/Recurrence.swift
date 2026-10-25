import Foundation

/// The subset of iCalendar RRULEs (RFC 5545 §3.3.10) TodoTim can advance: FREQ=DAILY, WEEKLY,
/// MONTHLY or YEARLY with INTERVAL, COUNT and UNTIL (WKST is ignored). Rules with any other
/// part (BYDAY, BYMONTHDAY, …) are kept as they are, but completing such a task completes it.
public enum Recurrence {
    /// The next due date after `due`, and the rule to store with it (COUNT counts down, because
    /// the series now starts one occurrence later). nil when the rule is not supported or the
    /// series has ended, so the task should be completed instead.
    public static func advance(_ rule: String, from due: DueDate, calendar: Calendar = .current) -> (due: DueDate, rule: String)? {
        var freq: Calendar.Component?
        var interval = 1
        var count: Int?
        var until: String?
        var parts: [String] = []
        for part in rule.split(separator: ";") where !part.isEmpty {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { return nil }
            switch kv[0].uppercased() {
            case "FREQ":
                switch kv[1].uppercased() {
                case "DAILY": freq = .day
                case "WEEKLY": freq = .weekOfYear
                case "MONTHLY": freq = .month
                case "YEARLY": freq = .year
                default: return nil
                }
            case "INTERVAL":
                guard let n = Int(kv[1]), (1...1000).contains(n) else { return nil }
                interval = n
            case "COUNT":
                guard let n = Int(kv[1]), n >= 0 else { return nil }
                count = n
                parts.append("")  // placeholder, replaced below
                continue
            case "UNTIL":
                guard kv[1].count >= 8, kv[1].utf8.prefix(8).allSatisfy({ (48...57).contains($0) }) else { return nil }
                until = String(kv[1].prefix(8))
            case "WKST": break
            default: return nil
            }
            parts.append(String(part))
        }
        guard let freq, let start = due.day(calendar: calendar),
              let nextDay = calendar.date(byAdding: freq, value: interval, to: start) else { return nil }
        let next = DueDate(nextDay, calendar: calendar)
        if let count, count <= 1 { return nil }
        if let until, next.date.replacingOccurrences(of: "-", with: "") > until { return nil }
        let newRule = parts.map { $0.isEmpty ? "COUNT=\(count! - 1)" : $0 }.joined(separator: ";")
        return (next, newRule)
    }

    /// Short description for the UI, e.g. "Every week" or "Every 2 months"; "Repeats" for rules
    /// `advance` does not understand.
    public static func summary(_ rule: String) -> String {
        var freq: String?
        var interval = 1
        var other = false
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).uppercased() }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "FREQ": freq = kv[1]
            case "INTERVAL": interval = Int(kv[1]) ?? 1
            case "COUNT", "UNTIL", "WKST": break
            default: other = true
            }
        }
        let unit: String
        switch freq {
        case "DAILY": unit = "day"
        case "WEEKLY": unit = "week"
        case "MONTHLY": unit = "month"
        case "YEARLY": unit = "year"
        default: return "Repeats"
        }
        if other { return "Repeats" }
        return interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
    }
}
