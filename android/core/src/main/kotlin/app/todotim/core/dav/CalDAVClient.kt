package app.todotim.core.dav

import app.todotim.core.SyncLimits
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient

/** A calendar in the user's calendar home, with the properties TodoTim syncs (raw values). */
@Serializable
data class RemoteCalendar(
    /** Relative to the DAV root, decoded, without trailing slash: "calendars/tim/work" on Nextcloud. */
    val path: String,
    val name: String? = null,
    /** `{http://apple.com/ns/ical/}calendar-color`, e.g. "#DB4035" or "#DB4035FF". */
    val color: String? = null,
    /** `{http://apple.com/ns/ical/}calendar-order` (an integer on Nextcloud). */
    val order: String? = null,
    /** `{https://todotim.app/ns}sections` / `labels` (raw JSON, see [PropertyList]); null when not set or not
     *  readable (a calendar shared with this user, or a server that refuses dead properties). */
    val sections: String? = null,
    val labels: String? = null,
    /** `{DAV:}sync-token` (RFC 6578), or [CalDAVClient.CTAG_PREFIX] + getctag on a server without sync-collection. */
    val syncToken: String? = null,
) {
    /** Last path segment (the calendar's URI). */
    val uri: String get() = path.substringAfterLast('/')

    /** The sections property, parsed and bounded; null when the property is missing or unreadable. */
    fun sectionEntries(): List<PropertyList.Entry>? = sections?.let(PropertyList::decode)

    /** The labels property (on the inbox calendar), parsed and bounded; null when missing or unreadable. */
    fun labelEntries(): List<PropertyList.Entry>? = labels?.let(PropertyList::decode)
}

/** One calendar object (task) on the server. */
data class RemoteResource(
    /** Relative to the DAV root, decoded: "calendars/tim/work/abc.ics". */
    val path: String,
    val etag: String?,
    val ics: String,
)

/** What changed in a calendar since a sync token. */
data class CalendarChanges(
    val syncToken: String?,
    val changed: List<RemoteResource>,
    /** Paths of members removed since the token. */
    val removed: List<String>,
    /** The token was not accepted (or none was given): [changed] is the complete content. */
    val isFull: Boolean,
)

/** Calendar properties TodoTim writes. */
enum class CalendarProperty(val namespace: String, val element: String) {
    NAME("DAV:", "displayname"),
    COLOR("http://apple.com/ns/ical/", "calendar-color"),
    ORDER("http://apple.com/ns/ical/", "calendar-order"),
    SECTIONS(CalDAVClient.TODOTIM_NS, "sections"),
    LABELS(CalDAVClient.TODOTIM_NS, "labels"),
    ;

    /** "namespace|element", as [Multistatus.Response.properties] keys it. */
    val qname: String get() = "$namespace|$element"

    companion object {
        /** Properties a server may refuse to store (Apple's and TodoTim's own dead properties); TodoTim then keeps
         *  them locally. The display name is standard WebDAV. */
        val OPTIONAL: Set<CalendarProperty> = setOf(COLOR, ORDER, SECTIONS, LABELS)
    }
}

/**
 * The CalDAV operations sync needs. [CalDAVClient] implements them over HTTP; tests can use an in-memory fake.
 * Paths are relative to the DAV root and not percent-encoded.
 */
interface CalDAVServer {
    /** The calendar home, relative to the DAV root: "calendars/<user>" on Nextcloud, "<user>" on Radicale, ""
     *  when the home is the DAV root itself. */
    val home: String

    /** Where the home is, for the sync state (so the next sync needs no discovery). */
    val calendarHome: CalendarHome

    /** The user's own calendars that hold only VTODOs (shared, subscribed, scheduling and event calendars are
     *  left out). */
    suspend fun calendars(): List<RemoteCalendar>

    /** Changes in [calendar] since [token] (RFC 6578 sync-collection, with calendar data); with a null or rejected
     *  token, or a ctag token, the full content. */
    suspend fun changes(calendar: String, since: String?): CalendarChanges

    /** MKCALENDAR with a VTODO-only component set. Returns the properties that could not be set with it. */
    suspend fun createCalendar(path: String, name: String, color: String, order: String): Set<CalendarProperty>

    /** PROPPATCH; a null value removes the property. Returns the optional properties the server refused to store;
     *  the others are set. Any other refusal throws. */
    suspend fun setProperties(path: String, values: Map<CalendarProperty, String?>): Set<CalendarProperty>

    suspend fun deleteCalendar(path: String)

    /** Shares a calendar read-write with another user (Nextcloud's sharing; other servers refuse it). */
    suspend fun share(path: String, user: String)

    /** PUT a calendar object: [ifMatch] null creates it (`If-None-Match: *`). Returns the new ETag if reported. */
    suspend fun put(path: String, ics: String, ifMatch: String?): String?

    /** MOVE a calendar object to another calendar (`If-Match` on the source, `Overwrite: F`). */
    suspend fun move(path: String, destination: String, ifMatch: String?)

    /** DELETE a calendar object; succeeds if it is already gone. */
    suspend fun delete(path: String, ifMatch: String?)
}

/**
 * CalDAV over [WebDAVClient] (docs/caldav.md). Server data is validated: paths must be direct children of the
 * calendar home or calendar, and responses are bounded.
 *
 * [home] is relative to `dav.baseURL` (by default the SabreDAV layout, "calendars/<username>").
 */
class CalDAVClient(
    val dav: WebDAVClient,
    val username: String,
    home: String? = null,
    calendarHome: CalendarHome? = null,
) : CalDAVServer {
    override val home: String = home ?: "calendars/$username"
    override val calendarHome: CalendarHome = calendarHome
        ?: CalendarHome(runCatching { dav.url(this.home, collection = true).toString() }.getOrElse { dav.baseURL.toString() })

    /** Decoded path of the user's principal ("remote.php/dav/principals/users/tim"), if discovery found it. */
    private val principalPath: String? = this.calendarHome.principal?.toHttpUrlOrNull()
        ?.let(WebDAVClient::decodedSegments)?.joinToString("/")

    private val xmlHeaders = mapOf("Content-Type" to "application/xml; charset=utf-8")

    // region Calendars

    override suspend fun calendars(): List<RemoteCalendar> {
        val props = CalendarProperty.entries.joinToString("") { "<x:${it.element} xmlns:x=\"${it.namespace}\"/>" }
        val body = """<?xml version="1.0" encoding="utf-8"?>""" + "\n" +
            """<d:propfind xmlns:d="DAV:" xmlns:c="$CALDAV_NS" xmlns:oc="$OWNCLOUD_NS" xmlns:cs="$CALENDARSERVER_NS">""" +
            "<d:prop><d:resourcetype/><c:supported-calendar-component-set/><d:sync-token/><cs:getctag/>" +
            "<oc:owner-principal/>$props</d:prop></d:propfind>"
        val doc = multistatus("PROPFIND", home, collection = true, depth = "1", body = body)
        val out = ArrayList<RemoteCalendar>()
        for (r in doc.responses) {
            val types = r.properties["DAV:|resourcetype"]?.children ?: emptyList()
            val path = dav.relativePath(r.href) ?: continue
            if (!isChild(path, home) || "$CALDAV_NS|calendar" !in types) continue
            // The scheduling inbox and outbox (RFC 6638) hold invitations, not tasks.
            if ("$CALDAV_NS|schedule-inbox" in types || "$CALDAV_NS|schedule-outbox" in types) continue
            if (r.properties["$CALDAV_NS|supported-calendar-component-set"]?.children != listOf("$CALDAV_NS|comp=VTODO")) continue
            // Calendars shared by other users also appear in the home (Nextcloud names them
            // "<uri>_shared_by_<owner>"); only the user's own are synced. Calendars that Nextcloud apps generate
            // (such as Deck boards, "app-generated--…") are read-only.
            if (path.substringAfterLast('/').startsWith("app-generated--")) continue
            val owner = r.text("$OWNCLOUD_NS|owner-principal")
            if (owner != null && !isOwnPrincipal(owner)) continue
            fun value(p: CalendarProperty) = r.text(p.qname)
            fun nonEmpty(qname: String) = r.text(qname)?.takeIf { it.isNotEmpty() }
            // Without sync-collection (RFC 6578 is optional), the CalendarServer ctag tells changes.
            val token = nonEmpty("DAV:|sync-token") ?: nonEmpty("$CALENDARSERVER_NS|getctag")?.let { CTAG_PREFIX + it }
            out.add(
                RemoteCalendar(
                    path = path,
                    name = value(CalendarProperty.NAME),
                    color = value(CalendarProperty.COLOR),
                    order = value(CalendarProperty.ORDER),
                    sections = value(CalendarProperty.SECTIONS),
                    labels = value(CalendarProperty.LABELS),
                    syncToken = token,
                ),
            )
        }
        return out
    }

    /**
     * With a sync token (RFC 6578), the changes since it; otherwise the full content. On a server without
     * sync-collection (a ctag token, or a REPORT it refuses), the full content by calendar-query, with no sync
     * token.
     */
    override suspend fun changes(calendar: String, since: String?): CalendarChanges {
        if (since?.startsWith(CTAG_PREFIX) == true) return allObjects(calendar)
        var token = since
        var isFull = since == null
        val changed = ArrayList<RemoteResource?>()
        val removed = ArrayList<String>()
        val seen = HashMap<String, Int>()
        // Changed objects reported without their data (Xandikos leaves calendar-data out of sync-collection, and
        // any server may fail a property): fetched with calendar-multiget.
        val withoutData = LinkedHashSet<String>()
        var finished = false
        var page = 0
        // Servers may return results in pages (a 507 response for the collection means "more").
        while (page < MAX_PAGES) {
            page++
            val body = """<?xml version="1.0" encoding="utf-8"?>""" + "\n" +
                """<d:sync-collection xmlns:d="DAV:" xmlns:c="$CALDAV_NS"><d:sync-token>${xmlEscape(token ?: "")}</d:sync-token>""" +
                "<d:sync-level>1</d:sync-level><d:prop><d:getetag/><c:calendar-data/></d:prop></d:sync-collection>"
            val doc = try {
                multistatus("REPORT", calendar, collection = true, depth = null, body = body, maxEntries = SyncLimits.MAX_TASKS + 1)
            } catch (e: SyncError) {
                when {
                    (e is SyncError.Forbidden || e is SyncError.Conflict) && token != null -> {
                        // valid-sync-token precondition failed (RFC 6578 §3.2, 403 or 409): start over.
                        token = null
                        isFull = true
                        changed.clear()
                        removed.clear()
                        seen.clear()
                        withoutData.clear()
                        continue
                    }
                    e is SyncError.Forbidden || e is SyncError.NotCalDAV ||
                        (e is SyncError.Http && e.status in setOf(400, 405, 415, 422, 501)) ->
                        // No sync-collection here (403 is RFC 3253's answer to an unsupported REPORT).
                        return allObjects(calendar)
                    else -> throw e
                }
            }
            var more = false
            for (r in doc.responses) {
                val path = dav.relativePath(r.href) ?: continue
                if (path == calendar) {
                    if (r.status == 507) more = true
                    continue
                }
                if (!isChild(path, calendar)) continue
                val ics = r.text("$CALDAV_NS|calendar-data")
                if (r.status == 404) {
                    removed.add(path)
                    seen.remove(path)?.let { changed[it] = null }
                    withoutData.remove(path)
                } else if (!ics.isNullOrEmpty()) {
                    val res = RemoteResource(path, WebDAVClient.normalizeETag(r.text("DAV:|getetag")), ics)
                    removed.remove(path)
                    withoutData.remove(path)
                    val i = seen[path]
                    if (i != null) {
                        changed[i] = res
                    } else {
                        seen[path] = changed.size
                        changed.add(res)
                    }
                } else {
                    removed.remove(path)
                    seen.remove(path)?.let { changed[it] = null }
                    withoutData.add(path)
                }
            }
            token = doc.syncToken ?: token
            if (!more) {
                finished = true
                break
            }
        }
        // A listing cut short must not count as complete (missing objects would look deleted).
        if (!finished) throw SyncError.LimitExceeded("more than $MAX_PAGES pages of changes in “$calendar”")
        val result = changed.filterNotNull().toMutableList()
        if (withoutData.isNotEmpty()) {
            val fetched = multiget(withoutData.sorted(), calendar)
            result += fetched.first
            removed += fetched.second
        }
        if (result.size > SyncLimits.MAX_TASKS) {
            throw SyncError.LimitExceeded("more than ${SyncLimits.MAX_TASKS} tasks in “$calendar”")
        }
        return CalendarChanges(token, result, removed.toList(), isFull)
    }

    /**
     * The objects at [paths] in [calendar], by calendar-multiget (RFC 4791 §7.9). Objects the server reports as
     * gone are returned as removed. Any other object it leaves out fails the listing, so that it cannot look
     * deleted.
     */
    private suspend fun multiget(paths: List<String>, calendar: String): Pair<List<RemoteResource>, List<String>> {
        val found = ArrayList<RemoteResource>()
        val removed = ArrayList<String>()
        for (batch in paths.chunked(MULTIGET_BATCH)) {
            val hrefs = batch.joinToString("") { "<d:href>${xmlEscape(dav.url(it).encodedPath)}</d:href>" }
            val body = """<?xml version="1.0" encoding="utf-8"?>""" + "\n" +
                """<c:calendar-multiget xmlns:d="DAV:" xmlns:c="$CALDAV_NS"><d:prop><d:getetag/><c:calendar-data/></d:prop>""" +
                "$hrefs</c:calendar-multiget>"
            val doc = multistatus("REPORT", calendar, collection = true, depth = "1", body = body, maxEntries = batch.size + 10)
            val missing = batch.toMutableSet()
            for (r in doc.responses) {
                val path = dav.relativePath(r.href) ?: continue
                if (path !in missing) continue
                val ics = r.text("$CALDAV_NS|calendar-data")
                if (!ics.isNullOrEmpty()) {
                    found.add(RemoteResource(path, WebDAVClient.normalizeETag(r.text("DAV:|getetag")), ics))
                    missing.remove(path)
                } else if (r.status == 404) {
                    removed.add(path)
                    missing.remove(path)
                }
            }
            missing.minOrNull()?.let { throw SyncError.BadRemoteData(it, "the server did not return its calendar data") }
        }
        return found to removed
    }

    /**
     * Every object in [calendar], by a calendar-query REPORT (RFC 4791 §7.8, which every CalDAV server has), with
     * no sync token. An object listed without its data is fetched by calendar-multiget, which fails the listing
     * if it cannot be read: the listing is taken as complete, so a missing object would look deleted.
     */
    private suspend fun allObjects(calendar: String): CalendarChanges {
        val body = """<?xml version="1.0" encoding="utf-8"?>""" + "\n" +
            """<c:calendar-query xmlns:d="DAV:" xmlns:c="$CALDAV_NS"><d:prop><d:getetag/><c:calendar-data/></d:prop>""" +
            """<c:filter><c:comp-filter name="VCALENDAR"/></c:filter></c:calendar-query>"""
        val doc = multistatus("REPORT", calendar, collection = true, depth = "1", body = body, maxEntries = SyncLimits.MAX_TASKS + 1)
        val changed = ArrayList<RemoteResource>()
        val seen = HashSet<String>()
        val withoutData = ArrayList<String>()
        for (r in doc.responses) {
            val path = dav.relativePath(r.href) ?: continue
            if (!isChild(path, calendar) || !seen.add(path)) continue
            val ics = r.text("$CALDAV_NS|calendar-data")
            if (!ics.isNullOrEmpty()) {
                changed.add(RemoteResource(path, WebDAVClient.normalizeETag(r.text("DAV:|getetag")), ics))
            } else if (r.status != 404) {
                withoutData.add(path)
            }
        }
        if (withoutData.isNotEmpty()) changed += multiget(withoutData, calendar).first
        if (changed.size > SyncLimits.MAX_TASKS) {
            throw SyncError.LimitExceeded("more than ${SyncLimits.MAX_TASKS} tasks in “$calendar”")
        }
        return CalendarChanges(null, changed, emptyList(), true)
    }

    override suspend fun createCalendar(path: String, name: String, color: String, order: String): Set<CalendarProperty> {
        val status = mkcalendar(path, name, color, order)
        if (status in 200..299) return emptySet()
        if (status !in setOf(400, 403, 409, 415, 422, 424)) throw mkcalendarError(status, path)
        // A server may refuse a property it does not know: try again with only the name and the component set
        // (the color and order then go through PROPPATCH, which may refuse them).
        val plain = mkcalendar(path, name, null, null)
        if (plain !in 200..299) throw mkcalendarError(plain, path)
        return setOf(CalendarProperty.COLOR, CalendarProperty.ORDER)
    }

    private suspend fun mkcalendar(path: String, name: String, color: String?, order: String?): Int {
        val apple = (color?.let { "<a:calendar-color>${xmlEscape(it)}</a:calendar-color>" } ?: "") +
            (order?.let { "<a:calendar-order>${xmlEscape(it)}</a:calendar-order>" } ?: "")
        val body = """<?xml version="1.0" encoding="utf-8"?>""" + "\n" +
            """<c:mkcalendar xmlns:d="DAV:" xmlns:c="$CALDAV_NS" xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop>""" +
            "<d:displayname>${xmlEscape(name)}</d:displayname>$apple" +
            """<c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>""" +
            "</d:prop></d:set></c:mkcalendar>"
        return dav.send("MKCALENDAR", path, collection = true, headers = xmlHeaders, body = body.toByteArray()).status
    }

    private fun mkcalendarError(status: Int, path: String): SyncError =
        if (status == 405) SyncError.CalendarExists(path) else WebDAVClient.error(status, path)

    override suspend fun setProperties(path: String, values: Map<CalendarProperty, String?>): Set<CalendarProperty> {
        if (values.isEmpty()) return emptySet()
        val status = proppatch(path, values)
        fun failed(s: Int?) = s != null && s !in 200..299
        val failures = values.keys.filter { failed(status[it]) }.toSet()
        if (failures.isEmpty()) return emptySet()
        // A property the server will not store fails with its own status (403, 409, …), the others with 424
        // (RFC 4918 §9.2), unless the server applied them anyway (Xandikos does).
        val refused = failures.filter { status[it] != 424 }.toSet()
        // A temporary failure (500, 423, 507, …) is not a refusal: the next sync sends it again.
        refused.mapNotNull { status[it] }.firstOrNull { it !in REFUSAL_STATUSES }?.let { throw WebDAVClient.error(it, path) }
        if (refused.isEmpty() || !CalendarProperty.OPTIONAL.containsAll(refused)) throw SyncError.Http(424, path)
        val retry = values.filterKeys { it in failures && it !in refused }
        if (retry.isNotEmpty()) {
            val again = proppatch(path, retry)
            if (retry.keys.any { failed(again[it]) }) throw SyncError.Http(424, path)
        }
        return refused
    }

    /** Sends a PROPPATCH; returns each property's status from a 207 response (none for another 2xx). */
    private suspend fun proppatch(path: String, values: Map<CalendarProperty, String?>): Map<CalendarProperty, Int> {
        val set = StringBuilder()
        val remove = StringBuilder()
        for ((p, v) in values.entries.sortedBy { it.key.name.lowercase() }) {
            if (v != null) {
                set.append("<x:${p.element} xmlns:x=\"${p.namespace}\">${xmlEscape(v)}</x:${p.element}>")
            } else {
                remove.append("<x:${p.element} xmlns:x=\"${p.namespace}\"/>")
            }
        }
        var body = """<?xml version="1.0" encoding="utf-8"?><d:propertyupdate xmlns:d="DAV:">"""
        if (set.isNotEmpty()) body += "<d:set><d:prop>$set</d:prop></d:set>"
        if (remove.isNotEmpty()) body += "<d:remove><d:prop>$remove</d:prop></d:remove>"
        body += "</d:propertyupdate>"
        val r = dav.send("PROPPATCH", path, collection = true, headers = xmlHeaders, body = body.toByteArray())
        if (r.status != 207 && r.status !in 200..299) throw WebDAVClient.error(r.status, path)
        if (r.status != 207) return emptyMap()
        val doc = try {
            Multistatus.parse(r.data, 16)
        } catch (e: Multistatus.Failure) {
            null
        }
        if (doc != null) {
            val status = HashMap<CalendarProperty, Int>()
            for (response in doc.responses) {
                for (p in values.keys) response.propertyStatus[p.qname]?.let { status[p] = it }
            }
            return status
        }
        // An unreadable 207 that reports an error fails the whole update.
        if (Regex("""HTTP/1\.[01] [45]\d\d""").containsMatchIn(r.text)) throw SyncError.Http(424, path)
        return emptyMap()
    }

    override suspend fun deleteCalendar(path: String) {
        val r = dav.send("DELETE", path, collection = true)
        if (r.status !in 200..299 && r.status != 404) throw WebDAVClient.error(r.status, path)
    }

    override suspend fun share(path: String, user: String) {
        val body = """<o:share xmlns:d="DAV:" xmlns:o="$OWNCLOUD_NS"><o:set>""" +
            "<d:href>principal:principals/users/${xmlEscape(user)}</d:href><o:read-write/></o:set></o:share>"
        val r = dav.send("POST", path, collection = true, headers = mapOf("Content-Type" to "application/xml"), body = body.toByteArray())
        if (r.status !in 200..299) {
            // A server without Nextcloud's sharing has no POST here.
            if (r.status == 405 || r.status == 501) throw SyncError.SharingUnsupported
            throw WebDAVClient.error(r.status, path)
        }
    }

    // endregion

    // region Tasks

    override suspend fun put(path: String, ics: String, ifMatch: String?): String? {
        val headers = mutableMapOf("Content-Type" to "text/calendar; charset=utf-8")
        if (ifMatch != null) headers["If-Match"] = ifMatch else headers["If-None-Match"] = "*"
        val r = dav.send("PUT", path, headers = headers, body = ics.toByteArray())
        if (r.status !in 200..299) throw WebDAVClient.error(r.status, path)
        return r.etag
    }

    override suspend fun move(path: String, destination: String, ifMatch: String?) {
        val headers = mutableMapOf("Destination" to dav.absoluteString(destination), "Overwrite" to "F")
        if (ifMatch != null) headers["If-Match"] = ifMatch
        val r = dav.send("MOVE", path, headers = headers)
        if (r.status !in 200..299) throw WebDAVClient.error(r.status, path)
    }

    override suspend fun delete(path: String, ifMatch: String?) {
        val r = dav.send("DELETE", path, headers = ifMatch?.let { mapOf("If-Match" to it) } ?: emptyMap())
        if (r.status !in 200..299 && r.status != 404) throw WebDAVClient.error(r.status, path)
    }

    // endregion

    private suspend fun multistatus(
        method: String,
        path: String,
        collection: Boolean,
        depth: String?,
        body: String,
        maxEntries: Int = SyncLimits.MAX_LISTING_ENTRIES,
    ): Multistatus.Document {
        val headers = xmlHeaders.toMutableMap()
        if (depth != null) headers["Depth"] = depth
        val r = dav.send(method, path, collection, headers, body.toByteArray())
        return when (r.status) {
            207 -> try {
                Multistatus.parse(r.data, maxEntries) ?: throw SyncError.NotCalDAV
            } catch (e: Multistatus.Failure.TooManyEntries) {
                throw SyncError.LimitExceeded("more than $maxEntries entries in “$path”")
            } catch (e: Multistatus.Failure) {
                throw SyncError.BadRemoteData(path, "the response is not plain WebDAV XML (${e.message})")
            }
            in 200..299 -> throw SyncError.NotCalDAV
            else -> throw WebDAVClient.error(r.status, path)
        }
    }

    /** Whether a Nextcloud `owner-principal` ("principals/users/tim") is this user: the principal named after the
     *  username, or the discovered one (the login name can differ from the user id). */
    private fun isOwnPrincipal(owner: String): Boolean {
        val trimmed = owner.trim('/')
        if (trimmed == "principals/users/$username") return true
        val decoded = WebDAVClient.percentDecode(trimmed) ?: trimmed
        val principal = principalPath ?: return false
        if (decoded.isEmpty()) return false
        return principal == decoded || principal.endsWith("/$decoded")
    }

    companion object {
        const val TODOTIM_NS = "https://todotim.app/ns"
        private const val CALDAV_NS = "urn:ietf:params:xml:ns:caldav"
        private const val CALENDARSERVER_NS = "http://calendarserver.org/ns/"
        private const val OWNCLOUD_NS = "http://owncloud.org/ns"

        /** Marks a [RemoteCalendar.syncToken] that is a getctag: the calendar has no sync-collection. */
        const val CTAG_PREFIX = "ctag:"

        /** Pages of a sync-collection REPORT followed before giving up. */
        const val MAX_PAGES = 100

        /** Objects per calendar-multiget request. */
        const val MULTIGET_BATCH = 100

        /** Property statuses by which a server says it will not store a property at all (RFC 4918 §9.2.1). */
        val REFUSAL_STATUSES = setOf(400, 403, 405, 409, 422, 501)

        /**
         * A client for the calendar home [home] (from discovery or the sync state) of the server at [serverURL].
         * Requests stay inside the DAV root when the home is inside it, and otherwise inside the home itself. A
         * home on another origin is refused with [SyncError.OtherServer].
         */
        fun create(
            serverURL: String,
            username: String,
            password: String,
            home: CalendarHome,
            httpClient: OkHttpClient? = null,
        ): CalDAVClient {
            val root = davRoot(serverURL)
            if (WebDAVClient.hasDotSegment(home.url)) throw SyncError.InvalidPath(home.url)
            val url = home.url.toHttpUrlOrNull()?.let { WebDAVClient.canonicalURL(it, collection = true) }
                ?: throw SyncError.InvalidPath(home.url)
            if (!WebDAVClient.isSameOrigin(url, root)) throw SyncError.OtherServer(WebDAVClient.displayString(url))
            val base = if (WebDAVClient.isWithin(url, root)) root else url
            val dav = WebDAVClient(base.toString(), username, password, httpClient)
            val path = dav.relativePath(url.toString()) ?: throw SyncError.InvalidPath(home.url)
            return CalDAVClient(dav, username, path, home)
        }

        /** A client for the calendar home of [serverURL]: [cached] (from the sync state), or else the one
         *  discovery finds ([CalDAVDiscovery]). */
        suspend fun connect(
            serverURL: String,
            username: String,
            password: String,
            cached: CalendarHome?,
            httpClient: OkHttpClient? = null,
        ): CalDAVClient {
            val home = cached ?: CalDAVDiscovery.discover(serverURL, username, password, httpClient)
            return create(serverURL, username, password, home, httpClient)
        }

        /** The DAV root for a configured server URL: the URL itself, or, for an old-style files URL
         *  (".../remote.php/dav/files/USER/"), the part before "files/". */
        fun davRoot(serverURL: String): HttpUrl {
            val url = WebDAVClient.normalizedBaseURL(serverURL)
            val segments = url.encodedPathSegments.filter { it.isNotEmpty() }
            if (segments.size >= 2 && segments[segments.size - 2] == "files") {
                val path = "/" + segments.dropLast(2).joinToString("") { "$it/" }
                return url.newBuilder().encodedPath(path).build()
            }
            return url
        }

        /** Whether [path] is a direct child of [parent] ("" is the DAV root). */
        fun isChild(path: String, parent: String): Boolean {
            val name = if (parent.isEmpty()) {
                path
            } else {
                if (!path.startsWith("$parent/")) return false
                path.substring(parent.length + 1)
            }
            return name.isNotEmpty() && !name.contains('/')
        }
    }
}

/** The path of [child] in the collection [parent], both relative to the DAV root ("" is the root). */
fun davPath(parent: String, child: String): String = if (parent.isEmpty()) child else "$parent/$child"

fun xmlEscape(s: String): String {
    val sb = StringBuilder(s.length)
    for (c in s) {
        when (c) {
            '&' -> sb.append("&amp;")
            '<' -> sb.append("&lt;")
            '>' -> sb.append("&gt;")
            '"' -> sb.append("&quot;")
            else -> sb.append(c)
        }
    }
    return sb.toString()
}
