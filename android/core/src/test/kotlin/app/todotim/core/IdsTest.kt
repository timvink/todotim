package app.todotim.core

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID

class IdsTest {
    @Test fun uuidV5MatchesRfc() {
        // RFC 9562 test vector: DNS namespace, "www.example.com".
        val dns = UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        assertEquals("2ed6657d-e927-568b-95e1-2665a8aea6a2", Ids.uuidV5(dns, "www.example.com"))
    }

    @Test fun validIdsAreKept() {
        assertEquals("abc-123_X", Ids.taskId("abc-123_X"))
        assertEquals(36, Ids.taskId("weird@uid").length)
    }
}
