import Foundation

/// The subset of iCalendar RRULEs (RFC 5545 §3.3.10) TodoTim can advance: FREQ=DAILY, WEEKLY,
/// MONTHLY or YEARLY with INTERVAL, COUNT and UNTIL (WKST is ignored). Rules with any other
/// part (BYDAY, BYMONTHDAY, …) are kept as they are, but completing such a task completes it.
public enum Recurrence {
    /// The next due date after `due`, and the rule to store with it (COUNT counts down, because
    /// the series now starts one occurrence later). nil when the rule is not supported or the
    /// series has ended, so the task should be completed instead.
    ///
    /// Monthly and yearly steps keep the day of the month: a date that does not exist (the 31st,
    /// February 29) is skipped, as RFC 5545 requires, rather than clamped. A DATE UNTIL is compared
    /// with the date. A DATE-TIME UNTIL bounds the occurrence's start time, which a date-only task
    /// does not know: TodoTim advances only while the next date is at least two days before it
    /// (enough for any timezone offset) and otherwise completes the task.
    public static func advance(_ rule: String, from due: DueDate, calendar: Calendar = .current) -> (due: DueDate, rule: String)? {
        var freq: Calendar.Component?
        var interval = 1
        var count: Int?
        var lastDate: String?
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
                guard let value = ICalendar.DateValue(ICalProperty("UNTIL", value: kv[1])) else { return nil }
                var until = value.localDate(calendar: calendar)
                if !value.isDate {
                    guard let day = until.day(calendar: calendar),
                          let margin = calendar.date(byAdding: .day, value: -2, to: day) else { return nil }
                    until = DueDate(margin, calendar: calendar)
                }
                lastDate = until.date
            case "WKST": break
            default: return nil
            }
            parts.append(String(part))
        }
        guard let freq, let next = nextDate(after: due, freq: freq, interval: interval, calendar: calendar) else { return nil }
        if let count, count <= 1 { return nil }
        if let lastDate, next.date > lastDate { return nil }
        let newRule = parts.map { $0.isEmpty ? "COUNT=\(count! - 1)" : $0 }.joined(separator: ";")
        return (next, newRule)
    }

    /// The next instance `interval` units after `due`; for months and years, the first one whose
    /// day of the month exists (at most 100 steps, which covers February 29).
    private static func nextDate(after due: DueDate, freq: Calendar.Component, interval: Int, calendar: Calendar) -> DueDate? {
        guard let start = due.day(calendar: calendar) else { return nil }
        guard freq == .month || freq == .year else {
            return calendar.date(byAdding: freq, value: interval, to: start).map { DueDate($0, calendar: calendar) }
        }
        let c = calendar.dateComponents([.year, .month, .day], from: start)
        for step in 1...100 {
            var target = DateComponents(year: c.year, month: c.month, day: 1)
            if freq == .month { target.month! += interval * step } else { target.year! += interval * step }
            guard let first = calendar.date(from: target),
                  let days = calendar.range(of: .day, in: .month, for: first) else { return nil }
            if days.contains(c.day!) {
                let m = calendar.dateComponents([.year, .month], from: first)
                return DueDate(date: String(format: "%04d-%02d-%02d", m.year!, m.month!, c.day!))
            }
        }
        return nil
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
