package app.todotim.core

import app.todotim.core.FixtureJson.array
import app.todotim.core.FixtureJson.date
import app.todotim.core.FixtureJson.string
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

class RecurrenceTest {
    private val amsterdam = ZoneId.of("Europe/Amsterdam")

    private fun next(rule: String, due: String): String? =
        Recurrence.advance(rule, LocalDate.parse(due), amsterdam)?.let { "${it.due} ${it.rule}" }

    // Port of VTodoTests.testRecurrenceAdvance.
    @Test fun advance() {
        assertEquals("2026-11-01 FREQ=DAILY", next("FREQ=DAILY", "2026-10-31"))
        assertEquals("2026-11-08 FREQ=WEEKLY;INTERVAL=2;WKST=MO", next("FREQ=WEEKLY;INTERVAL=2;WKST=MO", "2026-10-25"))
        assertEquals("February 31 is skipped, not clamped", "2026-03-31 FREQ=MONTHLY", next("FREQ=MONTHLY", "2026-01-31"))
        assertEquals("2026-05-31 FREQ=MONTHLY;INTERVAL=1", next("FREQ=MONTHLY;INTERVAL=1", "2026-03-31"))
        assertEquals("leap day stays a leap day", "2032-02-29 FREQ=YEARLY", next("FREQ=YEARLY", "2028-02-29"))
        assertEquals("2026-02-15 FREQ=MONTHLY", next("FREQ=MONTHLY", "2026-01-15"))
        assertEquals("2027-03-01 FREQ=YEARLY;COUNT=2", next("FREQ=YEARLY;COUNT=3", "2026-03-01"))
        assertNull("last occurrence: complete", next("FREQ=YEARLY;COUNT=1", "2026-03-01"))
        assertEquals("2026-11-02 FREQ=DAILY;UNTIL=20261102", next("FREQ=DAILY;UNTIL=20261102", "2026-11-01"))
        assertNull(next("FREQ=DAILY;UNTIL=20261102T000000Z", "2026-11-02"))
        // A DATE-TIME UNTIL bounds the start time, which a date-only task doesn't know: advance
        // only with two days to spare.
        assertNull(next("FREQ=DAILY;UNTIL=20261102T100000Z", "2026-11-01"))
        assertNull(next("FREQ=DAILY;UNTIL=20261104T100000Z", "2026-11-02"))
        assertEquals("2026-11-02 FREQ=DAILY;UNTIL=20261104T100000Z", next("FREQ=DAILY;UNTIL=20261104T100000Z", "2026-11-01"))
        assertNull(next("FREQ=DAILY;UNTIL=garbage", "2026-11-01"))
        assertNull("unsupported parts: complete", next("FREQ=WEEKLY;BYDAY=MO,WE", "2026-11-02"))
        assertNull(next("FREQ=HOURLY", "2026-11-02"))
        assertEquals("Every 2 weeks", Recurrence.summary("FREQ=WEEKLY;INTERVAL=2"))
        assertEquals("Every day", Recurrence.summary("FREQ=DAILY"))
        assertEquals("Repeats", Recurrence.summary("FREQ=WEEKLY;BYDAY=MO"))
    }

    @Test fun utcUntilDependsOnTheZone() {
        // 23:00Z on Nov 3 is Nov 4 in Amsterdam but Nov 3 in UTC.
        val rule = "FREQ=DAILY;UNTIL=20261103T230000Z"
        assertEquals(LocalDate.parse("2026-11-02"), Recurrence.advance(rule, LocalDate.parse("2026-11-01"), amsterdam)?.due)
        assertNull(Recurrence.advance(rule, LocalDate.parse("2026-11-01"), ZoneId.of("UTC")))
    }

    @Test fun fixtures() {
        val json = FixtureJson.load("recurrence.json")
        val zone = ZoneId.of(json.string("zone")!!)
        for (case in json.array("advance")) {
            val rule = case.string("rrule")!!
            val due = case.date("due") ?: case.date("today")!!
            val got = Recurrence.advance(rule, due, zone)
            val message = "$rule from $due (${case.string("note")})"
            when (val expected = case.getValue("expected")) {
                is JsonPrimitive -> {
                    assertEquals("complete", expected.content)
                    assertNull(message, got)
                }
                is JsonObject -> {
                    assertEquals(message, Recurrence.Next(expected.date("due")!!, expected.string("rrule")!!), got)
                }
                else -> error("bad expected in $message")
            }
        }
        for (case in json.array("summary")) {
            assertEquals(case.string("rrule"), case.string("expected"), Recurrence.summary(case.string("rrule")!!))
        }
    }
}
