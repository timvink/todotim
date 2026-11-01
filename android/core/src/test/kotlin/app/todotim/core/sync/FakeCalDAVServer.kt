package app.todotim.core.sync

import app.todotim.core.dav.CalendarChanges
import app.todotim.core.dav.CalDAVServer
import app.todotim.core.dav.CalendarHome
import app.todotim.core.dav.CalendarProperty
import app.todotim.core.dav.RemoteCalendar
import app.todotim.core.dav.RemoteResource
import app.todotim.core.dav.SyncError

/**
 * An in-memory CalDAV server for sync tests: calendars with ETags and RFC 6578-style sync tokens (one counter per
 * server), conditional writes that answer 412, and hooks to change things while a sync runs.
 */
class FakeCalDAVServer(override val home: String = "calendars/tim") : CalDAVServer {
    override val calendarHome = CalendarHome("https://dav.example.com/$home/")

    class Calendar(
        var name: String?,
        var color: String? = null,
        var order: String? = null,
        var sections: String? = null,
        var labels: String? = null,
        /** Path → (ics, etag). */
        val objects: MutableMap<String, Pair<String, String>> = sortedMapOf(),
        /** (token, path) for every change, in order. */
        val log: MutableList<Pair<Int, String>> = mutableListOf(),
        var token: Int = 0,
    )

    val calendars = sortedMapOf<String, Calendar>()
    private var counter = 0

    /** Write requests (method and path) in order. */
    val writes = mutableListOf<String>()
    /** changes() calls, by calendar path. */
    val changeRequests = mutableListOf<String>()
    /** Report ETags from PUT. */
    var reportETags = true
    /** Called before every write; may change the server. */
    var beforeWrite: (suspend (method: String, path: String) -> Unit)? = null
    /** Writes to these paths fail with 403. */
    val forbidden = mutableSetOf<String>()

    fun addCalendar(uri: String, name: String? = uri, order: String? = null, sections: String? = null, labels: String? = null): String {
        val path = "$home/$uri"
        calendars[path] = Calendar(name, order = order, sections = sections, labels = labels)
        return path
    }

    private fun calendarOf(path: String): Calendar =
        calendars[path.substringBeforeLast('/')] ?: throw SyncError.Conflict(path)

    private fun touch(cal: Calendar, path: String) {
        cal.token = ++counter
        cal.log.add(cal.token to path)
    }

    /** Stores an object directly (another client's write) and returns its ETag. */
    fun store(path: String, ics: String): String {
        val cal = calendarOf(path)
        val etag = "\"e${++counter}\""
        cal.objects[path] = ics to etag
        touch(cal, path)
        return etag
    }

    /** Removes an object directly (another client's delete). */
    fun remove(path: String) {
        val cal = calendarOf(path)
        cal.objects.remove(path)
        touch(cal, path)
    }

    fun ics(path: String): String? = calendars[path.substringBeforeLast('/')]?.objects?.get(path)?.first

    /** Rewrites an object's lines (another client's edit). */
    fun edit(path: String, transform: (String) -> String) = store(path, transform(ics(path)!!))

    override suspend fun calendars(): List<RemoteCalendar> = calendars.map { (path, c) ->
        RemoteCalendar(path, c.name, c.color, c.order, c.sections, c.labels, "tok-${c.token}")
    }

    override suspend fun changes(calendar: String, since: String?): CalendarChanges {
        changeRequests.add(calendar)
        val cal = calendars[calendar] ?: throw SyncError.NotFound(calendar)
        val from = since?.removePrefix("tok-")?.toIntOrNull()
        if (from == null) {
            return CalendarChanges("tok-${cal.token}", cal.objects.map { (p, o) -> RemoteResource(p, o.second, o.first) }, emptyList(), true)
        }
        val paths = cal.log.filter { it.first > from }.map { it.second }.toSortedSet()
        val changed = paths.mapNotNull { p -> cal.objects[p]?.let { RemoteResource(p, it.second, it.first) } }
        val removed = paths.filter { it !in cal.objects }
        return CalendarChanges("tok-${cal.token}", changed, removed, false)
    }

    override suspend fun createCalendar(path: String, name: String, color: String, order: String): Set<CalendarProperty> {
        writes.add("MKCALENDAR $path")
        calendars[path] = Calendar(name, color, order)
        touch(calendars.getValue(path), path)
        return emptySet()
    }

    override suspend fun setProperties(path: String, values: Map<CalendarProperty, String?>): Set<CalendarProperty> {
        writes.add("PROPPATCH $path")
        return emptySet()
    }

    override suspend fun deleteCalendar(path: String) {
        writes.add("DELETE-CALENDAR $path")
        calendars.remove(path)
    }

    override suspend fun share(path: String, user: String) {}

    override suspend fun put(path: String, ics: String, ifMatch: String?): String? {
        beforeWrite?.invoke("PUT", path)
        writes.add("PUT $path")
        if (path in forbidden) throw SyncError.Forbidden(path)
        val cal = calendarOf(path)
        val existing = cal.objects[path]
        if (ifMatch == null && existing != null) throw SyncError.PreconditionFailed(path)
        if (ifMatch != null && existing?.second != ifMatch) throw SyncError.PreconditionFailed(path)
        val etag = store(path, ics)
        return if (reportETags) etag else null
    }

    override suspend fun move(path: String, destination: String, ifMatch: String?) {
        beforeWrite?.invoke("MOVE", path)
        writes.add("MOVE $path $destination")
        val from = calendarOf(path)
        val to = calendarOf(destination)
        val existing = from.objects[path] ?: throw SyncError.NotFound(path)
        if (ifMatch != null && existing.second != ifMatch) throw SyncError.PreconditionFailed(path)
        if (destination in to.objects) throw SyncError.PreconditionFailed(destination)
        from.objects.remove(path)
        touch(from, path)
        to.objects[destination] = existing
        touch(to, destination)
    }

    override suspend fun delete(path: String, ifMatch: String?) {
        beforeWrite?.invoke("DELETE", path)
        writes.add("DELETE $path")
        if (path in forbidden) throw SyncError.Forbidden(path)
        val cal = calendars[path.substringBeforeLast('/')] ?: return
        val existing = cal.objects[path] ?: return
        if (ifMatch != null && existing.second != ifMatch) throw SyncError.PreconditionFailed(path)
        cal.objects.remove(path)
        touch(cal, path)
    }

    companion object {
        /** A VTODO object with [lines] (each a content line) in the master component. */
        fun vtodo(vararg lines: String, extra: String = ""): String =
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Other//EN\r\nBEGIN:VTODO\r\n" +
                lines.joinToString("") { "$it\r\n" } + "END:VTODO\r\n" + extra + "END:VCALENDAR\r\n"
    }
}
