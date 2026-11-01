package app.todotim.core.sync

import app.todotim.core.INBOX_CALENDAR
import app.todotim.core.dav.CalDAVClient
import app.todotim.core.dav.CalDAVServer
import app.todotim.core.dav.CalendarChanges
import app.todotim.core.dav.CalendarProperty
import app.todotim.core.dav.RemoteCalendar
import app.todotim.core.dav.RemoteResource
import app.todotim.core.dav.davPath
import org.junit.Assume.assumeTrue

/** A real CalDAV server for the live tests, from `TODOTIM_LIVE_URL`, `TODOTIM_LIVE_USER` and `TODOTIM_LIVE_PASSWORD`. */
object LiveServer {
    /** Skips the test unless the variables are set; otherwise connects (by discovery). */
    suspend fun connect(): CalDAVClient {
        val env = System.getenv()
        val url = env["TODOTIM_LIVE_URL"]
        val user = env["TODOTIM_LIVE_USER"]
        val password = env["TODOTIM_LIVE_PASSWORD"]
        assumeTrue("set TODOTIM_LIVE_URL, TODOTIM_LIVE_USER and TODOTIM_LIVE_PASSWORD to run", url != null && user != null && password != null)
        return CalDAVClient.connect(url!!, user!!, password!!, null)
    }

    /** Deletes every task list of the account (and the inbox), with their properties. */
    suspend fun wipe(client: CalDAVClient) {
        val paths = client.calendars().map { it.path }.toMutableSet()
        paths.add(davPath(client.home, INBOX_CALENDAR))
        for (path in paths) {
            runCatching { client.setProperties(path, mapOf(CalendarProperty.SECTIONS to null, CalendarProperty.LABELS to null)) }
            client.dav.send("DELETE", path, collection = true, headers = mapOf("X-NC-CalDAV-No-Trashbin" to "1"))
        }
    }

    /** The object at [path], read directly from the server. */
    suspend fun obj(server: CalDAVServer, path: String): RemoteResource? =
        server.changes(path.substringBeforeLast('/'), null).changed.firstOrNull { it.path == path }

    fun unfold(ics: String) = ics.replace("\r\n", "\n").replace("\n ", "").replace("\n\t", "")
}

/** Passes everything to [base], counting requests, and runs [beforePut] hooks once before a PUT of their path. */
class Recording(private val base: CalDAVServer) : CalDAVServer {
    override val home get() = base.home
    override val calendarHome get() = base.calendarHome
    val writes = mutableListOf<String>()
    var changeRequests = 0
    val beforePut = mutableMapOf<String, suspend () -> Unit>()

    override suspend fun calendars(): List<RemoteCalendar> = base.calendars()
    override suspend fun changes(calendar: String, since: String?): CalendarChanges {
        changeRequests++
        return base.changes(calendar, since)
    }
    override suspend fun createCalendar(path: String, name: String, color: String, order: String): Set<CalendarProperty> {
        writes.add("MKCALENDAR $path")
        return base.createCalendar(path, name, color, order)
    }
    override suspend fun setProperties(path: String, values: Map<CalendarProperty, String?>): Set<CalendarProperty> {
        writes.add("PROPPATCH $path")
        return base.setProperties(path, values)
    }
    override suspend fun deleteCalendar(path: String) {
        writes.add("DELETE-CALENDAR $path")
        base.deleteCalendar(path)
    }
    override suspend fun share(path: String, user: String) = base.share(path, user)
    override suspend fun put(path: String, ics: String, ifMatch: String?): String? {
        beforePut.remove(path)?.invoke()
        writes.add("PUT $path")
        return base.put(path, ics, ifMatch)
    }
    override suspend fun move(path: String, destination: String, ifMatch: String?) {
        writes.add("MOVE $path $destination")
        base.move(path, destination, ifMatch)
    }
    override suspend fun delete(path: String, ifMatch: String?) {
        writes.add("DELETE $path")
        base.delete(path, ifMatch)
    }
}
