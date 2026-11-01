package app.todotim.core.sync

import app.todotim.core.INBOX_ID
import app.todotim.core.Priority
import app.todotim.core.dav.CalendarHome
import app.todotim.core.dav.SyncError
import app.todotim.core.ical.ICalendar
import app.todotim.core.ical.VTodo
import app.todotim.core.store.Account
import app.todotim.core.store.TodoStore
import app.todotim.core.sync.FakeCalDAVServer.Companion.vtodo
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

class CalDAVSyncTest {
    private val utc = ZoneOffset.UTC
    private var now = T0
    private val store = TodoStore(clock = { now }, zone = utc)
    private val server = FakeCalDAVServer()
    private val inbox = server.addCalendar("todotim-inbox", "Inbox")
    private val work = server.addCalendar(
        "work", "Work", order = "2",
        sections = """[{"id":"s1","name":"Doing","order":1},{"id":"s2","name":"Done","order":2}]""",
    )

    private suspend fun sync(): SyncResult = CalDAVSync.sync(store, server, now, utc)

    private fun stamp(ms: Long) = ICalendar.utcString(ms)

    /** A task object as another client writes it. */
    private fun task(uid: String, summary: String, modified: Long = T0 - HOUR, vararg more: String) = vtodo(
        "UID:$uid", "SUMMARY:$summary", "CREATED:${stamp(T0 - DAY)}", "DTSTAMP:${stamp(modified)}",
        "LAST-MODIFIED:${stamp(modified)}", *more,
    )

    private fun put(calendar: String, uid: String, summary: String, vararg more: String, modified: Long = T0 - HOUR) =
        server.store("$calendar/$uid.ics", task(uid, summary, modified, *more))

    private fun line(ics: String, name: String): String? =
        ics.split("\r\n").firstOrNull { it.startsWith("$name:") || it.startsWith("$name;") }

    @Test fun firstSyncReadsListsSectionsLabelsAndTasks() = runTest {
        server.calendars.getValue(inbox).labels = """[{"color":"#DB4035","id":"l1","name":"home","order":1}]"""
        put(inbox, "a", "Milk", "CATEGORIES:home,errand")
        put(work, "b", "Report", "X-TODOTIM-SECTION;X-NAME=Doing;X-ORDER=1:s1", "PRIORITY:1")
        put(work, "c", "Draft", "RELATED-TO;RELTYPE=PARENT:b", "X-TODOTIM-SECTION;X-NAME=Doing;X-ORDER=1:s1")
        val result = sync()
        assertTrue(result.isComplete)
        assertEquals(3, result.downloaded)
        assertEquals(0, server.writes.size)
        val snap = store.snapshot.value
        assertEquals(listOf(INBOX_ID, "work"), snap.projects.map { it.id })
        assertEquals(listOf("Doing", "Done"), snap.sections("work").map { it.name })
        assertEquals(listOf("home", "errand"), snap.labels.map { it.name })
        assertEquals("red", snap.labels[0].color)
        assertEquals(listOf("b"), snap.taskIds("work", "s1"))
        assertEquals(listOf("c"), snap.subtaskIds("b"))
        assertEquals(Priority.P1, snap.task("b")!!.priority)
        assertEquals(0, snap.unsyncedCount)
        assertNotNull(snap.lastSyncAt)

        // An idle sync fetches nothing and writes nothing.
        server.changeRequests.clear()
        val idle = sync()
        assertTrue(idle.isComplete)
        assertEquals(emptyList<String>(), server.changeRequests)
        assertEquals(0, server.writes.size)
    }

    @Test fun sectionsComeFromTasksWithoutTheProperty() = runTest {
        val shared = server.addCalendar("shared", "Shared")
        put(shared, "a", "A", "X-TODOTIM-SECTION;X-NAME=First:sx")
        put(shared, "b", "B", "X-TODOTIM-SECTION;X-NAME=Second;X-ORDER=3:sx")
        sync()
        assertEquals(listOf("First"), store.snapshot.value.sections("shared").map { it.name })
    }

    @Test fun pullsEdits() = runTest {
        put(inbox, "a", "Milk")
        sync()
        server.edit("$inbox/a.ics") { it.replace("SUMMARY:Milk", "SUMMARY:Oat milk") }
        val r = sync()
        assertEquals(1, r.downloaded)
        assertEquals("Oat milk", store.snapshot.value.task("a")!!.content)
        assertEquals(0, server.writes.size)
    }

    @Test fun pushesEdits() = runTest {
        val etag = put(inbox, "a", "Milk")
        sync()
        now += HOUR
        store.updateTask("a") { copy(content = "Oat milk", due = LocalDate.of(2027, 2, 1)) }
        assertEquals(1, store.snapshot.value.unsyncedCount)
        val r = sync()
        assertTrue(r.isComplete)
        assertEquals(1, r.uploaded)
        assertEquals(listOf("PUT $inbox/a.ics"), server.writes)
        val ics = server.ics("$inbox/a.ics")!!
        assertEquals("SUMMARY:Oat milk", line(ics, "SUMMARY"))
        assertEquals("DUE;VALUE=DATE:20270201", line(ics, "DUE"))
        assertEquals("LAST-MODIFIED:${stamp(now)}", line(ics, "LAST-MODIFIED"))
        assertTrue(etag != store.database.value.shadows.getValue("a").etag)
        assertEquals(0, store.snapshot.value.unsyncedCount)
        server.writes.clear()
        sync()
        assertEquals(emptyList<String>(), server.writes)
    }

    @Test fun uploadsNewTaskAndSubtaskParentFirst() = runTest {
        sync()
        val child: String
        val parent = store.addTask("Trip", projectId = "work", sectionId = "s2").id
        child = store.addTask("Pack", parentId = parent).id
        // Created in this order on purpose: the child sorts first by id half the time.
        val r = sync()
        assertTrue(r.isComplete)
        assertEquals(listOf("PUT $work/$parent.ics", "PUT $work/$child.ics"), server.writes)
        val childIcs = server.ics("$work/$child.ics")!!
        assertEquals("RELATED-TO;RELTYPE=PARENT:$parent", line(childIcs, "RELATED-TO"))
        assertEquals("X-TODOTIM-SECTION;X-NAME=Done;X-ORDER=2:s2", line(childIcs, "X-TODOTIM-SECTION"))
        assertEquals(0, store.snapshot.value.unsyncedCount)
        server.writes.clear()
        sync()
        assertEquals(emptyList<String>(), server.writes)
    }

    @Test fun createsTheInboxWhenMissing() = runTest {
        server.calendars.remove(inbox)
        sync()
        val id = store.addTask("Milk").id
        val r = sync()
        assertTrue(r.isComplete)
        assertEquals(listOf("MKCALENDAR $inbox", "PUT $inbox/$id.ics"), server.writes)
        server.writes.clear()
        sync()
        assertEquals(emptyList<String>(), server.writes)
        assertEquals("Milk", store.snapshot.value.task(id)!!.content)
    }

    @Test fun deleteRetriesAfter412() = runTest {
        put(inbox, "a", "Milk")
        sync()
        now += HOUR
        store.delete("a")
        assertNull(store.snapshot.value.task("a"))
        // Another device edits the task (before the delete here) just before the DELETE arrives.
        var once = true
        server.beforeWrite = { method, path ->
            if (method == "DELETE" && once) {
                once = false
                server.edit(path) { it.replace("SUMMARY:Milk", "SUMMARY:Milk!") }
            }
        }
        val r = sync()
        assertTrue(r.isComplete)
        assertEquals(1, r.conflicts)
        assertEquals(listOf("DELETE $inbox/a.ics", "DELETE $inbox/a.ics"), server.writes)
        assertNull(server.ics("$inbox/a.ics"))
        assertNull(store.snapshot.value.task("a"))
        assertTrue(store.database.value.pendingDeletes.isEmpty())
    }

    @Test fun laterServerEditRevivesADeletedTask() = runTest {
        put(inbox, "a", "Milk")
        sync()
        store.delete("a")
        put(inbox, "a", "Milk today", modified = now + HOUR)
        val r = sync()
        assertTrue(r.isComplete)
        assertEquals("Milk today", store.snapshot.value.task("a")!!.content)
        assertEquals(emptyList<String>(), server.writes)
    }

    @Test fun concurrentEditsOfDifferentFieldsMerge() = runTest {
        put(inbox, "a", "Milk")
        sync()
        now += HOUR
        store.updateTask("a") { copy(content = "Oat milk") }
        put(inbox, "a", "Milk", "PRIORITY:1", modified = now + HOUR)
        val r = sync()
        assertTrue(r.isComplete)
        val t = store.snapshot.value.task("a")!!
        assertEquals("Oat milk", t.content)
        assertEquals(Priority.P1, t.priority)
        val ics = server.ics("$inbox/a.ics")!!
        assertEquals("SUMMARY:Oat milk", line(ics, "SUMMARY"))
        assertEquals("PRIORITY:1", line(ics, "PRIORITY"))
        // The written LAST-MODIFIED never goes back.
        assertEquals("LAST-MODIFIED:${stamp(now + HOUR)}", line(ics, "LAST-MODIFIED"))
    }

    @Test fun sameFieldIsLastWriterWins() = runTest {
        put(inbox, "a", "Milk")
        put(inbox, "b", "Bread")
        sync()
        now += HOUR
        store.updateTask("a") { copy(content = "Phone wins") }
        store.updateTask("b") { copy(content = "Phone loses") }
        put(inbox, "a", "Server loses", modified = now - MINUTE)
        put(inbox, "b", "Server wins", modified = now + MINUTE)
        sync()
        assertEquals("Phone wins", store.snapshot.value.task("a")!!.content)
        assertEquals("Server wins", store.snapshot.value.task("b")!!.content)
        assertEquals("SUMMARY:Phone wins", line(server.ics("$inbox/a.ics")!!, "SUMMARY"))
        assertEquals("SUMMARY:Server wins", line(server.ics("$inbox/b.ics")!!, "SUMMARY"))
        assertEquals(listOf("PUT $inbox/a.ics"), server.writes)
    }

    @Test fun completingAWeeklyTaskOnBothDevicesAdvancesOnce() = runTest {
        put(inbox, "w", "Bins", "DUE;VALUE=DATE:20270115", "RRULE:FREQ=WEEKLY;COUNT=5")
        sync()
        now += HOUR
        store.complete("w")
        val local = store.snapshot.value.task("w")!!
        assertEquals(LocalDate.of(2027, 1, 22), local.due)
        assertEquals("FREQ=WEEKLY;COUNT=4", local.recurrence)
        // The Mac completes it too, before the phone syncs.
        put(inbox, "w", "Bins", "DUE;VALUE=DATE:20270122", "RRULE:FREQ=WEEKLY;COUNT=4", modified = now + MINUTE)
        val r = sync()
        assertTrue(r.isComplete)
        assertEquals(emptyList<String>(), server.writes)
        val t = store.snapshot.value.task("w")!!
        assertEquals(LocalDate.of(2027, 1, 22), t.due)
        assertEquals("FREQ=WEEKLY;COUNT=4", t.recurrence)
        assertFalse(t.isCompleted)
        assertEquals(0, store.snapshot.value.unsyncedCount)
    }

    @Test fun serverDeleteDropsLocalEdits() = runTest {
        put(inbox, "a", "Milk")
        sync()
        store.updateTask("a") { copy(content = "Oat milk") }
        server.remove("$inbox/a.ics")
        val r = sync()
        assertTrue(r.isComplete)
        assertEquals(1, r.removed)
        assertNull(store.snapshot.value.task("a"))
        assertEquals(emptyList<String>(), server.writes)
        assertNull(server.ics("$inbox/a.ics"))
    }

    @Test fun deletedCalendarDropsItsTasks() = runTest {
        put(work, "a", "Report")
        sync()
        server.calendars.remove(work)
        sync()
        assertNull(store.snapshot.value.task("a"))
        assertNull(store.snapshot.value.project("work"))
    }

    @Test fun unreadableObjectIsKeptAndNotWritten() = runTest {
        put(inbox, "a", "Milk")
        sync()
        server.store("$inbox/a.ics", "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nSUMMARY:no uid\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        store.updateTask("a") { copy(content = "Oat milk") }
        val r = sync()
        assertTrue(r.isComplete)
        assertEquals(emptyList<String>(), server.writes)
        assertEquals("Oat milk", store.snapshot.value.task("a")!!.content)
        // Readable again: merged and written.
        now += HOUR
        put(inbox, "a", "Milk", "PRIORITY:1", modified = now - MINUTE)
        sync()
        val t = store.snapshot.value.task("a")!!
        assertEquals("Oat milk", t.content)
        assertEquals(Priority.P1, t.priority)
        assertEquals(listOf("PUT $inbox/a.ics"), server.writes)
    }

    @Test fun foreignPropertiesSurviveAPhoneEdit() = runTest {
        val alarm = "BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n"
        val original = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Other//EN\r\nBEGIN:VTODO\r\nUID:a\r\n" +
            "SUMMARY:Milk\r\nCREATED:${stamp(T0 - DAY)}\r\nDTSTAMP:${stamp(T0 - HOUR)}\r\n" +
            "LAST-MODIFIED:${stamp(T0 - HOUR)}\r\nX-FOO;X-LIST=\"a,b\":keep me\r\nGEO:52.1;4.3\r\n" +
            "DTSTART;TZID=Europe/Amsterdam:20270110T090000\r\n" + alarm + "END:VTODO\r\nEND:VCALENDAR\r\n"
        server.store("$inbox/a.ics", original)
        sync()
        now += HOUR
        store.updateTask("a") { copy(content = "Oat milk") }
        sync()
        val written = server.ics("$inbox/a.ics")!!
        fun owned(l: String) = l.startsWith("SUMMARY") || l.startsWith("DTSTAMP") || l.startsWith("LAST-MODIFIED")
        assertEquals(original.split("\r\n").filterNot(::owned), written.split("\r\n").filterNot(::owned))
        assertEquals("SUMMARY:Oat milk", line(written, "SUMMARY"))
    }

    @Test fun subtasksFollowTheirRootsSection() = runTest {
        put(work, "p", "Parent", "X-TODOTIM-SECTION;X-NAME=Doing;X-ORDER=1:s1")
        put(work, "c", "Child", "RELATED-TO;RELTYPE=PARENT:p", "X-TODOTIM-SECTION;X-NAME=Doing;X-ORDER=1:s1")
        put(work, "g", "Grandchild", "RELATED-TO;RELTYPE=PARENT:c", "X-TODOTIM-SECTION;X-NAME=Doing;X-ORDER=1:s1")
        sync()
        now += HOUR
        store.moveTask("p", "work", sectionId = "s2")
        sync()
        for (id in listOf("p", "c", "g")) {
            assertEquals("X-TODOTIM-SECTION;X-NAME=Done;X-ORDER=2:s2", line(server.ics("$work/$id.ics")!!, "X-TODOTIM-SECTION"))
        }
        assertEquals("RELATED-TO;RELTYPE=PARENT:p", line(server.ics("$work/c.ics")!!, "RELATED-TO"))
    }

    @Test fun movingToAnotherListMovesThenPatches() = runTest {
        put(inbox, "a", "Milk")
        put(inbox, "b", "Sub", "RELATED-TO;RELTYPE=PARENT:a")
        sync()
        now += HOUR
        store.moveTask("a", "work", sectionId = "s1")
        val r = sync()
        assertTrue(r.isComplete)
        assertTrue(server.writes.containsAll(listOf("MOVE $inbox/a.ics $work/a.ics", "PUT $work/a.ics", "MOVE $inbox/b.ics $work/b.ics", "PUT $work/b.ics")))
        assertNull(server.ics("$inbox/a.ics"))
        assertEquals("X-TODOTIM-SECTION;X-NAME=Doing;X-ORDER=1:s1", line(server.ics("$work/b.ics")!!, "X-TODOTIM-SECTION"))
        server.writes.clear()
        sync()
        assertEquals(emptyList<String>(), server.writes)
        assertEquals(listOf("b"), store.snapshot.value.subtaskIds("a"))
        assertEquals("work", store.snapshot.value.task("b")!!.projectId)
    }

    @Test fun anotherClientsMoveIsFollowed() = runTest {
        put(inbox, "a", "Milk")
        sync()
        store.updateTask("a") { copy(priority = Priority.P2) }
        val ics = server.ics("$inbox/a.ics")!!
        server.remove("$inbox/a.ics")
        server.store("$work/a.ics", ics)
        sync()
        val t = store.snapshot.value.task("a")!!
        assertEquals("work", t.projectId)
        assertEquals(Priority.P2, t.priority)
        assertEquals(listOf("PUT $work/a.ics"), server.writes)
    }

    @Test fun editsDuringASyncAreKept() = runTest {
        put(inbox, "a", "Milk")
        put(inbox, "b", "Bread")
        put(inbox, "c", "Eggs")
        sync()
        now += HOUR
        store.updateTask("a") { copy(content = "Oat milk") }
        var added: String? = null
        server.beforeWrite = { _, _ ->
            server.beforeWrite = null
            now += MINUTE
            // While the PUT of "a" is on its way: edit "a" again, edit "b", delete "c", add a task.
            store.updateTask("a") { copy(priority = Priority.P1) }
            store.updateTask("b") { copy(content = "Rye bread") }
            store.delete("c")
            added = store.addTask("Butter").id
        }
        sync()
        val snap = store.snapshot.value
        assertEquals("Oat milk", snap.task("a")!!.content)
        assertEquals(Priority.P1, snap.task("a")!!.priority)
        assertEquals("Rye bread", snap.task("b")!!.content)
        assertNull(snap.task("c"))
        assertNotNull(snap.task(added!!))
        assertEquals(4, snap.unsyncedCount)
        sync()
        assertEquals("PRIORITY:1", line(server.ics("$inbox/a.ics")!!, "PRIORITY"))
        assertEquals("SUMMARY:Rye bread", line(server.ics("$inbox/b.ics")!!, "SUMMARY"))
        assertNull(server.ics("$inbox/c.ics"))
        assertNotNull(server.ics("$inbox/$added.ics"))
        assertEquals(0, store.snapshot.value.unsyncedCount)
    }

    @Test fun putWithoutETagRereadsTheCalendar() = runTest {
        server.reportETags = false
        put(inbox, "a", "Milk")
        sync()
        now += HOUR
        store.updateTask("a") { copy(content = "Oat milk") }
        sync()
        assertNull(store.database.value.shadows.getValue("a").etag)
        sync()
        assertNotNull(store.database.value.shadows.getValue("a").etag)
        assertEquals("Oat milk", store.snapshot.value.task("a")!!.content)
        assertEquals(0, store.snapshot.value.unsyncedCount)
    }

    @Test fun refusedWriteIsReportedAndRetried() = runTest {
        put(inbox, "a", "Milk")
        sync()
        store.updateTask("a") { copy(content = "Oat milk") }
        server.forbidden.add("$inbox/a.ics")
        val r = sync()
        assertFalse(r.isComplete)
        assertEquals(1, r.warnings.size)
        server.forbidden.clear()
        assertTrue(sync().isComplete)
        assertEquals("SUMMARY:Oat milk", line(server.ics("$inbox/a.ics")!!, "SUMMARY"))
    }

    @Test fun persistentConflictsStopAfterThreePasses() = runTest {
        put(inbox, "a", "Milk")
        sync()
        store.updateTask("a") { copy(content = "Oat milk") }
        server.beforeWrite = { _, path -> server.edit(path) { it.replace("PRODID:-//Other//EN", "PRODID:-//Other//EN ") } }
        val r = sync()
        assertFalse(r.isComplete)
        assertEquals(3, r.conflicts)
        assertTrue(r.warnings.contains(SyncError.TooManyConflicts.message))
    }

    @Test fun derivedIdsKeepTheOriginalUid() = runTest {
        server.store("$inbox/x.ics", task("weird uid@host", "Parent"))
        sync()
        val id = VTodo.taskId("weird uid@host")
        val child = store.addTask("Child", parentId = id).id
        sync()
        assertEquals("RELATED-TO;RELTYPE=PARENT:weird uid@host", line(server.ics("$inbox/$child.ics")!!, "RELATED-TO"))
    }

    @Test fun controllerRediscoversWhenTheHomeIsGone() = runTest {
        put(inbox, "a", "Milk")
        val stale = FakeCalDAVServer("calendars/old")
        val homes = mutableListOf<CalendarHome?>()
        val controller = SyncController(store, zone = utc) { _, _, home ->
            homes.add(home)
            if (home == null) server else object : app.todotim.core.dav.CalDAVServer by stale {
                override suspend fun calendars() = throw SyncError.NotFound(stale.home)
            }
        }
        val settings = SyncSettings("https://dav.example.com/", "tim")
        controller.syncNow(settings, "pw")
        assertEquals(listOf<CalendarHome?>(null), homes)
        assertEquals(server.calendarHome, store.database.value.home)
        // The cached home now answers 404: discover again.
        store.setHome(stale.calendarHome)
        val r = controller.syncNow(settings, "pw")
        assertTrue(r.isComplete)
        assertEquals(listOf(null, stale.calendarHome, null), homes)
        assertEquals(server.calendarHome, store.database.value.home)
        assertEquals("Milk", store.snapshot.value.task("a")!!.content)
    }

    @Test fun anotherAccountStartsFresh() = runTest {
        put(inbox, "a", "Milk")
        val controller = SyncController(store, zone = utc) { _, _, _ -> server }
        controller.syncNow(SyncSettings("https://dav.example.com/", "tim"), "pw")
        val unsynced = store.addTask("Local").id
        val other = FakeCalDAVServer()
        other.addCalendar("todotim-inbox", "Inbox")
        val controller2 = SyncController(store, zone = utc) { _, _, _ -> other }
        controller2.syncNow(SyncSettings("https://dav.example.com/", "anna"), "pw")
        assertEquals(Account("https://dav.example.com/", "anna"), store.database.value.account)
        assertNull(store.snapshot.value.task("a"))
        assertNotNull(other.ics("${other.home}/todotim-inbox/$unsynced.ics"))
    }

    @Test fun aChangedHomeMatchesByIdAndDeletesNothing() = runTest {
        store.setHome(server.calendarHome)
        put(inbox, "a", "Milk")
        put(work, "b", "Report")
        put(inbox, "c", "Bread")
        sync()
        now += HOUR
        store.updateTask("a") { copy(content = "Oat milk") }
        store.delete("c")
        // The account's home moved: the new one has "a" (older) and "c", but not "b".
        val moved = FakeCalDAVServer("calendars/new")
        val newInbox = moved.addCalendar("todotim-inbox", "Inbox")
        val newWork = moved.addCalendar("work", "Work")
        moved.store("$newInbox/a.ics", task("a", "Milk"))
        moved.store("$newInbox/c.ics", task("c", "Bread"))
        store.setHome(moved.calendarHome)
        val r = CalDAVSync.sync(store, moved, now, utc)
        assertTrue(r.isComplete)
        assertEquals(0, r.removed)
        val snap = store.snapshot.value
        assertEquals("Oat milk", snap.task("a")!!.content)
        assertEquals("Report", snap.task("b")!!.content)
        assertEquals("SUMMARY:Oat milk", line(moved.ics("$newInbox/a.ics")!!, "SUMMARY"))
        assertEquals("SUMMARY:Report", line(moved.ics("$newWork/b.ics")!!, "SUMMARY"))
        // The delete was meant for the old home.
        assertTrue(moved.writes.none { it.startsWith("DELETE") })
        assertNotNull(moved.ics("$newInbox/c.ics"))
        assertEquals(0, snap.unsyncedCount)
        assertTrue(store.database.value.shadows.values.all { it.path.startsWith(moved.home) })
        // The old server was not touched.
        assertEquals(emptyList<String>(), server.writes)
    }

    @Test fun aDeleteRightAfterAnEditInTheSameSecondStaysDeleted() = runTest {
        put(inbox, "a", "Milk")
        now = T0
        sync()
        now = T0 + 100
        store.updateTask("a") { copy(content = "Oat milk") }
        sync()
        now = T0 + 150
        store.updateTask("a") { copy(content = "Oat milk!") }
        sync() // uploads LAST-MODIFIED of the next second
        now = T0 + 200
        store.delete("a")
        val r = sync()
        assertTrue(r.isComplete)
        assertNull(store.snapshot.value.task("a"))
        assertNull(server.ics("$inbox/a.ics"))
    }

    @Test fun anOverlongTitleIsUploadedOnce() = runTest {
        put(inbox, "a", "Milk")
        sync()
        now += HOUR
        store.updateTask("a") { copy(content = "x".repeat(app.todotim.core.SyncLimits.MAX_CONTENT_LENGTH + 10)) }
        sync()
        server.writes.clear()
        val r = sync()
        assertEquals(0, r.uploaded)
        assertEquals(emptyList<String>(), server.writes)
        assertEquals(0, store.snapshot.value.unsyncedCount)
    }

    companion object {
        const val T0 = 1_800_000_000_000L // 2027-01-15T08:00:00Z
        const val MINUTE = 60_000L
        const val HOUR = 3_600_000L
        const val DAY = 24 * HOUR
    }
}
