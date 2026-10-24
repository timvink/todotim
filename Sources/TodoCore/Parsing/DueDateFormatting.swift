import Foundation

extension DueDate {
    /// Whole days from today to this date in `calendar` (negative = past). nil if the stored
    /// string is not a valid date.
    public func daysFromToday(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let day = day(calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: today, to: day).day
    }

    /// Todoist-style label (English): "Today", "Tomorrow", "Yesterday", the weekday name
    /// ("Monday") for 2–6 days ahead, otherwise "Nov 3", or "Nov 3 2027" when the year differs
    /// from the current one.
    public func displayString(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let day = day(calendar: calendar), let diff = daysFromToday(now: now, calendar: calendar) else {
            return date
        }
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return Self.weekdayNames[calendar.component(.weekday, from: day) - 1]
        default:
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let label = "\(Self.monthNames[c.month! - 1]) \(c.day!)"
            return c.year == calendar.component(.year, from: now) ? label : "\(label) \(c.year!)"
        }
    }

    /// True if the date is before today.
    public func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        (daysFromToday(now: now, calendar: calendar) ?? 0) < 0
    }

    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
