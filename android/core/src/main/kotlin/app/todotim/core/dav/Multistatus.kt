package app.todotim.core.dav

import app.todotim.core.SyncLimits
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import org.xmlpull.v1.XmlPullParserFactory
import java.io.ByteArrayInputStream
import java.io.IOException

/**
 * Parses a WebDAV 207 Multi-Status body (PROPFIND, REPORT, PROPPATCH) with a streaming pull parser. Only
 * properties inside a propstat with a 2xx status are kept. Server XML is untrusted: DTDs and entities other
 * than the predefined ones are refused, and the number of responses and the length of any text are capped.
 */
object Multistatus {
    /**
     * A property value: its text, and the child elements (qualified "namespace|name"); a child with a `name`
     * attribute (CalDAV `<comp name="VTODO"/>`) is recorded as "namespace|name=VTODO".
     */
    data class Property(
        val text: String = "",
        val children: List<String> = emptyList(),
        /** Text of the `DAV:href` children (`current-user-principal`, `calendar-home-set`), at most [MAX_HREFS]. */
        val hrefs: List<String> = emptyList(),
    )

    const val MAX_HREFS = 100

    data class Response(
        val href: String,
        /** Status of the whole response (`<d:status>` outside propstat), e.g. 404 for a member removed since a
         *  sync token. */
        val status: Int?,
        /** Keyed by qualified name, e.g. "DAV:|displayname". */
        val properties: Map<String, Property> = emptyMap(),
        /** The status of every property named in a propstat, including failed ones (PROPPATCH). */
        val propertyStatus: Map<String, Int> = emptyMap(),
    ) {
        fun text(qname: String): String? = properties[qname]?.text
    }

    data class Document(
        val responses: List<Response>,
        /** Top-level `<d:sync-token>` of a sync-collection REPORT. */
        val syncToken: String?,
    )

    sealed class Failure(message: String) : Exception(message) {
        /** The document declares a DTD or entities (never needed for WebDAV; refused to rule out entity expansion). */
        class Dtd : Failure("the XML declares a DTD or entities")
        class TooManyEntries : Failure("too many entries")
        class TextTooLong : Failure("an element's text is too long")
    }

    /** Longest text of one element in UTF-8 bytes: room for one calendar object (1 MB) as XML. */
    const val MAX_TEXT_LENGTH = 2 * (1 shl 20)

    private val factory: XmlPullParserFactory by lazy {
        XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }
    }

    /** null if the body is not a DAV multistatus document. Throws [Failure]. */
    fun parse(data: ByteArray, maxEntries: Int = SyncLimits.MAX_LISTING_ENTRIES): Document? {
        if (contains(data, "<!DOCTYPE") || contains(data, "<!ENTITY")) throw Failure.Dtd()
        val parser = factory.newPullParser()
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        parser.setInput(ByteArrayInputStream(data), null)
        val state = State(maxEntries)
        try {
            state.run(parser)
        } catch (e: XmlPullParserException) {
            return null
        } catch (e: IOException) {
            return null
        } catch (e: IllegalArgumentException) {
            return null
        }
        // A truncated document (unclosed elements) is not a multistatus either. Content after the root element
        // is refused while parsing (kxml2 accepts it).
        if (!state.sawMultistatus || !state.isClosed) return null
        return Document(state.responses, state.syncToken)
    }

    private fun contains(data: ByteArray, needle: String): Boolean {
        val n = needle.toByteArray(Charsets.US_ASCII)
        outer@ for (i in 0..data.size - n.size) {
            for (j in n.indices) if (data[i + j] != n[j]) continue@outer
            return true
        }
        return false
    }

    private class PropertyBuilder(val name: String) {
        val children = ArrayList<String>()
        val hrefs = ArrayList<String>()
    }

    private class State(val maxEntries: Int) {
        val responses = ArrayList<Response>()
        var syncToken: String? = null
        var sawMultistatus = false

        /** Element path below the document root, as qualified names. */
        private val path = ArrayList<String>()
        private val text = StringBuilder()
        private var textBytes = 0
        private var href: String? = null
        private var responseStatus: Int? = null
        private var props = LinkedHashMap<String, Property>()
        private var propertyStatus = LinkedHashMap<String, Int>()
        private var propstatProps = LinkedHashMap<String, Property>()
        private var propstatStatus: Int? = null
        private var propstatOK = true

        /** Whether every element was closed. */
        val isClosed: Boolean get() = path.isEmpty()

        /** Whether the root element has ended: after it, only whitespace, comments and PIs may follow. */
        private var rootEnded = false

        /** The property being read (a direct child of `prop`). */
        private var current: PropertyBuilder? = null

        fun run(p: XmlPullParser) {
            while (true) {
                when (p.nextToken()) {
                    XmlPullParser.END_DOCUMENT -> return
                    XmlPullParser.DOCDECL -> throw Failure.Dtd()
                    XmlPullParser.START_TAG -> start(p)
                    XmlPullParser.END_TAG -> end(p)
                    XmlPullParser.TEXT, XmlPullParser.CDSECT, XmlPullParser.IGNORABLE_WHITESPACE -> append(p.text ?: "")
                    // The predefined entities and character references have a replacement text; anything else
                    // would need a DTD.
                    XmlPullParser.ENTITY_REF -> append(p.text ?: throw Failure.Dtd())
                    else -> {} // comments, processing instructions, the XML declaration
                }
            }
        }

        private fun append(s: String) {
            if (path.isEmpty()) {
                if (s.isNotBlank()) throw XmlPullParserException("text outside the root element")
                return
            }
            text.append(s)
            textBytes += utf8Length(s)
            if (textBytes > MAX_TEXT_LENGTH) throw Failure.TextTooLong()
        }

        private fun resetText() {
            text.setLength(0)
            textBytes = 0
        }

        private fun qname(p: XmlPullParser) = "${p.namespace ?: ""}|${p.name}"

        private fun start(p: XmlPullParser) {
            if (rootEnded) throw XmlPullParserException("an element after the root element")
            val q = qname(p)
            path.add(q)
            resetText()
            when {
                q == "DAV:|multistatus" && path.size == 1 -> sawMultistatus = true
                q == "DAV:|response" && path.size == 2 -> {
                    href = null
                    responseStatus = null
                    props = LinkedHashMap()
                    propertyStatus = LinkedHashMap()
                }
                q == "DAV:|propstat" && path.size == 3 -> {
                    propstatProps = LinkedHashMap()
                    propstatStatus = null
                    propstatOK = true
                }
                path.size == 5 && path[3] == "DAV:|prop" -> current = PropertyBuilder(q)
                path.size == 6 && current != null -> {
                    val name = p.getAttributeValue(null, "name")
                    current!!.children.add(if (name != null) "$q=$name" else q)
                }
            }
        }

        private fun end(p: XmlPullParser) {
            val q = qname(p)
            val depth = path.size
            val value = text.toString().trim()
            try {
                val c = current
                if (depth == 5 && c != null && c.name == q) {
                    propstatProps[q] = Property(value, c.children.toList(), c.hrefs.toList())
                    current = null
                    return
                }
                if (depth == 6 && q == "DAV:|href" && c != null) {
                    if (c.hrefs.size < MAX_HREFS) c.hrefs.add(value)
                    return
                }
                when {
                    q == "DAV:|sync-token" && depth == 2 -> syncToken = value
                    q == "DAV:|href" && depth == 3 && href == null -> href = value
                    q == "DAV:|status" && depth == 3 -> responseStatus = statusCode(value)
                    q == "DAV:|status" && depth == 4 -> {
                        propstatStatus = statusCode(value)
                        propstatOK = propstatStatus?.let { it in 200..299 } ?: false
                    }
                    q == "DAV:|propstat" && depth == 3 -> {
                        if (propstatOK) for ((k, v) in propstatProps) props.putIfAbsent(k, v)
                        propstatStatus?.let { s -> for (name in propstatProps.keys) propertyStatus[name] = s }
                    }
                    q == "DAV:|response" && depth == 2 -> {
                        val h = href ?: return
                        if (responses.size >= maxEntries) throw Failure.TooManyEntries()
                        responses.add(Response(h, responseStatus, props, propertyStatus))
                    }
                }
            } finally {
                path.removeAt(path.size - 1)
                if (path.isEmpty()) rootEnded = true
                resetText()
            }
        }
    }

    /** "HTTP/1.1 200 OK" → 200. */
    fun statusCode(s: String): Int? {
        val parts = s.trim().split(' ', '\t', '\n', '\r').filter { it.isNotEmpty() }
        return if (parts.size >= 2) parts[1].toIntOrNull() else null
    }

    internal fun utf8Length(s: String): Int {
        var n = 0
        var i = 0
        while (i < s.length) {
            val c = s[i]
            n += when {
                c.code < 0x80 -> 1
                c.code < 0x800 -> 2
                Character.isHighSurrogate(c) && i + 1 < s.length && Character.isLowSurrogate(s[i + 1]) -> { i++; 4 }
                else -> 3
            }
            i++
        }
        return n
    }
}
