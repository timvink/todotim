package app.todotim.android.data

import app.todotim.core.EntityID
import app.todotim.core.Label
import app.todotim.core.Priority
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.TodoTask
import kotlinx.coroutines.flow.StateFlow
import java.time.LocalDate

/**
 * Everything the UI reads and changes. The UI never holds its own copy of the data: it renders
 * [snapshot] and calls the mutations, which update [snapshot] synchronously (local-first), so a
 * later implementation can persist and sync in the background.
 *
 * Implementations: [InMemoryTodoRepository] (sample data, no persistence). The real one wraps the
 * core store and CalDAV sync.
 *
 * Rules every implementation keeps (same as the Mac app's `TodoStore`):
 * - mutations bump `updatedAt`;
 * - a subtask always has its parent's `projectId` and `sectionId` ([moveTask] carries descendants along);
 * - completing a task with a `recurrence` advances its `due` to the next occurrence instead of completing it;
 * - label names in [NewTask.labels] or [updateTask] that have no [Label] yet get one.
 */
interface TodoRepository {
    /** Current data, without deleted entities. Lists are in no particular order; sort by `order`. */
    val snapshot: StateFlow<TodoSnapshot>

    /** State of the last or running sync, for the pull-to-refresh spinner and Settings. */
    val syncStatus: StateFlow<SyncStatus>

    /** Adds a task (or a subtask when [NewTask.parentId] is set) at the end of its siblings. Returns its id. */
    fun addTask(task: NewTask): EntityID

    /**
     * Edits content, description, priority, due date, labels or recurrence. [change] gets the current task;
     * changes to ids, project, section, parent or order are ignored (use [moveTask]).
     */
    fun updateTask(id: EntityID, change: (TodoTask) -> TodoTask)

    /**
     * Moves the task and its subtasks to the end of [projectId] / [sectionId] (null = no section).
     * A subtask becomes a top-level task there.
     */
    fun moveTask(id: EntityID, projectId: EntityID, sectionId: EntityID?)

    /** Completes the task and its subtasks, or advances a recurring task to its next due date. */
    fun complete(id: EntityID)

    /** Reopens a completed task (and its completed ancestors, so it is visible again). */
    fun reopen(id: EntityID)

    /** Deletes the task and its subtasks. */
    fun delete(id: EntityID)

    /** Sets or clears the due date. */
    fun reschedule(id: EntityID, due: LocalDate?)

    /** Collapses or expands the task's subtasks in lists. */
    fun toggleCollapsed(id: EntityID)

    /** Runs one sync with the server; returns when done. Errors land in [syncStatus]. */
    suspend fun sync()
}

/** A consistent view of all data at one moment. */
data class TodoSnapshot(
    val projects: List<Project> = emptyList(),
    val sections: List<Section> = emptyList(),
    val labels: List<Label> = emptyList(),
    val tasks: List<TodoTask> = emptyList(),
) {
    val projectsById: Map<EntityID, Project> by lazy { projects.associateBy { it.id } }
    val sectionsById: Map<EntityID, Section> by lazy { sections.associateBy { it.id } }
    val labelsByName: Map<String, Label> by lazy { labels.associateBy { it.name } }
    val tasksById: Map<EntityID, TodoTask> by lazy { tasks.associateBy { it.id } }
    val childrenOf: Map<EntityID?, List<TodoTask>> by lazy {
        tasks.groupBy { it.parentId }.mapValues { (_, v) -> v.sortedBy { it.order } }
    }
}

/** Fields of a task to create. The repository assigns id, order and timestamps. */
data class NewTask(
    val content: String,
    val projectId: EntityID,
    val sectionId: EntityID? = null,
    val parentId: EntityID? = null,
    val description: String = "",
    val priority: Priority = Priority.P4,
    val due: LocalDate? = null,
    val labels: List<String> = emptyList(),
    val recurrence: String? = null,
)

data class SyncStatus(
    val isSyncing: Boolean = false,
    /** Epoch milliseconds of the last successful sync. */
    val lastSyncedAt: Long? = null,
    /** Human-readable error of the last sync, null when it succeeded. */
    val error: String? = null,
)
