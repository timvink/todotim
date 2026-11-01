package app.todotim.android

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import app.todotim.core.INBOX_ID
import app.todotim.core.Label
import app.todotim.core.Priority
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.store.Database
import app.todotim.core.store.TodoStore
import kotlinx.coroutines.launch
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters

/**
 * Debug builds only (src/debug/AndroidManifest.xml): fills an empty store (no account, no tasks) with the demo data of
 * the README screenshots, then opens [MainActivity]. A store that holds anything is left alone.
 */
class DemoActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val graph = (application as TodoTimApplication).graph
        graph.scope.launch {
            val seeded = graph.await().store.seed(DemoData.database(LocalDate.now()))
            graph.flush()
            runOnUiThread {
                if (!seeded) Toast.makeText(this@DemoActivity, "Not empty: demo data not added", Toast.LENGTH_LONG).show()
                startActivity(Intent(this@DemoActivity, MainActivity::class.java))
                finish()
            }
        }
    }
}

/** The macOS README screenshot's data, with due dates relative to [today]. Tasks go through [TodoStore.addTask]. */
object DemoData {
    fun database(today: LocalDate): Database {
        val projects = listOf(
            Database.defaultInbox(),
            Project("work", "Work", "blue", 1.0),
            Project("home", "Home", "green", 2.0),
            Project("side-project", "Side project", "grape", 3.0),
            Project("reading-list", "Reading list", "orange", 4.0),
        )
        val sections = listOf(
            Section("work-planning", "work", "Planning", 1.0),
            Section("work-operations", "work", "Operations", 2.0),
        )
        val labels = listOf("errands", "reading", "focus", "design").mapIndexed { i, name ->
            Label("label-$name", name, "charcoal", i + 1.0)
        }
        val store = TodoStore(
            Database(
                projects = projects.associateBy { it.id },
                sections = sections.associateBy { it.id },
                labels = labels.associateBy { it.id },
            ),
        )
        val tuesday = today.with(TemporalAdjusters.next(DayOfWeek.TUESDAY))
        val thursday = today.with(TemporalAdjusters.next(DayOfWeek.THURSDAY))

        store.addTask("Prepare quarterly review", "work", priority = Priority.P1, due = tuesday, labels = listOf("focus"))
        val roadmap = store.addTask(
            "Draft 2027 roadmap", "work", "work-planning", priority = Priority.P2, due = today.plusDays(8),
            description = "Collect input from the team first",
        )
        store.addTask("Interview product owners", parentId = roadmap.id)
        store.addTask("Write summary", parentId = roadmap.id, labels = listOf("focus"))
        store.addTask("Book offsite venue", "work", "work-planning", due = thursday)
        store.addTask("Rotate API keys", "work", "work-operations", priority = Priority.P1, due = today.minusDays(4))
        store.addTask("Update on-call schedule", "work", "work-operations", priority = Priority.P3)

        store.addTask("Buy coffee beans", labels = listOf("errands"), due = today)
        store.addTask("Call the dentist", priority = Priority.P2, due = today.plusDays(1))
        store.addTask("Pick up dry cleaning", labels = listOf("errands"))
        store.addTask("Sketch the new logo", labels = listOf("design"))

        store.addTask("Fix the leaking tap", "home", priority = Priority.P2, due = today.plusDays(2))
        store.addTask("Water the plants", "home", due = today, recurrence = "FREQ=WEEKLY")
        store.addTask("Clean out the garage", "home")
        store.addTask("Ship the beta", "side-project", priority = Priority.P3, due = today.plusDays(12))
        store.addTask("The Pragmatic Programmer", "reading-list", labels = listOf("reading"))
        return store.database.value
    }
}
