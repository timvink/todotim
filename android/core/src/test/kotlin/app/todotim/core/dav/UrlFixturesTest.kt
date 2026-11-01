package app.todotim.core.dav

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/** The language-neutral URL rules in fixtures/urls.json (see fixtures/README.md, "urls"). */
class UrlFixturesTest {
    private val fixture: JsonObject by lazy {
        val dir = System.getProperty("todotim.fixtures") ?: error("system property todotim.fixtures not set")
        Json.parseToJsonElement(File(dir, "urls.json").readText()).jsonObject
    }

    @Test fun baseURLs() {
        val base = fixture["baseURL"]!!.jsonObject
        for (case in base["valid"]!!.jsonArray) {
            val o = case.jsonObject
            val input = o["input"]!!.jsonPrimitive.content
            assertEquals(input, o["normalized"]!!.jsonPrimitive.content, WebDAVClient.normalizedBaseURL(input).toString())
        }
        for (input in base["insecure"]!!.jsonArray.map { it.jsonPrimitive.content }) {
            try {
                WebDAVClient.normalizedBaseURL(input)
                fail("accepted $input")
            } catch (e: SyncError.InsecureURL) {
            }
        }
        for (input in base["invalid"]!!.jsonArray.map { it.jsonPrimitive.content }) {
            try {
                WebDAVClient.normalizedBaseURL(input)
                fail("accepted $input")
            } catch (e: SyncError.InvalidURL) {
            }
        }
    }

    @Test fun requestPaths() {
        val section = fixture["requestPath"]!!.jsonObject
        val client = WebDAVClient(section["base"]!!.jsonPrimitive.content, "tim", "pw")
        for (case in section["encoded"]!!.jsonArray) {
            val o = case.jsonObject
            val path = o["path"]!!.jsonPrimitive.content
            assertEquals(path, o["url"]!!.jsonPrimitive.content, client.url(path, o["collection"]!!.jsonPrimitive.boolean).toString())
        }
        for (path in section["refused"]!!.jsonArray.map { it.jsonPrimitive.content }) {
            try {
                client.url(path)
                fail("accepted $path")
            } catch (e: SyncError.InvalidPath) {
            }
        }
    }

    @Test fun hrefs() {
        val section = fixture["href"]!!.jsonObject
        val client = WebDAVClient(section["base"]!!.jsonPrimitive.content, "tim", "pw")
        for (case in section["cases"]!!.jsonArray) {
            val o = case.jsonObject
            val href = o["href"]!!.jsonPrimitive.content
            val expected = o["path"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.content }
            assertEquals(href, expected, client.relativePath(href))
        }
    }
}
