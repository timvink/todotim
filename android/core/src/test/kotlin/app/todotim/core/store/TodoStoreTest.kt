package app.todotim.core.store

import app.todotim.core.INBOX_ID
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.TodoTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

class TodoStoreTest {
    private var now = 1_800_000_000_000L
    private val base = Database(
        projects = mapOf(
            INBOX_ID to Database.defaultInbox(),
            "work" to Project("work", "Work", order = 1.0),
        ),
        sections = mapOf("s1" to Section("s1", "work", "Doing", 1.0), "s2" to Section("s2", "work", "Done", 2.0)),
    )
    private val store = TodoStore(base, clock = { now }, zone = ZoneOffset.UTC)
    private val snap get() = store.snapshot.value

    private fun shadowOf(t: TodoTask) = Shadow("cal/${t.id}.ics", "\"1\"", "", t, t.id)

    @Test fun addsAtTheEndAndSubtasksTakeTheRootsPlace() {
        val a = store.addTask("A", projectId = "work", sectionId = "s1")
        val b = store.addTask("B", projectId = "work", sectionId = "s1")
        assertEquals(listOf(a.id, b.id), snap.taskIds("work", "s1"))
        assertEquals(2.0, b.order, 0.0)
        val c = store.addTask("C", parentId = a.id)
        val d = store.addTask("D", parentId = c.id)
        assertEquals("work", d.projectId)
        assertEquals("s1", d.sectionId)
        assertEquals(listOf(c.id), snap.subtaskIds(a.id))
        val unknown = store.addTask("E", projectId = "nope", sectionId = "s1")
        assertEquals(INBOX_ID, unknown.projectId)
        assertNull(unknown.sectionId)
    }

    @Test fun updateKeepsStructureAndBumpsUpdatedAt() {
        val a = store.addTask("A", projectId = "work")
        now += 10
        assertTrue(store.updateTask(a.id) { copy(content = "A2", projectId = INBOX_ID) })
        val t = snap.task(a.id)!!
        assertEquals("A2", t.content)
        assertEquals("work", t.projectId)
        // At least the next whole second, so LAST-MODIFIED moves forward.
        assertEquals(now - 10 + 1000, t.updatedAt)
        assertFalse(store.updateTask(a.id) { copy() })
    }

    @Test fun completeCascadesAndReopenWalksUp() {
        val p = store.addTask("P")
        val c = store.addTask("C", parentId = p.id)
        val g = store.addTask("G", parentId = c.id)
        store.complete(p.id)
        assertTrue(listOf(p, c, g).all { snap.task(it.id)!!.isCompleted })
        assertEquals(now, snap.task(g.id)!!.completedAt)
        store.reopen(g.id)
        assertTrue(listOf(p, c, g).none { snap.task(it.id)!!.isCompleted })
        store.complete(c.id)
        store.reopen(c.id)
        assertTrue(snap.task(g.id)!!.isCompleted) // subtasks stay completed
        assertEquals(2, snap.openCount(INBOX_ID))
    }

    @Test fun completingARepeatingTaskAdvancesIt() {
        val a = store.addTask("Bins", due = LocalDate.of(2027, 1, 31), recurrence = "FREQ=MONTHLY")
        val sub = store.addTask("Bag", parentId = a.id)
        store.complete(a.id)
        val t = snap.task(a.id)!!
        assertFalse(t.isCompleted)
        assertEquals(LocalDate.of(2027, 3, 31), t.due)
        assertFalse(snap.task(sub.id)!!.isCompleted)
        // Without a due date: counted from today.
        val b = store.addTask("Water", recurrence = "FREQ=DAILY")
        store.complete(b.id, today = LocalDate.of(2027, 5, 1))
        assertEquals(LocalDate.of(2027, 5, 2), snap.task(b.id)!!.due)
        // The last occurrence completes it.
        val c = store.addTask("Once", due = LocalDate.of(2027, 1, 1), recurrence = "FREQ=DAILY;COUNT=1")
        store.complete(c.id)
        assertTrue(snap.task(c.id)!!.isCompleted)
    }

    @Test fun deleteCascadesAndQueuesServerDeletes() {
        val p = store.addTask("P")
        val c = store.addTask("C", parentId = p.id)
        val g = store.addTask("G", parentId = c.id)
        val other = store.addTask("Other")
        // Pretend p and c were synced.
        val db = store.database.value
        store.applySync(db, db.copy(shadows = mapOf(p.id to shadowOf(p), c.id to shadowOf(c))))
        store.delete(p.id)
        assertNull(snap.task(p.id)); assertNull(snap.task(c.id)); assertNull(snap.task(g.id))
        assertEquals(setOf(p.id, c.id), store.database.value.pendingDeletes.keys)
        assertEquals("cal/${p.id}.ics", store.database.value.pendingDeletes.getValue(p.id).path)
        assertTrue(store.database.value.shadows.isEmpty())
        assertEquals(listOf(other.id), snap.taskIds(INBOX_ID, null))
        assertEquals(3, snap.unsyncedCount) // two deletes and the never-synced "Other"
    }

    @Test fun moveCarriesSubtasksAndRefusesCycles() {
        val p = store.addTask("P")
        val c = store.addTask("C", parentId = p.id)
        val g = store.addTask("G", parentId = c.id)
        store.moveTask(p.id, "work", sectionId = "s2")
        for (id in listOf(p.id, c.id, g.id)) {
            assertEquals("work", store.database.value.tasks.getValue(id).projectId)
            assertEquals("s2", store.database.value.tasks.getValue(id).sectionId)
        }
        store.moveTask(p.id, "work", parentId = g.id)
        assertNull(store.database.value.tasks.getValue(p.id).parentId)
        // Indent under another task: takes its place.
        val q = store.addTask("Q", projectId = "work", sectionId = "s1")
        store.moveTask(p.id, INBOX_ID, parentId = q.id)
        assertEquals("s1", store.database.value.tasks.getValue(g.id).sectionId)
        assertEquals(listOf(p.id), snap.subtaskIds(q.id))
    }

    @Test fun reorderTakesMidpointsAndRenumbers() {
        val a = store.addTask("A"); val b = store.addTask("B"); val c = store.addTask("C")
        store.reorder(c.id, a.id)
        assertEquals(listOf(a.id, c.id, b.id), snap.taskIds(INBOX_ID, null))
        assertEquals(1.5, snap.task(c.id)!!.order, 0.0)
        store.reorder(b.id, null)
        assertEquals(listOf(b.id, a.id, c.id), snap.taskIds(INBOX_ID, null))
        // Squeeze until the gap is used up: siblings get renumbered and the order stays right.
        repeat(80) {
            val ids = snap.taskIds(INBOX_ID, null)
            store.reorder(ids.last(), ids[0])
        }
        val ids = snap.taskIds(INBOX_ID, null)
        assertEquals(3, ids.size)
        val orders = ids.map { snap.task(it)!!.order }
        assertEquals(orders.sorted(), orders)
        assertEquals(orders.toSet().size, 3)
        // Added after a sibling.
        val d = store.addTask("D", afterId = ids[0])
        assertEquals(d.id, snap.taskIds(INBOX_ID, null)[1])
    }

    @Test fun snapshotRepairsStructureWithoutChangingTheDatabase() {
        fun t(id: String, parent: String? = null, project: String = "work", section: String? = null, order: Double = 1.0) =
            TodoTask(id, project, section, parent, id, order = order, createdAt = 0, updatedAt = 0)
        val tasks = listOf(
            t("orphan", parent = "missing"),
            t("x", parent = "y"), t("y", parent = "x"), // a cycle
            t("lost", section = "unknown"),
            t("root", section = "s1"), t("kid", parent = "root", section = "s2"),
            t("elsewhere", parent = "root", project = INBOX_ID),
            t("stray", project = "gone"),
        ) + (0 until 40).map { t("d$it", parent = if (it == 0) null else "d${it - 1}") }
        val db = base.copy(tasks = tasks.associateBy { it.id })
        val s = Snapshot.build(db, 1)
        assertNull(s.task("orphan")!!.parentId)
        assertTrue(s.taskIds("work", null).containsAll(listOf("orphan", "lost", "x")))
        assertEquals(listOf("y"), s.subtaskIds("x"))
        assertEquals("s1", s.task("kid")!!.sectionId)
        assertNull(s.task("elsewhere")!!.parentId)
        assertEquals(INBOX_ID, s.task("stray")!!.projectId)
        assertNull(s.task("d32")!!.parentId) // 33rd level
        assertEquals("d30", s.task("d31")!!.parentId)
        assertEquals("missing", db.tasks.getValue("orphan").parentId)
        assertEquals(31, s.descendantIds("d0").size)
        assertEquals(7, s.descendantIds("d32").size)
    }

    @Test fun editsDuringASyncAreRebased() {
        val a = store.addTask("A")
        val b = store.addTask("B")
        val before = store.database.value
        now += 5000
        store.updateTask(a.id) { copy(content = "A local") }
        store.delete(b.id)
        val result = before.copy(
            tasks = before.tasks + (a.id to a.copy(priority = app.todotim.core.Priority.P1)) + (b.id to b.copy(content = "B2")),
            shadows = mapOf(b.id to shadowOf(b)),
        )
        store.applySync(before, result)
        val t = snap.task(a.id)!!
        assertEquals("A local", t.content)
        assertEquals(app.todotim.core.Priority.P1, t.priority)
        assertNull(snap.task(b.id))
        assertEquals("cal/${b.id}.ics", store.database.value.pendingDeletes.getValue(b.id).path)
    }
}
