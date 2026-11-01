package app.todotim.core.ical

import app.todotim.core.Ids
import app.todotim.core.Priority
import app.todotim.core.Section
import app.todotim.core.TodoTask
import app.todotim.core.isValidEntityID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/** Port of `VTodoTests` in Tests/TodoCoreTests/VTodoTests.swift (the VTODO parts). */
class VTodoTest {
    private val amsterdam = ZoneId.of("Europe/Amsterdam")

    private fun vtodo(lines: String) =
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\n" + lines.trimIndent().replace("\n", "\r\n") +
            "\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"

    @Test fun readsForeignTask() {
        val ics = vtodo("""
            UID:abc
            SUMMARY:Buy milk
            PRIORITY:5
            DUE:20261103T230000Z
            STATUS:COMPLETED
            COMPLETED:20261101T120000Z
            RELATED-TO:parent-uid
            RELATED-TO;RELTYPE=SIBLING:other
            CATEGORIES:a,b
            CATEGORIES:c
            X-OC-HIDESUBTASKS:1
            X-APPLE-SORT-ORDER:12
            CREATED:20261001T000000Z
            LAST-MODIFIED:20261002T000000Z
        """)
        val t = VTodo.read(ics, "p", amsterdam)!!.task
        assertEquals("abc", t.id)
        assertEquals("Buy milk", t.content)
        assertEquals(Priority.P2, t.priority)
        assertEquals("a UTC time is read as its local date", LocalDate.parse("2026-11-04"), t.due)
        assertTrue(t.isCompleted)
        assertEquals(1_793_534_400_000, t.completedAt)
        assertEquals("parent-uid", t.parentId)
        assertEquals(listOf("a", "b", "c"), t.labels)
        assertTrue(t.collapsed)
        assertEquals(12.0, t.order, 0.0)
        assertEquals(1_790_899_200_000, t.updatedAt)
    }

    @Test fun priorityMapping() {
        assertEquals(
            listOf(Priority.P4, Priority.P1, Priority.P1, Priority.P1, Priority.P1, Priority.P2, Priority.P3, Priority.P3, Priority.P3, Priority.P3),
            (0..9).map { VTodo.priority(it.toString()) },
        )
        assertEquals(Priority.P4, VTodo.priority(null))
        assertEquals(Priority.P4, VTodo.priority("high"))
        assertEquals(Priority.P4, VTodo.priority("٥"), )
        assertEquals(Priority.P2, VTodo.priority(" +5 "))
        assertEquals(listOf("1", "5", "9", "0"), Priority.entries.map(VTodo::icalPriority))
    }

    @Test fun orderRules() {
        fun order(lines: String) = VTodo.read(vtodo("UID:x\n$lines"), "p")!!.task.order
        assertEquals(2.5, order("X-TODOTIM-ORDER:2.5\nX-APPLE-SORT-ORDER:2"), 0.0)
        assertEquals("no Apple order: trust ours", 2.5, order("X-TODOTIM-ORDER:2.5"), 0.0)
        assertEquals("another client reordered", 7.0, order("X-TODOTIM-ORDER:2.5\nX-APPLE-SORT-ORDER:7"), 0.0)
        assertEquals("floor, not truncation", -0.5, order("X-TODOTIM-ORDER:-0.5\nX-APPLE-SORT-ORDER:-1"), 0.0)
        assertEquals("no order: seconds since 2001", 60.0, order("CREATED:20010101T000100Z"), 0.0)
        assertEquals("not finite", 60.0, order("CREATED:20010101T000100Z\nX-TODOTIM-ORDER:inf"), 0.0)
    }

    @Test fun numberFormatsMatchSwift() {
        assertEquals("2", VTodo.format(2.0))
        assertEquals("0", VTodo.format(-0.0))
        assertEquals("0.25", VTodo.format(0.25))
        assertEquals("-1.5", VTodo.format(-1.5))
        assertEquals("0.1", VTodo.format(0.1))
        assertEquals("0.0001", VTodo.format(0.0001))
        assertEquals("1e-05", VTodo.format(0.00001))
        assertEquals("1.5e-07", VTodo.format(1.5e-7))
        assertEquals("1000000000000000.0", VTodo.format(1e15))
        assertEquals("1e+16", VTodo.format(1e16))
        assertEquals("1.2345678901234567e+19", VTodo.format(1.2345678901234567e19))
        assertEquals(-2L, VTodo.appleOrder(-1.5))
        assertEquals(Long.MAX_VALUE, VTodo.appleOrder(1e300))
        assertEquals(1.5, VTodo.finiteDouble(" 1.5 "))
        assertEquals(8.0, VTodo.finiteDouble("0x1p3"))
        assertEquals(16.0, VTodo.finiteDouble("0x10"))
        assertNull(VTodo.finiteDouble("1.5f"))
        assertNull(VTodo.finiteDouble("nan"))
        assertNull(VTodo.finiteDouble("1e400"))
    }

    @Test fun invalidUidGetsStableDerivedIdAndBadSectionIsDropped() {
        val v = VTodo.read(vtodo("UID:a/b c\nX-TODOTIM-SECTION;X-NAME=x:../bad\nRELATED-TO:also/bad"), "p")!!
        assertTrue(isValidEntityID(v.task.id))
        assertEquals(Ids.taskId("a/b c"), v.task.id)
        assertEquals("a/b c", v.uid)
        assertNull(v.task.sectionId)
        assertNull(v.sectionName)
        assertEquals(VTodo.taskId("also/bad"), v.task.parentId)
        assertNull(VTodo.read(vtodo("SUMMARY:no uid"), "p"))
        assertNull(VTodo.read(vtodo("UID:" + "u".repeat(1001)), "p"))
        assertNull(VTodo.read("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:e\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n", "p"))
        assertNull(VTodo.read("BEGIN:VTODO\r\nUID:e\r\nEND:VTODO\r\n", "p"))
    }

    @Test fun clipsRemoteText() {
        val v = VTodo.read(vtodo("UID:x\nSUMMARY:" + "a".repeat(10_001) + "\nCATEGORIES:" + (1..150).joinToString(",") { "l$it" }), "p")!!
        assertEquals(10_000, v.task.content.length)
        assertEquals(100, v.task.labels.size)
        // Clipping counts Characters: 10,000 emoji (40,000 bytes) are kept whole.
        val emoji = "👍🏽".repeat(10_000)
        assertEquals(emoji, VTodo.read(vtodo("UID:x\nSUMMARY:$emoji"), "p")!!.task.content)
        assertEquals(emoji, VTodo.read(vtodo("UID:x\nSUMMARY:${emoji}👍"), "p")!!.task.content)
    }

    @Test fun makeRoundTrips() {
        val created = 1_790_000_000_000L
        val section = Section("s1", "p", "Name, with: \"quotes\"", 1.5)
        val t = TodoTask(
            id = "t1", projectId = "p", sectionId = "s1", parentId = "t0", content = "Title; with, commas\\",
            description = "Line 1\nLine 2", priority = Priority.P3, due = LocalDate.parse("2026-11-03"),
            labels = listOf("a,b", "c"), isCompleted = true, completedAt = created + 60_000, order = 0.25,
            collapsed = true, recurrence = "FREQ=DAILY", createdAt = created, updatedAt = created + 60_000,
        )
        val ics = VTodo.make(t, "t1", "t0", section)
        assertTrue(ics.contains("DUE;VALUE=DATE:20261103"))
        assertTrue(ics.contains("X-APPLE-SORT-ORDER:0"))
        assertTrue(ics.contains("X-TODOTIM-ORDER:0.25"))
        assertTrue(ics.contains("PERCENT-COMPLETE:100"))
        val back = VTodo.read(ics, "p")!!
        assertEquals(t, back.task)
        assertEquals(section.name, back.sectionName)
        assertEquals(1.5, back.sectionOrder)
        assertNull("nothing to write", VTodo.patch(ics, back, t, "t0", section))
        // Canonically equivalent text is the same text, as in Swift.
        val decomposed = back.copy(task = back.task.copy(content = "é"))
        assertNull(VTodo.patch(ics, decomposed, decomposed.task.copy(content = "é"), "t0", section))
    }

    @Test fun patchTouchesOnlyChangedProperties() {
        val ics = vtodo("""
            UID:x
            SUMMARY:Old
            PRIORITY:3
            DTSTART;VALUE=DATE:20261101
            DUE;VALUE=DATE:20261102
            X-FOREIGN;P=1:keep
            BEGIN:VALARM
            TRIGGER:-PT5M
            END:VALARM
        """)
        val old = VTodo.read(ics, "p", amsterdam)!!
        val t = old.task.copy(content = "New", due = LocalDate.parse("2026-11-05"), isCompleted = true,
            completedAt = 1_800_000_000_000, updatedAt = 1_800_000_000_000)
        val patched = VTodo.patch(ics, old, t, null, null, amsterdam)!!
        assertTrue(patched.contains("SUMMARY:New"))
        assertTrue("unchanged priority keeps its value", patched.contains("PRIORITY:3"))
        assertTrue(patched.contains("DUE;VALUE=DATE:20261105"))
        assertTrue("start moves with the due date", patched.contains("DTSTART;VALUE=DATE:20261104"))
        assertTrue(patched.contains("X-FOREIGN;P=1:keep"))
        assertTrue(patched.contains("BEGIN:VALARM\r\nTRIGGER:-PT5M\r\nEND:VALARM"))
        assertTrue(patched.contains("STATUS:COMPLETED\r\n"))
        assertTrue(patched.contains("COMPLETED:20270115T080000Z"))
        assertTrue(patched.contains("LAST-MODIFIED:20270115T080000Z"))
        assertEquals("New", VTodo.read(patched, "p")?.task?.content)

        // Reopening removes COMPLETED; removing the due date removes DUE.
        val read = VTodo.read(patched, "p", amsterdam)!!
        val reopened = read.task.copy(isCompleted = false, completedAt = null, due = null)
        val again = VTodo.patch(patched, read, reopened, null, null, amsterdam)!!
        assertTrue(again.contains("STATUS:NEEDS-ACTION"))
        assertFalse(again.contains("COMPLETED:"))
        assertFalse(again.contains("DUE"))
    }

    @Test fun newDueDateFitsAForeignStartAndDuration() {
        val ics = vtodo("UID:x\nDTSTART;TZID=Europe/Amsterdam:20261110T090000\nDURATION:PT1H")
        val old = VTodo.read(ics, "p", amsterdam)!!
        val patched = VTodo.patch(ics, old, old.task.copy(due = LocalDate.parse("2026-11-05")), null, null, amsterdam)!!
        assertTrue("a DATE-TIME like DTSTART: $patched", patched.contains("DUE:20261105T235959\r\n"))
        assertTrue("the start is not after the due date", patched.contains("DTSTART;TZID=Europe/Amsterdam:20261105T090000"))
        assertFalse("DUE and DURATION exclude each other", patched.contains("DURATION"))
        assertEquals(LocalDate.parse("2026-11-05"), VTodo.read(patched, "p", amsterdam)?.task?.due)

        // A DATE start keeps the DATE due.
        val dateStart = vtodo("UID:y\nDTSTART;VALUE=DATE:20261101")
        val o2 = VTodo.read(dateStart, "p", amsterdam)!!
        val p2 = VTodo.patch(dateStart, o2, o2.task.copy(due = LocalDate.parse("2026-11-05")), null, null, amsterdam)!!
        assertTrue(p2.contains("DUE;VALUE=DATE:20261105"))
    }

    @Test fun overrideOnlyObjectIsNotATask() {
        val ics = vtodo("UID:x\nRECURRENCE-ID:20261101T090000Z\nSUMMARY:One occurrence")
        assertNull(VTodo.read(ics, "p"))
        val master = ics.replace("END:VCALENDAR", "BEGIN:VTODO\r\nUID:x\r\nSUMMARY:Series\r\nEND:VTODO\r\nEND:VCALENDAR")
        assertEquals("the master, not the override", "Series", VTodo.read(master, "p")?.task?.content)
    }

    @Test fun sectionParametersAreQuotedOnlyWhenNeeded() {
        val t = TodoTask(id = "t", projectId = "p", sectionId = "s", content = "x", order = 1.0, createdAt = 0, updatedAt = 0)
        assertTrue(VTodo.make(t, "t", null, Section("s", "p", "Garden", 1.0)).contains("X-TODOTIM-SECTION;X-NAME=Garden;X-ORDER=1:s"))
        val ics = VTodo.make(t, "t", null, Section("s", "p", "New \"quoted\"", 1.0))
        assertTrue(ics, ics.contains("X-NAME=New ^'quoted^';X-ORDER=1:s"))
        val crlf = VTodo.read(vtodo("UID:t\nX-TODOTIM-SECTION;X-NAME=a^nb:s").replace("^n", "\r"), "p")!!
        assertEquals("a\nb", crlf.sectionName)
    }
}
