package app.todotim.core.ical

import app.todotim.core.Priority
import app.todotim.core.Section
import app.todotim.core.TodoTask
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Runs the shared golden cases in `fixtures/vtodo` (format: fixtures/README.md, "vtodo"). */
class VTodoFixturesTest {
    private val zone = ZoneId.of("Europe/Amsterdam")
    private val now = "2027-01-15T08:00:00Z"
    private val dir = File(System.getProperty("todotim.fixtures") ?: error("todotim.fixtures not set"), "vtodo")

    private fun files(sub: String, suffix: String) =
        (File(dir, sub).listFiles() ?: emptyArray()).filter { it.name.endsWith(suffix) }.sortedBy { it.name }

    @Test fun read() {
        val cases = files("read", ".ics")
        assertTrue("no read fixtures in $dir", cases.size >= 10)
        for (f in cases) {
            val expected = Json.parseToJsonElement(File(f.path.removeSuffix(".ics") + ".json").readText())
            val actual = VTodo.read(f.readText(), "p", zone)
            if (expected is JsonNull) {
                assertNull(f.name, actual)
                continue
            }
            val e = expected.jsonObject
            requireNotNull(actual) { "${f.name}: not read" }
            val got = taskJson(actual.task) + mapOf(
                "uid" to JsonPrimitive(actual.uid),
                "sectionName" to JsonPrimitive(actual.sectionName),
                "sectionOrder" to JsonPrimitive(actual.sectionOrder),
            )
            assertEquals("${f.name}: keys", e.keys, got.keys)
            for (k in e.keys) assertTrue("${f.name}: $k = ${got[k]}, expected ${e[k]}", same(e[k]!!, got[k]!!))
        }
    }

    @Test fun patch() {
        val cases = files("patch", ".edit.json")
        assertTrue(cases.isNotEmpty())
        for (f in cases) {
            val name = f.name.removeSuffix(".edit.json")
            val before = File(dir, "patch/$name.before.ics").readText()
            val edit = Json.parseToJsonElement(f.readText()).jsonObject
            val old = requireNotNull(VTodo.read(before, "p", zone)) { "$name: before not readable" }
            var task = applyEdits(old.task.copy(updatedAt = Instant.parse(now).toEpochMilli()), edit["set"]!!.jsonObject)
            val parentUid = if ("parentUid" in edit) edit["parentUid"]!!.str() else task.parentId
            val section = if ("section" in edit) edit["section"]!!.section() else task.sectionId?.let {
                Section(it, task.projectId, old.sectionName ?: "", old.sectionOrder ?: 0.0)
            }
            val out = VTodo.patch(before, old, task, parentUid, section, zone)
            if (edit["unchanged"]?.jsonPrimitive?.boolean == true) {
                assertNull(name, out)
            } else {
                assertEquals(name, File(dir, "patch/$name.after.ics").readText(), out)
                // What was written reads back as the edited task (times in whole seconds).
                val back = VTodo.read(out!!, "p", zone)!!.task
                task = task.copy(parentId = parentUid?.let(VTodo::taskId), sectionId = section?.id)
                assertEquals(name, task.copy(createdAt = back.createdAt, updatedAt = back.updatedAt, completedAt = back.completedAt), back)
            }
        }
    }

    @Test fun make() {
        val cases = files("make", ".json")
        assertTrue(cases.isNotEmpty())
        for (f in cases) {
            val spec = Json.parseToJsonElement(f.readText()).jsonObject
            val t = spec["task"]!!.jsonObject
            val base = TodoTask(id = t["id"]!!.str()!!, projectId = t["projectId"]!!.str()!!, content = "", order = 0.0, createdAt = 0, updatedAt = 0)
            val task = applyEdits(base, JsonObject(t - "id" - "projectId"))
            val out = VTodo.make(task, spec["uid"]!!.str()!!, spec["parentUid"]!!.str(), spec["section"]!!.section())
            assertEquals(f.name, File(f.path.removeSuffix(".json") + ".ics").readText(), out)
        }
    }

    @Test fun numberFormat() {
        val cases = Json.parseToJsonElement(File(dir, "numbers.json").readText()).jsonObject["format"]!!.jsonArray
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val value = c.jsonObject["value"]!!.str()!!
            assertEquals(value, c.jsonObject["text"]!!.str(), VTodo.format(value.toDouble()))
        }
    }

    // JSON shape

    private fun JsonElement.str(): String? = if (this is JsonNull) null else jsonPrimitive.content
    private fun JsonElement.time(): Long? = str()?.let { Instant.parse(it).toEpochMilli() }
    private fun JsonElement.section(): Section? = if (this is JsonNull) null else jsonObject.let {
        Section(it["id"]!!.str()!!, "p", it["name"]!!.str()!!, it["order"]!!.jsonPrimitive.double)
    }

    private fun applyEdits(task: TodoTask, set: JsonObject): TodoTask {
        var t = task
        for ((k, v) in set) {
            t = when (k) {
                "sectionId" -> t.copy(sectionId = v.str())
                "parentId" -> t.copy(parentId = v.str())
                "content" -> t.copy(content = v.str()!!)
                "description" -> t.copy(description = v.str()!!)
                "priority" -> t.copy(priority = Priority.entries.first { it.level == v.jsonPrimitive.int })
                "due" -> t.copy(due = v.str()?.let(LocalDate::parse))
                "labels" -> t.copy(labels = v.jsonArray.map { it.str()!! })
                "isCompleted" -> t.copy(isCompleted = v.jsonPrimitive.boolean)
                "completedAt" -> t.copy(completedAt = v.time())
                "order" -> t.copy(order = v.jsonPrimitive.double)
                "collapsed" -> t.copy(collapsed = v.jsonPrimitive.boolean)
                "recurrence" -> t.copy(recurrence = v.str())
                "createdAt" -> t.copy(createdAt = v.time()!!)
                "updatedAt" -> t.copy(updatedAt = v.time()!!)
                else -> error("unknown task field $k")
            }
        }
        return t
    }

    private fun taskJson(t: TodoTask): Map<String, JsonElement> {
        fun time(ms: Long?) = JsonPrimitive(ms?.let { Instant.ofEpochMilli(it).toString() })
        return mapOf(
            "id" to JsonPrimitive(t.id), "projectId" to JsonPrimitive(t.projectId),
            "sectionId" to JsonPrimitive(t.sectionId), "parentId" to JsonPrimitive(t.parentId),
            "content" to JsonPrimitive(t.content), "description" to JsonPrimitive(t.description),
            "priority" to JsonPrimitive(t.priority.level), "due" to JsonPrimitive(t.due?.toString()),
            "labels" to JsonArray(t.labels.map(::JsonPrimitive)), "isCompleted" to JsonPrimitive(t.isCompleted),
            "completedAt" to time(t.completedAt), "order" to JsonPrimitive(t.order),
            "collapsed" to JsonPrimitive(t.collapsed), "recurrence" to JsonPrimitive(t.recurrence),
            "createdAt" to time(t.createdAt), "updatedAt" to time(t.updatedAt),
        )
    }

    /** JSON equality with numbers compared as numbers (12 == 12.0). */
    private fun same(a: JsonElement, b: JsonElement): Boolean = when {
        a is JsonNull || b is JsonNull -> a is JsonNull && b is JsonNull
        a is JsonArray && b is JsonArray -> a.size == b.size && a.indices.all { same(a[it], b[it]) }
        a is JsonPrimitive && b is JsonPrimitive && !a.isString && !b.isString &&
            a.content.toDoubleOrNull() != null -> a.content.toDouble() == b.content.toDoubleOrNull()
        else -> a == b
    }
}
