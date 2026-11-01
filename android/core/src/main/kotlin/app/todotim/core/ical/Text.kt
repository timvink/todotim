package app.todotim.core.ical

import java.math.BigDecimal
import java.text.BreakIterator

// Small helpers that reproduce Swift `String` semantics the Swift TodoCore relies on, so the Kotlin port
// reads and writes the same bytes.

/**
 * The extended grapheme clusters of [s] (Swift `Character`s). Swift compares and escapes text per
 * Character, so a `\` followed by a combining mark is not an escape, and CR LF is one newline.
 */
internal fun graphemes(s: String): List<String> {
    if (s.all { it.code < 0x80 }) {
        // ASCII: every character is a cluster, except CR LF.
        val out = ArrayList<String>(s.length)
        var i = 0
        while (i < s.length) {
            if (s[i] == '\r' && i + 1 < s.length && s[i + 1] == '\n') { out.add("\r\n"); i += 2 } else { out.add(s[i].toString()); i++ }
        }
        return out
    }
    val it = BreakIterator.getCharacterInstance()
    it.setText(s)
    val out = ArrayList<String>()
    var start = it.first()
    var end = it.next()
    while (end != BreakIterator.DONE) {
        out.add(s.substring(start, end))
        start = end
        end = it.next()
    }
    return out
}

/** Swift `s.count` (Characters). */
internal fun graphemeCount(s: String): Int = graphemes(s).size

/** Swift `trimmingCharacters(in: .whitespaces)`: Unicode Zs and tab (not newlines). */
internal fun trimWhitespace(s: String): String {
    fun ws(c: Char) = c == '\t' || Character.getType(c) == Character.SPACE_SEPARATOR.toInt()
    var a = 0
    var b = s.length
    while (a < b && ws(s[a])) a++
    while (b > a && ws(s[b - 1])) b--
    return if (a == 0 && b == s.length) s else s.substring(a, b)
}

private val INTEGER = Regex("[+-]?[0-9]+")

/** Swift `Int64(s)`: ASCII digits with an optional sign, nil on overflow. */
internal fun parseLong(s: String): Long? = if (INTEGER.matches(s)) s.toLongOrNull() else null

private val DECIMAL = Regex("[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?")
private val HEX = Regex("([+-]?)0[xX]([0-9a-fA-F]+\\.?[0-9a-fA-F]*|\\.[0-9a-fA-F]+)([pP][+-]?[0-9]+)?")

/** Swift `Double(s)` (strtod syntax, no surrounding whitespace). Infinity and NaN spellings give non-finite values. */
internal fun parseDouble(s: String): Double? {
    if (DECIMAL.matches(s)) return s.toDouble()
    HEX.matchEntire(s)?.let { m -> return (if (m.groupValues[3].isEmpty()) "${s}p0" else s).toDouble() }
    return when (s.lowercase().removePrefix("+").removePrefix("-")) {
        "inf", "infinity" -> if (s.startsWith("-")) Double.NEGATIVE_INFINITY else Double.POSITIVE_INFINITY
        "nan" -> Double.NaN
        else -> null
    }
}

/**
 * Swift `"\(d)"` (`Double.description`): shortest round-trip digits; exponential (`1e-05`, `1.5e+16`) below
 * 1e-4 or above 2^53, else decimal with at least one fractional digit (`2.0`, `0.25`).
 */
internal fun swiftDescription(d: Double): String {
    if (d.isNaN()) return "nan"
    if (d.isInfinite()) return if (d > 0) "inf" else "-inf"
    if (d == 0.0) return if (1.0 / d < 0) "-0.0" else "0.0"
    val sign = if (d < 0) "-" else ""
    // JDK 19+ Double.toString gives the shortest digits that read back as the same value.
    val bd = BigDecimal(java.lang.Double.toString(Math.abs(d))).stripTrailingZeros()
    val digits = bd.unscaledValue().toString()
    // value = 0.<digits> × 10^decimalExponent
    val decimalExponent = digits.length - bd.scale()
    if (decimalExponent < -3 || Math.abs(d) > 9007199254740992.0) {
        val e = decimalExponent - 1
        val mantissa = if (digits.length == 1) digits else digits[0] + "." + digits.substring(1)
        val exp = Math.abs(e).toString().padStart(2, '0')
        return sign + mantissa + "e" + (if (e < 0) "-" else "+") + exp
    }
    val body = when {
        decimalExponent <= 0 -> "0." + "0".repeat(-decimalExponent) + digits
        digits.length <= decimalExponent -> digits + "0".repeat(decimalExponent - digits.length) + ".0"
        else -> digits.substring(0, decimalExponent) + "." + digits.substring(decimalExponent)
    }
    return sign + body
}
