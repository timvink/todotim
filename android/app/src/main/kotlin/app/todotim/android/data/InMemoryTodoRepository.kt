package app.todotim.android.data

import app.todotim.core.EntityID
import app.todotim.core.Label
import app.todotim.core.TodoTask
import app.todotim.core.newID
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.time.LocalDate

/** [TodoRepository] without persistence or server, for running the app standalone and for previews. */
class InMemoryTodoRepository(
    initial: TodoSnapshot = SampleData.snapshot(),
    private val clock: () -> Long = System::currentTimeMillis,
    private val today: () -> LocalDate = LocalDate::now,
) : TodoRepository {
    private val state = MutableStateFlow(initial)
    override val snapshot: StateFlow<TodoSnapshot> = state.asStateFlow()

    private val status = MutableStateFlow(SyncStatus())
    override val syncStatus: StateFlow<SyncStatus> = status.asStateFlow()

    override fun addTask(task: NewTask): EntityID {
        val id = newID()
        val now = clock()
        state.update { s ->
            val parent = task.parentId?.let { s.tasksById[it] }
            val projectId = parent?.projectId ?: task.projectId
            val sectionId = if (parent != null) parent.sectionId else task.sectionId
            val siblings = s.tasks.filter { it.parentId == parent?.id && it.projectId == projectId && it.sectionId == sectionId }
            val created = TodoTask(
                id = id, projectId = projectId, sectionId = sectionId, parentId = parent?.id,
                content = task.content.trim(), description = task.description, priority = task.priority,
                due = task.due, labels = task.labels.distinct(), recurrence = task.recurrence,
                order = (siblings.maxOfOrNull { it.order } ?: 0.0) + 1, createdAt = now, updatedAt = now,
            )
            withLabels(s.copy(tasks = s.tasks + created), created.labels)
        }
        return id
    }

    override fun updateTask(id: EntityID, change: (TodoTask) -> TodoTask) = state.update { s ->
        val old = s.tasksById[id] ?: return@update s
        val new = change(old).copy(
            id = old.id, projectId = old.projectId, sectionId = old.sectionId, parentId = old.parentId,
            order = old.order, createdAt = old.createdAt, updatedAt = clock(),
        )
        if (new == old.copy(updatedAt = new.updatedAt)) return@update s
        withLabels(s.copy(tasks = s.tasks.map { if (it.id == id) new else it }), new.labels)
    }

    override fun moveTask(id: EntityID, projectId: EntityID, sectionId: EntityID?) = state.update { s ->
        val task = s.tasksById[id] ?: return@update s
        if (task.projectId == projectId && task.sectionId == sectionId && task.parentId == null) return@update s
        val moved = descendants(s, id) + id
        val order = (s.tasks.filter { it.parentId == null && it.projectId == projectId && it.sectionId == sectionId }
            .maxOfOrNull { it.order } ?: 0.0) + 1
        val now = clock()
        s.copy(tasks = s.tasks.map {
            when {
                it.id == id -> it.copy(projectId = projectId, sectionId = sectionId, parentId = null, order = order, updatedAt = now)
                it.id in moved -> it.copy(projectId = projectId, sectionId = sectionId, updatedAt = now)
                else -> it
            }
        })
    }

    override fun complete(id: EntityID) = state.update { s ->
        val task = s.tasksById[id] ?: return@update s
        if (task.isCompleted) return@update s
        val now = clock()
        val rule = task.recurrence
        if (rule != null) {
            val next = SimpleRecurrence.advance(rule, task.due ?: today())
            if (next != null) return@update s.copy(tasks = s.tasks.map { if (it.id == id) it.copy(due = next, updatedAt = now) else it })
        }
        val done = descendants(s, id) + id
        s.copy(tasks = s.tasks.map {
            if (it.id in done && !it.isCompleted) it.copy(isCompleted = true, completedAt = now, updatedAt = now) else it
        })
    }

    override fun reopen(id: EntityID) = state.update { s ->
        val chain = generateSequence(s.tasksById[id]) { t -> t.parentId?.let { s.tasksById[it] } }.map { it.id }.toSet()
        val now = clock()
        s.copy(tasks = s.tasks.map {
            if (it.id in chain && it.isCompleted) it.copy(isCompleted = false, completedAt = null, updatedAt = now) else it
        })
    }

    override fun delete(id: EntityID) = state.update { s ->
        val gone = descendants(s, id) + id
        s.copy(tasks = s.tasks.filterNot { it.id in gone })
    }

    override fun reschedule(id: EntityID, due: LocalDate?) = updateTask(id) { it.copy(due = due) }

    override fun toggleCollapsed(id: EntityID) = state.update { s ->
        // Collapsing is view state: no updatedAt bump, so it never wins a merge on its own.
        s.copy(tasks = s.tasks.map { if (it.id == id) it.copy(collapsed = !it.collapsed) else it })
    }

    override suspend fun sync() {
        if (status.value.isSyncing) return
        status.update { it.copy(isSyncing = true) }
        delay(800)
        status.value = SyncStatus(isSyncing = false, lastSyncedAt = clock(), error = null)
    }

    private fun descendants(s: TodoSnapshot, id: EntityID): Set<EntityID> {
        val out = mutableSetOf<EntityID>()
        val queue = ArrayDeque(listOf(id))
        while (queue.isNotEmpty()) {
            for (child in s.childrenOf[queue.removeFirst()].orEmpty()) if (out.add(child.id)) queue.add(child.id)
        }
        return out
    }

    private fun withLabels(s: TodoSnapshot, names: List<String>): TodoSnapshot {
        val missing = names.filter { it.isNotBlank() && it !in s.labelsByName }.distinct()
        if (missing.isEmpty()) return s
        var order = s.labels.maxOfOrNull { it.order } ?: 0.0
        return s.copy(labels = s.labels + missing.map { Label(id = newID(), name = it, order = ++order) })
    }
}

/**
 * Advances FREQ=DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL; null for anything else (the task then completes).
 * TODO: replace with the core `Recurrence` port, which handles the full RRULE subset of the Mac app.
 */
internal object SimpleRecurrence {
    fun advance(rule: String, from: LocalDate): LocalDate? {
        val parts = rule.split(';').mapNotNull { p -> p.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0].uppercase() to it[1] } }.toMap()
        val interval = parts["INTERVAL"]?.toLongOrNull()?.coerceAtLeast(1) ?: 1
        return when (parts["FREQ"]?.uppercase()) {
            "DAILY" -> from.plusDays(interval)
            "WEEKLY" -> from.plusWeeks(interval)
            "MONTHLY" -> from.plusMonths(interval)
            "YEARLY" -> from.plusYears(interval)
            else -> null
        }
    }
}
