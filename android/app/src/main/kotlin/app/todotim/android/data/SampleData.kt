package app.todotim.android.data

import app.todotim.core.INBOX_ID
import app.todotim.core.Label
import app.todotim.core.Priority
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.TodoTask
import java.time.LocalDate

/** Realistic sample data relative to [today], for [InMemoryTodoRepository] and previews. */
object SampleData {
    fun snapshot(today: LocalDate = LocalDate.now(), now: Long = System.currentTimeMillis()): TodoSnapshot {
        val projects = listOf(
            Project(INBOX_ID, "Inbox", "charcoal", 0.0, isInbox = true),
            Project("home", "Home", "green", 1.0),
            Project("work", "Work", "blue", 2.0),
            Project("fitness", "Fitness", "berry_red", 3.0),
            Project("groceries", "Groceries", "orange", 4.0),
        )
        val sections = listOf(
            Section("inbox-later", INBOX_ID, "Someday", 1.0),
            Section("home-garden", "home", "Garden", 1.0),
            Section("home-repairs", "home", "Repairs", 2.0),
            Section("work-planning", "work", "Planning", 1.0),
            Section("work-meetings", "work", "Meetings", 2.0),
        )
        val labels = listOf(
            Label("l-calls", "calls", "blue", 1.0),
            Label("l-errands", "errands", "orange", 2.0),
            Label("l-waiting", "waiting", "grape", 3.0),
            Label("l-quick", "quick", "mint_green", 3.0),
        )
        var order = 0.0
        fun t(
            id: String, project: String, content: String, section: String? = null, parent: String? = null,
            priority: Priority = Priority.P4, due: LocalDate? = null, labels: List<String> = emptyList(),
            description: String = "", recurrence: String? = null, completed: Boolean = false, collapsed: Boolean = false,
        ) = TodoTask(
            id = id, projectId = project, sectionId = section, parentId = parent, content = content,
            description = description, priority = priority, due = due, labels = labels,
            isCompleted = completed, completedAt = if (completed) now else null, order = ++order,
            collapsed = collapsed, recurrence = recurrence, createdAt = now, updatedAt = now,
        )
        val tasks = listOf(
            t("t1", INBOX_ID, "Call the dentist to reschedule", priority = Priority.P1, due = today.minusDays(2), labels = listOf("calls")),
            t("t2", INBOX_ID, "Buy a birthday present for Anna", priority = Priority.P2, due = today, labels = listOf("errands")),
            t("t3", INBOX_ID, "Plan the weekend trip", priority = Priority.P3, due = today.plusDays(1),
                description = "Train or car? Check the weather first."),
            t("t3a", INBOX_ID, "Book the hotel", parent = "t3", due = today.plusDays(1)),
            t("t3b", INBOX_ID, "Check train times", parent = "t3", labels = listOf("quick")),
            t("t3c", INBOX_ID, "Ask Mark about the car", parent = "t3", completed = true),
            t("t4", INBOX_ID, "Water the plants", due = today, recurrence = "FREQ=DAILY;INTERVAL=2"),
            t("t5", INBOX_ID, "Read the CalDAV RFC", due = today.plusDays(4)),
            t("t6", INBOX_ID, "Return library books", completed = true),
            t("t7", INBOX_ID, "Learn to play the ukulele", section = "inbox-later"),
            t("t8", INBOX_ID, "Visit Lisbon", section = "inbox-later", due = today.plusDays(40)),

            t("h1", "home", "Pay the energy bill", priority = Priority.P1, due = today.minusDays(1)),
            t("h2", "home", "Take out the recycling", due = today.plusDays(3), recurrence = "FREQ=WEEKLY"),
            t("h3", "home", "Plant tulip bulbs", section = "home-garden", due = today.plusDays(6)),
            t("h4", "home", "Prune the apple tree", section = "home-garden", collapsed = true),
            t("h4a", "home", "Sharpen the shears", parent = "h4"),
            t("h5", "home", "Fix the dripping tap", section = "home-repairs", priority = Priority.P2, labels = listOf("errands")),

            t("w1", "work", "Send the quarterly report", priority = Priority.P1, due = today, labels = listOf("quick")),
            t("w2", "work", "Draft the 2027 roadmap", section = "work-planning", priority = Priority.P2, due = today.plusDays(9)),
            t("w3", "work", "Collect feedback from the team", section = "work-planning", parent = "w2", labels = listOf("waiting")),
            t("w4", "work", "Weekly 1:1 with Sam", section = "work-meetings", due = today.plusDays(2),
                recurrence = "FREQ=WEEKLY", labels = listOf("calls")),

            t("f1", "fitness", "30 minutes of yoga", priority = Priority.P1, due = today, recurrence = "FREQ=DAILY"),
            t("f2", "fitness", "Renew the gym membership", due = today.plusDays(20)),

            t("g1", "groceries", "Bread", labels = listOf("errands")),
            t("g2", "groceries", "Oat milk"),
            t("g3", "groceries", "Coffee beans", priority = Priority.P3),
        )
        return TodoSnapshot(projects, sections, labels, tasks)
    }
}
