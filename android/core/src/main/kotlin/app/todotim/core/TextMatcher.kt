package app.todotim.core

import java.text.Normalizer
import java.util.Locale

/**
 * Case-insensitive substring search in [locale], for task search (port of `TextMatcher.swift`).
 *
 * The Swift version uses Foundation's localized search. The JVM has no localized substring
 * search, so this one folds both strings (NFC, then upper- and lowercase in [locale], so "ß"
 * matches "ss" and Turkish dotted/dotless i follow the locale) and searches the result. A
 * printable-ASCII query in ASCII text takes a fast path with ASCII case folding, which gives the
 * same answer except in Turkish and Azeri (those locales always take the folded search). An
 * empty query matches nothing, like Foundation.
 */
class TextMatcher(val query: String, val locale: Locale = Locale.getDefault()) {
    /** The query lowercased, when the fast path applies. */
    private val asciiQuery: ByteArray? =
        if (locale.language != "tr" && locale.language != "az" && query.isNotEmpty() && query.all { it in ' '..'~' }) {
            ByteArray(query.length) { lower(query[it].code.toByte()) }
        } else {
            null
        }
    private val foldedQuery: String by lazy { fold(query) }

    fun matches(text: String): Boolean {
        if (query.isEmpty()) return false
        val q = asciiQuery
        if (q != null && text.all { it.code < 0x80 }) return asciiContains(text, q)
        return fold(text).contains(foldedQuery)
    }

    private fun fold(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFC).uppercase(locale).lowercase(locale)

    private companion object {
        fun asciiContains(t: String, q: ByteArray): Boolean {
            val n = t.length
            val m = q.size
            if (m > n) return false
            val first = q[0]
            for (s in 0..n - m) {
                if (lower(t[s].code.toByte()) == first) {
                    var k = 1
                    while (k < m && lower(t[s + k].code.toByte()) == q[k]) k++
                    if (k == m) return true
                }
            }
            return false
        }

        fun lower(b: Byte): Byte = if (b in 'A'.code.toByte()..'Z'.code.toByte()) (b.toInt() or 0x20).toByte() else b
    }
}
