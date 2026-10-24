import XCTest
@testable import TodoCore

/// Fixed clock: Wednesday 2026-10-21 12:00 in Europe/Amsterdam, en_US gregorian calendar.
final class ParserTests: XCTestCase {
    private func makeCalendar(_ locale: String = "en_US") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        cal.locale = Locale(identifier: locale)
        return cal
    }

    private lazy var cal = makeCalendar()
    private lazy var now: Date = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!

    private func date(_ text: String, calendar: Calendar? = nil) -> String? {
        DateParser.parse(text, now: now, calendar: calendar ?? cal)?.date
    }

    private func quick(_ text: String, projects: [String] = [], sections: [String] = []) -> ParsedTask {
        QuickAddParser.parse(text, now: now, calendar: cal, projectNames: projects, sectionNames: sections)
    }

    private func display(_ d: String, now override: Date? = nil) -> String {
        DueDate(date: d).displayString(now: override ?? now, calendar: cal)
    }

    // MARK: - DateParser: relative words

    func testRelativeDays() {
        XCTAssertEqual(date("today"), "2026-10-21")
        XCTAssertEqual(date("tod"), "2026-10-21")
        XCTAssertEqual(date("Today"), "2026-10-21")
        XCTAssertEqual(date("tomorrow"), "2026-10-22")
        XCTAssertEqual(date("tom"), "2026-10-22")
        XCTAssertEqual(date("tmrw"), "2026-10-22")
        XCTAssertEqual(date("yesterday"), "2026-10-20")
        XCTAssertEqual(date("day after tomorrow"), "2026-10-23")
        XCTAssertEqual(date("  tomorrow  "), "2026-10-22")
    }

    func testWeekdays() {
        // Today is Wednesday: the weekday name of today means today.
        XCTAssertEqual(date("wed"), "2026-10-21")
        XCTAssertEqual(date("wednesday"), "2026-10-21")
        XCTAssertEqual(date("thu"), "2026-10-22")
        XCTAssertEqual(date("friday"), "2026-10-23")
        XCTAssertEqual(date("sat"), "2026-10-24")
        XCTAssertEqual(date("sunday"), "2026-10-25")
        XCTAssertEqual(date("mon"), "2026-10-26")
        XCTAssertEqual(date("Monday"), "2026-10-26")
        XCTAssertEqual(date("tues"), "2026-10-27")
        XCTAssertEqual(date("this friday"), "2026-10-23")
    }

    func testNextPhrases() {
        XCTAssertEqual(date("next week"), "2026-10-26") // Monday of next week
        XCTAssertEqual(date("next monday"), "2026-10-26")
        XCTAssertEqual(date("next friday"), "2026-10-30") // Friday of next week
        XCTAssertEqual(date("next wed"), "2026-10-28")
        XCTAssertEqual(date("next sunday"), "2026-11-01")
        XCTAssertEqual(date("next month"), "2026-11-01")
        XCTAssertEqual(date("next year"), "2027-01-01")
        XCTAssertEqual(date("weekend"), "2026-10-24")
        XCTAssertEqual(date("this weekend"), "2026-10-24")
        XCTAssertEqual(date("next weekend"), "2026-10-31")
    }

    func testNextPhrasesOnSunday() {
        let sunday = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9))!
        XCTAssertEqual(DateParser.parse("next week", now: sunday, calendar: cal)?.date, "2026-10-26")
        XCTAssertEqual(DateParser.parse("next friday", now: sunday, calendar: cal)?.date, "2026-10-30")
        XCTAssertEqual(DateParser.parse("sunday", now: sunday, calendar: cal)?.date, "2026-10-25")
        XCTAssertEqual(DateParser.parse("weekend", now: sunday, calendar: cal)?.date, "2026-10-25")
    }

    func testInDuration() {
        XCTAssertEqual(date("in 3 days"), "2026-10-24")
        XCTAssertEqual(date("in 1 day"), "2026-10-22")
        XCTAssertEqual(date("in 2 weeks"), "2026-11-04")
        XCTAssertEqual(date("in a week"), "2026-10-28")
        XCTAssertEqual(date("in two weeks"), "2026-11-04")
        XCTAssertEqual(date("in 1 month"), "2026-11-21")
        XCTAssertEqual(date("in 1 year"), "2027-10-21")
        XCTAssertNil(date("in 3"))
        XCTAssertNil(date("in days"))
    }

    // MARK: - DateParser: absolute dates

    func testMonthDay() {
        XCTAssertEqual(date("nov 3"), "2026-11-03")
        XCTAssertEqual(date("Nov 3"), "2026-11-03")
        XCTAssertEqual(date("jan 5"), "2027-01-05") // past in this year → next year
        XCTAssertEqual(date("5 jan"), "2027-01-05")
        XCTAssertEqual(date("january 5th"), "2027-01-05")
        XCTAssertEqual(date("5th of january"), "2027-01-05")
        XCTAssertEqual(date("oct 21"), "2026-10-21") // today is not in the past
        XCTAssertEqual(date("oct 20"), "2027-10-20")
        XCTAssertEqual(date("december 31st"), "2026-12-31")
        XCTAssertEqual(date("sept 1"), "2027-09-01")
    }

    func testMonthDayWithYear() {
        XCTAssertEqual(date("jan 5 2026"), "2026-01-05") // explicit year never rolls over
        XCTAssertEqual(date("nov 3 2027"), "2027-11-03")
        XCTAssertEqual(date("nov 3, 2027"), "2027-11-03")
        XCTAssertEqual(date("3 nov 2027"), "2027-11-03")
    }

    func testInvalidCalendarDates() {
        XCTAssertNil(date("feb 30"))
        XCTAssertNil(date("2026-02-30"))
        XCTAssertNil(date("13/1/2027"))
        XCTAssertNil(date("jan 32"))
        XCTAssertEqual(date("feb 29"), "2028-02-29") // next leap year
    }

    func testISO() {
        XCTAssertEqual(date("2026-11-03"), "2026-11-03")
        XCTAssertEqual(date("2025-01-01"), "2025-01-01")
    }

    func testSlashUsesLocaleOrder() {
        // en_US: month/day.
        XCTAssertEqual(date("5/1"), "2027-05-01")
        XCTAssertEqual(date("11/3"), "2026-11-03")
        XCTAssertEqual(date("11/3/2027"), "2027-11-03")
        XCTAssertEqual(date("11/3/27"), "2027-11-03")
        // en_GB / nl_NL: day/month.
        XCTAssertEqual(date("5/1", calendar: makeCalendar("en_GB")), "2027-01-05")
        XCTAssertEqual(date("3/11", calendar: makeCalendar("nl_NL")), "2026-11-03")
        XCTAssertTrue(DateParser.isDayFirst(makeCalendar("en_GB")))
        XCTAssertFalse(DateParser.isDayFirst(makeCalendar("en_US")))
    }

    func testNoDateAndConnectors() {
        XCTAssertEqual(DateParser.parsePhrase("no date", now: now, calendar: cal), .noDate)
        XCTAssertEqual(DateParser.parsePhrase("no due date", now: now, calendar: cal), .noDate)
        XCTAssertNil(date("no date"))
        XCTAssertEqual(date("on friday"), "2026-10-23")
        XCTAssertEqual(date("by tomorrow"), "2026-10-22")
        XCTAssertEqual(date("due on nov 3"), "2026-11-03")
    }

    func testDateParserRejectsNonDates() {
        XCTAssertNil(date(""))
        XCTAssertNil(date("may"))
        XCTAssertNil(date("5"))
        XCTAssertNil(date("tomorrow morning"))
        XCTAssertNil(date("buy milk"))
        XCTAssertNil(date("next"))
        XCTAssertNil(date("on"))
        XCTAssertNil(date("todays"))
    }

    // MARK: - QuickAddParser

    func testFullLine() {
        let t = quick("Buy milk tomorrow p1 @errands #Shopping /Groceries")
        XCTAssertEqual(t.content, "Buy milk")
        XCTAssertEqual(t.priority, .p1)
        XCTAssertEqual(t.due, DueDate(date: "2026-10-22"))
        XCTAssertEqual(t.labels, ["errands"])
        XCTAssertEqual(t.projectName, "Shopping")
        XCTAssertEqual(t.sectionName, "Groceries")
        XCTAssertFalse(t.noDate)
    }

    func testPlainText() {
        let t = quick("  Buy   milk ")
        XCTAssertEqual(t, ParsedTask(content: "Buy milk"))
    }

    func testPriority() {
        XCTAssertEqual(quick("email p1 report").priority, .p1)
        XCTAssertEqual(quick("email p1 report").content, "email report")
        XCTAssertEqual(quick("p3 email").priority, .p3)
        XCTAssertEqual(quick("email P2").priority, .p2)
        XCTAssertEqual(quick("a p1 b p4").priority, .p4) // last wins, both removed
        XCTAssertEqual(quick("a p1 b p4").content, "a b")
        XCTAssertNil(quick("fix p5 bug").priority)
        XCTAssertNil(quick("buy mp3 player").priority)
        XCTAssertNil(quick("check p1x").priority)
        XCTAssertEqual(quick("check p1x").content, "check p1x")
    }

    func testLabels() {
        let t = quick("call @phone bank @work @Phone")
        XCTAssertEqual(t.labels, ["phone", "work"])
        XCTAssertEqual(t.content, "call bank")
        XCTAssertEqual(quick("mail tim@example.com").labels, [])
        XCTAssertEqual(quick("mail tim@example.com").content, "mail tim@example.com")
        XCTAssertEqual(quick("lone @ sign").content, "lone @ sign")
    }

    func testProjectAndSectionMatching() {
        let projects = ["Big Project", "Big", "Home"]
        var t = quick("Plan #big project kickoff", projects: projects)
        XCTAssertEqual(t.projectName, "Big Project") // longest known name, canonical spelling
        XCTAssertEqual(t.content, "Plan kickoff")

        t = quick("Plan #Big projection", projects: projects)
        XCTAssertEqual(t.projectName, "Big") // "Big Project" must end at a word boundary
        XCTAssertEqual(t.content, "Plan projection")

        t = quick("Plan #Unknown thing", projects: projects)
        XCTAssertEqual(t.projectName, "Unknown")
        XCTAssertEqual(t.content, "Plan thing")

        t = quick("Fix tap /To Do later", sections: ["To Do", "Done"])
        XCTAssertEqual(t.sectionName, "To Do")
        XCTAssertEqual(t.content, "Fix tap later")

        XCTAssertNil(quick("read and/or write").sectionName)
        XCTAssertEqual(quick("read and/or write").content, "read and/or write")
        XCTAssertNil(quick("issue # 5").projectName)
    }

    func testDateAnywhere() {
        var t = quick("tomorrow buy milk")
        XCTAssertEqual(t.due?.date, "2026-10-22")
        XCTAssertEqual(t.content, "buy milk")

        t = quick("Submit report next friday @work")
        XCTAssertEqual(t.due?.date, "2026-10-30")
        XCTAssertEqual(t.content, "Submit report")
        XCTAssertEqual(t.labels, ["work"])

        t = quick("Renew passport in 2 weeks p2")
        XCTAssertEqual(t.due?.date, "2026-11-04")
        XCTAssertEqual(t.content, "Renew passport")
        XCTAssertEqual(t.priority, .p2)

        t = quick("Dentist jan 5, 2027 #Health", projects: ["Health"])
        XCTAssertEqual(t.due?.date, "2027-01-05")
        XCTAssertEqual(t.content, "Dentist")

        t = quick("Pay invoice 2026-11-03")
        XCTAssertEqual(t.due?.date, "2026-11-03")
        XCTAssertEqual(t.content, "Pay invoice")
    }

    func testConnectorsAreRemoved() {
        XCTAssertEqual(quick("Meet Anna on friday").content, "Meet Anna")
        XCTAssertEqual(quick("Meet Anna on friday").due?.date, "2026-10-23")
        XCTAssertEqual(quick("Pay rent by nov 3").content, "Pay rent")
        XCTAssertEqual(quick("Taxes due tomorrow").content, "Taxes")
        XCTAssertEqual(quick("Taxes due by monday").content, "Taxes")
        XCTAssertEqual(quick("Taxes due by monday").due?.date, "2026-10-26")
        // "on" without a following date stays.
        XCTAssertEqual(quick("Work on report").content, "Work on report")
    }

    func testOnlyLastDateIsUsed() {
        let t = quick("Move meeting from monday to friday")
        XCTAssertEqual(t.due?.date, "2026-10-23")
        XCTAssertEqual(t.content, "Move meeting from monday to")
    }

    func testPunctuation() {
        XCTAssertEqual(quick("Pay rent tomorrow.").content, "Pay rent.")
        XCTAssertEqual(quick("Pay rent tomorrow.").due?.date, "2026-10-22")
        XCTAssertEqual(quick("tomorrow, call the bank").content, "call the bank")
        XCTAssertEqual(quick("tomorrow, call the bank").due?.date, "2026-10-22")
        // A phrase does not extend across punctuation: "next, week" is not "next week".
        XCTAssertNil(quick("next, week").due)
    }

    func testNoDate() {
        let t = quick("Someday read a book no date")
        XCTAssertTrue(t.noDate)
        XCTAssertNil(t.due)
        XCTAssertEqual(t.content, "Someday read a book")
    }

    // MARK: - False positives

    func testFalsePositives() {
        // Bare numbers and bare month names are never dates.
        XCTAssertNil(quick("Read chapter 5").due)
        XCTAssertEqual(quick("Read chapter 5").content, "Read chapter 5")
        XCTAssertNil(quick("Call mom about may").due)
        XCTAssertNil(quick("Ask about the March release").due)
        XCTAssertNil(quick("Buy 3 apples").due)
        // Whole words only.
        XCTAssertNil(quick("Read today's paper").due)
        XCTAssertNil(quick("Fix monday.com integration").due)
        XCTAssertNil(quick("Read tomorrowland").due)
        // Ambiguous words: names / common words.
        XCTAssertNil(quick("Call Tom").due)
        XCTAssertEqual(quick("Call Tom").content, "Call Tom")
        XCTAssertNil(quick("buy sun cream").due)
        XCTAssertNil(quick("Plan weekend trip").due)
        XCTAssertNil(quick("tom said hi").due)
        XCTAssertNil(quick("Get wed photos printed").due)
    }

    func testAmbiguousWordsWhenIntended() {
        XCTAssertEqual(quick("call mom tom").due?.date, "2026-10-22")
        XCTAssertEqual(quick("call mom tom").content, "call mom")
        XCTAssertEqual(quick("call mom tom p1").due?.date, "2026-10-22") // last word ignoring tokens
        XCTAssertEqual(quick("mow lawn on sat please").due?.date, "2026-10-24")
        XCTAssertEqual(quick("mow lawn on sat please").content, "mow lawn please")
        XCTAssertEqual(quick("clean house weekend").due?.date, "2026-10-24")
        XCTAssertEqual(quick("Call Tom tomorrow").due?.date, "2026-10-22")
        XCTAssertEqual(quick("Call Tom tomorrow").content, "Call Tom")
        // Multi-word phrases are not ambiguous.
        XCTAssertEqual(quick("Groceries next sat for party").due?.date, "2026-10-31")
    }

    // MARK: - Tokens

    func testTokensMatchParse() {
        let text = "Buy milk on friday p1 @errands #Big Project"
        let tokens = QuickAddParser.tokens(in: text, now: now, calendar: cal, projectNames: ["Big Project"])
        let pieces = tokens.map { "\($0.kind.rawValue):\(text[$0.range])" }
        XCTAssertEqual(pieces, ["date:on friday", "priority:p1", "label:@errands", "project:#Big Project"])
    }

    func testTokensSkipAmbiguousAndEmpty() {
        XCTAssertEqual(QuickAddParser.tokens(in: "Call Tom", now: now, calendar: cal), [])
        XCTAssertEqual(QuickAddParser.tokens(in: "", now: now, calendar: cal), [])
        let text = "Pay rent tomorrow."
        let tokens = QuickAddParser.tokens(in: text, now: now, calendar: cal)
        XCTAssertEqual(tokens.map { String(text[$0.range]) }, ["tomorrow"])
    }

    func testDateNotSplitAcrossTokens() {
        // "next" and "week" are separated by a label, so they don't form a phrase.
        let t = quick("plan next @work week")
        XCTAssertNil(t.due)
        XCTAssertEqual(t.content, "plan next week")
    }

    // MARK: - Display

    func testDisplayString() {
        XCTAssertEqual(display("2026-10-21"), "Today")
        XCTAssertEqual(display("2026-10-22"), "Tomorrow")
        XCTAssertEqual(display("2026-10-20"), "Yesterday")
        XCTAssertEqual(display("2026-10-23"), "Friday")
        XCTAssertEqual(display("2026-10-27"), "Tuesday") // 6 days ahead
        XCTAssertEqual(display("2026-10-28"), "Oct 28") // 7 days ahead
        XCTAssertEqual(display("2026-10-19"), "Oct 19")
        XCTAssertEqual(display("2026-11-03"), "Nov 3")
        XCTAssertEqual(display("2027-11-03"), "Nov 3 2027")
        XCTAssertEqual(display("2025-12-31"), "Dec 31 2025")
        XCTAssertEqual(display("garbage"), "garbage")
    }

    func testDisplayAcrossYearBoundary() {
        let dec30 = cal.date(from: DateComponents(year: 2026, month: 12, day: 30, hour: 23, minute: 59))!
        XCTAssertEqual(display("2027-01-01", now: dec30), "Friday")
        XCTAssertEqual(display("2027-01-10", now: dec30), "Jan 10 2027")
    }

    func testIsOverdue() {
        XCTAssertTrue(DueDate(date: "2026-10-20").isOverdue(now: now, calendar: cal))
        XCTAssertFalse(DueDate(date: "2026-10-21").isOverdue(now: now, calendar: cal))
        XCTAssertFalse(DueDate(date: "2026-10-22").isOverdue(now: now, calendar: cal))
        XCTAssertEqual(DueDate(date: "2026-10-31").daysFromToday(now: now, calendar: cal), 10)
    }

    func testDSTTransitionDoesNotShiftDays() {
        // Europe/Amsterdam leaves DST on 2026-10-25.
        let sat = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 30))!
        XCTAssertEqual(DateParser.parse("in 2 days", now: sat, calendar: cal)?.date, "2026-10-26")
        XCTAssertEqual(DueDate(date: "2026-10-26").displayString(now: sat, calendar: cal), "Monday")
    }
}
