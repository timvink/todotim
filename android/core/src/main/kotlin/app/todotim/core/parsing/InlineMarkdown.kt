package app.todotim.core.parsing

/**
 * Inline Markdown in task titles and descriptions, as the Mac app renders it (`RichText`): `[text](url)`,
 * `**bold**` / `__bold__`, `*italic*` / `_italic_`, `` `code` ``, `~~strike~~`, backslash escapes, and bare
 * `http(s)://`, `mailto:` and `www.` URLs as links. Only http, https and mailto links are kept; a link with
 * another scheme keeps its text without the link. The stored text is never changed: this only drives display.
 */
object InlineMarkdown {
    /** A run of text with one style; [url] is set for a link. */
    data class Span(
        val text: String,
        val bold: Boolean = false,
        val italic: Boolean = false,
        val code: Boolean = false,
        val strike: Boolean = false,
        val url: String? = null,
    )

    val allowedSchemes = setOf("http", "https", "mailto")

    /** The display text without markup. */
    fun plainText(source: String): String = parse(source).joinToString("") { it.text }

    fun parse(source: String): List<Span> {
        if (source.isEmpty()) return emptyList()
        if (source.none { it in MARKUP } && !mayContainURL(source)) return listOf(Span(source))
        val out = ArrayList<Span>()
        Parser(source, out).run(0, source.length, Span(""))
        return merge(out)
    }

    fun isAllowed(url: String): Boolean {
        val colon = url.indexOf(':')
        if (colon <= 0) return false
        return url.substring(0, colon).lowercase() in allowedSchemes
    }

    private const val MARKUP = "[*_`~\\"
    private const val MAX_DEPTH = 8

    private fun mayContainURL(s: String) =
        s.contains("http", ignoreCase = true) || s.contains("mailto:", ignoreCase = true) || s.contains("www.", ignoreCase = true)

    private val bareURL = Regex("""(?:https?://|mailto:|www\.)[^\s<>]+""", RegexOption.IGNORE_CASE)

    private fun merge(spans: List<Span>): List<Span> {
        val out = ArrayList<Span>(spans.size)
        for (s in spans) {
            if (s.text.isEmpty()) continue
            val last = out.lastOrNull()
            if (last != null && last.copy(text = "") == s.copy(text = "")) out[out.size - 1] = last.copy(text = last.text + s.text)
            else out.add(s)
        }
        return out
    }

    private class Parser(val s: String, val out: MutableList<Span>) {
        private var depth = 0

        fun run(start: Int, end: Int, style: Span) {
            depth++
            val buf = StringBuilder()
            fun flush() { if (buf.isNotEmpty()) { out.add(style.copy(text = buf.toString())); buf.clear() } }
            var i = start
            while (i < end) {
                val c = s[i]
                // Backslash escape of ASCII punctuation.
                if (c == '\\' && i + 1 < end && s[i + 1].isAsciiPunctuation()) {
                    buf.append(s[i + 1]); i += 2; continue
                }
                // Bare URL (before emphasis, so `_` inside a URL stays literal).
                if (style.url == null && (c == 'h' || c == 'H' || c == 'm' || c == 'M' || c == 'w' || c == 'W') &&
                    (i == 0 || !s[i - 1].isLetterOrDigit())
                ) {
                    val m = bareURL.matchAt(s, i)
                    if (m != null && m.range.last < end) {
                        val raw = trimURL(m.value)
                        val url = if (raw.startsWith("www.", ignoreCase = true)) "https://$raw" else raw
                        if (raw.length > 4 && !raw.endsWith("://") && isAllowed(url)) {
                            flush()
                            out.add(style.copy(text = raw, url = url))
                            i += raw.length
                            continue
                        }
                    }
                }
                if (depth <= MAX_DEPTH) {
                    val next = when (c) {
                        '`' -> code(i, end, style, ::flush)
                        '[' -> link(i, end, style, ::flush)
                        '*', '_', '~' -> emphasis(i, end, style, ::flush)
                        else -> -1
                    }
                    if (next >= 0) { i = next; continue }
                }
                buf.append(c); i++
            }
            flush()
            depth--
        }

        /** `` `code` ``: no markup inside. Returns the index after it, or -1. */
        private fun code(i: Int, end: Int, style: Span, flush: () -> Unit): Int {
            var ticks = 0
            while (i + ticks < end && s[i + ticks] == '`') ticks++
            val fence = "`".repeat(ticks)
            var j = s.indexOf(fence, i + ticks)
            while (j in 0 until end && j + ticks < end && s[j + ticks] == '`') j = s.indexOf(fence, j + ticks + 1)
            if (j < 0 || j + ticks > end || j == i + ticks) return -1
            flush()
            out.add(style.copy(text = s.substring(i + ticks, j), code = true))
            return j + ticks
        }

        /** `[text](url)`. Returns the index after it, or -1. */
        private fun link(i: Int, end: Int, style: Span, flush: () -> Unit): Int {
            if (style.url != null) return -1
            var j = i + 1
            var nest = 0
            while (j < end) {
                when (s[j]) {
                    '\\' -> j++
                    '[' -> nest++
                    ']' -> if (nest == 0) break else nest--
                }
                j++
            }
            if (j >= end || j + 1 >= end || s[j + 1] != '(') return -1
            val close = j
            var k = close + 2
            var parens = 0
            while (k < end) {
                val c = s[k]
                if (c.isWhitespace()) return -1
                if (c == '(') parens++
                if (c == ')') { if (parens == 0) break else parens-- }
                k++
            }
            if (k >= end) return -1
            var url = s.substring(close + 2, k)
            if (url.startsWith('<') && url.endsWith('>')) url = url.substring(1, url.length - 1)
            flush()
            run(i + 1, close, if (isAllowed(url)) style.copy(url = url) else style)
            return k + 1
        }

        /** `**bold**`, `__bold__`, `*italic*`, `_italic_`, `~~strike~~`. Returns the index after it, or -1. */
        private fun emphasis(i: Int, end: Int, style: Span, flush: () -> Unit): Int {
            val c = s[i]
            val double = i + 1 < end && s[i + 1] == c
            if (c == '~' && !double) return -1
            val n = if (double) 2 else 1
            val open = i + n
            if (open >= end || s[open].isWhitespace()) return -1
            // `_` only opens and closes at word boundaries (snake_case stays literal).
            if (c == '_' && i > 0 && s[i - 1].isLetterOrDigit()) return -1
            var j = open
            while (j < end) {
                val ch = s[j]
                if (ch == '\\') { j += 2; continue }
                if (ch == '`') { val after = codeEnd(j, end); if (after > 0) { j = after; continue } }
                if (ch == c) {
                    val run = countRun(j, end, c)
                    val closes = !s[j - 1].isWhitespace() && run >= n &&
                        (c != '_' || j + run >= end || !s[j + run].isLetterOrDigit()) &&
                        (double || run == 1 || run >= 3)
                    // A longer run closes with its last delimiters, so `***x***` is bold around italic.
                    val close = j + run - n
                    if (closes && close > open) {
                        flush()
                        val inner = when {
                            c == '~' -> style.copy(strike = true)
                            double -> style.copy(bold = true)
                            else -> style.copy(italic = true)
                        }
                        run(open, close, inner)
                        return close + n
                    }
                    j += run
                    continue
                }
                j++
            }
            return -1
        }

        private fun countRun(j: Int, end: Int, c: Char): Int {
            var k = j
            while (k < end && s[k] == c) k++
            return k - j
        }

        private fun codeEnd(j: Int, end: Int): Int {
            val close = s.indexOf('`', j + 1)
            return if (close in (j + 2) until end) close + 1 else -1
        }
    }

    /** Drops trailing punctuation that ends the sentence rather than the URL, and an unbalanced `)`. */
    private fun trimURL(raw: String): String {
        var u = raw
        while (u.isNotEmpty()) {
            val last = u.last()
            u = when {
                last in ".,;:!?'\"*_~" -> u.dropLast(1)
                last == ')' && u.count { it == '(' } < u.count { it == ')' } -> u.dropLast(1)
                last == ']' && u.count { it == '[' } < u.count { it == ']' } -> u.dropLast(1)
                else -> return u
            }
        }
        return u
    }

    private fun Char.isAsciiPunctuation() = this in "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
}
