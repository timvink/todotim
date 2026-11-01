package app.todotim.core.parsing

import app.todotim.core.FixtureJson
import app.todotim.core.FixtureJson.array
import app.todotim.core.FixtureJson.date
import app.todotim.core.FixtureJson.string
import app.todotim.core.FixtureJson.strings
import app.todotim.core.Priority
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.util.Locale

/** Fixed clock: Wednesday 2026-10-21, en_US (port of the QuickAddParser part of ParserTests). */
class QuickAddParserTest {
    private val today = LocalDate.of(2026, 10, 21)

    private fun quick(text: String, projects: List<String> = emptyList(), sections: List<String> = emptyList()) =
        QuickAddParser.parse(text, today, Locale.US, projects, sections)

    private fun tokens(text: String, projects: List<String> = emptyList()) =
        QuickAddParser.tokens(text, today, Locale.US, projects).map { "${it.kind.name.lowercase()}:${text.substring(it.start, it.end)}" }

    private fun d(s: String) = LocalDate.parse(s)

    @Test fun fullLine() {
        val t = quick("Buy milk tomorrow p1 @errands #Shopping /Groceries")
        assertEquals("Buy milk", t.content)
        assertEquals(Priority.P1, t.priority)
        assertEquals(d("2026-10-22"), t.due)
        assertEquals(listOf("errands"), t.labels)
        assertEquals("Shopping", t.projectName)
        assertEquals("Groceries", t.sectionName)
        assertFalse(t.noDate)
    }

    @Test fun plainText() {
        assertEquals(ParsedTask(content = "Buy milk"), quick("  Buy   milk "))
    }

    @Test fun priority() {
        assertEquals(Priority.P1, quick("email p1 report").priority)
        assertEquals("email report", quick("email p1 report").content)
        assertEquals(Priority.P3, quick("p3 email").priority)
        assertEquals(Priority.P2, quick("email P2").priority)
        assertEquals(Priority.P4, quick("a p1 b p4").priority) // last wins, both removed
        assertEquals("a b", quick("a p1 b p4").content)
        assertNull(quick("fix p5 bug").priority)
        assertNull(quick("buy mp3 player").priority)
        assertNull(quick("check p1x").priority)
        assertEquals("check p1x", quick("check p1x").content)
    }

    @Test fun labels() {
        val t = quick("call @phone bank @work @Phone")
        assertEquals(listOf("phone", "work"), t.labels)
        assertEquals("call bank", t.content)
        assertEquals(emptyList<String>(), quick("mail tim@example.com").labels)
        assertEquals("mail tim@example.com", quick("mail tim@example.com").content)
        assertEquals("lone @ sign", quick("lone @ sign").content)
    }

    @Test fun projectAndSectionMatching() {
        val projects = listOf("Big Project", "Big", "Home")
        var t = quick("Plan #big project kickoff", projects)
        assertEquals("Big Project", t.projectName) // longest known name, canonical spelling
        assertEquals("Plan kickoff", t.content)

        t = quick("Plan #Big projection", projects)
        assertEquals("Big", t.projectName) // "Big Project" must end at a word boundary
        assertEquals("Plan projection", t.content)

        t = quick("Plan #Unknown thing", projects)
        assertEquals("Unknown", t.projectName)
        assertEquals("Plan thing", t.content)

        t = quick("Fix tap /To Do later", sections = listOf("To Do", "Done"))
        assertEquals("To Do", t.sectionName)
        assertEquals("Fix tap later", t.content)

        assertNull(quick("read and/or write").sectionName)
        assertEquals("read and/or write", quick("read and/or write").content)
        assertNull(quick("issue # 5").projectName)
    }

    @Test fun dateAnywhere() {
        var t = quick("tomorrow buy milk")
        assertEquals(d("2026-10-22"), t.due)
        assertEquals("buy milk", t.content)

        t = quick("Submit report next friday @work")
        assertEquals(d("2026-10-30"), t.due)
        assertEquals("Submit report", t.content)
        assertEquals(listOf("work"), t.labels)

        t = quick("Renew passport in 2 weeks p2")
        assertEquals(d("2026-11-04"), t.due)
        assertEquals("Renew passport", t.content)
        assertEquals(Priority.P2, t.priority)

        t = quick("Dentist jan 5, 2027 #Health", listOf("Health"))
        assertEquals(d("2027-01-05"), t.due)
        assertEquals("Dentist", t.content)

        t = quick("Pay invoice 2026-11-03")
        assertEquals(d("2026-11-03"), t.due)
        assertEquals("Pay invoice", t.content)
    }

    @Test fun connectorsAreRemoved() {
        assertEquals("Meet Anna", quick("Meet Anna on friday").content)
        assertEquals(d("2026-10-23"), quick("Meet Anna on friday").due)
        assertEquals("Pay rent", quick("Pay rent by nov 3").content)
        assertEquals("Taxes", quick("Taxes due tomorrow").content)
        assertEquals("Taxes", quick("Taxes due by monday").content)
        assertEquals(d("2026-10-26"), quick("Taxes due by monday").due)
        // "on" without a following date stays.
        assertEquals("Work on report", quick("Work on report").content)
    }

    @Test fun onlyLastDateIsUsed() {
        val t = quick("Move meeting from monday to friday")
        assertEquals(d("2026-10-23"), t.due)
        assertEquals("Move meeting from monday to", t.content)
    }

    @Test fun punctuation() {
        assertEquals("Pay rent.", quick("Pay rent tomorrow.").content)
        assertEquals(d("2026-10-22"), quick("Pay rent tomorrow.").due)
        assertEquals("call the bank", quick("tomorrow, call the bank").content)
        assertEquals(d("2026-10-22"), quick("tomorrow, call the bank").due)
        // A phrase does not extend across punctuation: "next, week" is not "next week".
        assertNull(quick("next, week").due)
    }

    @Test fun noDate() {
        val t = quick("Someday read a book no date")
        assertTrue(t.noDate)
        assertNull(t.due)
        assertEquals("Someday read a book", t.content)
    }

    @Test fun falsePositives() {
        // Bare numbers and bare month names are never dates; whole words only; ambiguous words.
        for (text in listOf(
            "Read chapter 5", "Call mom about may", "Ask about the March release", "Buy 3 apples",
            "Read today's paper", "Fix monday.com integration", "Read tomorrowland",
            "Call Tom", "buy sun cream", "Plan weekend trip", "tom said hi", "Get wed photos printed",
        )) {
            assertNull(text, quick(text).due)
        }
        assertEquals("Read chapter 5", quick("Read chapter 5").content)
        assertEquals("Call Tom", quick("Call Tom").content)
    }

    @Test fun ambiguousWordsWhenIntended() {
        assertEquals(d("2026-10-22"), quick("call mom tom").due)
        assertEquals("call mom", quick("call mom tom").content)
        assertEquals(d("2026-10-22"), quick("call mom tom p1").due) // last word ignoring tokens
        assertEquals(d("2026-10-24"), quick("mow lawn on sat please").due)
        assertEquals("mow lawn please", quick("mow lawn on sat please").content)
        assertEquals(d("2026-10-24"), quick("clean house weekend").due)
        assertEquals(d("2026-10-22"), quick("Call Tom tomorrow").due)
        assertEquals("Call Tom", quick("Call Tom tomorrow").content)
        // Multi-word phrases are not ambiguous.
        assertEquals(d("2026-10-31"), quick("Groceries next sat for party").due)
    }

    @Test fun tokensMatchParse() {
        assertEquals(
            listOf("date:on friday", "priority:p1", "label:@errands", "project:#Big Project"),
            tokens("Buy milk on friday p1 @errands #Big Project", listOf("Big Project")),
        )
    }

    @Test fun tokensSkipAmbiguousAndEmpty() {
        assertEquals(emptyList<String>(), tokens("Call Tom"))
        assertEquals(emptyList<String>(), tokens(""))
        assertEquals(listOf("date:tomorrow"), tokens("Pay rent tomorrow."))
    }

    @Test fun dateNotSplitAcrossTokens() {
        // "next" and "week" are separated by a label, so they don't form a phrase.
        val t = quick("plan next @work week")
        assertNull(t.due)
        assertEquals("plan next week", t.content)
    }

    @Test fun fixtures() {
        val json = FixtureJson.load("quickadd.json")
        val today = json.date("today")!!
        assertEquals(json.string("todayWeekday")!!.uppercase(), today.dayOfWeek.name)
        val locale = FixtureJson.locale(json.string("locale")!!)
        for (case in json.array("cases")) {
            val input = case.string("input")!!
            val caseToday = case.date("today") ?: today
            val caseLocale = case.string("locale")?.let(FixtureJson::locale) ?: locale
            val projects = case.strings("projects")
            val sections = case.strings("sections")
            val e = case.getValue("expected") as JsonObject
            val expected = ParsedTask(
                content = e.string("content")!!,
                priority = (e["priority"] as? JsonPrimitive)?.takeIf { it.content != "null" }?.int
                    ?.let { p -> Priority.entries.first { it.level == p } },
                due = e.date("due"),
                labels = e.strings("labels"),
                projectName = e.string("project"),
                sectionName = e.string("section"),
                noDate = (e["noDate"] as? JsonPrimitive)?.boolean ?: false,
            )
            val message = "'$input'"
            assertEquals(message, expected, QuickAddParser.parse(input, caseToday, caseLocale, projects, sections))
            case["tokens"]?.let { arr ->
                val want = arr.jsonArray.map { (it as JsonObject).let { t -> "${t.string("kind")}:${t.string("text")}" } }
                val got = QuickAddParser.tokens(input, caseToday, caseLocale, projects, sections)
                    .map { "${it.kind.name.lowercase()}:${input.substring(it.start, it.end)}" }
                assertEquals(message, want, got)
            }
        }
    }
}
