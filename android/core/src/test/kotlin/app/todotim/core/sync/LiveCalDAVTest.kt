package app.todotim.core.sync

import app.todotim.core.INBOX_CALENDAR
import app.todotim.core.INBOX_ID
import app.todotim.core.Priority
import app.todotim.core.ProjectColor
import app.todotim.core.dav.CalDAVClient
import app.todotim.core.dav.CalDAVServer
import app.todotim.core.dav.CalendarProperty
import app.todotim.core.dav.davPath
import app.todotim.core.store.TodoStore
import app.todotim.core.sync.LiveServer.obj
import app.todotim.core.sync.LiveServer.unfold
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.LocalDate

/**
 * Phone sync against a real CalDAV server (Radicale, Nextcloud, …), found by discovery. Opt-in, and destructive for
 * the account's task lists: use a throwaway user. Mirrors the Swift `LiveCalDAVTests` within the phone's scope (the
 * phone does not create lists or sections, so the test makes the list itself).
 *
 *     TODOTIM_LIVE_URL=http://localhost:5232/ TODOTIM_LIVE_USER=tim TODOTIM_LIVE_PASSWORD=secret \
 *       ./gradlew :core:test --tests app.todotim.core.sync.LiveCalDAVTest
 */
class LiveCalDAVTest {
    private lateinit var client: CalDAVClient

    @Before fun setUp() = runBlocking {
        client = LiveServer.connect()
        LiveServer.wipe(client)
    }

    @After fun tearDown() = runBlocking {
        if (::client.isInitialized) LiveServer.wipe(client)
    }

    /** One phone; [offset] shifts its clock, so last-writer-wins has a clear winner. */
    private class Phone(var offset: Long = 0) {
        val store = TodoStore(clock = { System.currentTimeMillis() + offset })
        suspend fun sync(server: CalDAVServer): SyncResult = CalDAVSync.sync(store, server)
        fun task(id: String) = store.snapshot.value.task(id)
    }

    @Test fun phoneRoundTrip() = runBlocking {
        val home = client.home
        val work = "live-work"
        val workPath = davPath(home, work)
        val inboxPath = davPath(home, INBOX_CALENDAR)
        client.createCalendar(workPath, "Work", ProjectColor.hex("green"), "1")
        val sectionsJSON = """[{"id":"sec-doing","name":"Doing \"now\"","order":1}]"""
        val hasSections = CalendarProperty.SECTIONS !in client.setProperties(workPath, mapOf(CalendarProperty.SECTIONS to sectionsJSON))

        // 1. A phone reads the list (and its section).
        val a = Phone()
        assertTrue(a.sync(client).isComplete)
        val snap = a.store.snapshot.value
        assertEquals("Work", snap.project(work)?.name)
        assertEquals("green", snap.project(work)?.color)
        if (hasSections) assertEquals(listOf("Doing \"now\""), snap.sections(work).map { it.name })

        // 2. New tasks: in the inbox (which the phone creates), in a section, a subtask, a repeating one.
        val s = a.store
        val mum = s.addTask("Call mum", INBOX_ID, priority = Priority.P2)
        val report = s.addTask(
            "Report; draft", work, sectionId = if (hasSections) "sec-doing" else null, due = LocalDate.of(2026, 11, 3),
            priority = Priority.P1, labels = listOf("outside", "weekend"), description = "Line 1\nLine 2",
        )
        val shears = s.addTask("Buy shears", work, parentId = report.id, priority = Priority.P3)
        val water = s.addTask("Water plants", work, due = LocalDate.of(2026, 11, 2), recurrence = "FREQ=WEEKLY;COUNT=5")
        val first = a.sync(client)
        assertTrue(first.warnings.toString(), first.isComplete)
        assertEquals(4, first.uploaded)
        assertNotNull(client.calendars().firstOrNull { it.path == inboxPath })
        val reportICS = unfold(obj(client, "$workPath/${report.id}.ics")!!.ics)
        assertTrue(reportICS, reportICS.contains("SUMMARY:Report\\; draft"))
        assertTrue(reportICS.contains("PRIORITY:1"))
        assertTrue(reportICS.contains("DUE;VALUE=DATE:20261103"))
        assertTrue(reportICS.contains("CATEGORIES:outside,weekend"))
        assertTrue(reportICS.contains("DESCRIPTION:Line 1\\nLine 2"))
        val shearsICS = unfold(obj(client, "$workPath/${shears.id}.ics")!!.ics)
        assertTrue(shearsICS, shearsICS.contains("RELATED-TO;RELTYPE=PARENT:${report.id}"))
        if (hasSections) {
            assertTrue(reportICS, reportICS.contains("X-TODOTIM-SECTION;X-NAME=Doing ^'now^';X-ORDER=1:sec-doing"))
            assertTrue(shearsICS, shearsICS.contains("X-TODOTIM-SECTION;X-NAME=Doing ^'now^';X-ORDER=1:sec-doing"))
        }
        assertNotNull(obj(client, "$inboxPath/${mum.id}.ics"))

        // 3. The next sync fetches its own writes and takes nothing from them, writes nothing; then it is idle:
        //    nothing fetched, nothing written.
        val second = Recording(client)
        val r = a.sync(second)
        assertTrue(r.isComplete)
        assertEquals(0, r.uploaded)
        assertEquals(0, r.downloaded)
        assertEquals(emptyList<String>(), second.writes)
        val idle = Recording(client)
        assertEquals(0, a.sync(idle).uploaded)
        assertEquals(emptyList<String>(), idle.writes)
        assertEquals(0, idle.changeRequests)

        // 4. A second phone gets the same tasks.
        val b = Phone(offset = 5_000)
        assertTrue(b.sync(client).isComplete)
        assertEquals(a.store.database.value.tasks, b.store.database.value.tasks)
        assertEquals(a.store.snapshot.value.sections(work), b.store.snapshot.value.sections(work))
        assertEquals(a.store.snapshot.value.labels.map { it.name }.sorted(), listOf("outside", "weekend"))

        // 5. Edits of different fields on both phones merge.
        a.store.updateTask(mum.id) { copy(priority = Priority.P1) }
        b.store.updateTask(mum.id) { copy(description = "About the weekend") }
        assertTrue(a.sync(client).isComplete)
        assertTrue(b.sync(client).isComplete)
        assertTrue(a.sync(client).isComplete)
        for (p in listOf(a, b)) {
            assertEquals(Priority.P1, p.task(mum.id)!!.priority)
            assertEquals("About the weekend", p.task(mum.id)!!.description)
        }

        // 6. Conflict: phone A writes between B's listing and B's PUT. The server answers B's PUT with 412; B's next
        //    pass fetches A's version and merges (B's edit is later, so it wins).
        val mumPath = "$inboxPath/${mum.id}.ics"
        b.offset += 60_000
        a.store.updateTask(mum.id) { copy(content = "Call mum (a)") }
        b.store.updateTask(mum.id) { copy(content = "Call mum (b)") }
        val racing = Recording(client)
        racing.beforePut[mumPath] = { assertTrue(a.sync(client).isComplete) }
        val raced = b.sync(racing)
        assertTrue(raced.warnings.toString(), raced.isComplete)
        assertEquals(1, raced.conflicts)
        assertEquals(racing.writes.toString(), 2, racing.writes.count { it == "PUT $mumPath" })
        assertTrue(unfold(obj(client, mumPath)!!.ics).contains("SUMMARY:Call mum (b)"))
        a.sync(client)
        assertEquals("Call mum (b)", a.task(mum.id)!!.content)
        assertEquals(Priority.P1, a.task(mum.id)!!.priority)

        // 7. Completing: a repeating task moves on, a subtask is completed.
        b.store.complete(water.id)
        a.store.complete(shears.id)
        assertTrue(b.sync(client).isComplete)
        assertTrue(a.sync(client).isComplete)
        assertTrue(b.sync(client).isComplete)
        val waterICS = unfold(obj(client, "$workPath/${water.id}.ics")!!.ics)
        assertTrue(waterICS, waterICS.contains("DUE;VALUE=DATE:20261109"))
        assertTrue(waterICS, waterICS.contains("RRULE:FREQ=WEEKLY;COUNT=4"))
        assertFalse(waterICS.contains("STATUS:COMPLETED"))
        assertTrue(unfold(obj(client, "$workPath/${shears.id}.ics")!!.ics).contains("STATUS:COMPLETED"))
        for (p in listOf(a, b)) {
            assertEquals(LocalDate.of(2026, 11, 9), p.task(water.id)!!.due)
            assertTrue(p.task(shears.id)!!.isCompleted)
        }

        // 8. Moving a task to another list (DAV MOVE), into a section.
        b.store.moveTask(mum.id, work, if (hasSections) "sec-doing" else null)
        val moving = Recording(client)
        assertTrue(b.sync(moving).isComplete)
        assertTrue(moving.writes.toString(), moving.writes.any { it.startsWith("MOVE $mumPath") })
        assertNull(obj(client, mumPath))
        val movedICS = unfold(obj(client, "$workPath/${mum.id}.ics")!!.ics)
        assertTrue(movedICS.contains("SUMMARY:Call mum (b)"))
        if (hasSections) assertTrue(movedICS, movedICS.contains("X-TODOTIM-SECTION;X-NAME=Doing ^'now^';X-ORDER=1:sec-doing"))
        a.sync(client)
        assertEquals(work, a.task(mum.id)!!.projectId)

        // 9. Another client edits a task and adds an alarm and its own property; the phone picks up the edit, and its
        //    own later edit keeps both.
        val movedPath = "$workPath/${mum.id}.ics"
        val current = obj(client, movedPath)!!
        val foreign = current.ics
            .replace(Regex("SUMMARY:[^\r\n]*"), "SUMMARY:Call mum (elsewhere)")
            .replace("END:VTODO", "X-OTHER;X-P=\"a,b\":keep\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:x\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VTODO")
            .replace(Regex("LAST-MODIFIED:\\d{8}T\\d{6}Z"), "LAST-MODIFIED:${app.todotim.core.ical.ICalendar.utcString(System.currentTimeMillis() + 120_000)}")
        client.put(movedPath, foreign, current.etag)
        a.sync(client)
        assertEquals("Call mum (elsewhere)", a.task(mum.id)!!.content)
        a.offset += 180_000
        a.store.updateTask(mum.id) { copy(priority = Priority.P3) }
        assertTrue(a.sync(client).isComplete)
        val kept = unfold(obj(client, movedPath)!!.ics)
        assertTrue(kept, kept.contains("TRIGGER:-PT15M"))
        assertTrue(kept, kept.contains("X-OTHER;X-P=\"a,b\":keep"))
        assertTrue(kept, kept.contains("PRIORITY:9"))
        assertTrue(kept, kept.contains("SUMMARY:Call mum (elsewhere)"))

        // 10. A repeating task with a time from another client: completing it on the phone moves DUE and DTSTART by
        //     the same number of days and keeps the time.
        val rid = "repeat-live"
        val repeating = listOf(
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Other//EN", "BEGIN:VTODO", "UID:$rid", "DTSTAMP:20261020T100000Z",
            "SUMMARY:Pills", "DTSTART:20261101T070000Z", "DUE:20261101T080000Z", "RRULE:FREQ=DAILY;INTERVAL=2", "END:VTODO",
            "END:VCALENDAR", "",
        ).joinToString("\r\n")
        client.put("$workPath/$rid.ics", repeating, null)
        b.sync(client)
        b.store.complete(rid)
        assertTrue(b.sync(client).isComplete)
        val advanced = unfold(obj(client, "$workPath/$rid.ics")!!.ics)
        assertTrue(advanced, advanced.contains("DUE:20261103T080000Z"))
        assertTrue(advanced, advanced.contains("DTSTART:20261103T070000Z"))
        assertFalse(advanced.contains("STATUS:COMPLETED"))
        a.sync(client)
        assertEquals(b.task(rid)!!.due, a.task(rid)!!.due)

        // 11. Another client deletes a task the phone edited: the server's delete wins (the phone's model).
        b.store.updateTask(rid) { copy(content = "Pills (b)") }
        client.delete("$workPath/$rid.ics", null)
        assertTrue(b.sync(client).isComplete)
        assertNull(b.task(rid))
        assertNull(obj(client, "$workPath/$rid.ics"))
        a.sync(client)
        assertNull(a.task(rid))

        // 12. Deleting a task deletes its subtask too.
        a.store.delete(report.id)
        assertTrue(a.sync(client).isComplete)
        assertNull(obj(client, "$workPath/${report.id}.ics"))
        assertNull(obj(client, "$workPath/${shears.id}.ics"))
        b.sync(client)
        assertNull(b.task(report.id))
        assertNull(b.task(shears.id))

        // 13. Converged, and idle on both.
        assertEquals(a.store.database.value.tasks, b.store.database.value.tasks)
        for (p in listOf(a, b)) {
            for (i in 1..2) {
                val rec = Recording(client)
                val res = p.sync(rec)
                assertEquals(0, res.uploaded)
                assertEquals(0, res.downloaded)
                assertEquals(emptyList<String>(), rec.writes)
                if (i == 2) assertEquals(0, rec.changeRequests)
            }
            assertEquals(0, p.store.snapshot.value.unsyncedCount)
        }
    }
}
