package app.todotim.core.store

import app.todotim.core.TodoTask

/**
 * The fields of a task the phone edits and syncs, in groups that change together. A local edit is a group that
 * differs between the local task and its shadow; merging works per group.
 *
 * `updatedAt` and `createdAt` are not edits. Completion times compare in whole seconds, as the server stores them.
 */
internal enum class TaskField {
    CONTENT, DESCRIPTION, PRIORITY,
    /** Due date and repeat rule: completing a repeating task moves both. */
    SCHEDULE,
    LABELS,
    /** Completed flag and time. */
    COMPLETION,
    ORDER, COLLAPSED,
    /** Project, section and parent: a subtask's place depends on all three. */
    LOCATION,
    ;

    fun value(t: TodoTask): Any? = when (this) {
        CONTENT -> t.content
        DESCRIPTION -> t.description
        PRIORITY -> t.priority
        SCHEDULE -> t.due to t.recurrence
        LABELS -> t.labels
        COMPLETION -> t.isCompleted to (if (t.isCompleted) t.completedAt?.let { Math.floorDiv(it, 1000L) } else null)
        ORDER -> t.order + 0.0
        COLLAPSED -> t.collapsed
        LOCATION -> Triple(t.projectId, t.sectionId, t.parentId)
    }

    /** [target] with this group's fields taken from [source]. */
    fun copy(target: TodoTask, source: TodoTask): TodoTask = when (this) {
        CONTENT -> target.copy(content = source.content)
        DESCRIPTION -> target.copy(description = source.description)
        PRIORITY -> target.copy(priority = source.priority)
        SCHEDULE -> target.copy(due = source.due, recurrence = source.recurrence)
        LABELS -> target.copy(labels = source.labels)
        COMPLETION -> target.copy(isCompleted = source.isCompleted, completedAt = source.completedAt)
        ORDER -> target.copy(order = source.order)
        COLLAPSED -> target.copy(collapsed = source.collapsed)
        LOCATION -> target.copy(projectId = source.projectId, sectionId = source.sectionId, parentId = source.parentId)
    }

    fun differs(a: TodoTask, b: TodoTask) = value(a) != value(b)
}

internal object TaskFields {
    /** Whether [local] has edits that [base] (the shadow) does not. */
    fun edited(local: TodoTask, base: TodoTask): Boolean = TaskField.entries.any { it.differs(local, base) }

    /**
     * Field-level three-way merge of [local] and [server] since [base]: groups only the phone changed keep the
     * local value, all others take the server's. A group both sides changed goes to the later `updatedAt`
     * (the server's is its LAST-MODIFIED); a tie goes to the server.
     */
    fun merge(local: TodoTask, base: TodoTask, server: TodoTask): TodoTask {
        var out = server
        var keptLocal = false
        for (f in TaskField.entries) {
            if (!f.differs(local, base)) continue
            if (f.differs(server, base) && local.updatedAt <= server.updatedAt) continue
            if (f.differs(local, server)) keptLocal = true
            out = f.copy(out, local)
        }
        return if (keptLocal) out.copy(updatedAt = maxOf(local.updatedAt, server.updatedAt)) else out
    }

    /**
     * [result] (what a sync made of [before]) with the edits made to [current] since [before] put back on top,
     * group by group. Used when the user edited a task while a sync was running.
     */
    fun rebase(current: TodoTask, before: TodoTask, result: TodoTask): TodoTask {
        var out = result
        for (f in TaskField.entries) if (f.differs(current, before)) out = f.copy(out, current)
        return if (current.updatedAt != before.updatedAt) out.copy(updatedAt = maxOf(current.updatedAt, result.updatedAt)) else out
    }
}
