package app.todotim.core.ical

import app.todotim.core.TodoTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** Port of `ICalendarTests` in Tests/TodoCoreTests/VTodoTests.swift, plus Swift-compatibility checks. */
class ICalendarTest {
    private val amsterdam = ZoneId.of("Europe/Amsterdam")

    @Test fun parsesFoldedLinesParamsAndEscapes() {
        val text = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:1\r\nSUMMARY:Long line that is\r\n  folded\r\n" +
            "DESCRIPTION:a\\nb\\, c\\; d\\\\\r\nX-TODOTIM-SECTION;X-NAME=\"a:b;c\";X-ORDER=2:s1\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
        val root = ICalendar.parse(text)
        val todo = root.components.first()
        assertEquals("Long line that is folded", todo.first("SUMMARY")?.value)
        assertEquals("a\nb, c; d\\", ICalendar.unescapeText(todo.first("DESCRIPTION")!!.value))
        val section = todo.first("X-TODOTIM-SECTION")!!
        assertEquals("a:b;c", section.param("X-NAME"))
        assertEquals("2", section.param("X-ORDER"))
        assertEquals("s1", section.value)
        // Bare LF line endings (as in XML responses) work too.
        assertEquals(root, ICalendar.parse(text.replace("\r\n", "\n")))
    }

    @Test fun serializeFoldsAt75OctetsAndRoundTrips() {
        val long = "é".repeat(100)
        val todo = ICalComponent("VTODO", mutableListOf(
            ICalProperty("SUMMARY", long),
            ICalProperty("X-A", listOf(ICalParam("X-NAME", "say \"hi\"\n")), "v"),
        ))
        val text = ICalendar.serialize(ICalComponent("VCALENDAR", components = mutableListOf(todo)))
        for (line in text.split("\r\n")) assertTrue(line.toByteArray().size <= 75)
        assertTrue(text, text.contains("X-A;X-NAME=say ^'hi^'^n:v"))
        val back = ICalendar.parse(text)
        assertEquals(long, back.components.first().first("SUMMARY")?.value)
        assertEquals("say \"hi\"\n", back.components.first().first("X-A")?.param("X-NAME"))
    }

    @Test fun foldingBeforeACombiningCodePointRoundTrips() {
        // A fold may fall just before U+FE0F (emoji presentation), a ZWJ or a combining accent.
        for (tail in listOf("❤️", "👨‍👩‍👧", "é", "👍🏽")) {
            for (pad in 60..76) {
                val summary = "a".repeat(pad) + tail + " end"
                val t = TodoTask(id = "t", projectId = "p", content = summary, order = 1.0, createdAt = 0, updatedAt = 0)
                val ics = VTodo.make(t, "t", null, null)
                assertEquals("$pad $tail", summary, VTodo.read(ics, "p")?.task?.content)
            }
        }
    }

    @Test fun hostileDatesAndParametersDoNotCrashOrChange() {
        val ics = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:x\r\nDUE:20261103T١٢٣٤٥٦Z\r\nCREATED:20261103T１２３４５６\r\n" +
            "ATTENDEE;MEMBER=\"mailto:a@x\",\"mailto:b@x\";CN=A:mailto:c@x\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
        val v = VTodo.read(ics, "p")!!
        assertNull(v.task.due)
        val patched = VTodo.patch(ics, v, v.task.copy(content = "changed"), null, null)!!
        assertTrue(patched, patched.contains("ATTENDEE;MEMBER=\"mailto:a@x\",\"mailto:b@x\";CN=A:mailto:c@x"))
    }

    @Test fun rejectsMalformedAndOversizedInput() {
        for (bad in listOf("BEGIN:VCALENDAR\r\n", "END:VCALENDAR\r\n", "BEGIN:A\r\nEND:B\r\n", "SUMMARY:x\r\n",
            "BEGIN:A\r\nnovalue\r\nEND:A\r\n", "BEGIN:A\r\nX;P=\"open:x\r\nEND:A\r\n", " continued\r\n",
            "BEGIN:A\r\nEND:A\r\nBEGIN:B\r\nEND:B\r\n", "")) {
            assertThrows(bad, ICalException::class.java) { ICalendar.parse(bad) }
        }
        assertThrows(ICalException.TooLarge::class.java) {
            ICalendar.parse("BEGIN:X\r\n".repeat(20) + "END:X\r\n".repeat(20))
        }
        ICalendar.parse("BEGIN:X\r\n".repeat(8) + "END:X\r\n".repeat(8))
        assertThrows(ICalException.TooLarge::class.java) { ICalendar.parse("x".repeat(ICalendar.MAX_BYTES + 1)) }
        assertThrows(ICalException.TooLarge::class.java) {
            ICalendar.parse("BEGIN:A\r\n" + "X:1\r\n".repeat(ICalendar.MAX_LINES) + "END:A\r\n")
        }
        val params = (1..65).joinToString("") { ";P=1" }
        assertThrows(ICalException.Malformed::class.java) { ICalendar.parse("BEGIN:A\r\nX$params:v\r\nEND:A\r\n") }
        val many = "BEGIN:A\r\n" + "BEGIN:B\r\nEND:B\r\n".repeat(ICalendar.MAX_COMPONENTS) + "END:A\r\n"
        assertThrows(ICalException.TooLarge::class.java) { ICalendar.parse(many) }
    }

    @Test fun textListsAndDates() {
        assertEquals(listOf("a", "b,c", "d"), ICalendar.splitTextList("a,b\\,c,d"))
        assertEquals("20261024T182005Z", ICalendar.utcString(1_792_866_005_700))
        assertEquals("19691231T235959Z", ICalendar.utcString(-1))
        val p = ICalProperty("DUE", listOf(ICalParam("TZID", "America/New_York")), "20261103T220000")
        val v = DateValue.of(p)!!
        assertFalse(v.isDate)
        assertEquals("converted to the local date", LocalDate.parse("2026-11-04"), v.localDate(amsterdam))
        assertEquals("20261203T220000", v.shifted(30).property("DUE", p).value)
        assertNull(DateValue.of(ICalProperty("DUE", "2026-11-03")))
        assertNull(DateValue.of(ICalProperty("DUE", "20261303")))
        assertNull(DateValue.of(ICalProperty("DUE", "20261103T1000")))
        // Out-of-range days roll over, like Foundation's calendar.
        assertEquals(LocalDate.parse("2026-03-03"), DateValue.of(ICalProperty("DUE", "20260231"))!!.localDate(amsterdam))
        assertEquals(1_793_750_400_000, ICalendar.instant(ICalProperty("DUE", listOf(ICalParam("VALUE", "DATE")), "20261104")))
        assertEquals(1_793_746_800_000, ICalendar.instant(ICalProperty("DUE", "20261104T000000"), amsterdam))
    }

    @Test fun escapingFollowsSwiftCharacters() {
        assertEquals("a\\\\b\\;c\\,d\\ne\\nf", ICalendar.escapeText("a\\b;c,d\ne\r\nf\r"))
        // A combining mark makes `\` + mark one Character, which is not an escape.
        assertEquals("\\́", ICalendar.escapeText("\\́"))
        assertEquals("x\\́n", ICalendar.unescapeText("x\\́n"))
        assertEquals("^^^'^n", ICalendar.encodeParam("^\"\r\n"))
        assertEquals("a^b\n\"^x^", ICalendar.decodeParam("a^^b^n^'^x^"))
        assertEquals("X;P=\"\":v", ICalendar.line(ICalProperty("X", listOf(ICalParam("P", "")), "v")))
    }

    @Test fun numbersParseLikeSwift() {
        for ((s, v) in listOf(
            "1" to 1.0, "-1.5" to -1.5, "+.5" to 0.5, "1." to 1.0, "1e3" to 1000.0, "1.5E-2" to 0.015,
            "0x1p4" to 16.0, "0X.8" to 0.5, "-0x1.8" to -1.5, "0x1P-1" to 0.5, "0x1." to 1.0,
            "inf" to Double.POSITIVE_INFINITY, "-Infinity" to Double.NEGATIVE_INFINITY,
        )) {
            assertEquals(s, v, parseDouble(s)!!, 0.0)
        }
        assertTrue(parseDouble("nan")!!.isNaN())
        for (bad in listOf("", "+", ".", "e5", "1e", "1e+", "1x", " 1", "1 ", "0x", "0x.", "0xg", "0x1p", "1.2.3", "--1", "1_0", "١")) {
            assertNull(bad, parseDouble(bad))
        }
        assertEquals(42L, parseLong("+42"))
        assertEquals(-7L, parseLong("-7"))
        for (bad in listOf("", "-", "1.0", "１", "99999999999999999999")) assertNull(bad, parseLong(bad))
    }

    /** A long almost-number must not make the parser backtrack (a regex took seconds for this). */
    @Test fun longInvalidNumbersParseInLinearTime() {
        val digits = "1".repeat(20_000)
        val start = System.nanoTime()
        for (s in listOf(digits + "x", "0x" + digits + "x", digits + "." + digits + "x", digits + "e" + digits + "x")) {
            assertNull(parseDouble(s))
        }
        val ics = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:a\r\nSUMMARY:x\r\nX-TODOTIM-ORDER:${digits}x\r\n" +
            "END:VTODO\r\nEND:VCALENDAR\r\n"
        VTodo.read(ics, "inbox", amsterdam)
        val millis = (System.nanoTime() - start) / 1_000_000
        assertTrue("took $millis ms", millis < 500)
    }

    /** Foundation's `TimeZone(identifier:)` knows abbreviations such as EST; unknown ids stay floating. */
    @Test fun tzidAbbreviationsAreResolved() {
        val p = ICalProperty("DUE", listOf(ICalParam("TZID", "EST")), "20261103T230000")
        assertEquals(LocalDate.parse("2026-11-04"), DateValue.of(p)!!.localDate(amsterdam))
        assertEquals(1_793_764_800_000, ICalendar.instant(p, amsterdam))
        val unknown = ICalProperty("DUE", listOf(ICalParam("TZID", "Nowhere/Special")), "20261103T230000")
        assertEquals(LocalDate.parse("2026-11-03"), DateValue.of(unknown)!!.localDate(amsterdam))
        assertEquals(1_793_743_200_000, ICalendar.instant(unknown, amsterdam))
    }
}
