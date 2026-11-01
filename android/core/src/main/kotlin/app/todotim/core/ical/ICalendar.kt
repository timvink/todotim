package app.todotim.core.ical

import java.io.ByteArrayOutputStream
import java.time.DateTimeException
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit
import java.util.Locale

/** A property parameter; name upper-cased, value unquoted and RFC 6868-decoded. */
data class ICalParam(val name: String, val value: String)

/**
 * One content line of an iCalendar object (RFC 5545 §3.1), e.g. `DUE;VALUE=DATE:20261103`. [value] is kept as
 * written (TEXT values stay escaped), so properties TodoTim does not own round-trip byte for byte (apart from
 * line folding).
 */
class ICalProperty(
    /** Upper-cased, e.g. "DUE" or "X-APPLE-SORT-ORDER". */
    val name: String,
    /** In order of appearance. */
    val params: List<ICalParam> = emptyList(),
    val value: String,
    /**
     * The parameter values as written (quotes and lists intact), when parsed; used to write them back
     * unchanged. Ignored when its size no longer matches [params].
     */
    val rawParams: List<String>? = null,
) {
    constructor(name: String, value: String) : this(name, emptyList(), value)

    fun param(name: String): String? = params.firstOrNull { it.name == name }?.value

    fun copy(name: String = this.name, value: String = this.value): ICalProperty = ICalProperty(name, params, value, rawParams)

    /** Name, parameters and value; [rawParams] is not compared. */
    override fun equals(other: Any?): Boolean =
        other is ICalProperty && name == other.name && value == other.value && params == other.params

    override fun hashCode(): Int = (name.hashCode() * 31 + value.hashCode()) * 31 + params.hashCode()

    override fun toString(): String = ICalendar.line(this)
}

/** A component (`BEGIN:X` … `END:X`) with its properties and subcomponents, in order. */
data class ICalComponent(
    val name: String,
    val properties: MutableList<ICalProperty> = mutableListOf(),
    val components: MutableList<ICalComponent> = mutableListOf(),
) {
    fun first(name: String): ICalProperty? = properties.firstOrNull { it.name == name }
    fun all(name: String): List<ICalProperty> = properties.filter { it.name == name }

    fun remove(name: String) { properties.removeAll { it.name == name } }

    /**
     * Replaces the first property called `property.name` (keeping its position) and removes any others with that
     * name; appends it when there is none.
     */
    fun set(property: ICalProperty) {
        val i = properties.indexOfFirst { it.name == property.name }
        if (i < 0) { properties.add(property); return }
        properties[i] = property
        var k = properties.size - 1
        while (k > i) {
            if (properties[k].name == property.name) properties.removeAt(k)
            k--
        }
    }

    /** A deep copy (properties are immutable). */
    fun deepCopy(): ICalComponent =
        ICalComponent(name, properties.toMutableList(), components.mapTo(mutableListOf()) { it.deepCopy() })
}

/** Why calendar data was rejected. */
sealed class ICalException(message: String) : Exception(message) {
    class TooLarge : ICalException("calendar object too large")
    class Malformed(val reason: String) : ICalException(reason)
}

/**
 * Bounded iCalendar parser and serializer (mirrors `ICalendar` in the Swift TodoCore). Calendar data comes from
 * the server (and from any client that writes to it), so it is treated as hostile: size, line count, nesting and
 * component count are capped, and anything malformed is rejected as a whole.
 */
object ICalendar {
    /** Largest accepted calendar object (one task) in bytes. */
    const val MAX_BYTES = 1 shl 20
    const val MAX_LINES = 20_000
    const val MAX_DEPTH = 8
    const val MAX_COMPONENTS = 1_000
    const val MAX_PARAMS = 64

    private const val SPACE = ' '.code.toByte()
    private const val TAB = '\t'.code.toByte()
    private const val CR = '\r'.code.toByte()
    private const val LF = '\n'.code.toByte()
    private const val SEMI = ';'.code.toByte()
    private const val COLON = ':'.code.toByte()
    private const val EQUALS = '='.code.toByte()
    private const val QUOTE = '"'.code.toByte()

    /**
     * Parses one iCalendar object; the result is the outermost component (normally VCALENDAR). Works on UTF-8
     * bytes: folding may split a line before any code point, including one that combines with the previous
     * character.
     */
    @Throws(ICalException::class)
    fun parse(text: String): ICalComponent {
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_BYTES) throw ICalException.TooLarge()
        // Unfold (RFC 5545 §3.1): a line starting with a space or tab continues the previous one.
        // Servers may deliver LF instead of CRLF (e.g. inside XML), so both are accepted.
        val lines = ArrayList<ByteArrayOutputStream>()
        var physical = 0
        var start = 0
        while (start <= bytes.size) {
            var end = start
            while (end < bytes.size && bytes[end] != LF) end++
            var lineEnd = end
            if (lineEnd > start && bytes[lineEnd - 1] == CR) lineEnd--
            physical++
            if (physical > MAX_LINES) throw ICalException.TooLarge()
            if (lineEnd > start && (bytes[start] == SPACE || bytes[start] == TAB)) {
                if (lines.isEmpty()) throw ICalException.Malformed("continuation without a line")
                lines.last().write(bytes, start + 1, lineEnd - start - 1)
            } else if (lineEnd > start) {
                lines.add(ByteArrayOutputStream(lineEnd - start).apply { write(bytes, start, lineEnd - start) })
            }
            start = end + 1
        }
        val stack = ArrayList<ICalComponent>()
        var root: ICalComponent? = null
        var componentCount = 0
        for (line in lines) {
            val p = parseLine(line.toByteArray())
            when (p.name) {
                "BEGIN" -> {
                    if (root != null) throw ICalException.Malformed("content after the end")
                    componentCount++
                    if (stack.size >= MAX_DEPTH || componentCount > MAX_COMPONENTS) throw ICalException.TooLarge()
                    stack.add(ICalComponent(p.value.uppercase()))
                }
                "END" -> {
                    val done = stack.removeLastOrNull()
                    if (done == null || done.name != p.value.uppercase()) throw ICalException.Malformed("unbalanced END:${p.value}")
                    if (stack.isEmpty()) root = done else stack.last().components.add(done)
                }
                else -> {
                    if (stack.isEmpty()) throw ICalException.Malformed("property outside a component")
                    stack.last().properties.add(p)
                }
            }
        }
        if (stack.isNotEmpty() || root == null) throw ICalException.Malformed("missing END")
        return root
    }

    /** `NAME;P=V;P2="a:b":value`, as UTF-8 bytes (all delimiters are ASCII). */
    @Throws(ICalException::class)
    fun parseLine(line: ByteArray): ICalProperty {
        fun isNameByte(c: Byte): Boolean {
            val b = c.toInt()
            return (b in 0x41..0x5A) || (b in 0x61..0x7A) || (b in 0x30..0x39) || b == 0x2D
        }
        fun text(from: Int, to: Int) = String(line, from, to - from, Charsets.UTF_8)
        val n = line.size
        var i = 0
        while (i < n && isNameByte(line[i])) i++
        val name = text(0, i).uppercase()
        if (name.isEmpty() || i >= n) throw ICalException.Malformed("bad content line")
        val params = ArrayList<ICalParam>()
        val raw = ArrayList<String>()
        while (line[i] == SEMI) {
            i++
            val start = i
            while (i < n && isNameByte(line[i])) i++
            val pname = text(start, i).uppercase()
            if (pname.isEmpty() || i >= n || line[i] != EQUALS) throw ICalException.Malformed("bad parameter")
            i++
            // A parameter may hold a comma-separated list; quoted parts may contain ; : ,
            val valueStart = i
            val value = ByteArrayOutputStream()
            while (i < n && line[i] != SEMI && line[i] != COLON) {
                if (line[i] == QUOTE) {
                    var close = i + 1
                    while (close < n && line[close] != QUOTE) close++
                    if (close >= n) throw ICalException.Malformed("unterminated quote")
                    value.write(line, i + 1, close - i - 1)
                    i = close + 1
                } else {
                    value.write(line[i].toInt())
                    i++
                }
            }
            params.add(ICalParam(pname, decodeParam(value.toString(Charsets.UTF_8))))
            raw.add(text(valueStart, i))
            if (params.size > MAX_PARAMS || i >= n) throw ICalException.Malformed("bad parameters")
        }
        if (line[i] != COLON) throw ICalException.Malformed("missing ':'")
        return ICalProperty(name, params, text(i + 1, n), raw)
    }

    fun serialize(c: ICalComponent): String {
        val out = StringBuilder()
        fun emit(c: ICalComponent) {
            out.append(fold("BEGIN:${c.name}"))
            for (p in c.properties) out.append(fold(line(p)))
            for (sub in c.components) emit(sub)
            out.append(fold("END:${c.name}"))
        }
        emit(c)
        return out.toString()
    }

    fun line(p: ICalProperty): String {
        val s = StringBuilder(p.name)
        val raw = p.rawParams?.takeIf { it.size == p.params.size }
        for ((k, param) in p.params.withIndex()) {
            if (raw != null) {
                s.append(';').append(param.name).append('=').append(raw[k])
                continue
            }
            val encoded = encodeParam(param.value)
            val needsQuotes = encoded.any { it == ':' || it == ';' || it == ',' } || encoded.isEmpty()
            s.append(';').append(param.name).append('=').append(if (needsQuotes) "\"$encoded\"" else encoded)
        }
        return s.append(':').append(p.value).toString()
    }

    /** Folds at 75 octets (RFC 5545 §3.1) without splitting a UTF-8 sequence; ends with CRLF. */
    fun fold(line: String): String {
        val out = StringBuilder(line.length + 8)
        var count = 0
        var i = 0
        while (i < line.length) {
            val cp = line.codePointAt(i)
            val n = when {
                cp < 0x80 -> 1
                cp < 0x800 -> 2
                cp < 0x10000 -> 3
                else -> 4
            }
            if (count + n > 75) {
                out.append("\r\n ")
                count = 1
            }
            out.appendCodePoint(cp)
            count += n
            i += Character.charCount(cp)
        }
        return out.append("\r\n").toString()
    }

    // Values

    /** TEXT escaping (RFC 5545 §3.3.11). */
    fun escapeText(s: String): String {
        val out = StringBuilder(s.length + 8)
        for (c in graphemes(s)) {
            when (c) {
                "\\" -> out.append("\\\\")
                ";" -> out.append("\\;")
                "," -> out.append("\\,")
                "\n", "\r\n" -> out.append("\\n")
                "\r" -> {}
                else -> out.append(c)
            }
        }
        return out.toString()
    }

    fun unescapeText(s: String): String {
        if (!s.contains('\\')) return s
        val out = StringBuilder(s.length)
        var escaped = false
        for (c in graphemes(s)) {
            if (escaped) {
                if (c == "n" || c == "N") out.append('\n') else out.append(c) // \\ \; \, and anything unexpected
                escaped = false
            } else if (c == "\\") {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out.toString()
    }

    /** Splits a TEXT list (e.g. CATEGORIES) on unescaped commas and unescapes each item. */
    fun splitTextList(s: String): List<String> {
        val items = ArrayList<String>()
        val current = StringBuilder()
        var escaped = false
        for (c in graphemes(s)) {
            if (escaped) { current.append('\\').append(c); escaped = false }
            else if (c == "\\") escaped = true
            else if (c == ",") { items.add(current.toString()); current.setLength(0) }
            else current.append(c)
        }
        items.add(current.toString())
        return items.map(::unescapeText)
    }

    /**
     * RFC 6868 parameter encoding: ^n newline, ^' double quote, ^^ caret. (RFC 5545 itself cannot put a double
     * quote in a parameter value.)
     */
    fun encodeParam(s: String): String {
        val out = StringBuilder(s.length)
        for (c in graphemes(s)) {
            when (c) {
                "^" -> out.append("^^")
                "\"" -> out.append("^'")
                "\n", "\r\n" -> out.append("^n")
                "\r" -> {}
                else -> out.append(c)
            }
        }
        return out.toString()
    }

    fun decodeParam(s: String): String {
        if (!s.contains('^')) return s
        val out = StringBuilder(s.length)
        var caret = false
        for (c in graphemes(s)) {
            if (caret) {
                when (c) {
                    "n" -> out.append('\n')
                    "'" -> out.append('"')
                    "^" -> out.append('^')
                    else -> out.append('^').append(c)
                }
                caret = false
            } else if (c == "^") {
                caret = true
            } else {
                out.append(c)
            }
        }
        if (caret) out.append('^')
        return out.toString()
    }

    // Dates

    /** `DUE;VALUE=DATE:20261103`. */
    fun dateProperty(name: String, due: LocalDate): ICalProperty =
        ICalProperty(name, listOf(ICalParam("VALUE", "DATE")), basicDate(due.year, due.monthValue, due.dayOfMonth))

    /** UTC DATE-TIME `20261103T101500Z` (whole seconds, rounded down) for epoch milliseconds. */
    fun utcString(epochMillis: Long): String {
        val t = Instant.ofEpochSecond(Math.floorDiv(epochMillis, 1000L)).atOffset(ZoneOffset.UTC)
        return basicDate(t.year, t.monthValue, t.dayOfMonth) +
            String.format(Locale.ROOT, "T%02d%02d%02dZ", t.hour, t.minute, t.second)
    }

    /**
     * Parses a DATE-TIME as epoch milliseconds: UTC (`Z`), TZID (when known) or floating (read in [floating]).
     * A DATE is midnight UTC. Null when invalid.
     */
    fun instant(p: ICalProperty, floating: ZoneId = ZoneId.systemDefault()): Long? {
        val v = DateValue.of(p) ?: return null
        val t = v.timePart ?: return v.dateTime(0, 0, 0)?.toInstant(ZoneOffset.UTC)?.toEpochMilli()
        val zone: ZoneId = if (t.endsWith("Z")) ZoneOffset.UTC else (v.tzid?.let(::zoneOrNull) ?: floating)
        val (h, m, s) = v.clock()
        return v.dateTime(h, m, s)?.atZone(zone)?.toInstant()?.toEpochMilli()
    }

    internal fun basicDate(year: Int, month: Int, day: Int) = String.format(Locale.ROOT, "%04d%02d%02d", year, month, day)

    /**
     * Swift `TimeZone(identifier:)`: a region id, UTC/GMT, or an abbreviation Foundation also knows (`EST`, `PST`,
     * via [ZoneId.SHORT_IDS]); not offsets like `+01:00`.
     */
    internal fun zoneOrNull(id: String): ZoneId? {
        if (id.isEmpty() || id[0] == '+' || id[0] == '-' || id == "Z") return null
        return try { ZoneId.of(id, ZoneId.SHORT_IDS) } catch (_: DateTimeException) { null }
    }
}

/**
 * A DATE or DATE-TIME value as written: `yyyyMMdd`, optionally `THHmmss` and `Z`, plus the TZID parameter.
 * Like Foundation's calendar, out-of-range days and times roll over (Feb 31 is Mar 3, T250000 the next day).
 */
data class DateValue(
    val year: Int,
    val month: Int,
    val day: Int,
    /** "THHmmss" or "THHmmssZ"; null for a DATE. */
    val timePart: String?,
    val tzid: String?,
) {
    val isDate: Boolean get() = timePart == null

    internal fun clock(): Triple<Int, Int, Int> {
        val d = timePart!!.substring(1, 7).map { it - '0' }
        return Triple(d[0] * 10 + d[1], d[2] * 10 + d[3], d[4] * 10 + d[5])
    }

    /** The written date, rolled over like Foundation's lenient calendar. */
    internal fun date(): LocalDate? = try {
        LocalDate.of(year, month, 1).plusDays((day - 1).toLong())
    } catch (_: DateTimeException) { null }

    internal fun dateTime(h: Int, m: Int, s: Int): LocalDateTime? =
        date()?.atStartOfDay()?.plusHours(h.toLong())?.plusMinutes(m.toLong())?.plusSeconds(s.toLong())

    /**
     * The date in [zone]: a DATE or floating time as written; a UTC or TZID time converted (an unknown TZID is
     * read as floating).
     */
    fun localDate(zone: ZoneId): LocalDate? {
        val t = timePart ?: return date()
        val source: ZoneId = (if (t.endsWith("Z")) ZoneOffset.UTC else tzid?.let(ICalendar::zoneOrNull)) ?: return date()
        val (h, m, s) = clock()
        val local = dateTime(h, m, s) ?: return date()
        return local.atZone(source).withZoneSameInstant(zone).toLocalDate()
    }

    /** The same value moved by [days] calendar days (time of day and TZID unchanged). */
    fun shifted(days: Long): DateValue {
        val moved = date()?.plusDays(days) ?: return this
        return copy(year = moved.year, month = moved.monthValue, day = moved.dayOfMonth)
    }

    fun property(name: String, keeping: ICalProperty): ICalProperty =
        keeping.copy(name = name, value = ICalendar.basicDate(year, month, day) + (timePart ?: ""))

    companion object {
        fun of(p: ICalProperty): DateValue? {
            val v = trimWhitespace(p.value)
            if (v.length < 8 || !v.substring(0, 8).all { it in '0'..'9' }) return null
            val y = v.substring(0, 4).toInt()
            val m = v.substring(4, 6).toInt()
            val d = v.substring(6, 8).toInt()
            if (m !in 1..12 || d !in 1..31) return null
            if (v.length == 8) return DateValue(y, m, d, null, p.param("TZID"))
            val t = v.substring(8)
            // Swift counts Characters here, so a trailing combining mark does not change the length.
            val clusters = graphemes(t)
            val digits = t.drop(1).take(6)
            if (!t.startsWith("T") || digits.length != 6 || !digits.all { it in '0'..'9' } ||
                !(clusters.size == 7 || (clusters.size == 8 && clusters.last() == "Z"))) return null
            return DateValue(y, m, d, t, p.param("TZID"))
        }
    }
}

/** Calendar days from [from] to [to]. */
internal fun daysBetween(from: LocalDate, to: LocalDate): Long = ChronoUnit.DAYS.between(from, to)
