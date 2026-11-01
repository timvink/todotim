package app.todotim.android.data

import app.todotim.core.Priority
import java.time.LocalDate

/**
 * Quick-add parsing as the UI needs it: the cleaned title, the recognised values, and the ranges of
 * the tokens so the field can highlight them.
 *
 * TODO: back this with `app.todotim.core.parsing.QuickAddParser` (being ported from the Mac app) and
 * delete [StubQuickAddParser].
 */
interface QuickAddParsing {
    fun parse(text: String, today: LocalDate): QuickAddResult
}

data class QuickAddResult(
    /** The text with the recognised tokens removed. */
    val content: String,
    val due: LocalDate? = null,
    val recurrence: String? = null,
    val priority: Priority? = null,
    val labels: List<String> = emptyList(),
    /** Project name after `#`, matched against projects by the UI. */
    val projectName: String? = null,
    /** Section name after `/`. */
    val sectionName: String? = null,
    val tokens: List<QuickAddToken> = emptyList(),
)

data class QuickAddToken(val range: IntRange, val kind: Kind) {
    enum class Kind { Date, Priority, Label, Project, Section }
}

/**
 * Minimal parser so the sheet works: `p1`–`p4`, `@label`, `#project`, `/section` (single words) and the
 * date words `today`, `tod`, `tomorrow`, `tom`. Not the real grammar.
 */
object StubQuickAddParser : QuickAddParsing {
    private val token = Regex("""(?<=^|\s)(p[1-4]|@[\w-]+|#[\w-]+|/[\w-]+|today|tod|tomorrow|tom)(?=\s|$)""", RegexOption.IGNORE_CASE)

    override fun parse(text: String, today: LocalDate): QuickAddResult {
        var due: LocalDate? = null
        var priority: Priority? = null
        var project: String? = null
        var section: String? = null
        val labels = mutableListOf<String>()
        val tokens = mutableListOf<QuickAddToken>()
        for (m in token.findAll(text)) {
            val v = m.value
            val kind = when {
                v.startsWith("@") -> QuickAddToken.Kind.Label.also { labels += v.drop(1) }
                v.startsWith("#") -> QuickAddToken.Kind.Project.also { project = v.drop(1) }
                v.startsWith("/") -> QuickAddToken.Kind.Section.also { section = v.drop(1) }
                v.length == 2 && v[0].lowercaseChar() == 'p' ->
                    QuickAddToken.Kind.Priority.also { priority = Priority.entries[v[1].digitToInt() - 1] }
                else -> QuickAddToken.Kind.Date.also {
                    due = if (v.lowercase().startsWith("tod")) today else today.plusDays(1)
                }
            }
            tokens += QuickAddToken(m.range, kind)
        }
        val content = tokens.sortedByDescending { it.range.first }
            .fold(text) { acc, t -> acc.removeRange(t.range) }
            .replace(Regex("\\s+"), " ").trim()
        return QuickAddResult(content, due, null, priority, labels.distinct(), project, section, tokens)
    }
}
