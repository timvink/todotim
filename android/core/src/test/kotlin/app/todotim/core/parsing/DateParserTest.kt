package app.todotim.core.parsing

import app.todotim.core.FixtureJson
import app.todotim.core.FixtureJson.array
import app.todotim.core.FixtureJson.date
import app.todotim.core.FixtureJson.string
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.util.Locale

/** Fixed clock: Wednesday 2026-10-21, en_US (port of the DateParser and display parts of ParserTests). */
class DateParserTest {
    private val today = LocalDate.of(2026, 10, 21)

    private fun date(text: String, locale: Locale = Locale.US, today: LocalDate = this.today): String? =
        DateParser.parse(text, today, locale)?.toString()

    private fun display(d: String, today: LocalDate = this.today) = DueDateFormatting.displayString(LocalDate.parse(d), today)

    @Test fun relativeDays() {
        assertEquals("2026-10-21", date("today"))
        assertEquals("2026-10-21", date("tod"))
        assertEquals("2026-10-21", date("Today"))
        assertEquals("2026-10-22", date("tomorrow"))
        assertEquals("2026-10-22", date("tom"))
        assertEquals("2026-10-22", date("tmrw"))
        assertEquals("2026-10-20", date("yesterday"))
        assertEquals("2026-10-23", date("day after tomorrow"))
        assertEquals("2026-10-22", date("  tomorrow  "))
    }

    @Test fun weekdays() {
        // Today is Wednesday: the weekday name of today means today.
        assertEquals("2026-10-21", date("wed"))
        assertEquals("2026-10-21", date("wednesday"))
        assertEquals("2026-10-22", date("thu"))
        assertEquals("2026-10-23", date("friday"))
        assertEquals("2026-10-24", date("sat"))
        assertEquals("2026-10-25", date("sunday"))
        assertEquals("2026-10-26", date("mon"))
        assertEquals("2026-10-26", date("Monday"))
        assertEquals("2026-10-27", date("tues"))
        assertEquals("2026-10-23", date("this friday"))
    }

    @Test fun nextPhrases() {
        assertEquals("2026-10-26", date("next week"))
        assertEquals("2026-10-26", date("next monday"))
        assertEquals("2026-10-30", date("next friday"))
        assertEquals("2026-10-28", date("next wed"))
        assertEquals("2026-11-01", date("next sunday"))
        assertEquals("2026-11-01", date("next month"))
        assertEquals("2027-01-01", date("next year"))
        assertEquals("2026-10-24", date("weekend"))
        assertEquals("2026-10-24", date("this weekend"))
        assertEquals("2026-10-31", date("next weekend"))
    }

    @Test fun nextPhrasesOnSunday() {
        val sunday = LocalDate.of(2026, 10, 25)
        assertEquals("2026-10-26", date("next week", today = sunday))
        assertEquals("2026-10-30", date("next friday", today = sunday))
        assertEquals("2026-10-25", date("sunday", today = sunday))
        assertEquals("2026-10-25", date("weekend", today = sunday))
    }

    @Test fun inDuration() {
        assertEquals("2026-10-24", date("in 3 days"))
        assertEquals("2026-10-22", date("in 1 day"))
        assertEquals("2026-11-04", date("in 2 weeks"))
        assertEquals("2026-10-28", date("in a week"))
        assertEquals("2026-11-04", date("in two weeks"))
        assertEquals("2026-11-21", date("in 1 month"))
        assertEquals("2027-10-21", date("in 1 year"))
        assertNull(date("in 3"))
        assertNull(date("in days"))
    }

    @Test fun monthDay() {
        assertEquals("2026-11-03", date("nov 3"))
        assertEquals("2026-11-03", date("Nov 3"))
        assertEquals("2027-01-05", date("jan 5")) // past in this year → next year
        assertEquals("2027-01-05", date("5 jan"))
        assertEquals("2027-01-05", date("january 5th"))
        assertEquals("2027-01-05", date("5th of january"))
        assertEquals("2026-10-21", date("oct 21")) // today is not in the past
        assertEquals("2027-10-20", date("oct 20"))
        assertEquals("2026-12-31", date("december 31st"))
        assertEquals("2027-09-01", date("sept 1"))
    }

    @Test fun monthDayWithYear() {
        assertEquals("2026-01-05", date("jan 5 2026")) // explicit year never rolls over
        assertEquals("2027-11-03", date("nov 3 2027"))
        assertEquals("2027-11-03", date("nov 3, 2027"))
        assertEquals("2027-11-03", date("3 nov 2027"))
    }

    @Test fun invalidCalendarDates() {
        assertNull(date("feb 30"))
        assertNull(date("2026-02-30"))
        assertNull(date("13/1/2027"))
        assertNull(date("jan 32"))
        assertEquals("2028-02-29", date("feb 29")) // next leap year
    }

    @Test fun iso() {
        assertEquals("2026-11-03", date("2026-11-03"))
        assertEquals("2025-01-01", date("2025-01-01"))
    }

    @Test fun slashUsesLocaleOrder() {
        assertEquals("2027-05-01", date("5/1"))
        assertEquals("2026-11-03", date("11/3"))
        assertEquals("2027-11-03", date("11/3/2027"))
        assertEquals("2027-11-03", date("11/3/27"))
        assertEquals("2027-01-05", date("5/1", Locale.UK))
        assertEquals("2026-11-03", date("3/11", Locale.forLanguageTag("nl-NL")))
        assertTrue(DateParser.isDayFirst(Locale.UK))
        assertFalse(DateParser.isDayFirst(Locale.US))
    }

    @Test fun noDateAndConnectors() {
        assertEquals(DateParseResult.NoDate, DateParser.parsePhrase("no date", today, Locale.US))
        assertEquals(DateParseResult.NoDate, DateParser.parsePhrase("no due date", today, Locale.US))
        assertNull(date("no date"))
        assertEquals("2026-10-23", date("on friday"))
        assertEquals("2026-10-22", date("by tomorrow"))
        assertEquals("2026-11-03", date("due on nov 3"))
    }

    @Test fun rejectsNonDates() {
        for (text in listOf("", "may", "5", "tomorrow morning", "buy milk", "next", "on", "todays")) {
            assertNull(text, date(text))
        }
    }

    @Test fun displayString() {
        assertEquals("Today", display("2026-10-21"))
        assertEquals("Tomorrow", display("2026-10-22"))
        assertEquals("Yesterday", display("2026-10-20"))
        assertEquals("Friday", display("2026-10-23"))
        assertEquals("Tuesday", display("2026-10-27")) // 6 days ahead
        assertEquals("Oct 28", display("2026-10-28")) // 7 days ahead
        assertEquals("Oct 19", display("2026-10-19"))
        assertEquals("Nov 3", display("2026-11-03"))
        assertEquals("Nov 3 2027", display("2027-11-03"))
        assertEquals("Dec 31 2025", display("2025-12-31"))
    }

    @Test fun displayAcrossYearBoundary() {
        val dec30 = LocalDate.of(2026, 12, 30)
        assertEquals("Friday", display("2027-01-01", dec30))
        assertEquals("Jan 10 2027", display("2027-01-10", dec30))
    }

    @Test fun isOverdue() {
        assertTrue(DueDateFormatting.isOverdue(LocalDate.parse("2026-10-20"), today))
        assertFalse(DueDateFormatting.isOverdue(LocalDate.parse("2026-10-21"), today))
        assertFalse(DueDateFormatting.isOverdue(LocalDate.parse("2026-10-22"), today))
        assertEquals(10L, DueDateFormatting.daysFromToday(LocalDate.parse("2026-10-31"), today))
    }

    @Test fun fixtures() {
        val json = FixtureJson.load("dates.json")
        val today = json.date("today")!!
        assertEquals(json.string("todayWeekday")!!.uppercase(), today.dayOfWeek.name)
        val locale = FixtureJson.locale(json.string("locale")!!)
        for (case in json.array("parse")) {
            val input = case.string("input")!!
            val caseLocale = case.string("locale")?.let(FixtureJson::locale) ?: locale
            val got = DateParser.parsePhrase(input, case.date("today") ?: today, caseLocale)
            val expected: DateParseResult? = when (val e = case.getValue("expected")) {
                is JsonNull -> null
                else -> if (e.jsonPrimitive.content == "noDate") DateParseResult.NoDate
                else DateParseResult.Date(LocalDate.parse(e.jsonPrimitive.content))
            }
            assertEquals("'$input' (${caseLocale.toLanguageTag()})", expected, got)
        }
        for (case in json.array("dayFirst")) {
            val id = case.string("locale")!!
            assertEquals(id, case.getValue("expected").jsonPrimitive.boolean, DateParser.isDayFirst(FixtureJson.locale(id)))
        }
        for (case in json.array("display")) {
            val d = case.date("date")!!
            assertEquals(d.toString(), case.string("expected"), DueDateFormatting.displayString(d, case.date("today") ?: today))
        }
        for (case in json.array("relative")) {
            val d = case.date("date")!!
            assertEquals(d.toString(), case.getValue("days").jsonPrimitive.long, DueDateFormatting.daysFromToday(d, today))
            assertEquals(d.toString(), case.getValue("overdue").jsonPrimitive.boolean, DueDateFormatting.isOverdue(d, today))
        }
    }
}
