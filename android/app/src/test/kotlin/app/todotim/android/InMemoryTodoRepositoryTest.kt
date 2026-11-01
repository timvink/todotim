package app.todotim.android

import app.todotim.android.data.InMemoryTodoRepository
import app.todotim.android.data.NewTask
import app.todotim.android.data.SampleData
import app.todotim.android.data.StubQuickAddParser
import app.todotim.android.ui.DueDates
import app.todotim.android.ui.ListItem
import app.todotim.android.ui.TaskLists
import app.todotim.core.INBOX_ID
import app.todotim.core.Priority
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class InMemoryTodoRepositoryTest {
    private val today = LocalDate.of(2026, 11, 2)
    private fun repo() = InMemoryTodoRepository(SampleData.snapshot(today), today = { today })

    @Test fun completingParentCompletesSubtasksAndReopenRestoresChain() {
        val r = repo()
        r.complete("t3")
        val s = r.snapshot.value
        assertTrue(listOf("t3", "t3a", "t3b").all { s.tasksById.getValue(it).isCompleted })
        r.reopen("t3a")
        assertFalse(r.snapshot.value.tasksById.getValue("t3").isCompleted)
        assertFalse(r.snapshot.value.tasksById.getValue("t3a").isCompleted)
        assertTrue(r.snapshot.value.tasksById.getValue("t3b").isCompleted)
    }

    @Test fun completingRecurringTaskAdvancesDue() {
        val r = repo()
        r.complete("t4") // every 2 days, due today
        val t = r.snapshot.value.tasksById.getValue("t4")
        assertFalse(t.isCompleted)
        assertEquals(today.plusDays(2), t.due)
    }

    @Test fun subtaskInheritsParentProjectAndSection() {
        val r = repo()
        val id = r.addTask(NewTask(content = "Water", projectId = INBOX_ID, parentId = "h3"))
        val t = r.snapshot.value.tasksById.getValue(id)
        assertEquals("home", t.projectId)
        assertEquals("home-garden", t.sectionId)
    }

    @Test fun moveCarriesSubtasks() {
        val r = repo()
        r.moveTask("t3", "work", "work-planning")
        val s = r.snapshot.value
        assertEquals("work-planning", s.tasksById.getValue("t3a").sectionId)
        assertEquals("work", s.tasksById.getValue("t3c").projectId)
    }

    @Test fun newLabelsAreCreated() {
        val r = repo()
        r.addTask(NewTask(content = "x", projectId = INBOX_ID, labels = listOf("new")))
        assertTrue("new" in r.snapshot.value.labelsByName)
    }

    @Test fun projectListHidesCompletedAndCollapsedChildren() {
        val s = SampleData.snapshot(today)
        val inbox = TaskLists.project(s, INBOX_ID, showCompleted = false)
        val ids = inbox.filterIsInstance<ListItem.TaskItem>().map { it.task.id }
        assertFalse("t6" in ids)
        assertFalse("t3c" in ids)
        assertEquals(1, inbox.filterIsInstance<ListItem.TaskItem>().first { it.task.id == "t3a" }.depth)
        assertTrue(inbox.any { it is ListItem.Header && it.title == "Someday" })
        val home = TaskLists.project(s, "home", showCompleted = false).filterIsInstance<ListItem.TaskItem>().map { it.task.id }
        assertTrue("h4" in home)
        assertFalse("h4a" in home) // h4 is collapsed
    }

    @Test fun stubParserFindsTokens() {
        val r = StubQuickAddParser.parse("Call Anna tomorrow p1 #Work @calls", today)
        assertEquals("Call Anna", r.content)
        assertEquals(today.plusDays(1), r.due)
        assertEquals(Priority.P1, r.priority)
        assertEquals("Work", r.projectName)
        assertEquals(listOf("calls"), r.labels)
        assertEquals(4, r.tokens.size)
        assertNull(StubQuickAddParser.parse("Read p5", today).priority)
    }

    @Test fun dueLabels() {
        assertEquals("Today", DueDates.label(today, today))
        assertEquals("Yesterday", DueDates.label(today.minusDays(1), today))
        assertEquals("Friday", DueDates.label(LocalDate.of(2026, 11, 6), today))
        assertEquals("12 Dec", DueDates.label(LocalDate.of(2026, 12, 12), today))
        assertEquals("every 2 weeks", DueDates.describeRecurrence("FREQ=WEEKLY;INTERVAL=2"))
        assertEquals(LocalDate.of(2026, 11, 9), DueDates.nextWeek(today))
        assertEquals(today, DueDates.fromPickerMillis(DueDates.toPickerMillis(today)))
    }
}
