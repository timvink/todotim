package app.todotim.core.ical

import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
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

/** Swift `Double(s)` (strtod syntax, no surrounding whitespace). Infinity and NaN spellings give non-finite values. */
internal fun parseDouble(s: String): Double? {
    // Scanned by hand: a regex with optional parts backtracks quadratically on a long almost-number.
    when (scanNumber(s)) {
        NumberSyntax.DECIMAL, NumberSyntax.HEX -> return s.toDouble()
        NumberSyntax.HEX_WITHOUT_EXPONENT -> return "${s}p0".toDouble()
        null -> {}
    }
    return when (s.lowercase().removePrefix("+").removePrefix("-")) {
        "inf", "infinity" -> if (s.startsWith("-")) Double.NEGATIVE_INFINITY else Double.POSITIVE_INFINITY
        "nan" -> Double.NaN
        else -> null
    }
}

private enum class NumberSyntax { DECIMAL, HEX, HEX_WITHOUT_EXPONENT }

/**
 * The strtod syntax of [s], in one pass: `[+-]?(digits[.digits]|.digits)([eE][+-]?digits)?` or
 * `[+-]?0[xX](hexdigits[.hexdigits]|.hexdigits)([pP][+-]?digits)?` (ASCII digits); null otherwise.
 */
private fun scanNumber(s: String): NumberSyntax? {
    fun digits(from: Int, hex: Boolean): Int {
        var i = from
        while (i < s.length && (s[i] in '0'..'9' || hex && (s[i] in 'a'..'f' || s[i] in 'A'..'F'))) i++
        return i
    }
    fun sign(at: Int) = if (at < s.length && (s[at] == '+' || s[at] == '-')) at + 1 else at
    var i = sign(0)
    val hex = i + 1 < s.length && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')
    if (hex) i += 2
    var end = digits(i, hex)
    var mantissaDigits = end - i
    i = end
    if (i < s.length && s[i] == '.') {
        end = digits(i + 1, hex)
        mantissaDigits += end - i - 1
        i = end
    }
    if (mantissaDigits == 0) return null
    val exponentMarks = if (hex) "pP" else "eE"
    var hasExponent = false
    if (i < s.length && s[i] in exponentMarks) {
        val from = sign(i + 1)
        end = digits(from, hex = false)
        if (end == from) return null
        i = end
        hasExponent = true
    }
    if (i != s.length) return null
    return when {
        !hex -> NumberSyntax.DECIMAL
        hasExponent -> NumberSyntax.HEX
        else -> NumberSyntax.HEX_WITHOUT_EXPONENT
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
    // JDK 19+ Double.toString gives the shortest digits that read back as the same value, but at least two
    // (the closest two-digit decimal: 4.9E-324 for Double.MIN_VALUE); Swift writes one digit when one reads
    // back (5e-324), the closest such digit when both neighbours do.
    var bd = BigDecimal(java.lang.Double.toString(Math.abs(d))).stripTrailingZeros()
    if (bd.precision() == 2) {
        bd = listOf(RoundingMode.HALF_EVEN, RoundingMode.UP, RoundingMode.DOWN)
            .map { bd.round(MathContext(1, it)) }
            .firstOrNull { it.toDouble() == Math.abs(d) }?.stripTrailingZeros() ?: bd
    }
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
