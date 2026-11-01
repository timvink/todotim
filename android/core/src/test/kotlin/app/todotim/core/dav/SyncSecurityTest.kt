package app.todotim.core.dav

import app.todotim.core.SyncLimits
import app.todotim.core.isValidEntityID
import app.todotim.core.newID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Remote data validation and resource limits at the network layer. */
class SyncSecurityTest {
    @Test fun entityIDValidation() {
        for (ok in listOf("inbox", newID(), "a", "A_b-9", "x".repeat(64))) assertTrue(ok, isValidEntityID(ok))
        for (bad in listOf("", "..", ".", "a/b", "../../outside", "a.b", "a b", "a\n", "é", "x".repeat(65))) {
            assertFalse(bad, isValidEntityID(bad))
        }
    }

    @Test fun propertyListDropsInvalidEntriesAndClipsText() {
        val json = """[{"id":"s1","name":"A\r\nB","order":1.5},{"id":"s1","name":"dup","order":2},
            {"id":"../x","name":"bad","order":3},{"id":"s2","order":"7"},{"name":"no id"},"junk",
            {"id":"l1","name":"${"n".repeat(2_000)}","order":1e400,"color":"${"#".repeat(100)}"}]"""
        val entries = PropertyList.decode(json)!!
        assertEquals(listOf("s1", "s2", "l1"), entries.map { it.id })
        assertEquals("A\nB", entries[0].name)
        assertEquals(1.5, entries[0].order, 0.0)
        assertEquals("", entries[1].name)
        assertEquals("a string order is not a number", 0.0, entries[1].order, 0.0)
        assertEquals(SyncLimits.MAX_NAME_LENGTH, entries[2].name.length)
        assertEquals(SyncLimits.MAX_COLOR_LENGTH, entries[2].color!!.length)
        assertEquals("a non-finite order becomes 0", 0.0, entries[2].order, 0.0)
    }

    @Test fun propertyListIsBounded() {
        assertNull(PropertyList.decode("not json"))
        assertNull(PropertyList.decode("""{"id":"a"}"""))
        assertEquals(emptyList<PropertyList.Entry>(), PropertyList.decode("[]"))
        val many = (0 until SyncLimits.MAX_PROPERTY_ENTRIES + 10).joinToString(",", "[", "]") { """{"id":"s$it","name":"","order":$it}""" }
        assertEquals(SyncLimits.MAX_PROPERTY_ENTRIES, PropertyList.decode(many)!!.size)
        val huge = """[{"id":"a","name":"${"x".repeat(SyncLimits.MAX_PROPERTY_BYTES)}","order":1}]"""
        assertNull(PropertyList.decode(huge))
    }

    @Test fun propertyListRoundTripsInTheSwiftFormat() {
        val entries = listOf(PropertyList.Entry("l1", "A & B", 1.0, "#DB4035"), PropertyList.Entry("s1", "Later", 2.5))
        val json = PropertyList.encode(entries)
        assertEquals("""[{"color":"#DB4035","id":"l1","name":"A & B","order":1},{"id":"s1","name":"Later","order":2.5}]""", json)
        assertEquals(entries, PropertyList.decode(json))
    }

    @Test fun hrefResolutionRefusesCredentialsQueriesAndDotSegments() {
        val base = "https://cloud.example.com/remote.php/dav/".toUrl()
        assertEquals("https://cloud.example.com/remote.php/dav/principals/tim/", WebDAVClient.resolveHref(" principals/tim/ ", base).toString())
        for (bad in listOf("", "https://u:p@cloud.example.com/x/", "/x/?a=1", "/x/#f", "/a/%2e%2E/b/", "/a/./b/", "ftp://cloud.example.com/x/")) {
            assertNull(bad, WebDAVClient.resolveHref(bad, base))
        }
        assertTrue(WebDAVClient.hasDotSegment("https://h/a/%2E/b"))
        assertFalse(WebDAVClient.hasDotSegment("https://h/a/..b/c..ics"))
        assertTrue("a malformed escape is refused", WebDAVClient.hasDotSegment("/a/%zz/"))
    }
}
