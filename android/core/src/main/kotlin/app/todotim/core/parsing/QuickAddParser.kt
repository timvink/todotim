package app.todotim.core.parsing

import app.todotim.core.Priority
import java.time.LocalDate
import java.util.Locale

/**
 * Result of parsing a Todoist-style quick-add line such as
 * "Buy milk tomorrow p1 @errands #Shopping /Groceries".
 */
data class ParsedTask(
    /** Task title with all recognised tokens removed. */
    val content: String,
    val priority: Priority? = null,
    val due: LocalDate? = null,
    val labels: List<String> = emptyList(),
    /**
     * Project name after '#'. When it matches one of the `projectNames` passed to the parser
     * (case-insensitively), this is that name as given; otherwise the single word as typed.
     */
    val projectName: String? = null,
    /** Section name after '/'. Same matching rules as [projectName], against `sectionNames`. */
    val sectionName: String? = null,
    /** True when the line contained "no date" / "no due date" (the due date was explicitly cleared). */
    val noDate: Boolean = false,
)

/** A recognised token in a quick-add line, for highlighting while typing. */
data class ParsedToken(
    /** UTF-16 range in the original text, `start` inclusive, `end` exclusive. For [Kind.DATE] it includes a leading "on"/"by"/"due". */
    val start: Int,
    val end: Int,
    val kind: Kind,
) {
    enum class Kind { PRIORITY, LABEL, PROJECT, SECTION, DATE }
}

/**
 * Todoist-style quick-add parsing (English). Port of `QuickAddParser.swift`; both are checked
 * against `fixtures/quickadd.json`.
 *
 * Tokens may appear anywhere in the line:
 * - `p1`...`p4` as a whole word (case-insensitive). The last one wins; all are removed.
 * - `@label`: the non-space characters after '@'. All labels are kept (deduplicated).
 * - `#Project`, `/Section`: the longest name from `projectNames`/`sectionNames` that matches
 *   case-insensitively (may contain spaces) and ends at a space or the end of the line;
 *   otherwise the single word after the sigil. The last one wins; all are removed.
 * - A date phrase (see [DateParser]). Only the last date phrase is used and removed; earlier
 *   ones stay in the content. A directly preceding "on", "by", "due", "due on" or "due by"
 *   is removed with it.
 *
 * Sigils ('@', '#', '/') only start a token at the start of the line or after whitespace, so
 * "a@b.com" and "and/or" are left alone.
 *
 * False-positive rules for dates: phrases match whole words only; a bare number ("chapter 5")
 * or a bare month name ("about may") is never a date. Words that are also common words or
 * names ("tom", "tod", "sat", "sun", "wed", "weekend") only count as a date when typed in
 * lowercase and either at the end of the line (ignoring other tokens) or introduced by
 * "on"/"by"/"due".
 */
object QuickAddParser {
    fun parse(
        text: String,
        today: LocalDate,
        locale: Locale = Locale.getDefault(),
        projectNames: List<String> = emptyList(),
        sectionNames: List<String> = emptyList(),
    ): ParsedTask = analyse(text, today, locale, projectNames, sectionNames).first

    /**
     * Recognised tokens in [text], sorted by position. Consistent with [parse]: exactly these
     * ranges are removed from the content.
     */
    fun tokens(
        text: String,
        today: LocalDate,
        locale: Locale = Locale.getDefault(),
        projectNames: List<String> = emptyList(),
        sectionNames: List<String> = emptyList(),
    ): List<ParsedToken> = analyse(text, today, locale, projectNames, sectionNames).second

    private fun analyse(
        text: String,
        today: LocalDate,
        locale: Locale,
        projectNames: List<String>,
        sectionNames: List<String>,
    ): Pair<ParsedTask, List<ParsedToken>> {
        val tokens = mutableListOf<ParsedToken>()
        val labels = mutableListOf<String>()
        var projectName: String? = null
        var sectionName: String? = null
        var priority: Priority? = null

        // 1. Sigil tokens.
        var i = 0
        while (i < text.length) {
            val c = text[i]
            val atWordStart = i == 0 || text[i - 1].isWhitespace()
            val after = i + 1
            if ((c == '@' || c == '#' || c == '/') && atWordStart && after < text.length && !text[after].isWhitespace()) {
                val known = when (c) {
                    '#' -> projectNames
                    '/' -> sectionNames
                    else -> emptyList()
                }
                val end: Int
                val value: String
                val m = longestKnownName(text, after, known)
                if (m != null) {
                    end = m.first; value = m.second
                } else {
                    var e = after
                    while (e < text.length && !text[e].isWhitespace()) e++
                    end = e; value = text.substring(after, e)
                }
                when (c) {
                    '@' -> {
                        tokens.add(ParsedToken(i, end, ParsedToken.Kind.LABEL))
                        if (labels.none { it.equals(value, ignoreCase = true) }) labels.add(value)
                    }
                    '#' -> { tokens.add(ParsedToken(i, end, ParsedToken.Kind.PROJECT)); projectName = value }
                    else -> { tokens.add(ParsedToken(i, end, ParsedToken.Kind.SECTION)); sectionName = value }
                }
                i = end
                continue
            }
            i = after
        }

        // 2. Words outside sigil tokens; priorities.
        val sigilRanges = tokens.toList()
        val words = DateWord.split(text)
        val free = words.map { w ->
            val consumed = sigilRanges.any { it.start < w.end && w.start < it.end }
            val p = if (!consumed && w.lower.length == 2 && w.lower[0] == 'p') {
                Priority.entries.firstOrNull { it.level.toString() == w.lower.substring(1) }
            } else null
            if (p != null) {
                tokens.add(ParsedToken(w.start, w.end, ParsedToken.Kind.PRIORITY))
                priority = p
                false
            } else {
                !consumed
            }
        }

        // 3. Date phrases within runs of consecutive free words; the last one wins.
        val runs = mutableListOf<List<DateWord>>()
        var current = mutableListOf<DateWord>()
        for ((w, isFree) in words.zip(free)) {
            if (isFree) current.add(w) else if (current.isNotEmpty()) { runs.add(current); current = mutableListOf() }
        }
        if (current.isNotEmpty()) runs.add(current)

        val ctx = DateParser.Context(today, DateParser.isDayFirst(locale))
        var chosen: Triple<Int, Int, DateParseResult>? = null
        for ((r, run) in runs.withIndex()) {
            var k = 0
            while (k < run.size) {
                val m = DateParser.match(run, k, ctx)
                if (m == null) { k++; continue }
                val connector = connectorStart(run, k)
                if (m.count == 1 && run[k].lower in DateParser.ambiguousSingleWords) {
                    val isLast = r == runs.size - 1 && k == run.size - 1
                    if (run[k].original != run[k].lower || !(isLast || connector != null)) { k++; continue }
                }
                val start = connector?.let { run[it].start } ?: run[k].start
                chosen = Triple(start, run[k + m.count - 1].end, m.result)
                k += m.count
            }
        }
        var due: LocalDate? = null
        var noDate = false
        chosen?.let { (start, end, result) ->
            tokens.add(ParsedToken(start, end, ParsedToken.Kind.DATE))
            when (result) {
                is DateParseResult.Date -> due = result.date
                DateParseResult.NoDate -> noDate = true
            }
        }

        tokens.sortBy { it.start }
        val task = ParsedTask(
            content = content(text, tokens), priority = priority, due = due, labels = labels,
            projectName = projectName, sectionName = sectionName, noDate = noDate,
        )
        return task to tokens
    }

    /** Index of a connector ("on", "by", "due", "due on", "due by") directly before `run[k]`. */
    private fun connectorStart(run: List<DateWord>, k: Int): Int? {
        if (k <= 0 || run[k - 1].hasTrailingPunct || run[k - 1].lower !in DateParser.connectors) return null
        if (run[k - 1].lower != "due" && k > 1 && run[k - 2].lower == "due" && !run[k - 2].hasTrailingPunct) return k - 2
        return k - 1
    }

    /** End index and canonical spelling of the longest of [names] at [start] that ends at whitespace or the end. */
    private fun longestKnownName(text: String, start: Int, names: List<String>): Pair<Int, String>? {
        var best: Pair<Int, String>? = null
        for (name in names) {
            if (name.isEmpty() || !text.regionMatches(start, name, 0, name.length, ignoreCase = true)) continue
            val end = start + name.length
            if (end != text.length && !text[end].isWhitespace()) continue
            if (best == null || end > best.first) best = end to name
        }
        return best
    }

    private val spaceBeforePunct = Regex(" +([,.;:!?])")
    private val leading = Regex("^[\\s,;:]+")
    private val trailing = Regex("[\\s,;:]+$")

    private fun content(text: String, tokens: List<ParsedToken>): String {
        val kept = StringBuilder()
        var cursor = 0
        for (t in tokens.sortedBy { it.start }) {
            if (t.start < cursor) continue
            kept.append(text, cursor, t.start).append(' ')
            cursor = t.end
        }
        kept.append(text, cursor, text.length)
        var s = DateWord.pieces(kept.toString()).joinToString(" ")
        // Punctuation left behind by a removed token: "Pay rent tomorrow." → "Pay rent."
        s = spaceBeforePunct.replace(s, "$1")
        s = leading.replace(s, "")
        s = trailing.replace(s, "")
        return s
    }
}
