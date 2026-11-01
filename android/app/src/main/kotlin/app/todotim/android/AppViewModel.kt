package app.todotim.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import app.todotim.android.data.edit
import app.todotim.core.EntityID
import app.todotim.core.INBOX_ID
import app.todotim.core.store.TodoStore

/** Where the app is. Tabs are roots; the others are pushed on top of a tab. */
sealed interface Screen {
    data object Inbox : Screen
    data object Search : Screen
    data object Browse : Screen
    data class ProjectTasks(val projectId: EntityID) : Screen
    data class LabelTasks(val label: String) : Screen
    data object Settings : Screen
}

/** What the quick-add sheet starts with, from the screen it was opened on. */
data class QuickAddDefaults(val projectId: EntityID = INBOX_ID, val sectionId: EntityID? = null, val text: String = "")

/** The one ViewModel: navigation, sheets and view options. The data lives in the app's [TodoStore]. */
class AppViewModel : ViewModel() {
    private val backStack = mutableStateListOf<Screen>(Screen.Inbox)
    val screen: Screen get() = backStack.last()
    val tab: Screen get() = backStack.first()
    val canGoBack: Boolean get() = backStack.size > 1

    /** Task shown in the detail sheet, or null. */
    var detailTaskId by mutableStateOf<EntityID?>(null)

    /** Non-null while the quick-add sheet is open. */
    var quickAdd by mutableStateOf<QuickAddDefaults?>(null)

    var showCompleted by mutableStateOf(false)

    fun selectTab(tab: Screen) {
        backStack.clear()
        backStack.add(tab)
    }

    fun open(screen: Screen) {
        backStack.add(screen)
    }

    fun back() {
        if (backStack.size > 1) backStack.removeAt(backStack.lastIndex)
    }

    fun openQuickAdd() {
        quickAdd = when (val s = screen) {
            is Screen.ProjectTasks -> QuickAddDefaults(projectId = s.projectId)
            is Screen.LabelTasks -> QuickAddDefaults(text = "@${s.label} ")
            else -> QuickAddDefaults()
        }
    }

    /** Completes the task and returns how to undo it (reopen, or restore the due date of a repeating task). */
    fun complete(store: TodoStore, id: EntityID): () -> Unit {
        val s = store.snapshot.value
        val before = s.task(id) ?: return {}
        // Open tasks in the subtree: completing the parent completes them too, so undo reopens them all.
        val open = (listOf(id) + s.descendantIds(id)).filter { s.task(it)?.isCompleted == false }
        store.complete(id)
        return {
            if (before.recurrence != null && store.snapshot.value.task(id)?.isCompleted == false) {
                store.edit(id) { it.copy(due = before.due, recurrence = before.recurrence) }
            } else {
                open.forEach(store::reopen)
            }
        }
    }
}
