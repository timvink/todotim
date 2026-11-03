package app.todotim.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import app.todotim.core.parsing.InlineMarkdown

/**
 * Task titles and description lines with inline Markdown and bare URLs rendered, like the Mac app: links are
 * underlined in the surrounding text colour and open in the browser (http, https and mailto only). Taps outside
 * a link still reach the row.
 */
@Composable
fun rememberRichText(source: String): AnnotatedString = remember(source) { richText(source) }

private val linkStyles = TextLinkStyles(SpanStyle(textDecoration = TextDecoration.Underline))

fun richText(source: String): AnnotatedString {
    val spans = InlineMarkdown.parse(source)
    if (spans.size == 1 && spans[0].let { !it.bold && !it.italic && !it.code && !it.strike && it.url == null }) {
        return AnnotatedString(source)
    }
    return buildAnnotatedString {
        for (span in spans) {
            val style = SpanStyle(
                fontWeight = if (span.bold) FontWeight.Bold else null,
                fontStyle = if (span.italic) FontStyle.Italic else null,
                fontFamily = if (span.code) FontFamily.Monospace else null,
                textDecoration = if (span.strike) TextDecoration.LineThrough else null,
            )
            val url = span.url
            if (url != null) withLink(LinkAnnotation.Url(url, linkStyles)) { withStyle(style) { append(span.text) } }
            else withStyle(style) { append(span.text) }
        }
    }
}
