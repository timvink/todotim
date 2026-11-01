package app.todotim.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.todotim.android.data.InMemorySyncSettingsStore
import app.todotim.android.data.InMemoryTodoRepository
import app.todotim.android.data.QuickAddParsing
import app.todotim.android.data.StubQuickAddParser
import app.todotim.android.data.SyncSettingsStore
import app.todotim.android.data.TodoRepository
import app.todotim.core.EntityID
import app.todotim.core.INBOX_ID
import kotlinx.coroutines.launch

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

/**
 * The one ViewModel: navigation, sheets and view options, plus pass-through access to the repository.
 * TODO: the integrator constructs it with the real repository, settings store and parser (a factory or DI).
 */
class AppViewModel(
    val repository: TodoRepository = InMemoryTodoRepository(),
    val settingsStore: SyncSettingsStore = InMemorySyncSettingsStore(),
    val parser: QuickAddParsing = StubQuickAddParser,
) : ViewModel() {
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

    fun sync() {
        viewModelScope.launch { repository.sync() }
    }

    /** Completes the task and returns how to undo it (reopen, or restore the due date of a recurring task). */
    fun complete(id: EntityID): () -> Unit {
        val s = repository.snapshot.value
        val before = s.tasksById[id] ?: return {}
        // Open tasks in the subtree: completing the parent completes them too, so undo reopens them all.
        val open = mutableListOf<EntityID>()
        val queue = ArrayDeque(listOf(before))
        while (queue.isNotEmpty()) {
            val t = queue.removeFirst()
            if (!t.isCompleted) open += t.id
            queue.addAll(s.childrenOf[t.id].orEmpty())
        }
        repository.complete(id)
        return {
            if (before.recurrence != null && repository.snapshot.value.tasksById[id]?.isCompleted == false) {
                repository.reschedule(id, before.due)
            } else {
                open.forEach(repository::reopen)
            }
        }
    }
}
