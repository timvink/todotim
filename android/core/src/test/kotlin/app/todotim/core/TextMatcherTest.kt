package app.todotim.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale
import kotlin.random.Random

class TextMatcherTest {
    private val us = Locale.US
    private val turkish = Locale.forLanguageTag("tr-TR")

    private fun m(query: String, text: String, locale: Locale = us) = TextMatcher(query, locale).matches(text)

    @Test fun caseInsensitiveSubstring() {
        assertTrue(m("review", "Review report"))
        assertTrue(m("REV", "a review"))
        assertTrue(m("tab", "Tab\there"))
        assertTrue(m("ïve", "naïve plan"))
        assertTrue(m("é", "RÉVIEW"))
        assertFalse(m("x", "review"))
        assertFalse(m("review", "rev"))
    }

    @Test fun emptyQueryMatchesNothing() {
        assertFalse(m("", "anything"))
        assertFalse(m("", ""))
    }

    @Test fun accentsAreSignificant() {
        assertFalse(m("e", "é"))
        assertFalse(m("review", "réview"))
    }

    @Test fun fullCaseFoldingAndNormalisation() {
        assertTrue(m("strasse", "Straße"))
        assertTrue(m("é", "é")) // decomposed and precomposed are the same text
        assertTrue(m("fi", "ﬁle"))
    }

    // Port of TextMatcherTests.testTurkishCasingTakesTheLocalizedSearch.
    @Test fun turkishCasing() {
        assertTrue(m("i", "ISTANBUL"))
        assertFalse(m("i", "ISTANBUL", turkish)) // Turkish I lowercases to dotless ı
        assertFalse(m("I", "istanbul", turkish))
        assertTrue(m("i", "İSTANBUL", turkish))
        assertTrue(m("ı", "ISTANBUL", turkish))
    }

    /** The ASCII fast path must give the folded search's answer. */
    @Test fun fastPathMatchesTheFoldedSearch() {
        val random = Random(42)
        val printable = (0x20..0x7E).map { it.toChar() }
        val textAlphabet = printable + listOf('\u0000', '\u0001', '\t', '\n', '\u007F')
        fun random(alphabet: List<Char>, length: Int) = String(CharArray(length) { alphabet[random.nextInt(alphabet.size)] })
        for (locale in listOf(us, Locale.forLanguageTag("nl-NL"), Locale.forLanguageTag("lt-LT"))) {
            repeat(3000) {
                val text = random(textAlphabet, random.nextInt(14))
                val query = random(printable, 1 + random.nextInt(3))
                // Lowercasing both sides is the folded search for ASCII outside Turkish and Azeri.
                val reference = text.lowercase(locale).contains(query.lowercase(locale))
                assertEquals("$text ~ $query", reference, TextMatcher(query, locale).matches(text))
            }
        }
    }
}
