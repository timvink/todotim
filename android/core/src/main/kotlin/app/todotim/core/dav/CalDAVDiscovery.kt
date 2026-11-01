package app.todotim.core.dav

import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient

/** Where the user's calendars are, as found by discovery. The sync state keeps it, so discovery runs once per
 *  account and again only when the home stops working (404/403), or for another server URL or username. */
@Serializable
data class CalendarHome(
    /** Absolute URL of the calendar home collection, ending in "/". */
    val url: String,
    /** Absolute URL of the user's principal (`current-user-principal`); null when discovery found none. */
    val principal: String? = null,
)

/**
 * Finds the calendar home for a server URL, as RFC 6764 (§6) and RFC 4791 (§6.2.1) describe:
 *
 * 1. `PROPFIND` (Depth 0) of `current-user-principal` on the server URL (the DAV root), and when that names no
 *    principal, on `/.well-known/caldav` of the same origin.
 * 2. `PROPFIND` (Depth 0) of `calendar-home-set` on that principal.
 *
 * When neither gives a home, the home is `calendars/<username>/` below the server URL (the SabreDAV layout of
 * Nextcloud, ownCloud and Baïkal).
 *
 * Every request goes to the server URL's origin (scheme, host and port). Redirects are followed here, one hop
 * at a time, so PROPFIND stays PROPFIND and each target is checked. A principal, home or redirect on another
 * origin (such as iCloud's `pNN-caldav` hosts, or https → http) is refused with [SyncError.OtherServer], so the
 * password only goes to the server the user entered.
 */
object CalDAVDiscovery {
    const val MAX_REDIRECTS = 5
    const val MAX_ENTRIES = 64
    private const val CALDAV_NS = "urn:ietf:params:xml:ns:caldav"

    suspend fun discover(
        serverURL: String,
        username: String,
        password: String,
        httpClient: OkHttpClient? = null,
    ): CalendarHome {
        val root = CalDAVClient.davRoot(serverURL)
        val origin = WebDAVClient.originRoot(root)
        val dav = WebDAVClient(origin.toString(), username, password, httpClient)
        dav.followsRedirects = false
        dav.maxResponseBytes = app.todotim.core.SyncLimits.MAX_DISCOVERY_RESPONSE_BYTES

        var principal: HttpUrl? = null
        // The well-known URL has no trailing slash: servers often match it exactly.
        val wellKnown = origin.resolve(".well-known/caldav")!!
        for (start in listOf(root, wellKnown)) {
            principal = hrefs("DAV:|current-user-principal", "<d:current-user-principal/>", start, dav).firstOrNull()
            if (principal != null) break
        }
        val principalURL = principal?.let { WebDAVClient.canonicalURL(it, collection = true) }?.toString()
        if (principal != null) {
            val homes = hrefs("$CALDAV_NS|calendar-home-set", "<c:calendar-home-set/>", principal, dav)
            val home = homes.firstNotNullOfOrNull { WebDAVClient.canonicalURL(it, collection = true) }
            if (home != null) return CalendarHome(home.toString(), principalURL)
        }
        val fallback = legacyHome(root, username) ?: throw SyncError.InvalidURL(serverURL)
        return CalendarHome(fallback, principalURL)
    }

    /** The home TodoTim used before discovery, and uses when discovery finds none: `calendars/<username>/` below
     *  the DAV root. */
    fun legacyHome(root: HttpUrl, username: String): String? {
        val segments = (WebDAVClient.decodedSegments(root) ?: return null) + "calendars" +
            username.split('/').filter { it.isNotEmpty() }
        if (segments.any { it == "." || it == ".." }) return null
        val path = segments.joinToString("/") { WebDAVClient.encodeSegment(it) } + "/"
        return (WebDAVClient.originRoot(root).toString() + path).toHttpUrlOrNull()?.toString()
    }

    /**
     * The hrefs in property [property] of the resource at [start], resolved, on the origin of `dav.baseURL`.
     * Empty when the server has no such resource or property (or is not WebDAV). Throws for a wrong password,
     * a server error, and a redirect, principal or home on another origin.
     */
    private suspend fun hrefs(property: String, element: String, start: HttpUrl, dav: WebDAVClient): List<HttpUrl> {
        val body = """<?xml version="1.0" encoding="utf-8"?>
            |<d:propfind xmlns:d="DAV:" xmlns:c="$CALDAV_NS"><d:prop>$element</d:prop></d:propfind>
        """.trimMargin().toByteArray()
        val headers = mapOf("Content-Type" to "application/xml; charset=utf-8", "Depth" to "0")
        var url = start
        repeat(MAX_REDIRECTS + 1) {
            val r = dav.send("PROPFIND", url, headers, body)
            when (r.status) {
                207 -> {
                    val doc = try {
                        Multistatus.parse(r.data, MAX_ENTRIES)
                    } catch (e: Multistatus.Failure) {
                        return emptyList()
                    }
                    val found = ArrayList<HttpUrl>()
                    var elsewhere: HttpUrl? = null
                    for (href in doc?.responses?.flatMap { it.properties[property]?.hrefs ?: emptyList() } ?: emptyList()) {
                        val target = WebDAVClient.resolveHref(href, url) ?: continue
                        if (WebDAVClient.isSameOrigin(target, dav.baseURL)) found.add(target) else if (elsewhere == null) elsewhere = target
                    }
                    if (found.isEmpty() && elsewhere != null) throw SyncError.OtherServer(WebDAVClient.displayString(elsewhere!!))
                    return found
                }
                in 300..399 -> {
                    val target = r.location?.let { WebDAVClient.resolveHref(it, url) } ?: return emptyList()
                    if (!WebDAVClient.isSameOrigin(target, dav.baseURL)) {
                        throw SyncError.OtherServer(WebDAVClient.displayString(target))
                    }
                    url = target
                }
                401 -> throw SyncError.Unauthorized
                429, 500, in 502..599 -> throw WebDAVClient.error(r.status, decodedPath(url))
                // 404, 405, 403, 501, a web page (200), …: nothing here.
                else -> return emptyList()
            }
        }
        throw SyncError.BadRemoteData(decodedPath(start), "more than $MAX_REDIRECTS redirects")
    }

    private fun decodedPath(url: HttpUrl): String = "/" + url.pathSegments.joinToString("/")
}
