package app.todotim.core.dav

import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Discovery of the calendar home (RFC 6764, RFC 4791) on the layouts of several servers. */
class CalDAVDiscoveryTest {
    private val server = TestServer()

    @After fun tearDown() = server.close()

    private suspend fun discover(layout: FakeDAVLayout, serverURL: String? = null, password: String = "pw"): CalendarHome {
        server.handler = layout::respond
        return CalDAVDiscovery.discover(serverURL ?: layout.serverURL, layout.user, password, server.client)
    }

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

    @Test fun nextcloudHomeIsTheOneUsedBeforeDiscovery() = runTest {
        val layout = FakeDAVLayout.nextcloud()
        val home = discover(layout)
        assertEquals(
            CalendarHome("https://cloud.example.com/remote.php/dav/calendars/tim/", "https://cloud.example.com/remote.php/dav/principals/users/tim/"),
            home,
        )
        assertEquals(
            listOf("https://cloud.example.com/remote.php/dav/", "https://cloud.example.com/remote.php/dav/principals/users/tim/"),
            server.urls,
        )
        assertTrue(server.requests.all { it.method == "PROPFIND" && it.header("Depth") == "0" })
        // Same paths as before discovery, so existing sync state stays valid.
        val client = CalDAVClient.create(layout.serverURL, "tim", "pw", home)
        assertEquals("calendars/tim", client.home)
        assertEquals("https://cloud.example.com/remote.php/dav/", client.dav.baseURL.toString())
        assertEquals(home.url, CalDAVDiscovery.legacyHome(client.dav.baseURL, "tim"))
    }

    @Test fun radicaleAndXandikosLayouts() = runTest {
        val radicale = discover(FakeDAVLayout.radicale())
        assertEquals(CalendarHome("http://localhost:5232/tim/", "http://localhost:5232/tim/"), radicale)
        val r = CalDAVClient.create("http://localhost:5232/", "tim", "pw", radicale)
        assertEquals("tim", r.home)
        assertEquals("http://localhost:5232/", r.dav.baseURL.toString())

        val xandikos = discover(FakeDAVLayout.xandikos)
        assertEquals(CalendarHome("http://localhost:8080/user/calendars/", "http://localhost:8080/user/"), xandikos)
        val x = CalDAVClient.create("http://localhost:8080/", "tim", "pw", xandikos)
        assertEquals("user/calendars", x.home)
    }

    /** A server that speaks WebDAV only below /dav/ is found through /.well-known/caldav. The redirect is followed
     *  as a PROPFIND, and percent-encoded hrefs are understood. */
    @Test fun wellKnownRedirectOnTheSameServer() = runTest {
        val layout = FakeDAVLayout.hosted
        val home = discover(layout)
        assertEquals(
            CalendarHome(
                "https://caldav.example.com/dav/calendars/user/tim@example.com/",
                "https://caldav.example.com/dav/principals/user/tim@example.com/",
            ),
            home,
        )
        assertEquals(
            listOf(
                "https://caldav.example.com/", "https://caldav.example.com/.well-known/caldav",
                "https://caldav.example.com/dav/", "https://caldav.example.com/dav/principals/user/tim%40example.com/",
            ),
            server.urls,
        )
        assertTrue(server.requests.all { it.method == "PROPFIND" })
        val client = CalDAVClient.create(layout.serverURL, layout.user, "pw", home)
        assertEquals("dav/calendars/user/tim@example.com", client.home)
    }

    /** A redirect to another origin (another host, or plain http) is not followed. */
    @Test fun redirectToAnotherServerIsRefused() = runTest {
        for (target in listOf("https://dav.elsewhere.example/dav/", "http://caldav.example.com/dav/")) {
            server.reset()
            val e = assertFails<SyncError.OtherServer> { discover(FakeDAVLayout.hosted.copy(wellKnown = target)) }
            assertEquals(target, e.target + "/")
            assertEquals(listOf("https://caldav.example.com/", "https://caldav.example.com/.well-known/caldav"), server.urls)
        }
    }

    /** The user entered their principal URL: the home is outside the server URL, so requests are confined to the
     *  home itself. */
    @Test fun homeOutsideTheServerURL() = runTest {
        val layout = FakeDAVLayout.hosted
        val serverURL = "https://caldav.example.com/dav/principals/user/tim@example.com/"
        val home = discover(layout, serverURL)
        assertEquals("https://caldav.example.com/dav/calendars/user/tim@example.com/", home.url)
        assertEquals(2, server.requests.size)
        val client = CalDAVClient.create(serverURL, layout.user, "pw", home)
        assertEquals("", client.home)
        assertEquals(home.url, client.dav.baseURL.toString())
        assertEquals("work", client.dav.relativePath("/dav/calendars/user/tim%40example.com/work/"))
        assertEquals(null, client.dav.relativePath("/dav/principals/user/tim%40example.com/"))
    }

    /** Servers without `current-user-principal`, or a principal without a calendar home, get the SabreDAV layout
     *  below the server URL. */
    @Test fun fallsBackToCalendarsUsername() = runTest {
        var layout = FakeDAVLayout.nextcloud().copy(principal = null, wellKnown = null)
        assertEquals(CalendarHome("https://cloud.example.com/remote.php/dav/calendars/tim/"), discover(layout))
        assertEquals(listOf("https://cloud.example.com/remote.php/dav/", "https://cloud.example.com/.well-known/caldav"), server.urls)

        server.reset()
        layout = layout.copy(principal = "remote.php/dav/principals/users/tim", home = null)
        assertEquals(
            CalendarHome("https://cloud.example.com/remote.php/dav/calendars/tim/", "https://cloud.example.com/remote.php/dav/principals/users/tim/"),
            discover(layout),
        )
    }

    /** iCloud names a calendar home on another host (pNN-caldav): refused, and never contacted. */
    @Test fun homeOnAnotherServerIsRefused() = runTest {
        val layout = FakeDAVLayout(
            origin = "https://caldav.example.com", root = "", davArea = "", principal = "123/principal",
            home = "123/calendars", homeOrigin = "https://p42-caldav.example.com:443",
        )
        val e = assertFails<SyncError.OtherServer> { discover(layout) }
        assertTrue(e.target, e.target.startsWith("https://p42-caldav.example.com"))
        assertTrue(e.message!!.contains("another server"))
        assertTrue(server.urls.all { it.startsWith("https://caldav.example.com/") })

        // A home kept from earlier is checked the same way.
        val elsewhere = CalendarHome("https://p42-caldav.example.com/123/calendars/")
        assertFails<SyncError.OtherServer> { CalDAVClient.create("https://caldav.example.com/", "tim", "pw", elsewhere) }
    }

    @Test fun wrongPasswordAndServerErrorsStopDiscovery() = runTest {
        val layout = FakeDAVLayout.radicale().copy(password = "right")
        assertFails<SyncError.Unauthorized> { discover(layout, password = "wrong") }
        assertEquals(1, server.requests.size)
        assertEquals("http://localhost:5232/tim/", discover(layout, password = "right").url)

        // A server error is not "nothing found" (whose fallback would then be kept).
        server.handler = { Reply(503) }
        try {
            CalDAVDiscovery.discover("https://cloud.example.com/remote.php/dav/", "tim", "pw", server.client)
            fail("expected an HTTP error")
        } catch (e: SyncError) {
            assertEquals(SyncError.Http(503, "/remote.php/dav/"), e)
        }
    }

    /** Discovery, then the listing of a Radicale-style home over HTTP. The scheduling inbox and outbox are
     *  recognized by their resource type, whatever they are called. */
    @Test fun listsTheCalendarsOfADiscoveredHome() = runTest {
        val layout = FakeDAVLayout.radicale().copy(
            collections = listOf(
                FakeDAVLayout.Collection("todotim-inbox", listOf("d:collection", "c:calendar"), listOf("VTODO")),
                FakeDAVLayout.Collection("work", listOf("d:collection", "c:calendar"), listOf("VTODO")),
                FakeDAVLayout.Collection("events", listOf("d:collection", "c:calendar"), listOf("VEVENT", "VTODO")),
                FakeDAVLayout.Collection("invitations", listOf("d:collection", "c:calendar", "c:schedule-inbox"), listOf("VTODO")),
                FakeDAVLayout.Collection("outbox", listOf("d:collection", "c:schedule-outbox")),
                FakeDAVLayout.Collection("contacts", listOf("d:collection")),
            ),
        )
        server.handler = layout::respond
        val client = CalDAVClient.connect(layout.serverURL, "tim", "pw", null, server.client)
        val calendars = client.calendars()
        assertEquals(listOf("tim/todotim-inbox", "tim/work"), calendars.map { it.path }.sorted())
        assertEquals("http://localhost:5232/tim/", server.urls.last())
        assertEquals("1", server.requests.last().header("Depth"))

        // With the home known, connecting sends nothing.
        server.reset()
        val again = CalDAVClient.connect(layout.serverURL, "tim", "pw", client.calendarHome, server.client)
        assertEquals("tim", again.home)
        assertTrue(server.requests.isEmpty())
    }
}
