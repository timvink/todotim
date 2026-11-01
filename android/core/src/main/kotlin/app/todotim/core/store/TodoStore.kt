package app.todotim.core.store

import app.todotim.core.EntityID
import app.todotim.core.INBOX_ID
import app.todotim.core.Priority
import app.todotim.core.Recurrence
import app.todotim.core.SyncLimits
import app.todotim.core.TodoTask
import app.todotim.core.dav.CalendarHome
import app.todotim.core.ical.VTodo
import app.todotim.core.newID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.LocalDate
import java.time.ZoneId

/**
 * The phone's task store: holds the [Database], publishes a [Snapshot] for the UI, and makes every change
 * (mutations here, sync results through [applySync]). All changes run under one lock, so the UI can mutate while a
 * sync waits on the network; sync merges its result with edits made in the meantime.
 *
 * Every mutation sets `updatedAt` of the tasks it changes (and moves it past the previous value), because other
 * devices resolve conflicting edits by last writer wins on LAST-MODIFIED. Mutations are synchronous and cheap
 * enough for the main thread at phone scale; [database] changes are what [Persistence] saves.
 *
 * Projects, sections and labels come from the server; on the phone they are read-only.
 *
 * [clock] gives epoch milliseconds; [zone] is the user's timezone (today's date for repeating tasks).
 */
class TodoStore(
    initial: Database = Database(),
    private val clock: () -> Long = System::currentTimeMillis,
    private val zone: ZoneId = ZoneId.systemDefault(),
) {
    private val lock = Any()
    private var version = 0L
    private val _database = MutableStateFlow(initial)
    private val _snapshot = MutableStateFlow(Snapshot.build(initial, 0))

    /** The stored data. Changes on every mutation and sync. */
    val database: StateFlow<Database> = _database.asStateFlow()

    /** The read model for the UI. */
    val snapshot: StateFlow<Snapshot> = _snapshot.asStateFlow()

    // region Tasks

    /**
     * Adds a task at the end of its siblings (or right after [afterId], a sibling). A subtask takes its root task's
     * project and section. An unknown project means the inbox; a section of another project means none.
     */
    fun addTask(
        content: String,
        projectId: EntityID = INBOX_ID,
        sectionId: EntityID? = null,
        parentId: EntityID? = null,
        due: LocalDate? = null,
        priority: Priority = Priority.P4,
        labels: List<String> = emptyList(),
        description: String = "",
        recurrence: String? = null,
        afterId: EntityID? = null,
    ): TodoTask = mutate { tx ->
        val parent = parentId?.let { tx.tasks[it] }
        val root = parent?.let { tx.shownRoot(it.id) }
        var pid = root?.projectId ?: projectId
        if (pid !in tx.db.projects) pid = INBOX_ID
        val sid = if (root != null) root.sectionId else sectionId?.takeIf { tx.db.sections[it]?.projectId == pid }
        val now = tx.now
        val order = tx.insertionOrder(pid, sid, parent?.id, exclude = null, afterId = afterId, atEnd = afterId == null)
            ?: tx.insertionOrder(pid, sid, parent?.id, exclude = null, afterId = null, atEnd = true)!!
        val t = TodoTask(
            id = newID(), projectId = pid, sectionId = sid, parentId = parent?.id, content = content,
            description = description, priority = priority, due = due, labels = labels.distinct(), order = order,
            recurrence = recurrence?.takeIf { it.isNotBlank() }, createdAt = now, updatedAt = now,
        )
        val stored = limited(t)
        tx.tasks[t.id] = stored
        stored
    }

    /**
     * Edits a task: `updateTask(id) { copy(content = "New") }`. The block gets the stored task (raw structure).
     * Project, section, parent and creation time are kept (use [moveTask]); completion is better done with
     * [complete] and [reopen], which cascade. Returns false when the task does not exist or nothing changed.
     */
    fun updateTask(id: EntityID, edit: TodoTask.() -> TodoTask): Boolean = mutate { tx ->
        val old = tx.tasks[id] ?: return@mutate false
        var t = old.edit().copy(
            id = old.id, projectId = old.projectId, sectionId = old.sectionId, parentId = old.parentId,
            createdAt = old.createdAt, updatedAt = old.updatedAt,
        )
        if (t.labels.size != t.labels.distinct().size) t = t.copy(labels = t.labels.distinct())
        if (t.isCompleted && t.completedAt == null) t = t.copy(completedAt = tx.now)
        if (!t.isCompleted && t.completedAt != null) t = t.copy(completedAt = null)
        if (t == old) return@mutate false
        tx.put(t)
        true
    }

    /**
     * Completes a task and its open subtasks. A repeating task moves to its next occurrence instead (counted from
     * its due date, or [today] without one) while its rule allows ([Recurrence.advance]).
     */
    fun complete(id: EntityID, today: LocalDate = LocalDate.now(zone)) = mutate { tx ->
        val t = tx.tasks[id] ?: return@mutate
        if (t.isCompleted) return@mutate
        val rule = t.recurrence
        if (rule != null) {
            val next = Recurrence.advance(rule, t.due ?: today, zone)
            if (next != null) {
                tx.put(t.copy(due = next.due, recurrence = next.rule))
                return@mutate
            }
        }
        val now = tx.now
        for (did in listOf(id) + tx.snapshot.descendantIds(id)) {
            val d = tx.tasks[did] ?: continue
            if (!d.isCompleted) tx.put(d.copy(isCompleted = true, completedAt = now))
        }
    }

    /** Reopens a task and its completed (displayed) ancestors, so it is visible again. Subtasks stay as they are. */
    fun reopen(id: EntityID) = mutate { tx ->
        var cur: EntityID? = id
        val seen = HashSet<EntityID>()
        while (cur != null && seen.add(cur)) {
            val t = tx.tasks[cur] ?: break
            if (t.isCompleted) tx.put(t.copy(isCompleted = false, completedAt = null))
            cur = tx.snapshot.task(cur)?.parentId
        }
    }

    /**
     * Deletes a task and its subtasks as shown ([Snapshot]): a task that names it as parent but is shown elsewhere
     * stays. Synced ones are deleted on the server by the next sync.
     */
    fun delete(id: EntityID) = mutate { tx ->
        if (id !in tx.tasks) return@mutate
        for (did in listOf(id) + tx.snapshot.descendantIds(id)) tx.remove(did)
    }

    /**
     * Moves a task with its subtasks to the end of a new place. With [parentId] the task becomes a subtask and takes
     * the parent's project and section; a task never moves below itself. Its shown subtasks follow the project and
     * section; tasks that name it as parent but are shown elsewhere stay where they are.
     */
    fun moveTask(id: EntityID, projectId: EntityID, sectionId: EntityID? = null, parentId: EntityID? = null) = mutate { tx ->
        val t = tx.tasks[id] ?: return@mutate
        // Raw descendants refuse cycles; only the shown subtasks move along.
        if (parentId != null && (parentId == id || parentId in tx.descendants(id))) return@mutate
        val descendants = tx.snapshot.descendantIds(id)
        val parent = parentId?.let { tx.tasks[it] }
        val pid = parent?.projectId ?: projectId
        if (pid !in tx.db.projects) return@mutate
        val sid = if (parent != null) parent.sectionId else sectionId?.takeIf { tx.db.sections[it]?.projectId == pid }
        if (t.projectId == pid && t.sectionId == sid && t.parentId == parent?.id) return@mutate
        val order = tx.insertionOrder(pid, sid, parent?.id, exclude = id, afterId = null, atEnd = true)!!
        tx.put(t.copy(projectId = pid, sectionId = sid, parentId = parent?.id, order = order))
        for (did in descendants) {
            val d = tx.tasks[did] ?: continue
            if (d.projectId != pid || d.sectionId != sid) tx.put(d.copy(projectId = pid, sectionId = sid))
        }
    }

    fun setCollapsed(id: EntityID, collapsed: Boolean) {
        updateTask(id) { copy(collapsed = collapsed) }
    }

    /**
     * Moves a task among its (displayed) siblings to right after [afterId], or to the top when [afterId] is null.
     * Takes the midpoint of the neighbours' orders; renumbers the siblings when the gap is used up.
     */
    fun reorder(id: EntityID, afterId: EntityID?) = mutate { tx ->
        val shown = tx.snapshot.task(id) ?: return@mutate
        if (afterId == id) return@mutate
        val order = tx.insertionOrder(shown.projectId, shown.sectionId, shown.parentId, exclude = id, afterId = afterId, atEnd = false)
            ?: return@mutate
        val t = tx.tasks.getValue(id)
        if (t.order != order) tx.put(t.copy(order = order))
    }

    // endregion

    // region Account and sync

    /**
     * Prepares the store for another server URL or username: everything synced is dropped (it belongs to the other
     * account); tasks never uploaded are kept and go to the new account, in the inbox when their project is gone.
     */
    fun resetAccount(account: Account) = mutate { tx ->
        val keep = tx.db.tasks.filterKeys { it !in tx.db.shadows }
        tx.db = Database(account = account)
        tx.tasks.clear()
        for (t in keep.values) tx.tasks[t.id] = if (t.projectId == INBOX_ID) t else t.copy(projectId = INBOX_ID, sectionId = null)
        tx.shadows.clear()
        tx.pendingDeletes.clear()
    }

    /**
     * Records the calendar home. A home other than the stored one makes the next sync start from scratch
     * (docs/caldav.md): the shadows and pending deletes (paths in the old home) are dropped and every calendar is
     * read again, so tasks are matched by id in the new home (local edits kept, last writer wins), tasks it does
     * not have are uploaded as new, and nothing is deleted there.
     */
    fun setHome(home: CalendarHome) = mutate { tx ->
        if (tx.db.home == home) return@mutate
        if (tx.db.home == null) {
            tx.db = tx.db.copy(home = home)
            return@mutate
        }
        tx.db = tx.db.copy(home = home, calendars = emptyMap())
        tx.shadows.clear()
        tx.pendingDeletes.clear()
    }

    /**
     * Applies a sync result. [base] is the database the sync started from, [result] what it made of it. Edits the
     * user made since [base] are kept on top, field by field ([TaskFields.rebase]); a task deleted meanwhile stays
     * deleted (and is deleted on the server next time); a task added meanwhile stays.
     */
    internal fun applySync(base: Database, result: Database) = mutate { tx ->
        val current = tx.db
        tx.db = result
        tx.tasks.clear(); tx.tasks.putAll(result.tasks)
        tx.shadows.clear(); tx.shadows.putAll(result.shadows)
        tx.pendingDeletes.clear(); tx.pendingDeletes.putAll(result.pendingDeletes)
        if (current === base) return@mutate
        for (id in base.tasks.keys + current.tasks.keys) {
            val before = base.tasks[id]
            val now = current.tasks[id]
            if (now == before) continue
            when {
                before == null -> tx.tasks[id] = now!! // added during the sync
                now == null -> { // deleted during the sync
                    tx.tasks.remove(id)
                    val shadow = tx.shadows.remove(id)
                    if (shadow != null) {
                        val deletedAt = current.pendingDeletes[id]?.deletedAt ?: tx.now
                        tx.pendingDeletes[id] = PendingDelete(shadow.path, shadow.etag, deletedAt, shadow.unreadable)
                    }
                }
                else -> {
                    val merged = result.tasks[id] ?: continue // removed on the server: dropped
                    tx.tasks[id] = TaskFields.rebase(now, before, merged)
                }
            }
        }
    }

    /** Records the time of a complete sync. */
    internal fun markSynced(at: Long) = mutate { tx -> tx.db = tx.db.copy(lastSyncAt = at) }

    /**
     * Replaces the database of a store that holds nothing yet (no tasks, no account) with [db]: demo data in debug
     * builds (`android/app/src/debug`). Returns false, changing nothing, when the store is not empty.
     */
    fun seed(db: Database): Boolean = mutate { tx ->
        if (tx.db.account != null || tx.tasks.isNotEmpty() || tx.shadows.isNotEmpty()) return@mutate false
        tx.db = db
        tx.tasks.clear(); tx.tasks.putAll(db.tasks)
        tx.shadows.clear(); tx.shadows.putAll(db.shadows)
        tx.pendingDeletes.clear(); tx.pendingDeletes.putAll(db.pendingDeletes)
        true
    }

    // endregion

    // region Plumbing

    private fun <R> mutate(body: (Tx) -> R): R = synchronized(lock) {
        val before = _database.value
        val tx = Tx(before)
        val r = body(tx)
        val after = tx.build()
        if (after != before) {
            _database.value = after
            _snapshot.value = Snapshot.build(after, ++version)
        }
        r
    }

    /** One mutation: copies of the maps it changes, and helpers over them. */
    private inner class Tx(var db: Database) {
        val tasks = db.tasks.toMutableMap()
        val shadows = db.shadows.toMutableMap()
        val pendingDeletes = db.pendingDeletes.toMutableMap()
        val now: Long = clock()
        val snapshot: Snapshot get() = _snapshot.value

        fun build(): Database = db.copy(tasks = tasks, shadows = shadows, pendingDeletes = pendingDeletes)

        /** Stores [t] as edited now: `updatedAt` moves forward to at least the next whole second after the old one,
         *  so LAST-MODIFIED (whole seconds) always increases. */
        fun put(t: TodoTask) {
            tasks[t.id] = limited(t).copy(updatedAt = after(tasks[t.id]))
        }

        /** Deletes a task; the delete counts as later than its last edit (same rule as [put]). */
        fun remove(id: EntityID) {
            val old = tasks.remove(id) ?: return
            val shadow = shadows.remove(id) ?: return
            pendingDeletes[id] = PendingDelete(shadow.path, shadow.etag, after(old), shadow.unreadable)
        }

        /** Now, but at least the next whole second after [old]'s `updatedAt`. */
        private fun after(old: TodoTask?): Long {
            val floor = old?.let { (Math.floorDiv(it.updatedAt, 1000L) + 1) * 1000L } ?: Long.MIN_VALUE
            return maxOf(now, floor)
        }

        /** The root of [id] as shown, with its shown project and section ([Snapshot]). */
        fun shownRoot(id: EntityID): TodoTask {
            var cur = id
            val seen = hashSetOf(id)
            while (true) {
                val p = snapshot.task(cur)?.parentId ?: break
                if (!seen.add(p)) break
                cur = p
            }
            return snapshot.task(cur) ?: tasks.getValue(id)
        }

        /** Live descendants by raw parent, depth first, guarded against cycles. */
        fun descendants(id: EntityID): List<EntityID> {
            val byParent = tasks.values.groupBy { it.parentId }
            val out = ArrayList<EntityID>()
            val seen = hashSetOf(id)
            val stack = ArrayDeque(listOf(id))
            while (stack.isNotEmpty()) {
                for (c in byParent[stack.removeLast()].orEmpty()) {
                    if (seen.add(c.id)) {
                        out.add(c.id)
                        stack.addLast(c.id)
                    }
                }
            }
            return out
        }

        /**
         * The order for a task placed among the displayed siblings of (project, section, parent), excluding [exclude]:
         * at the end, or right after [afterId] (null: first). When the neighbours are too close, the siblings are
         * renumbered 1…N first. null when [afterId] is not a sibling.
         */
        fun insertionOrder(
            projectId: EntityID, sectionId: EntityID?, parentId: EntityID?, exclude: EntityID?, afterId: EntityID?,
            atEnd: Boolean,
        ): Double? {
            val ids = snapshot.siblingIds(projectId, sectionId, parentId).filter { it != exclude && it in tasks }
            fun orders() = ids.map { tasks.getValue(it).order }
            val index = when {
                atEnd -> ids.size
                afterId == null -> 0
                else -> ids.indexOf(afterId).takeIf { it >= 0 }?.plus(1) ?: return null
            }
            gapOrder(index, orders())?.let { return it }
            for ((k, sid) in ids.withIndex()) {
                val t = tasks.getValue(sid)
                if (t.order != (k + 1).toDouble()) put(t.copy(order = (k + 1).toDouble()))
            }
            return gapOrder(index, orders()) ?: (ids.size + 1).toDouble()
        }
    }

    companion object {
        /**
         * [t] with its text within [SyncLimits] (title, description, label count and names), clipped as the server
         * copy is on read, so a written task reads back unchanged.
         */
        internal fun limited(t: TodoTask): TodoTask {
            val content = VTodo.clip(t.content, SyncLimits.MAX_CONTENT_LENGTH)
            val description = VTodo.clip(t.description, SyncLimits.MAX_DESCRIPTION_LENGTH)
            var labels = t.labels
            if (labels.size > SyncLimits.MAX_LABELS_PER_TASK || labels.any { VTodo.clip(it, SyncLimits.MAX_NAME_LENGTH) != it }) {
                labels = labels.map { VTodo.clip(it, SyncLimits.MAX_NAME_LENGTH) }.distinct().take(SyncLimits.MAX_LABELS_PER_TASK)
            }
            if (content === t.content && description === t.description && labels === t.labels) return t
            return t.copy(content = content, description = description, labels = labels)
        }

        /**
         * Order for inserting at [index] among sorted [orders]: max + 1 at the end, min − 1 at the start, else the
         * midpoint; null when the neighbours are too close (or out of order) for a distinct midpoint.
         */
        fun gapOrder(index: Int, orders: List<Double>): Double? {
            val i = index.coerceIn(0, orders.size)
            val prev = if (i == 0) null else orders[i - 1]
            val next = if (i == orders.size) null else orders[i]
            return when {
                prev == null && next == null -> 1.0
                prev == null -> next!! - 1
                next == null -> prev + 1
                else -> {
                    val mid = (prev + next) / 2
                    val minGap = maxOf(1.0, Math.abs(prev), Math.abs(next)) * 1e-9
                    if (next - prev > minGap && mid > prev && mid < next) mid else null
                }
            }
        }
    }
}
