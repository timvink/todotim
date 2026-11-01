package app.todotim.core.dav

import okhttp3.Credentials
import okhttp3.HttpUrl.Companion.toHttpUrl

/** The URL layout of a CalDAV server, answering discovery and the home listing (port of the Swift test helper). */
data class FakeDAVLayout(
    val user: String = "tim",
    /** "https://cloud.example.com" */
    val origin: String,
    /** The server URL the user enters (the DAV root). */
    val root: String,
    /** Where PROPFIND works (and names the principal); elsewhere the server answers 404. */
    val davArea: String,
    /** null: the server has no `current-user-principal`. */
    val principal: String?,
    /** The principal's `calendar-home-set`; null: none. */
    val home: String?,
    /** The origin in the `calendar-home-set` href, when the home is on another server (iCloud). */
    val homeOrigin: String? = null,
    /** Target of the redirect at `/.well-known/caldav` (a path, or an absolute URL); null: 404. */
    val wellKnown: String? = null,
    /** What a Depth 1 PROPFIND of the home lists. */
    val collections: List<Collection> = emptyList(),
    /** When set, requests without this password get 401. */
    val password: String? = null,
) {
    data class Collection(val name: String, val types: List<String>, val components: List<String> = emptyList())

    val serverURL: String get() = "$origin/" + (if (root.isEmpty()) "" else "$root/")

    /** An absolute-path href for [path]; "@" is percent-encoded, as some servers do. */
    private fun href(path: String): String = "/" + path.split('/').filter { it.isNotEmpty() }.joinToString("") { seg ->
        val sb = StringBuilder()
        for (b in seg.toByteArray()) {
            val c = b.toInt() and 0xFF
            if (c < 0x80 && (c.toChar().isLetterOrDigit() || c.toChar() in "-._~")) sb.append(c.toChar())
            else sb.append('%').append(String.format("%02X", c))
        }
        "$sb/"
    }

    fun respond(request: SentRequest): Reply {
        val url = request.url.toHttpUrl()
        val segments = WebDAVClient.decodedSegments(url) ?: return Reply(400)
        if (password != null && request.header("Authorization") != Credentials.basic(user, password, Charsets.UTF_8)) {
            return Reply(401, mapOf("WWW-Authenticate" to "Basic realm=\"dav\""))
        }
        val path = segments.joinToString("/")
        if (request.method != "PROPFIND") return Reply(405)
        if (path == ".well-known/caldav") {
            val wk = wellKnown ?: return Reply(404)
            return Reply(301, mapOf("Location" to if (wk.startsWith("http")) wk else "/$wk"))
        }
        if (!(davArea.isEmpty() || path == davArea || path.startsWith("$davArea/"))) {
            return Reply(404, mapOf("Content-Type" to "text/html"), "<html><body>Not found</body></html>")
        }
        val responses = ArrayList<String>()
        var props = ""
        if (request.body.contains("current-user-principal") && principal != null) {
            props += "<d:current-user-principal><d:href>${href(principal)}</d:href></d:current-user-principal>"
        }
        if (request.body.contains("calendar-home-set") && path == principal && home != null) {
            props += "<c:calendar-home-set><d:href>${homeOrigin ?: ""}${href(home)}</d:href></c:calendar-home-set>"
        }
        if (request.header("Depth") == "1" && path == home) {
            props += "<d:resourcetype><d:collection/></d:resourcetype>"
            for (c in collections) {
                responses.add(
                    "<d:response><d:href>${href("$path/${c.name}")}</d:href><d:propstat><d:prop>" +
                        "<d:resourcetype>${c.types.joinToString("") { "<$it/>" }}</d:resourcetype>" +
                        "<c:supported-calendar-component-set>${c.components.joinToString("") { "<c:comp name=\"$it\"/>" }}" +
                        "</c:supported-calendar-component-set><d:sync-token>http://example.com/sync/1</d:sync-token>" +
                        "<d:displayname>${c.name}</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>",
                )
            }
        }
        val own = if (props.isEmpty()) {
            "<d:propstat><d:prop><d:current-user-principal/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>"
        } else {
            "<d:propstat><d:prop>$props</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
        }
        responses.add(0, "<d:response><d:href>${href(path)}</d:href>$own</d:response>")
        val xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
            "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">${responses.joinToString("")}</d:multistatus>"
        return Reply(207, mapOf("Content-Type" to "application/xml; charset=utf-8"), xml)
    }

    companion object {
        fun nextcloud(user: String = "tim") = FakeDAVLayout(
            user = user, origin = "https://cloud.example.com", root = "remote.php/dav", davArea = "remote.php/dav",
            principal = "remote.php/dav/principals/users/$user", home = "remote.php/dav/calendars/$user",
            wellKnown = "remote.php/dav/",
        )

        /** Radicale: the principal is the calendar home, "/<user>/"; no well-known redirect. */
        fun radicale(user: String = "tim") = FakeDAVLayout(
            user = user, origin = "http://localhost:5232", root = "", davArea = "", principal = user, home = user,
        )

        /** Xandikos: principal "/user/", calendar home "/user/calendars/". */
        val xandikos = FakeDAVLayout(
            origin = "http://localhost:8080", root = "", davArea = "", principal = "user", home = "user/calendars", wellKnown = "",
        )

        /** A hosted service that answers WebDAV only below /dav/, found through /.well-known/caldav. */
        val hosted = FakeDAVLayout(
            user = "tim@example.com", origin = "https://caldav.example.com", root = "", davArea = "dav",
            principal = "dav/principals/user/tim@example.com", home = "dav/calendars/user/tim@example.com", wellKnown = "dav/",
        )
    }
}
