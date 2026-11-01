package app.todotim.core.sync

import app.todotim.core.EntityID
import app.todotim.core.INBOX_CALENDAR
import app.todotim.core.INBOX_ID
import app.todotim.core.Ids
import app.todotim.core.Label
import app.todotim.core.Project
import app.todotim.core.ProjectColor
import app.todotim.core.Section
import app.todotim.core.SyncLimits
import app.todotim.core.TodoTask
import app.todotim.core.dav.CalendarChanges
import app.todotim.core.dav.CalDAVServer
import app.todotim.core.dav.RemoteCalendar
import app.todotim.core.dav.SyncError
import app.todotim.core.dav.davPath
import app.todotim.core.ical.VTodo
import app.todotim.core.isValidEntityID
import app.todotim.core.store.CalendarState
import app.todotim.core.store.Database
import app.todotim.core.store.PendingDelete
import app.todotim.core.store.Shadow
import app.todotim.core.store.TaskFields
import app.todotim.core.store.TodoStore
import java.time.ZoneId

/** What one sync did. */
data class SyncResult(
    /** Every write succeeded: no conflicts left, nothing refused or skipped. */
    val isComplete: Boolean,
    /** Tasks taken from the server (new or changed). */
    val downloaded: Int = 0,
    /** Tasks removed locally because the server no longer has them. */
    val removed: Int = 0,
    /** Tasks created or changed on the server. */
    val uploaded: Int = 0,
    /** Tasks deleted on the server. */
    val deleted: Int = 0,
    /** Writes refused with 412 (another device changed the task); merged again in another pass. */
    val conflicts: Int = 0,
    /** Problems that did not stop the sync, for the user. */
    val warnings: List<String> = emptyList(),
)

/**
 * Two-way sync of a [TodoStore] with the user's CalDAV task lists (docs/caldav.md), with the phone's shadow model
 * (see [Database]):
 *
 * - **Pull**: list the calendars (projects; sections and labels from their properties or the tasks), fetch the
 *   changes of each calendar whose sync token moved, and merge each changed task: without local edits the server
 *   version is taken; with local edits field by field ([TaskFields.merge]). The shadow becomes the server copy.
 *   An object that cannot be read leaves its task as it is and blocks writes for it. A removed object drops its
 *   task, local edits included.
 * - **Push**: conditional writes of pending deletes, new tasks (parents first) and edited tasks (MOVE first when the
 *   project changed). A 412 leaves the task for another pass, which pulls and merges again (at most [maxPasses]).
 *
 * The store is not locked during network calls: each phase works on a copy and hands the result to
 * [TodoStore.applySync], which keeps edits the user made in the meantime.
 *
 * The phone does not create, change or delete lists, sections or labels; it only creates the inbox calendar when
 * a task needs it.
 */
class CalDAVSync(
    private val store: TodoStore,
    private val server: CalDAVServer,
    private val zone: ZoneId = ZoneId.systemDefault(),
    private val maxPasses: Int = 3,
) {
    private var downloaded = 0
    private var removed = 0
    private var uploaded = 0
    private var deleted = 0
    private var conflicts = 0
    private val warnings = LinkedHashSet<String>()
    private var incomplete = false

    suspend fun run(now: Long = System.currentTimeMillis()): SyncResult {
        var conflicted = true
        var pass = 0
        while (conflicted && pass < maxPasses) {
            pass++
            pull()
            conflicted = push()
        }
        if (conflicted) {
            warnings.add(SyncError.TooManyConflicts.message!!)
            incomplete = true
        }
        val complete = !incomplete
        if (complete) store.markSynced(now)
        return SyncResult(complete, downloaded, removed, uploaded, deleted, conflicts, warnings.toList())
    }

    // region Pull

    private suspend fun pull() {
        val base = store.database.value
        val listed = server.calendars()
        if (listed.size > SyncLimits.MAX_CALENDARS) throw SyncError.LimitExceeded("more than ${SyncLimits.MAX_CALENDARS} calendars")

        // One calendar per project id; the first by path wins.
        val chosen = LinkedHashMap<EntityID, RemoteCalendar>()
        for (cal in listed.sortedBy { it.path }) chosen.putIfAbsent(projectId(cal.uri), cal)

        val calendars = LinkedHashMap<String, CalendarState>()
        val fetched = ArrayList<Pair<CalendarState, CalendarChanges>>()
        for ((pid, cal) in chosen) {
            val known = base.calendars[cal.path]?.takeIf { it.projectId == pid }
            val token = known?.calendar?.syncToken
            if (known != null && !known.stale && cal.syncToken != null && token == cal.syncToken) {
                calendars[cal.path] = CalendarState(cal, pid)
                continue
            }
            val changes = server.changes(cal.path, token)
            val state = CalendarState(cal.copy(syncToken = changes.syncToken ?: cal.syncToken), pid)
            calendars[cal.path] = state
            fetched.add(state to changes)
        }

        val tasks = base.tasks.toMutableMap()
        val shadows = base.shadows.toMutableMap()
        val pending = base.pendingDeletes.toMutableMap()
        fun calendarOf(path: String) = path.substringBeforeLast('/', "")

        // Calendars gone from the server (or no longer a project): their tasks go too.
        for ((id, s) in base.shadows) {
            if (calendarOf(s.path) !in calendars) {
                shadows.remove(id)
                if (tasks.remove(id) != null) removed++
            }
        }
        pending.entries.removeAll { calendarOf(it.value.path) !in calendars }

        // Changed objects, by path; a UID seen twice in this pull keeps its first path.
        val claimed = HashMap<EntityID, String>()
        val removals = LinkedHashSet<String>()
        for ((cal, changes) in fetched) {
            if (changes.isFull) {
                val listedPaths = changes.changed.map { it.path }.toSet()
                for (s in base.shadows.values) if (calendarOf(s.path) == cal.path && s.path !in listedPaths) removals.add(s.path)
                for (p in base.pendingDeletes.values) if (calendarOf(p.path) == cal.path && p.path !in listedPaths) removals.add(p.path)
            }
            removals.addAll(changes.removed)
            for (r in changes.changed.sortedBy { it.path }) {
                val v = VTodo.read(r.ics, cal.projectId, zone)
                if (v == null) {
                    // Unreadable: keep the task as it is and write nothing for it until it can be read again.
                    shadows.entries.firstOrNull { it.value.path == r.path }?.let { (id, s) -> shadows[id] = s.copy(unreadable = true) }
                    pending.entries.firstOrNull { it.value.path == r.path }?.let { (id, p) -> pending[id] = p.copy(unreadable = true) }
                    continue
                }
                val id = v.task.id
                if (claimed.putIfAbsent(id, r.path) != null) continue
                val shadow = Shadow.of(r.path, r.etag, r.ics, v)
                val server = v.task
                val delete = pending[id]
                if (delete != null) {
                    if (server.updatedAt > delete.deletedAt) {
                        // Edited on another device after the delete here: the later change wins.
                        pending.remove(id)
                        tasks[id] = server
                        shadows[id] = shadow
                        downloaded++
                    } else {
                        pending[id] = PendingDelete(r.path, r.etag, delete.deletedAt)
                    }
                    continue
                }
                val local = tasks[id]
                val old = shadows[id]
                tasks[id] = when {
                    local == null -> server
                    old == null -> if (local.updatedAt > server.updatedAt) local else server // created on both sides
                    old.task == server -> local
                    !TaskFields.edited(local, old.task) -> server
                    else -> TaskFields.merge(local, old.task, server)
                }
                if (tasks[id] != local) downloaded++
                shadows[id] = shadow
            }
        }
        // Removed objects: drop their tasks, pending edits included. A task that moved (its shadow is elsewhere now)
        // stays.
        if (removals.isNotEmpty()) {
            for ((id, s) in shadows.entries.toList()) {
                if (s.path in removals) {
                    shadows.remove(id)
                    if (tasks.remove(id) != null) removed++
                }
            }
            pending.entries.removeAll { it.value.path in removals }
        }
        val total = shadows.size + pending.size
        if (total > SyncLimits.MAX_TASKS) throw SyncError.LimitExceeded("more than ${SyncLimits.MAX_TASKS} tasks")

        // Projects, sections and labels, as the server has them.
        val projects = LinkedHashMap<EntityID, Project>()
        for (state in calendars.values) {
            val cal = state.calendar
            val pid = state.projectId
            projects[pid] = Project(
                id = pid,
                name = cal.name?.takeIf { it.isNotBlank() }?.let { clip(it, SyncLimits.MAX_NAME_LENGTH) }
                    ?: if (pid == INBOX_ID) "Inbox" else cal.uri,
                color = cal.color?.let(ProjectColor::key) ?: "charcoal",
                order = if (pid == INBOX_ID) -1.0 else (cal.order?.let(VTodo::finiteDouble) ?: 0.0),
                isInbox = pid == INBOX_ID,
            )
        }
        if (INBOX_ID !in projects) projects[INBOX_ID] = Database.defaultInbox()

        val sections = LinkedHashMap<EntityID, Section>()
        val fromTasks = HashSet<EntityID>()
        for (state in calendars.values.sortedBy { it.path }) {
            val list = state.calendar.sectionEntries()
            if (list == null) {
                fromTasks.add(state.projectId)
                continue
            }
            for (e in list) sections.putIfAbsent(e.id, Section(e.id, state.projectId, e.name, e.order))
        }
        for (s in shadows.values.sortedBy { it.path }) {
            val sid = s.task.sectionId ?: continue
            if (s.task.projectId in fromTasks) sections.putIfAbsent(sid, Section(sid, s.task.projectId, s.sectionName ?: "Section", s.sectionOrder ?: 0.0))
        }

        val labels = LinkedHashMap<EntityID, Label>()
        calendars.values.firstOrNull { it.projectId == INBOX_ID }?.calendar?.labelEntries()?.forEach { e ->
            labels.putIfAbsent(e.id, Label(e.id, e.name, e.color?.let(ProjectColor::key) ?: "charcoal", e.order))
        }
        val names = labels.values.map { it.name }.toHashSet()
        var nextOrder = (labels.values.maxOfOrNull { it.order } ?: 0.0) + 1
        for (s in shadows.values.sortedBy { it.task.id }) {
            for (name in s.task.labels) if (names.add(name)) {
                val lid = Ids.labelId(name)
                labels.putIfAbsent(lid, Label(lid, name, order = nextOrder++))
            }
        }

        // Tasks never uploaded whose list is gone move to the inbox.
        for ((id, t) in tasks) {
            if (id !in shadows && t.projectId !in projects) tasks[id] = t.copy(projectId = INBOX_ID, sectionId = null)
        }

        store.applySync(
            base,
            base.copy(
                projects = projects, sections = sections, labels = labels, tasks = tasks, shadows = shadows,
                pendingDeletes = pending, calendars = calendars,
            ),
        )
    }

    // endregion

    // region Push

    private sealed class Outcome {
        data object Done : Outcome()
        data object Conflict : Outcome()
        data class Failed(val error: SyncError) : Outcome()
    }

    private suspend fun <T> attempt(block: suspend () -> T): Pair<T?, Outcome> = try {
        block() to Outcome.Done
    } catch (e: SyncError.PreconditionFailed) {
        null to Outcome.Conflict
    } catch (e: SyncError) {
        if (!e.isPerResource) throw e
        null to Outcome.Failed(e)
    }

    /** Writes local changes. Returns whether a write met a conflict (412), so another pass is needed. */
    private suspend fun push(): Boolean {
        val base = store.database.value
        val work = Work(base)
        try {
            return pushInto(base, work)
        } finally {
            store.applySync(base, work.build())
        }
    }

    /** The result of a push, built up as writes succeed. */
    private class Work(base: Database) {
        var db = base
        val tasks = base.tasks.toMutableMap()
        val shadows = base.shadows.toMutableMap()
        val pending = base.pendingDeletes.toMutableMap()
        val calendars = base.calendars.toMutableMap()
        fun build() = db.copy(tasks = tasks, shadows = shadows, pendingDeletes = pending, calendars = calendars)
    }

    private suspend fun pushInto(base: Database, work: Work): Boolean {
        var conflicted = false
        fun outcome(o: Outcome, what: String): Boolean {
            when (o) {
                Outcome.Done -> return true
                Outcome.Conflict -> { conflicted = true; conflicts++ }
                is Outcome.Failed -> { incomplete = true; warnings.add("$what: ${o.error.message}") }
            }
            return false
        }
        fun calendarPath(projectId: EntityID): String? = work.calendars.values.firstOrNull { it.projectId == projectId }?.path

        // Tasks to write.
        val created = base.tasks.values.filter { it.id !in base.shadows }
        val edited = base.tasks.values.filter { t ->
            val s = base.shadows[t.id] ?: return@filter false
            !s.unreadable && TaskFields.edited(t, s.task)
        }

        // The inbox calendar, when a task needs it and the server has none.
        if (calendarPath(INBOX_ID) == null && (created + edited).any { it.projectId == INBOX_ID }) {
            val path = davPath(server.home, INBOX_CALENDAR)
            val color = ProjectColor.hex("charcoal")
            val (_, o) = attempt { server.createCalendar(path, "Inbox", color, "0") }
            if (outcome(o, "Could not create the inbox")) {
                work.calendars[path] = CalendarState(RemoteCalendar(path, "Inbox", color, "0"), INBOX_ID, stale = true)
            }
        }

        // 1. Deletes.
        for ((id, p) in base.pendingDeletes) {
            if (p.unreadable) continue
            val (_, o) = attempt { server.delete(p.path, p.etag) }
            if (outcome(o, "Could not delete a task")) {
                work.pending.remove(id)
                deleted++
            }
        }

        // 2. New tasks, parents first.
        val newIds = created.map { it.id }.toSet()
        fun newDepth(t: TodoTask): Int {
            var d = 0
            var cur = t.parentId
            val seen = hashSetOf(t.id)
            while (cur != null && cur in newIds && seen.add(cur) && d < SyncLimits.MAX_TASK_DEPTH) {
                d++
                cur = base.tasks[cur]?.parentId
            }
            return d
        }
        for (t in created.sortedWith(compareBy<TodoTask> { newDepth(it) }.thenBy { it.createdAt }.thenBy { it.id })) {
            val cal = calendarPath(t.projectId)
            if (cal == null) {
                incomplete = true
                warnings.add("Could not upload “${t.content}”: its list is not on the server")
                continue
            }
            val path = "$cal/${t.id}.ics"
            val ics = VTodo.make(t, t.id, parentUid(t, work), section(t, base, null))
            val (etag, o) = attempt { server.put(path, ics, null) }
            if (!outcome(o, "Could not upload “${t.content}”")) continue
            written(work, t, path, etag, ics)
        }

        // 3. Edited tasks.
        for (t in edited) {
            val shadow = base.shadows.getValue(t.id)
            var path = shadow.path
            if (t.projectId != shadow.task.projectId) {
                val cal = calendarPath(t.projectId)
                if (cal == null) {
                    incomplete = true
                    warnings.add("Could not move “${t.content}”: its list is not on the server")
                    continue
                }
                path = "$cal/${shadow.path.substringAfterLast('/')}"
                if (work.shadows.values.any { it.path == path }) {
                    incomplete = true
                    warnings.add("Could not move “${t.content}”: “$path” already exists on the server")
                    continue
                }
            }
            val patched = VTodo.patch(shadow.ics, shadow.vtodo, t, parentUid(t, work), section(t, base, shadow), zone)
            if (path != shadow.path) {
                val (_, o) = attempt { server.move(shadow.path, path, shadow.etag) }
                if (!outcome(o, "Could not move “${t.content}”")) continue
                // MOVE keeps the ETag, so the same precondition holds for the PUT.
                val moved = shadow.copy(path = path, task = shadow.task.copy(projectId = t.projectId))
                work.shadows[t.id] = moved
                if (patched == null) {
                    uploaded++
                    adopt(work, t, moved.task)
                    continue
                }
            }
            if (patched == null) {
                // Nothing the server stores differs (for example only sub-second times): take the server's copy.
                adopt(work, t, shadow.task)
                continue
            }
            val (etag, o) = attempt { server.put(path, patched, shadow.etag) }
            if (!outcome(o, "Could not save “${t.content}”")) continue
            written(work, t, path, etag, patched)
        }
        return conflicted
    }

    /** After a successful PUT: the shadow is what was written, and the task takes the server's whole-second times
     *  (so it does not look edited). Without an ETag, the calendar is read again next time. */
    private fun written(work: Work, t: TodoTask, path: String, etag: String?, ics: String) {
        uploaded++
        val v = VTodo.read(ics, t.projectId, zone)
        if (v == null) {
            work.shadows.remove(t.id)
            return
        }
        work.shadows[t.id] = Shadow.of(path, etag, ics, v)
        adopt(work, t, v.task)
        if (etag == null) {
            val cal = path.substringBeforeLast('/', "")
            work.calendars[cal]?.let { work.calendars[cal] = it.copy(stale = true) }
        }
    }

    private fun adopt(work: Work, t: TodoTask, server: TodoTask) {
        work.tasks[t.id] = if (TaskFields.edited(t, server)) t else server
    }

    /** The parent's UID: its server UID when known, else its id (which is the UID of tasks made here). */
    private fun parentUid(t: TodoTask, work: Work): String? = t.parentId?.let { work.shadows[it]?.uid ?: it }

    /**
     * The section to write for [t]: the list's section, or for a section the phone does not know, the name and
     * order the server copy (or another task in it) already carries.
     */
    private fun section(t: TodoTask, db: Database, shadow: Shadow?): Section? {
        val sid = t.sectionId ?: return null
        db.sections[sid]?.takeIf { it.projectId == t.projectId }?.let { return it }
        val carrier = shadow?.takeIf { it.task.sectionId == sid } ?: db.shadows.values.firstOrNull { it.task.sectionId == sid }
        return Section(sid, t.projectId, carrier?.sectionName ?: "Section", carrier?.sectionOrder ?: 0.0)
    }

    // endregion

    companion object {
        /** Syncs [store] with [server] once. */
        suspend fun sync(store: TodoStore, server: CalDAVServer, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): SyncResult =
            CalDAVSync(store, server, zone).run(now)

        /** The project id of a calendar URI: the inbox, the URI when it is a valid id, else derived. */
        fun projectId(uri: String): EntityID = when {
            uri == INBOX_CALENDAR -> INBOX_ID
            isValidEntityID(uri) && uri != INBOX_ID -> uri
            else -> Ids.uuidV5(Ids.NAMESPACE, "calendar:$uri")
        }

        private fun clip(s: String, max: Int): String =
            if (s.codePointCount(0, s.length) <= max) s else s.substring(0, s.offsetByCodePoints(0, max))
    }
}
