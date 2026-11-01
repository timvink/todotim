package app.todotim.core.sync

import app.todotim.core.INBOX_ID
import app.todotim.core.Priority
import app.todotim.core.dav.CalDAVClient
import app.todotim.core.ical.VTodo
import app.todotim.core.store.Persistence
import app.todotim.core.store.TodoStore
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.time.LocalDate

/**
 * The phone's steps of the cross-client test with the Mac (Swift `CrossClientLiveTests`), against a real CalDAV
 * server; run by `scripts/live-interop.sh`. State goes through the server and files in `TODOTIM_CROSS_DIR`.
 *
 * Steps: `b` the phone reads the Mac's data exactly, then edits, completes, adds, moves and deletes; `d1` it completes
 * "Gym" and syncs, then completes "Take out bins" without syncing; `d3` it syncs and checks each repeating task
 * advanced once, and writes its tasks for the Mac to compare.
 */
class CrossClientLiveTest {
    private val step = System.getenv("TODOTIM_CROSS_STEP")
    private val dir = System.getenv("TODOTIM_CROSS_DIR")?.let(::File)

    @Test fun step() = runBlocking {
        assumeTrue("run by scripts/live-interop.sh", step in setOf("b", "d1", "d3") && dir != null)
        val client = LiveServer.connect()
        val persistence = Persistence(File(dir, "phone").apply { mkdirs() })
        val store = TodoStore(persistence.load())
        val ids = readMap("ids.json")
        when (step) {
            "b" -> stepB(client, store, ids)
            "d1" -> stepD1(client, store, ids)
            "d3" -> stepD3(client, store, ids)
        }
        persistence.save(store.database.value)
    }

    private fun readMap(name: String): Map<String, String> =
        Json.parseToJsonElement(File(dir, name).readText()).let { e ->
            (e as kotlinx.serialization.json.JsonObject).mapValues { it.value.jsonPrimitive.content }
        }

    private suspend fun syncOK(store: TodoStore, client: CalDAVClient): SyncResult {
        val r = CalDAVSync.sync(store, client)
        assertTrue(r.warnings.toString(), r.isComplete)
        assertEquals(emptyList<String>(), r.warnings)
        return r
    }

    private suspend fun settled(store: TodoStore, client: CalDAVClient) {
        val rec = Recording(client)
        val r = CalDAVSync.sync(store, rec)
        assertEquals(0, r.uploaded)
        assertEquals(emptyList<String>(), rec.writes)
        assertEquals(0, store.snapshot.value.unsyncedCount)
    }

    /** The phone sees exactly what the Mac made, then changes it. */
    private suspend fun stepB(client: CalDAVClient, store: TodoStore, ids: Map<String, String>) {
        syncOK(store, client)
        val snap = store.snapshot.value
        val home = ids.getValue("home")
        val errands = ids.getValue("errands")
        val garden = ids.getValue("garden")
        val otherList = ids.getValue("otherList")
        assertEquals(listOf(INBOX_ID, home, errands, otherList), snap.projects.map { it.id })
        assertEquals(listOf("Inbox", "Home", "Errands", "Other list"), snap.projects.map { it.name })
        assertEquals(listOf("green", "orange", "red"), snap.projects.drop(1).map { it.color })
        assertEquals(listOf(garden to "Garden", ids.getValue("indoors") to "Indoors"), snap.sections(home).map { it.id to it.name })
        assertEquals(emptyList<Any>(), snap.sections(errands))
        assertEquals(
            listOf("outside" to "red", "weekend" to "blue", "errand, quick" to "charcoal"),
            snap.labels.map { it.name to it.color },
        )
        assertEquals(listOf(ids.getValue("outside"), ids.getValue("weekend")), snap.labels.take(2).map { it.id })
        assertEquals(15, store.database.value.tasks.size)
        with(snap.task(ids.getValue("foreignUid"))!!) {
            assertEquals("Foreign uid", content)
            assertEquals(INBOX_ID, projectId)
            assertEquals(LocalDate.of(2026, 11, 20), due)
        }
        assertEquals(otherList, snap.task("t1")!!.projectId)

        fun t(key: String) = snap.task(ids.getValue(key))!!
        with(t("prune")) {
            assertEquals("Prune roses", content)
            assertEquals(home, projectId)
            assertEquals(garden, sectionId)
            assertNull(parentId)
            assertEquals(Priority.P1, priority)
            assertEquals(LocalDate.of(2026, 11, 3), due)
            assertEquals(listOf("outside"), labels)
            assertEquals("Line 1\nLine 2", description)
        }
        with(t("shears")) {
            assertEquals(ids.getValue("prune"), parentId)
            assertEquals(garden, sectionId)
            assertEquals(Priority.P3, priority)
        }
        assertEquals(listOf(ids.getValue("shears")), snap.subtaskIds(ids.getValue("prune")))
        with(t("water")) {
            assertEquals(home, projectId)
            assertNull(sectionId)
            assertEquals(LocalDate.of(2026, 11, 2), due)
            assertEquals("FREQ=WEEKLY;COUNT=10", recurrence)
        }
        assertEquals("FREQ=WEEKLY" to LocalDate.of(2026, 11, 4), t("bins").recurrence to t("bins").due)
        assertEquals("FREQ=DAILY;INTERVAL=2" to LocalDate.of(2026, 11, 5), t("gym").recurrence to t("gym").due)
        with(t("mum")) {
            assertEquals(INBOX_ID, projectId)
            assertEquals(Priority.P2, priority)
            assertEquals(listOf("weekend"), labels)
        }
        assertEquals(ids.getValue("indoors"), t("vacuum").sectionId)
        assertEquals(INBOX_ID, t("passport").projectId)
        with(t("unicode")) {
            assertEquals(MAC_TITLE, content)
            assertEquals(MAC_DESCRIPTION, description)
            assertEquals(listOf("errand, quick"), labels)
        }
        assertEquals(listOf(ids.getValue("paint")), snap.subtaskIds(ids.getValue("fence")))
        assertEquals(listOf(ids.getValue("hotel")), snap.subtaskIds(ids.getValue("trip")))
        assertEquals(0, snap.unsyncedCount)

        // The phone's changes.
        store.updateTask(ids.getValue("passport")) { copy(content = "Renew passport (phone)") }
        store.updateTask(ids.getValue("prune")) { copy(due = LocalDate.of(2026, 11, 10)) }
        store.complete(ids.getValue("water"))
        assertEquals(LocalDate.of(2026, 11, 9), store.snapshot.value.task(ids.getValue("water"))!!.due)
        store.complete(ids.getValue("shears"))
        val gate = store.addTask("Fix gate", home, sectionId = garden, priority = Priority.P2)
        val hinge = store.addTask("Buy hinge", home, parentId = gate.id)
        store.delete(ids.getValue("vacuum"))
        store.moveTask(ids.getValue("mum"), errands)
        store.updateTask(ids.getValue("mum")) { copy(labels = labels + "outside") }
        store.updateTask(ids.getValue("prune")) { copy(description = "") }
        store.complete(ids.getValue("fence"))
        assertTrue(store.snapshot.value.task(ids.getValue("paint"))!!.isCompleted)
        store.moveTask(ids.getValue("trip"), errands)
        store.setCollapsed(ids.getValue("trip"), true)
        assertEquals(errands, store.snapshot.value.task(ids.getValue("hotel"))!!.projectId)
        val phoneUnicode = store.addTask(PHONE_TITLE, INBOX_ID, description = PHONE_DESCRIPTION, labels = listOf("phone, label", "outside"))
        val pruneChild = store.addTask("Sharpen shears", home, parentId = ids.getValue("prune"))
        store.updateTask(ids.getValue("foreignUid")) { copy(content = "Foreign uid (phone)") }
        store.moveTask("t1", errands, parentId = ids.getValue("trip"))
        store.moveTask(ids.getValue("shears"), home)
        store.reorder(gate.id, afterId = null)
        store.updateTask(ids.getValue("mum")) { copy(priority = Priority.P4) }
        store.updateTask(ids.getValue("hotel")) { copy(due = null) }
        store.updateTask(ids.getValue("unicode")) { copy(labels = emptyList()) }
        syncOK(store, client)
        settled(store, client)
        File(dir, "phone-ids.json").writeText(
            buildJsonObject {
                put("gate", JsonPrimitive(gate.id))
                put("hinge", JsonPrimitive(hinge.id))
                put("phoneUnicode", JsonPrimitive(phoneUnicode.id))
                put("pruneChild", JsonPrimitive(pruneChild.id))
            }.toString(),
        )
    }

    /** "Gym" is completed here first (synced); "Take out bins" is completed here but synced after the Mac's. */
    private suspend fun stepD1(client: CalDAVClient, store: TodoStore, ids: Map<String, String>) {
        syncOK(store, client)
        // The Mac renamed a label.
        assertEquals(listOf("week end", "outside"), store.snapshot.value.task(ids.getValue("mum"))!!.labels)
        assertEquals("week end", store.snapshot.value.labels.first { it.id == ids.getValue("weekend") }.name)
        // The Mac renamed a section and a list, added a section, deleted a section and a list.
        val snap = store.snapshot.value
        val home = ids.getValue("home")
        assertEquals(listOf(ids.getValue("garden") to GARDEN_NAME, ids.getValue("shed") to "Shed"), snap.sections(home).map { it.id to it.name })
        assertEquals("Errands & shops", snap.project(ids.getValue("errands"))!!.name)
        assertNull(snap.project(ids.getValue("otherList")))
        val gate = readMap("phone-ids.json").getValue("gate")
        val oil = store.addTask("Oil hinges", home, sectionId = ids.getValue("garden"))
        val sweep = store.addTask("Sweep", home, sectionId = ids.getValue("shed"))
        store.updateTask(gate) { copy(content = "Fix gate (phone)") }
        File(dir, "phone-ids-d1.json").writeText(
            buildJsonObject {
                put("oil", JsonPrimitive(oil.id))
                put("sweep", JsonPrimitive(sweep.id))
                put("gate", JsonPrimitive(gate))
            }.toString(),
        )
        store.complete(ids.getValue("gym"))
        assertEquals(LocalDate.of(2026, 11, 7), store.snapshot.value.task(ids.getValue("gym"))!!.due)
        // Meet the Mac's unsynced move of "Prune roses" and edit of "Renew passport".
        store.updateTask(ids.getValue("prune")) { copy(description = "phone note") }
        store.delete(ids.getValue("passport"))
        syncOK(store, client)
        store.complete(ids.getValue("bins"))
        assertEquals(LocalDate.of(2026, 11, 11), store.snapshot.value.task(ids.getValue("bins"))!!.due)
    }

    /** Each repeating task advanced once; the tasks go to the Mac for comparison. */
    private suspend fun stepD3(client: CalDAVClient, store: TodoStore, ids: Map<String, String>) {
        syncOK(store, client)
        settled(store, client)
        val snap = store.snapshot.value
        for ((key, due, rule) in listOf(
            Triple("bins", LocalDate.of(2026, 11, 11), "FREQ=WEEKLY"),
            Triple("gym", LocalDate.of(2026, 11, 7), "FREQ=DAILY;INTERVAL=2"),
        )) {
            val t = snap.task(ids.getValue(key))!!
            assertEquals(key, due, t.due)
            assertEquals(key, rule, t.recurrence)
            assertFalse(key, t.isCompleted)
        }
        val tasks = buildJsonObject {
            for (t in store.database.value.tasks.values) {
                put(t.id, buildJsonObject {
                    put("projectId", JsonPrimitive(t.projectId))
                    put("sectionId", t.sectionId?.let(::JsonPrimitive) ?: JsonNull)
                    put("parentId", t.parentId?.let(::JsonPrimitive) ?: JsonNull)
                    put("content", JsonPrimitive(t.content))
                    put("description", JsonPrimitive(t.description))
                    put("priority", JsonPrimitive(t.priority.level))
                    put("due", t.due?.toString()?.let(::JsonPrimitive) ?: JsonNull)
                    put("labels", JsonArray(t.labels.map(::JsonPrimitive)))
                    put("isCompleted", JsonPrimitive(t.isCompleted))
                    put("recurrence", t.recurrence?.let(::JsonPrimitive) ?: JsonNull)
                    put("order", JsonPrimitive(t.order))
                })
            }
        }
        File(dir, "phone-tasks.json").writeText(tasks.toString())
        val db = store.database.value
        val meta = buildJsonObject {
            for (p in db.projects.values) put("project:${p.id}", JsonPrimitive("${p.name}|${p.color}"))
            for (x in db.sections.values) put("section:${x.id}", JsonPrimitive("${x.projectId}|${x.name}|${VTodo.format(x.order)}"))
            for (l in db.labels.values) put("label:${l.id}", JsonPrimitive("${l.name}|${l.color}"))
        }
        File(dir, "phone-meta.json").writeText(meta.toString())
    }

    companion object {
        // As in the Swift CrossClientLiveTests.
        val PHONE_TITLE = "Ünïcødé ✅ ".repeat(9)
        const val PHONE_DESCRIPTION = "x;y,z\\\n🙂"
        val MAC_TITLE = "Café ☕️ — 日本語 ".repeat(6)
        const val MAC_DESCRIPTION = "a,b;c\\d\nline 2: \"quoted\""
        const val GARDEN_NAME = "Garden; \"yard\": 1,2 ^"
    }
}
