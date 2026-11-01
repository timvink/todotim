package app.todotim.core.dav

import kotlinx.coroutines.test.runTest
import okhttp3.Credentials
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Realistic Nextcloud response to PROPFIND Depth 1 on a calendar home (trimmed). */
internal val CALENDAR_HOME = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:response><d:href>/remote.php/dav/calendars/tim/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/todotim-inbox/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
   <d:sync-token>http://sabre.io/ns/sync/7</d:sync-token>
   <oc:owner-principal>principals/users/tim</oc:owner-principal>
   <d:displayname>Inbox</d:displayname>
   <x1:calendar-color xmlns:x1="http://apple.com/ns/ical/">#808080</x1:calendar-color>
   <x2:labels xmlns:x2="https://todotim.app/ns">[{&quot;id&quot;:&quot;l1&quot;,&quot;name&quot;:&quot;A &amp; B&quot;,&quot;order&quot;:1}]</x2:labels>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  <d:propstat><d:prop><x2:sections xmlns:x2="https://todotim.app/ns"/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/personal/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VEVENT"/><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
   <oc:owner-principal>principals/users/tim</oc:owner-principal>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/list_shared_by_bob/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
   <oc:owner-principal>principals/users/bob</oc:owner-principal>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/inbox/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/><cal:schedule-inbox/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>https://evil.example.com/remote.php/dav/calendars/tim/evil/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>
"""

internal val SYNC_COLLECTION = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
 <d:response><d:href>/remote.php/dav/calendars/tim/work/a.ics</d:href>
  <d:propstat><d:prop><d:getetag>&quot;e1&quot;</d:getetag><cal:calendar-data>BEGIN:VCALENDAR
BEGIN:VTODO
UID:a
END:VTODO
END:VCALENDAR
</cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/work/gone.ics</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/work/sub/nested.ics</d:href>
  <d:propstat><d:prop><cal:calendar-data>x</cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/tim/work/%2E%2E</d:href>
  <d:propstat><d:prop><cal:calendar-data>x</cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:sync-token>http://sabre.io/ns/sync/9</d:sync-token>
</d:multistatus>
"""

class WebDAVClientTest {
    private val server = TestServer()

    @After fun tearDown() = server.close()

    private fun caldav(username: String = "tim", home: String? = null, calendarHome: CalendarHome? = null) =
        CalDAVClient(server.webdav(), username, home, calendarHome)

    private suspend inline fun <reified E : SyncError> assertFails(block: () -> Unit): E {
        try {
            block()
        } catch (e: SyncError) {
            if (e is E) return e
            fail("expected ${E::class.simpleName}, got $e")
        }
        fail("expected ${E::class.simpleName}")
        throw AssertionError()
    }

    // region Multistatus

    @Test fun parsesMultistatusProperties() {
        val doc = Multistatus.parse(CALENDAR_HOME.toByteArray())!!
        assertEquals(6, doc.responses.size)
        val inbox = doc.responses[1]
        assertEquals("Inbox", inbox.text("DAV:|displayname"))
        assertEquals(listOf("DAV:|collection", "urn:ietf:params:xml:ns:caldav|calendar"), inbox.properties["DAV:|resourcetype"]?.children)
        assertEquals(
            listOf("urn:ietf:params:xml:ns:caldav|comp=VTODO"),
            inbox.properties["urn:ietf:params:xml:ns:caldav|supported-calendar-component-set"]?.children,
        )
        assertEquals("""[{"id":"l1","name":"A & B","order":1}]""", inbox.text("https://todotim.app/ns|labels"))
        assertNull("properties in a 404 propstat are ignored", inbox.properties["https://todotim.app/ns|sections"])
        assertEquals(404, inbox.propertyStatus["https://todotim.app/ns|sections"])

        val changes = Multistatus.parse(SYNC_COLLECTION.toByteArray())!!
        assertEquals("http://sabre.io/ns/sync/9", changes.syncToken)
        assertEquals(404, changes.responses[1].status)
        assertTrue(changes.responses[0].text("urn:ietf:params:xml:ns:caldav|calendar-data")!!.contains("UID:a"))
        assertEquals("\"e1\"", changes.responses[0].text("DAV:|getetag"))
    }

    @Test fun parsesCDataCharacterReferencesAndHrefs() {
        val xml = """<d:multistatus xmlns:d="DAV:"><d:response><d:href>/a/</d:href><d:propstat><d:prop>
            <d:displayname><![CDATA[x < y]]> &#38; &#x7A;</d:displayname>
            <d:current-user-principal><d:href>/p/1/</d:href><d:href>/p/2/</d:href></d:current-user-principal>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"""
        val r = Multistatus.parse(xml.toByteArray())!!.responses.single()
        assertEquals("x < y & z", r.text("DAV:|displayname"))
        assertEquals(listOf("/p/1/", "/p/2/"), r.properties["DAV:|current-user-principal"]?.hrefs)
    }

    @Test fun rejectsNonMultistatus() {
        assertNull(Multistatus.parse("<html><body>Nextcloud</body></html>".toByteArray()))
        assertNull(Multistatus.parse("not xml".toByteArray()))
        assertNull(Multistatus.parse("<d:multistatus xmlns:d=\"DAV:\"><d:response>".toByteArray()))
        assertNull(Multistatus.parse("<d:multistatus xmlns:d=\"DAV:\">".toByteArray()))
        // Nothing but whitespace, comments and processing instructions may follow the root element.
        for (trailing in listOf("<extra/>", "text", "<d:multistatus xmlns:d=\"DAV:\"/>", "<a>")) {
            assertNull(trailing, Multistatus.parse("<d:multistatus xmlns:d=\"DAV:\"/>$trailing".toByteArray()))
        }
        assertEquals(0, Multistatus.parse("<d:multistatus xmlns:d=\"DAV:\"/>\n<!-- c --><?pi x?> \n".toByteArray())!!.responses.size)
    }

    @Test fun parserRefusesDTDAndEntitiesAndCapsEntries() {
        val xxe = """<?xml version="1.0"?>
<!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]>
<d:multistatus xmlns:d="DAV:"><d:response><d:href>&x;</d:href></d:response></d:multistatus>"""
        try {
            Multistatus.parse(xxe.toByteArray())
            fail("expected Dtd")
        } catch (e: Multistatus.Failure.Dtd) {
        }
        // An undeclared entity without a DTD is not expanded either.
        val undeclared = """<d:multistatus xmlns:d="DAV:"><d:response><d:href>&x;</d:href></d:response></d:multistatus>"""
        val result = runCatching { Multistatus.parse(undeclared.toByteArray()) }
        assertTrue(result.isFailure || result.getOrNull() == null)

        try {
            Multistatus.parse(CALENDAR_HOME.toByteArray(), maxEntries = 3)
            fail("expected TooManyEntries")
        } catch (e: Multistatus.Failure.TooManyEntries) {
        }
        assertEquals(6, Multistatus.parse(CALENDAR_HOME.toByteArray(), maxEntries = 6)?.responses?.size)
    }

    @Test fun parserCapsTextLength() {
        val big = "x".repeat(Multistatus.MAX_TEXT_LENGTH + 1)
        val xml = """<d:multistatus xmlns:d="DAV:"><d:response><d:href>/a</d:href><d:propstat><d:prop><d:displayname>$big</d:displayname></d:prop></d:propstat></d:response></d:multistatus>"""
        try {
            Multistatus.parse(xml.toByteArray())
            fail("expected TextTooLong")
        } catch (e: Multistatus.Failure.TextTooLong) {
        }
    }

    // endregion

    // region URLs and paths

    @Test fun baseURLNormalizationAndPathEncoding() {
        for (bad in listOf("https://tim:pw@cloud.example.com/dav/", "https://cloud.example.com/dav/?x=1", "", "ftp://x/", "cloud.example.com",
            "https://cloud.example.com/dav/#x", "https://cloud.example.com/a/../dav/")) {
            assertFails(bad) { WebDAVClient.normalizedBaseURL(bad) }
        }
        val client = WebDAVClient("  https://cloud.example.com/remote.php/dav ", "tim", "pw")
        assertEquals("https://cloud.example.com/remote.php/dav/", client.baseURL.toString())
        assertEquals("https://cloud.example.com/remote.php/dav/calendars/tim%20v/a%23b%3F.ics", client.url("calendars/tim v/a#b?.ics").toString())
        assertEquals("https://cloud.example.com/remote.php/dav/calendars/tim/", client.url("/calendars/tim/", collection = true).toString())
        assertEquals("https://cloud.example.com/remote.php/dav/a/%C3%A9%25/b@x", client.url("a/é%/b@x").toString())
    }

    private fun assertFails(label: String, block: () -> Unit) {
        try {
            block()
            fail("expected an error: $label")
        } catch (e: SyncError) {
        }
    }

    @Test fun davRootFromServerURL() {
        assertEquals("https://c.example.com/remote.php/dav/", CalDAVClient.davRoot("https://c.example.com/remote.php/dav").toString())
        assertEquals(
            "an old files URL still works",
            "https://c.example.com/remote.php/dav/",
            CalDAVClient.davRoot("https://c.example.com/remote.php/dav/files/tim/").toString(),
        )
        assertFails("http") { CalDAVClient.davRoot("http://c.example.com/remote.php/dav/") }
    }

    @Test fun plainHTTPOnlyForLocalhost() {
        try {
            WebDAVClient.normalizedBaseURL("http://cloud.example.com/dav/")
            fail()
        } catch (e: SyncError) {
            assertEquals(SyncError.InsecureURL("http://cloud.example.com/dav/"), e)
            assertTrue(e.message!!.contains("https://"))
        }
        for (ok in listOf("http://localhost:8080/dav/", "http://127.0.0.1/dav/", "http://[::1]:8080/dav/", "HTTP://LOCALHOST/")) {
            WebDAVClient.normalizedBaseURL(ok)
        }
    }

    @Test fun refusesDotAndEmptySegments() = runTest {
        val client = server.webdav()
        for (bad in listOf("a/../b", "..", "calendars/tim/../../outside", "./x", "a//b", "a/./b")) {
            try {
                client.url(bad)
                fail(bad)
            } catch (e: SyncError) {
                assertEquals(SyncError.InvalidPath(bad), e)
            }
        }
        server.handler = { Reply(200) }
        val e = assertFails<SyncError.InvalidPath> { client.send("GET", "calendars/../../outside") }
        assertEquals(SyncError.InvalidPath("calendars/../../outside"), e)
        assertTrue("no request is sent for an unsafe path", server.requests.isEmpty())
        assertEquals("https://cloud.example.com/remote.php/dav/a/..b/c..ics", client.url("a/..b/c..ics").toString())
        // An absolute URL outside the base is refused without a request.
        assertFails<SyncError.InvalidPath> { client.send("GET", "https://cloud.example.com/remote.php/other/x".toUrl()) }
        assertFails<SyncError.InvalidPath> { client.send("GET", "https://cloud.example.com/remote.php/dav/x?y=1".toUrl()) }
        assertTrue(server.requests.isEmpty())
    }

    @Test fun relativePathOfHrefStaysInsideBase() {
        val client = server.webdav()
        assertEquals("calendars/tim/work/a b.ics", client.relativePath("/remote.php/dav/calendars/tim/work/a%20b.ics"))
        assertEquals("calendars/tim", client.relativePath("https://cloud.example.com/remote.php/dav/calendars/tim/"))
        for (bad in listOf(
            "https://evil.example.com/remote.php/dav/calendars/tim/x.ics",
            "https://cloud.example.com:8443/remote.php/dav/calendars/tim/x.ics",
            "http://cloud.example.com/remote.php/dav/calendars/tim/x.ics",
            "/remote.php/other/x.ics", "/remote.php/dav/../x",
            "/remote.php/dav/calendars/tim/%2E%2E/x", "/remote.php/dav/calendars/tim/%2e/x",
            "/remote.php/dav/calendars/tim/a%2Fb.ics",
            // Empty interior segments are not collapsed.
            "/remote.php/dav/calendars/tim/work//a.ics", "/remote.php//dav/calendars/tim/a.ics",
            // OkHttp reads "\" as "/": a backslash, raw or encoded, is refused.
            "/remote.php/dav/a/..\\calendars/tim/a.ics", "/remote.php/dav/calendars\\tim/a.ics",
            "/remote.php/dav/calendars/tim/a%5Cb.ics", "/remote.php/dav/a/%2E%2E%5Ccalendars/x.ics",
        )) {
            assertNull(bad, client.relativePath(bad))
        }
    }

    @Test fun emptySegmentsAndBackslashesAreRefused() {
        val base = "https://host/dav/tim/".toUrl()
        assertTrue(WebDAVClient.isWithin("https://host/dav/tim/a.ics".toUrl(), base))
        assertFalse(WebDAVClient.isWithin("https://host/dav//tim/a.ics".toUrl(), base))
        assertFalse(WebDAVClient.isWithin("https://host/dav/tim//a.ics".toUrl(), base))
        assertFalse(WebDAVClient.isWithin("https://host/dav/tim/a.ics".toUrl(), "https://host/dav//tim/".toUrl()))
        for (bad in listOf("https://host/dav//tim/", "https://host/dav\\tim/", "https://host/dav/a/..\\tim/", "https://host/dav/%5C/")) {
            try {
                WebDAVClient.normalizedBaseURL(bad)
                fail("accepted $bad")
            } catch (e: SyncError.InvalidURL) {
            }
        }
        for (bad in listOf("/dav/tim//a.ics", "/dav/a/..\\tim/a.ics", "\\\\evil.example.com/dav/", "/dav/tim/%5c")) {
            assertNull(bad, WebDAVClient.resolveHref(bad, base))
        }
        assertEquals("https://host/dav/tim/a.ics", WebDAVClient.resolveHref("a.ics", base).toString())
    }

    @Test fun pathsAreComparedDecodedAndHomeCanBeTheRoot() {
        val client = WebDAVClient("https://dav.example.com/dav/calendars/user/tim@example.com/", "tim@example.com", "pw")
        assertEquals("work", client.relativePath("/dav/calendars/user/tim%40example.com/work/"))
        assertEquals("", client.relativePath("https://dav.example.com/dav/calendars/user/tim@example.com/"))
        assertNull(client.relativePath("/dav/calendars/user/bob%40example.com/work/"))
        assertTrue(CalDAVClient.isChild("work", ""))
        assertFalse(CalDAVClient.isChild("", ""))
        assertFalse(CalDAVClient.isChild("work/a.ics", ""))
        assertTrue(CalDAVClient.isChild("work/a.ics", "work"))
        assertFalse(CalDAVClient.isChild("work2/a.ics", "work"))
        assertEquals("work", davPath("", "work"))
        assertEquals("tim/work", davPath("tim", "work"))
    }

    // endregion

    // region Requests

    /** Xandikos answers 423 (Locked) to a write while it writes another one: sent again. */
    @Test fun lockedRequestsAreSentAgain() = runTest {
        val client = server.webdav()
        client.lockedRetryDelayMillis = 1
        var calls = 0
        server.handler = {
            calls++
            if (calls < 3) Reply(423) else Reply(204, mapOf("ETag" to "\"e2\""))
        }
        val r = client.send("PUT", "calendars/tim/work/a.ics", headers = mapOf("If-Match" to "\"e1\""), body = "x".toByteArray())
        assertEquals(204, r.status)
        assertEquals("\"e2\"", r.etag)
        assertEquals(3, server.requests.size)
        assertTrue(server.requests.all { it.header("If-Match") == "\"e1\"" && it.body == "x" })

        server.reset()
        server.handler = { Reply(423) }
        val locked = client.send("PUT", "calendars/tim/work/a.ics")
        assertEquals("a lasting lock is reported", 423, locked.status)
        assertEquals(1 + WebDAVClient.LOCKED_RETRIES, server.requests.size)
    }

    @Test fun responseBodyIsCapped() = runTest {
        val client = server.webdav()
        client.maxResponseBytes = 100_000
        // No Content-Length: the limit is enforced while reading.
        server.handler = { Reply(200, body = ByteArray(300_000), chunked = true) }
        assertFails<SyncError.LimitExceeded> { client.send("GET", "calendars/tim/x.ics") }
        // With a Content-Length above the limit, nothing is read.
        server.handler = { Reply(200, body = ByteArray(300_000)) }
        assertFails<SyncError.LimitExceeded> { client.send("GET", "calendars/tim/x.ics") }
        server.handler = { Reply(200, body = ByteArray(90_000), chunked = true) }
        assertEquals(90_000, client.send("GET", "calendars/tim/x.ics").data.size)
    }

    @Test fun redirectsOutsideBaseAreRefused() = runTest {
        val client = server.webdav()
        for (target in listOf(
            "https://evil.example.com/remote.php/dav/calendars/tim/x.ics",
            "http://cloud.example.com/remote.php/dav/calendars/tim/x.ics",
            "https://cloud.example.com:8443/remote.php/dav/calendars/tim/x.ics",
            "https://cloud.example.com/remote.php/other/x.ics",
            "/remote.php/dav/calendars/tim/%2E%2E/%2E%2E/%2E%2E/other/x.ics",
        )) {
            server.reset()
            server.handler = { req -> if (req.url == target) Reply(200, body = "leaked") else Reply(307, mapOf("Location" to target)) }
            assertFails<SyncError.RedirectRejected> { client.send("GET", "calendars/tim/x.ics") }
            assertEquals("redirect to $target is not followed", 1, server.requests.size)
        }
        // A redirect inside the base URL is followed, with the same method, headers and body.
        server.reset()
        val inside = "https://cloud.example.com/remote.php/dav/calendars/tim/moved.ics"
        server.handler = { req -> if (req.url == inside) Reply(200, body = "ok") else Reply(307, mapOf("Location" to inside)) }
        val r = client.send("PROPFIND", "calendars/tim/x.ics", headers = mapOf("Depth" to "0"), body = "<x/>".toByteArray())
        assertEquals("ok", r.text)
        assertEquals(listOf("PROPFIND", "PROPFIND"), server.requests.map { it.method })
        assertTrue(server.requests.all { it.body == "<x/>" && it.header("Depth") == "0" })

        // Without following, the redirect is returned.
        client.followsRedirects = false
        assertEquals(inside, client.send("GET", "calendars/tim/x.ics").location)
    }

    @Test fun errorMessages() {
        assertEquals("Wrong username or app password", WebDAVClient.error(401, "x").message)
        assertEquals(SyncError.BaseNotFound, WebDAVClient.error(404, ""))
        assertTrue(WebDAVClient.error(404, "").message!!.startsWith("Server URL not found"))
        assertEquals(SyncError.NotFound("a/b"), WebDAVClient.error(404, "a/b"))
        assertEquals(SyncError.PreconditionFailed("a"), WebDAVClient.error(412, "a"))
        assertEquals(SyncError.InsufficientStorage, WebDAVClient.error(507, "a"))
        assertEquals(SyncError.Http(500, "a"), WebDAVClient.error(500, "a"))
        assertTrue(SyncError.Http(500, "a").isPerResource)
        assertFalse(SyncError.Unauthorized.isPerResource)
    }

    @Test fun etagNormalizationStripsProxyCompressionMarkers() {
        assertEquals("\"abc\"", WebDAVClient.normalizeETag("\"abc-gzip\""))
        assertEquals("\"abc\"", WebDAVClient.normalizeETag("\"abc-br\""))
        assertEquals("\"abc\"", WebDAVClient.normalizeETag("W/\"abc\""))
        assertEquals("\"abc\"", WebDAVClient.normalizeETag("\"abc\""))
        assertEquals("\"abc\"", WebDAVClient.normalizeETag("abc"))
        assertNull(WebDAVClient.normalizeETag(""))
        assertNull(WebDAVClient.normalizeETag(null))
    }

    // endregion

    // region CalDAV requests

    @Test fun listsOnlyOwnTaskCalendars() = runTest {
        server.handler = { Reply(207, body = CALENDAR_HOME) }
        val calendars = caldav().calendars()
        assertEquals(
            listOf(
                RemoteCalendar(
                    path = "calendars/tim/todotim-inbox", name = "Inbox", color = "#808080",
                    labels = """[{"id":"l1","name":"A & B","order":1}]""", syncToken = "http://sabre.io/ns/sync/7",
                ),
            ),
            calendars,
        )
        assertEquals(listOf(PropertyList.Entry("l1", "A & B", 1.0)), calendars[0].labelEntries())
        assertNull(calendars[0].sectionEntries())
        // An unreadable listing fails instead of looking like an empty home.
        for (bad in listOf("""<d:multistatus xmlns:d="DAV:"/><extra/>""", """<d:multistatus xmlns:d="DAV:">""")) {
            server.handler = { Reply(207, body = bad) }
            assertFails<SyncError.NotCalDAV> { caldav().calendars() }
        }
        server.handler = { Reply(207, body = CALENDAR_HOME) }
        val req = server.requests.first()
        assertEquals("PROPFIND", req.method)
        assertEquals("1", req.header("Depth"))
        assertEquals("https://cloud.example.com/remote.php/dav/calendars/tim/", req.url)
        assertEquals(Credentials.basic("tim", "app-pass", Charsets.UTF_8), req.header("Authorization"))
        for (p in listOf("resourcetype", "supported-calendar-component-set", "sync-token", "getctag", "owner-principal",
            "displayname", "calendar-color", "calendar-order", "sections", "labels")) {
            assertTrue(p, req.body.contains(p))
        }
    }

    @Test fun skipsAppGeneratedCalendars() = runTest {
        val deck = CALENDAR_HOME.replace("/remote.php/dav/calendars/tim/todotim-inbox/", "/remote.php/dav/calendars/tim/app-generated--deck--board-1/")
        server.handler = { Reply(207, body = deck) }
        assertEquals(emptyList<RemoteCalendar>(), caldav().calendars())
    }

    /** Nextcloud with a login name that is not the user id (LDAP, e-mail login): the calendars' owner-principal is
     *  the user id, which the discovered principal names. */
    @Test fun ownCalendarsAreRecognizedByTheDiscoveredPrincipal() = runTest {
        server.handler = { Reply(207, body = CALENDAR_HOME) }
        val principal = CalendarHome(
            "https://cloud.example.com/remote.php/dav/calendars/tim/",
            "https://cloud.example.com/remote.php/dav/principals/users/tim/",
        )
        val listed = caldav("tim@example.com", "calendars/tim", principal).calendars()
        assertEquals("the calendar shared by bob stays out", listOf("todotim-inbox"), listed.map { it.uri })
        val none = caldav("tim@example.com", "calendars/tim").calendars()
        assertEquals("without the principal, the login name does not match the owner", emptyList<RemoteCalendar>(), none)
    }

    @Test fun syncCollectionKeepsOnlyDirectChildren() = runTest {
        server.handler = { Reply(207, body = SYNC_COLLECTION) }
        val client = caldav()
        val changes = client.changes("calendars/tim/work", "http://sabre.io/ns/sync/3")
        assertEquals(listOf("calendars/tim/work/a.ics"), changes.changed.map { it.path })
        assertEquals("\"e1\"", changes.changed.first().etag)
        assertEquals(listOf("calendars/tim/work/gone.ics"), changes.removed)
        assertEquals("http://sabre.io/ns/sync/9", changes.syncToken)
        assertFalse(changes.isFull)
        val body = server.requests.first().body
        assertTrue(body, body.contains("<d:sync-token>http://sabre.io/ns/sync/3</d:sync-token>"))
        assertEquals("REPORT", server.requests.first().method)
        assertNull(server.requests.first().header("Depth"))

        // A rejected token (403 valid-sync-token) falls back to a full listing.
        var calls = 0
        server.handler = {
            calls++
            if (calls == 1) Reply(403) else Reply(207, body = SYNC_COLLECTION)
        }
        val full = client.changes("calendars/tim/work", "stale")
        assertTrue(full.isFull)
        assertEquals(1, full.changed.size)
    }

    /** A server without sync-collection (RFC 6578 is optional in CalDAV): the getctag serves as the sync token,
     *  and a calendar-query lists the whole calendar. */
    @Test fun serverWithoutSyncCollectionIsListedByCalendarQuery() = runTest {
        val listing = """<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">
 <d:response><d:href>/remote.php/dav/calendars/tim/work/</d:href><d:propstat><d:prop>
  <d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
  <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
  <cs:getctag>42</cs:getctag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  <d:propstat><d:prop><d:sync-token/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
</d:multistatus>"""
        val query = SYNC_COLLECTION.replace(" <d:sync-token>http://sabre.io/ns/sync/9</d:sync-token>\n", "")
        server.handler = { req ->
            when {
                req.method == "PROPFIND" -> Reply(207, body = listing)
                req.body.contains("sync-collection") -> Reply(501)
                else -> Reply(207, body = query)
            }
        }
        val client = caldav()
        assertEquals(listOf("ctag:42"), client.calendars().map { it.syncToken })

        val changes = client.changes("calendars/tim/work", "ctag:41")
        assertEquals(listOf("calendars/tim/work/a.ics"), changes.changed.map { it.path })
        assertEquals(emptyList<String>(), changes.removed)
        assertTrue(changes.isFull)
        assertNull(changes.syncToken)
        val request = server.requests.last()
        assertTrue(request.body.contains("<c:calendar-query"))
        assertEquals("1", request.header("Depth"))

        // Before any token is stored, a refused sync-collection falls back to calendar-query.
        server.reset()
        val first = client.changes("calendars/tim/work", null)
        assertEquals(listOf("calendars/tim/work/a.ics"), first.changed.map { it.path })
        assertEquals(2, server.requests.size)
    }

    /** Xandikos answers sync-collection with ETags but no calendar data (calendar-data 404): the objects are fetched
     *  with calendar-multiget. An object it cannot return fails the listing instead of looking deleted. */
    @Test fun objectsWithoutDataAreFetchedWithMultiget() = runTest {
        fun response(name: String, data: Boolean): String =
            "<d:response><d:href>/remote.php/dav/calendars/tim/work/$name</d:href>" +
                "<d:propstat><d:prop><d:getetag>\"e-$name\"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>" +
                "<d:propstat><d:prop><cal:calendar-data" +
                (if (data) ">BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:$name\nEND:VTODO\nEND:VCALENDAR\n</cal:calendar-data>" else "/>") +
                "</d:prop><d:status>HTTP/1.1 ${if (data) "200 OK" else "404 Not Found"}</d:status></d:propstat></d:response>"
        fun multistatus(responses: String) = "<d:multistatus xmlns:d=\"DAV:\" xmlns:cal=\"urn:ietf:params:xml:ns:caldav\">$responses" +
            "<d:sync-token>http://example.com/sync/2</d:sync-token></d:multistatus>"
        val gone = "<d:response><d:href>/remote.php/dav/calendars/tim/work/b.ics</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
        var omit = false
        server.handler = { req ->
            if (req.body.contains("sync-collection")) {
                Reply(207, body = multistatus(response("a.ics", false) + response("b.ics", false)))
            } else {
                Reply(207, body = multistatus((if (omit) "" else response("a.ics", true)) + gone))
            }
        }
        val client = caldav()
        val changes = client.changes("calendars/tim/work", null)
        assertEquals(listOf("calendars/tim/work/a.ics"), changes.changed.map { it.path })
        assertTrue(changes.changed[0].ics.contains("UID:a.ics"))
        assertEquals("\"e-a.ics\"", changes.changed[0].etag)
        assertEquals("gone since the listing", listOf("calendars/tim/work/b.ics"), changes.removed)
        assertEquals("http://example.com/sync/2", changes.syncToken)
        val multiget = server.requests.last().body
        assertTrue(multiget, multiget.contains("<c:calendar-multiget"))
        assertTrue(multiget, multiget.contains("<d:href>/remote.php/dav/calendars/tim/work/a.ics</d:href>"))

        omit = true
        assertFails<SyncError.BadRemoteData> { client.changes("calendars/tim/work", null) }
    }

    /** An object listed with failed properties (neither data nor ETag) is fetched with calendar-multiget too. If
     *  that fails as well, the full listing fails: leaving the object out would make its task look deleted. */
    @Test fun objectWithFailedPropertiesIsFetchedOrFailsTheListing() = runTest {
        val failed = "<d:response><d:href>/remote.php/dav/calendars/tim/work/b.ics</d:href><d:propstat><d:prop><d:getetag/>" +
            "<cal:calendar-data/></d:prop><d:status>HTTP/1.1 500 Internal Server Error</d:status></d:propstat></d:response>"
        val readable = "<d:response><d:href>/remote.php/dav/calendars/tim/work/b.ics</d:href><d:propstat><d:prop><d:getetag>\"e-b\"</d:getetag>" +
            "<cal:calendar-data>BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:b\nEND:VTODO\nEND:VCALENDAR\n</cal:calendar-data></d:prop>" +
            "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        fun multistatus(responses: String) = "<d:multistatus xmlns:d=\"DAV:\" xmlns:cal=\"urn:ietf:params:xml:ns:caldav\">$responses" +
            "<d:sync-token>http://example.com/sync/2</d:sync-token></d:multistatus>"
        var hasSyncCollection = true
        var multigetReads = true
        server.handler = { req ->
            when {
                req.body.contains("sync-collection") -> if (hasSyncCollection) Reply(207, body = multistatus(failed)) else Reply(501)
                req.body.contains("calendar-query") -> Reply(207, body = multistatus(failed))
                else -> Reply(207, body = multistatus(if (multigetReads) readable else failed))
            }
        }
        val client = caldav()
        for (syncCollection in listOf(true, false)) {
            hasSyncCollection = syncCollection
            multigetReads = true
            val changes = client.changes("calendars/tim/work", null)
            assertTrue(changes.isFull)
            assertEquals("sync-collection: $syncCollection", listOf("calendars/tim/work/b.ics"), changes.changed.map { it.path })
            multigetReads = false
            assertFails<SyncError.BadRemoteData> { client.changes("calendars/tim/work", null) }
        }
    }

    @Test fun multigetIsSentInBatches() = runTest {
        val names = (0 until 250).map { "t$it.ics" }
        fun withoutData(n: String) = "<d:response><d:href>/remote.php/dav/calendars/tim/work/$n</d:href><d:propstat><d:prop>" +
            "<d:getetag>\"e\"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        fun withData(n: String) = "<d:response><d:href>/remote.php/dav/calendars/tim/work/$n</d:href><d:propstat><d:prop>" +
            "<d:getetag>\"e\"</d:getetag><cal:calendar-data>BEGIN:VCALENDAR\nEND:VCALENDAR\n</cal:calendar-data></d:prop>" +
            "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        fun ms(s: String) = "<d:multistatus xmlns:d=\"DAV:\" xmlns:cal=\"urn:ietf:params:xml:ns:caldav\">$s</d:multistatus>"
        server.handler = { req ->
            if (req.body.contains("sync-collection")) {
                Reply(207, body = ms(names.joinToString("") { withoutData(it) }))
            } else {
                val asked = Regex("work/(t\\d+\\.ics)</d:href>").findAll(req.body).map { it.groupValues[1] }.toList()
                Reply(207, body = ms(asked.joinToString("") { withData(it) }))
            }
        }
        val changes = caldav().changes("calendars/tim/work", null)
        assertEquals(250, changes.changed.size)
        assertEquals(1 + 3, server.requests.size)
    }

    /** A property the server will not store comes back 403; atomic servers fail the rest with 424 (sent again
     *  without it), others apply the rest at once (Xandikos). */
    @Test fun refusedOptionalPropertiesAreReportedAndTheRestIsSet() = runTest {
        fun reply(statuses: List<Pair<String, String>>): Reply {
            val propstats = statuses.joinToString("") { "<d:propstat><d:prop>${it.first}</d:prop><d:status>HTTP/1.1 ${it.second}</d:status></d:propstat>" }
            return Reply(207, body = "<d:multistatus xmlns:d=\"DAV:\" xmlns:t=\"https://todotim.app/ns\"><d:response>" +
                "<d:href>/remote.php/dav/calendars/tim/w/</d:href>$propstats</d:response></d:multistatus>")
        }
        val client = caldav()
        var calls = 0
        server.handler = {
            calls++
            if (calls == 1) reply(listOf("<d:displayname/>" to "424 Failed Dependency", "<t:sections/>" to "403 Forbidden"))
            else reply(listOf("<d:displayname/>" to "200 OK"))
        }
        val values = mapOf(CalendarProperty.NAME to "New", CalendarProperty.SECTIONS to "[]")
        assertEquals(setOf(CalendarProperty.SECTIONS), client.setProperties("calendars/tim/w", values))
        assertEquals(2, server.requests.size)
        val retry = server.requests.last().body
        assertTrue(retry, retry.contains("displayname") && !retry.contains("sections"))

        server.reset()
        server.handler = { reply(listOf("<d:displayname/>" to "200 OK", "<t:sections/>" to "403 Forbidden")) }
        assertEquals(setOf(CalendarProperty.SECTIONS), client.setProperties("calendars/tim/w", values))
        assertEquals("already applied", 1, server.requests.size)

        // A temporary failure is no refusal: the update fails, and the next sync sends it again.
        for (status in listOf("500 Internal Server Error", "423 Locked", "507 Insufficient Storage")) {
            server.handler = { reply(listOf("<d:displayname/>" to "424 Failed Dependency", "<t:sections/>" to status)) }
            try {
                val refused = client.setProperties("calendars/tim/w", values)
                fail("$status taken as a refusal of $refused")
            } catch (e: SyncError) {
            }
        }
    }

    @Test fun proppatchFailureIsReported() = runTest {
        server.handler = {
            Reply(207, body = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/remote.php/dav/calendars/tim/w/</d:href>" +
                "<d:propstat><d:prop><d:displayname/></d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response></d:multistatus>")
        }
        val e = assertFails<SyncError.Http> { caldav().setProperties("calendars/tim/w", mapOf(CalendarProperty.NAME to "x")) }
        assertEquals(SyncError.Http(424, "calendars/tim/w"), e)
        val body = server.requests.first().body
        assertTrue(body, body.contains("<x:displayname xmlns:x=\"DAV:\">x</x:displayname>"))
    }

    @Test fun calendarIsCreatedWithoutPropertiesTheServerRefuses() = runTest {
        var calls = 0
        server.handler = {
            calls++
            if (calls == 1) Reply(403) else Reply(201)
        }
        val client = caldav()
        assertEquals(setOf(CalendarProperty.COLOR, CalendarProperty.ORDER), client.createCalendar("calendars/tim/w", "W", "#DB4035", "1"))
        val bodies = server.requests.map { it.body }
        assertEquals(2, bodies.size)
        assertEquals("MKCALENDAR", server.requests.first().method)
        assertTrue(bodies[0].contains("calendar-color"))
        assertFalse(bodies[1].contains("calendar-color"))
        assertTrue(bodies[1].contains("<c:comp name=\"VTODO\"/>"))

        server.handler = { Reply(405) }
        assertEquals(SyncError.CalendarExists("calendars/tim/w"), assertFails<SyncError.CalendarExists> {
            client.createCalendar("calendars/tim/w", "W", "#DB4035", "1")
        })
    }

    @Test fun sharingOnAServerWithoutItFailsClearly() = runTest {
        server.handler = { Reply(405) }
        val e = assertFails<SyncError.SharingUnsupported> { caldav().share("calendars/tim/w", "bob") }
        assertTrue(e.message!!.contains("Nextcloud"))
    }

    @Test fun endlessPagingFailsInsteadOfReturningAPartialListing() = runTest {
        val truncated = SYNC_COLLECTION.replace(
            " <d:sync-token>",
            " <d:response><d:href>/remote.php/dav/calendars/tim/work/</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status></d:response>\n <d:sync-token>",
        )
        server.handler = { Reply(207, body = truncated) }
        assertFails<SyncError.LimitExceeded> { caldav().changes("calendars/tim/work", null) }
        assertEquals(CalDAVClient.MAX_PAGES, server.requests.size)
    }

    @Test fun pagedSyncCollectionIsFollowed() = runTest {
        val page1 = SYNC_COLLECTION.replace(
            " <d:sync-token>http://sabre.io/ns/sync/9</d:sync-token>",
            " <d:response><d:href>/remote.php/dav/calendars/tim/work/</d:href><d:status>HTTP/1.1 507 Insufficient Storage</d:status></d:response>\n" +
                " <d:sync-token>http://sabre.io/ns/sync/8</d:sync-token>",
        )
        val page2 = """<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
 <d:response><d:href>/remote.php/dav/calendars/tim/work/c.ics</d:href><d:propstat><d:prop><d:getetag>"e3"</d:getetag>
 <cal:calendar-data>X</cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:sync-token>http://sabre.io/ns/sync/9</d:sync-token></d:multistatus>"""
        server.handler = { req -> Reply(207, body = if (req.body.contains("sync/8")) page2 else page1) }
        val changes = caldav().changes("calendars/tim/work", "http://sabre.io/ns/sync/3")
        assertEquals(listOf("calendars/tim/work/a.ics", "calendars/tim/work/c.ics"), changes.changed.map { it.path })
        assertEquals("http://sabre.io/ns/sync/9", changes.syncToken)
        assertEquals(2, server.requests.size)
    }

    @Test fun writesAreConditional() = runTest {
        server.handler = { Reply(201, mapOf("ETag" to "\"new-gzip\"")) }
        val client = caldav()
        assertEquals("\"new\"", client.put("calendars/tim/work/a.ics", "X", "\"old\""))
        client.put("calendars/tim/work/b.ics", "X", null)
        client.move("calendars/tim/work/a.ics", "calendars/tim/home/a.ics", "\"new\"")
        client.delete("calendars/tim/home/a.ics", "\"new\"")
        val reqs = server.requests
        assertEquals(listOf("PUT", "PUT", "MOVE", "DELETE"), reqs.map { it.method })
        assertEquals("\"old\"", reqs[0].header("If-Match"))
        assertTrue(reqs[0].header("Content-Type")!!.startsWith("text/calendar"))
        assertEquals("X", reqs[0].body)
        assertEquals("*", reqs[1].header("If-None-Match"))
        assertNull(reqs[1].header("If-Match"))
        assertEquals("https://cloud.example.com/remote.php/dav/calendars/tim/home/a.ics", reqs[2].header("Destination"))
        assertEquals("F", reqs[2].header("Overwrite"))
        assertEquals("\"new\"", reqs[2].header("If-Match"))
        assertEquals("\"new\"", reqs[3].header("If-Match"))

        server.handler = { Reply(412) }
        assertEquals(
            SyncError.PreconditionFailed("calendars/tim/work/a.ics"),
            assertFails<SyncError.PreconditionFailed> { client.put("calendars/tim/work/a.ics", "X", "\"x\"") },
        )
        // A delete of something already gone succeeds.
        server.handler = { Reply(404) }
        client.delete("calendars/tim/work/a.ics", "\"x\"")
        client.deleteCalendar("calendars/tim/work")
    }

    // endregion
}
