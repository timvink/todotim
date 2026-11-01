package app.todotim.android

import app.todotim.android.data.edit
import app.todotim.android.data.validateServerSettings
import app.todotim.android.ui.ListItem
import app.todotim.android.ui.TaskLists
import app.todotim.core.INBOX_ID
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.store.Database
import app.todotim.core.store.TodoStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate

class TaskListsTest {
    private val store = TodoStore(
        Database(
            projects = listOf(
                Database.defaultInbox(),
                Project("work", "Work", "blue", 1.0),
            ).associateBy { it.id },
            sections = mapOf("plan" to Section("plan", "work", "Planning", 1.0)),
        ),
    )

    private fun rows(projectId: String, showCompleted: Boolean = false) =
        TaskLists.project(store.snapshot.value, projectId, showCompleted).map {
            when (it) {
                is ListItem.Header -> "# ${it.title} (${it.count})"
                is ListItem.TaskItem -> "  ".repeat(it.depth) + it.task.content
            }
        }

    @Test
    fun projectListsTasksThenSectionsWithIndentedSubtasks() {
        val a = store.addTask("A", projectId = "work")
        store.addTask("A1", parentId = a.id)
        store.addTask("B", projectId = "work", sectionId = "plan")
        assertEquals(listOf("A", "  A1", "# Planning (1)", "B"), rows("work"))
    }

    @Test
    fun collapsedTaskHidesSubtasksAndCompletedOnesShowOnRequest() {
        val a = store.addTask("A")
        val a1 = store.addTask("A1", parentId = a.id)
        store.complete(a1.id)
        assertEquals(listOf("A"), rows(INBOX_ID))
        assertEquals(listOf("A", "  A1"), rows(INBOX_ID, showCompleted = true))
        store.setCollapsed(a.id, true)
        assertEquals(listOf("A"), rows(INBOX_ID, showCompleted = true))
    }

    @Test
    fun searchGroupsByProjectInProjectOrder() {
        store.addTask("Call Anna", projectId = "work")
        store.addTask("call Bob")
        store.addTask("Water plants")
        val items = TaskLists.search(store.snapshot.value, "call")
        assertEquals(
            listOf("Inbox:1", "call Bob", "Work:1", "Call Anna"),
            items.map { if (it is ListItem.Header) "${it.title}:${it.count}" else (it as ListItem.TaskItem).task.content },
        )
    }

    @Test
    fun labelsUsedByTasksAppearWithoutLabelEntries() {
        store.addTask("Errand", labels = listOf("shops"))
        val s = store.snapshot.value
        assertEquals(listOf("shops"), s.labels.map { it.name })
        assertEquals(listOf("Errand"), TaskLists.label(s, "shops").map { (it as ListItem.TaskItem).task.content })
    }

    @Test
    fun undoOfCompletingRepeatingTaskRestoresDueDate() {
        val due = LocalDate.of(2026, 11, 2)
        val t = store.addTask("Water", due = due, recurrence = "FREQ=DAILY;COUNT=3")
        val undo = AppViewModel().complete(store, t.id)
        assertEquals(due.plusDays(1), store.snapshot.value.task(t.id)?.due)
        undo()
        val after = store.snapshot.value.task(t.id)!!
        assertEquals(due, after.due)
        assertEquals("FREQ=DAILY;COUNT=3", after.recurrence)
    }

    @Test
    fun undoOfCompletingParentReopensOnlyTheTasksItCompleted() {
        val p = store.addTask("P")
        val done = store.addTask("done", parentId = p.id)
        val open = store.addTask("open", parentId = p.id)
        store.complete(done.id)
        val undo = AppViewModel().complete(store, p.id)
        undo()
        val s = store.snapshot.value
        assertEquals(false, s.task(p.id)!!.isCompleted)
        assertEquals(false, s.task(open.id)!!.isCompleted)
        assertEquals(true, s.task(done.id)!!.isCompleted)
    }

    @Test
    fun editChangesTheStoredTask() {
        val t = store.addTask("Old")
        store.edit(t.id) { it.copy(content = "New") }
        assertEquals("New", store.snapshot.value.task(t.id)?.content)
    }

    @Test
    fun serverSettingsValidation() {
        assertNull(validateServerSettings("https://cloud.example.com/remote.php/dav/", "tim"))
        assertNull(validateServerSettings("http://localhost:5232/", "tim"))
        assertNotNull(validateServerSettings("http://cloud.example.com/", "tim"))
        assertNotNull(validateServerSettings("cloud.example.com", "tim"))
        assertNotNull(validateServerSettings("https://cloud.example.com/", " "))
    }
}
