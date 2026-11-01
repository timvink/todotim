package app.todotim.android.ui

import app.todotim.core.INBOX_ID
import app.todotim.core.Label
import app.todotim.core.Priority
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.TodoTask
import app.todotim.core.store.Database
import app.todotim.core.store.Snapshot
import java.time.LocalDate

/** A small data set for `@Preview`s only (R8 drops it from release builds with the previews). */
internal object PreviewData {
    fun snapshot(today: LocalDate = LocalDate.of(2026, 11, 2)): Snapshot {
        val projects = listOf(
            Project(INBOX_ID, "Inbox", "charcoal", 0.0, isInbox = true),
            Project("home", "Home", "green", 1.0),
            Project("work", "Work", "blue", 2.0),
        )
        val sections = listOf(
            Section("inbox-later", INBOX_ID, "Someday", 1.0),
            Section("work-planning", "work", "Planning", 1.0),
        )
        val labels = listOf(Label("l-calls", "calls", "blue", 1.0), Label("l-errands", "errands", "orange", 2.0))
        var order = 0.0
        fun t(
            id: String, project: String, content: String, section: String? = null, parent: String? = null,
            priority: Priority = Priority.P4, due: LocalDate? = null, labels: List<String> = emptyList(),
            recurrence: String? = null, completed: Boolean = false,
        ) = TodoTask(
            id = id, projectId = project, sectionId = section, parentId = parent, content = content,
            priority = priority, due = due, labels = labels, isCompleted = completed, completedAt = if (completed) 1L else null,
            order = ++order, recurrence = recurrence, createdAt = 0, updatedAt = 0,
        )
        val tasks = listOf(
            t("t1", INBOX_ID, "Call the dentist to reschedule", priority = Priority.P1, due = today.minusDays(2), labels = listOf("calls")),
            t("t2", INBOX_ID, "Buy a birthday present for Anna", priority = Priority.P2, due = today, labels = listOf("errands")),
            t("t3", INBOX_ID, "Plan the weekend trip", priority = Priority.P3, due = today.plusDays(1)),
            t("t3a", INBOX_ID, "Book the hotel", parent = "t3", due = today.plusDays(1)),
            t("t3b", INBOX_ID, "Ask Mark about the car", parent = "t3", completed = true),
            t("t4", INBOX_ID, "Water the plants", due = today, recurrence = "FREQ=DAILY;INTERVAL=2"),
            t("t5", INBOX_ID, "Visit Lisbon", section = "inbox-later", due = today.plusDays(40)),
            t("h1", "home", "Pay the energy bill", priority = Priority.P1, due = today.minusDays(1), labels = listOf("calls")),
            t("w1", "work", "Draft the 2027 roadmap", section = "work-planning", priority = Priority.P2, due = today.plusDays(9)),
        )
        val db = Database(
            projects = projects.associateBy { it.id },
            sections = sections.associateBy { it.id },
            labels = labels.associateBy { it.id },
            tasks = tasks.associateBy { it.id },
        )
        return Snapshot.build(db, 0)
    }
}
