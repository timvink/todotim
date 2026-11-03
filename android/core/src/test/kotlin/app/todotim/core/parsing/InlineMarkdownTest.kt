package app.todotim.core.parsing

import app.todotim.core.parsing.InlineMarkdown.Span
import org.junit.Assert.assertEquals
import org.junit.Test

class InlineMarkdownTest {
    private fun p(s: String) = InlineMarkdown.parse(s)

    @Test fun plainTextIsOneSpan() {
        assertEquals(listOf(Span("Buy milk")), p("Buy milk"))
        assertEquals(emptyList<Span>(), p(""))
    }

    @Test fun markdownLink() {
        assertEquals(
            listOf(Span("Read "), Span("the docs", url = "https://example.com/a_b"), Span(" today")),
            p("Read [the docs](https://example.com/a_b) today"),
        )
        assertEquals(listOf(Span("x", url = "https://e.com/wiki/A_(b)")), p("[x](https://e.com/wiki/A_(b))"))
        assertEquals(listOf(Span("mail", url = "mailto:a@b.c")), p("[mail](mailto:a@b.c)"))
    }

    @Test fun otherSchemesKeepTextOnly() {
        assertEquals(listOf(Span("click")), p("[click](javascript:alert(1))"))
        assertEquals(listOf(Span("f")), p("[f](file:///etc/passwd)"))
    }

    @Test fun notALink() {
        assertEquals(listOf(Span("[a] (b)")), p("[a] (b)"))
        assertEquals(listOf(Span("[a](b c)")), p("[a](b c)"))
        assertEquals(listOf(Span("[open")), p("[open"))
    }

    @Test fun bareURLs() {
        assertEquals(
            listOf(Span("See "), Span("https://example.com/x_y_z", url = "https://example.com/x_y_z"), Span(".")),
            p("See https://example.com/x_y_z."),
        )
        assertEquals(listOf(Span("("), Span("http://a.b/c", url = "http://a.b/c"), Span(")")), p("(http://a.b/c)"))
        assertEquals(listOf(Span("www.a.nl", url = "https://www.a.nl")), p("www.a.nl"))
        assertEquals(listOf(Span("https://")), p("https://"))
        assertEquals(listOf(Span("xhttp://a.b")), p("xhttp://a.b"))
    }

    @Test fun emphasis() {
        assertEquals(listOf(Span("a "), Span("b", bold = true), Span(" c")), p("a **b** c"))
        assertEquals(listOf(Span("b", bold = true)), p("__b__"))
        assertEquals(listOf(Span("i", italic = true)), p("*i*"))
        assertEquals(listOf(Span("i", italic = true)), p("_i_"))
        assertEquals(listOf(Span("s", strike = true)), p("~~s~~"))
        assertEquals(listOf(Span("x"), Span("y", bold = true, italic = true)), p("x***y***"))
        assertEquals(listOf(Span("a "), Span("b ", italic = true), Span("c", italic = true, bold = true)), p("a *b **c***"))
    }

    @Test fun emphasisNeedsFlanking() {
        assertEquals(listOf(Span("snake_case_name")), p("snake_case_name"))
        assertEquals(listOf(Span("2 * 3 * 4")), p("2 * 3 * 4"))
        assertEquals(listOf(Span("**")), p("**"))
        assertEquals(listOf(Span("~a~")), p("~a~"))
    }

    @Test fun codeAndEscapes() {
        assertEquals(listOf(Span("run "), Span("a_b *c*", code = true)), p("run `a_b *c*`"))
        assertEquals(listOf(Span("*not*")), p("\\*not\\*"))
        assertEquals(listOf(Span("`")), p("`"))
    }

    @Test fun boldLink() {
        assertEquals(listOf(Span("go", bold = true, url = "https://a.b")), p("**[go](https://a.b)**"))
        assertEquals(listOf(Span("go", bold = true, url = "https://a.b")), p("[**go**](https://a.b)"))
    }

    @Test fun plainText() {
        assertEquals("Read the docs now", InlineMarkdown.plainText("Read [the docs](https://x.y) **now**"))
    }

    @Test fun deepNestingTerminates() {
        val s = "*".repeat(500) + "a" + "*".repeat(500) + "[".repeat(500)
        assertEquals(s.count { it == 'a' }, InlineMarkdown.plainText(s).count { it == 'a' })
    }
}
