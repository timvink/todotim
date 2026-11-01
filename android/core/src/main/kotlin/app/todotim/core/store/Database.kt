package app.todotim.core.store

import app.todotim.core.EntityID
import app.todotim.core.INBOX_ID
import app.todotim.core.Label
import app.todotim.core.Project
import app.todotim.core.Section
import app.todotim.core.TodoTask
import app.todotim.core.dav.CalendarHome
import app.todotim.core.dav.RemoteCalendar
import app.todotim.core.ical.VTodoTask
import kotlinx.serialization.Serializable

/**
 * Everything the phone stores, in one JSON file (see [Persistence]).
 *
 * The phone keeps a **shadow** of each task: the server copy it last saw. A local edit is a field difference
 * between [tasks] and [shadows] (see [TaskFields]); a task without a shadow has never been uploaded. Projects,
 * sections and labels come from the server and are read-only on the phone.
 *
 * Structure is kept raw (as the server has it): a subtask may name a parent the phone cannot see, or a section
 * that does not exist. [Snapshot] repairs that for display only, so the repair is never written back.
 */
@Serializable
data class Database(
    val version: Int = 1,
    /** The account the synced data belongs to; another server URL or username starts fresh. */
    val account: Account? = null,
    /** The calendar home found by discovery, so a sync needs no discovery requests. */
    val home: CalendarHome? = null,
    val projects: Map<EntityID, Project> = mapOf(INBOX_ID to defaultInbox()),
    val sections: Map<EntityID, Section> = emptyMap(),
    val labels: Map<EntityID, Label> = emptyMap(),
    /** The local view of every task (raw structure). */
    val tasks: Map<EntityID, TodoTask> = emptyMap(),
    /** The server copy of each synced task, by task id. */
    val shadows: Map<EntityID, Shadow> = emptyMap(),
    /** Tasks deleted on the phone that still have to be deleted on the server, by task id. */
    val pendingDeletes: Map<EntityID, PendingDelete> = emptyMap(),
    /** Synced calendars by path (relative to the DAV root). */
    val calendars: Map<String, CalendarState> = emptyMap(),
    /** Epoch milliseconds of the last complete sync. */
    val lastSyncAt: Long? = null,
) {
    companion object {
        fun defaultInbox() = Project(id = INBOX_ID, name = "Inbox", color = "charcoal", order = -1.0, isInbox = true)
    }
}

@Serializable
data class Account(val serverUrl: String, val username: String)

/** The server copy of a task: where it is, its ETag, the object as the server sent it, and what it reads as. */
@Serializable
data class Shadow(
    val path: String,
    val etag: String?,
    val ics: String,
    /** [ics] read as a task (`VTodo.read`). */
    val task: TodoTask,
    val uid: String,
    val sectionName: String? = null,
    val sectionOrder: Double? = null,
    /** The server's object became unreadable: the task is kept as it is and nothing is written for it until the
     *  object can be read again ([ics] and [etag] are still the last readable version). */
    val unreadable: Boolean = false,
) {
    val vtodo: VTodoTask get() = VTodoTask(task, uid, sectionName, sectionOrder)

    companion object {
        fun of(path: String, etag: String?, ics: String, v: VTodoTask) =
            Shadow(path, etag, ics, v.task, v.uid, v.sectionName, v.sectionOrder)
    }
}

/** A delete the server has not seen yet; sent as a conditional DELETE on [etag]. */
@Serializable
data class PendingDelete(
    val path: String,
    val etag: String?,
    /** Epoch milliseconds; a server edit after this brings the task back (last writer wins). */
    val deletedAt: Long,
    /** The server's object is unreadable: wait until it can be read again. */
    val unreadable: Boolean = false,
)

/** A synced calendar: its listing properties, and the sync token (or ctag) its tasks are synced up to. */
@Serializable
data class CalendarState(
    val calendar: RemoteCalendar,
    val projectId: EntityID,
    /** A write returned no ETag: fetch this calendar's changes on the next sync even if its token looks unchanged. */
    val stale: Boolean = false,
) {
    val path: String get() = calendar.path
}
