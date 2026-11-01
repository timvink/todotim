package app.todotim.core.parsing

import java.time.DateTimeException
import java.time.LocalDate
import java.time.chrono.IsoChronology
import java.time.format.DateTimeFormatterBuilder
import java.time.format.FormatStyle
import java.util.Locale

/** Outcome of recognising a date phrase. */
sealed interface DateParseResult {
    /** A concrete calendar date. */
    data class Date(val date: LocalDate) : DateParseResult

    /** The phrase "no date" / "no due date": the user explicitly asked for no due date. */
    data object NoDate : DateParseResult

    val dueDate: LocalDate? get() = (this as? Date)?.date
}

/**
 * English, date-only natural-language date grammar modelled on Todoist quick add (port of
 * `DateParser.swift`; both are checked against `fixtures/dates.json`).
 *
 * Recognised phrases (case-insensitive, whole words only):
 * - `today`/`tod`, `tomorrow`/`tom`/`tmr`/`tmrw`, `yesterday`, `overmorrow`, `day after tomorrow`
 * - weekday names and abbreviations (`mon`, `monday`, `tue`, `tues`, ...): the next occurrence,
 *   where today counts ("monday" on a Monday is today). `this friday` is the same.
 * - `next week` = Monday of next week; `next <weekday>` = that weekday in next week (weeks start
 *   on Monday); `weekend`/`this weekend` = the upcoming Saturday (today on a Saturday or Sunday);
 *   `next weekend` = Saturday of next week; `next month` = the 1st of next month; `next year` =
 *   January 1st of next year.
 * - `in 3 days`, `in 2 weeks`, `in a month`, `in one year` (number words one–twelve, a/an).
 *   Months and years clamp to the end of a shorter month (Jan 31 + 1 month = Feb 28).
 * - `jan 5`, `january 5th`, `5 jan`, `5th of january`, optionally followed by a 4-digit year
 *   (`jan 5 2027`, `jan 5, 2027`). Without a year, a date before today rolls over to next year.
 * - `5/1` and `5/1/2027` (or `/27`): day/month order follows [locale] (see [isDayFirst]).
 *   Without a year, a date before today rolls over to next year.
 * - ISO `2026-11-03`.
 * - `no date`, `no due date` → [DateParseResult.NoDate].
 *
 * A bare month name ("may") or a bare number ("5") is never a date. [today] is the user's local
 * date (pass `LocalDate.now(zone)`).
 */
object DateParser {
    /**
     * Parses [text] as a whole date phrase (for a "set due date" field). Returns null when the
     * text is not entirely a date phrase, and also for "no date" (use [parsePhrase] to see that).
     * A leading "on", "by" or "due" is allowed ("on friday").
     */
    fun parse(text: String, today: LocalDate, locale: Locale = Locale.getDefault()): LocalDate? =
        parsePhrase(text, today, locale)?.dueDate

    /** Like [parse], but distinguishes "no date" from unparseable text (null). */
    fun parsePhrase(text: String, today: LocalDate, locale: Locale = Locale.getDefault()): DateParseResult? {
        var words = DateWord.split(text)
        if (words.isEmpty()) return null
        if (words.size > 1 && words[0].lower == "due") words = words.drop(1)
        if (words.size > 1 && (words[0].lower == "on" || words[0].lower == "by")) words = words.drop(1)
        val m = match(words, 0, Context(today, isDayFirst(locale))) ?: return null
        return if (m.count == words.size) m.result else null
    }

    /** True when [locale] writes numeric dates day-first ("5/1" = 5 January): en_GB, nl_NL; not en_US. */
    fun isDayFirst(locale: Locale): Boolean {
        val pattern = try {
            DateTimeFormatterBuilder.getLocalizedDateTimePattern(FormatStyle.SHORT, null, IsoChronology.INSTANCE, locale)
        } catch (_: Exception) {
            return false
        }
        val d = pattern.indexOf('d')
        val m = pattern.indexOf('M')
        return d >= 0 && m >= 0 && d < m
    }

    // Internal grammar (shared with QuickAddParser)

    /** Words that may introduce a date phrase in quick add and are removed with it. */
    internal val connectors = setOf("on", "by", "due")

    /**
     * Single-word phrases that are also common English words or names. In quick add they only
     * count as a date when typed in lowercase and either at the end of the line or introduced by
     * "on"/"by"/"due" ("call tom" → tomorrow, "Call Tom" → no date, "buy sun cream" → no date).
     */
    internal val ambiguousSingleWords = setOf("tom", "tod", "sat", "sun", "wed", "weekend")

    internal class Context(val today: LocalDate, val dayFirst: Boolean)

    internal class Match(val count: Int, val result: DateParseResult)

    /**
     * Longest date phrase starting at `words[start]`. Phrases never extend across a word with
     * trailing punctuation, except a comma before a year ("jan 5, 2027"). Among phrases of the
     * same length the first one considered wins.
     */
    internal fun match(words: List<DateWord>, start: Int, ctx: Context): Match? {
        fun lw(k: Int): String? {
            val j = start + k
            if (j >= words.size) return null
            if (k > 0 && words[j - 1].hasTrailingPunct) return null
            return words[j].lower
        }
        /** Like lw, but allows the previous word to end in a comma (for "jan 5, 2027"). */
        fun lwAfterComma(k: Int): String? {
            val j = start + k
            if (j >= words.size || k <= 0) return null
            val prev = words[j - 1]
            if (prev.hasTrailingPunct && prev.trailingPunct != ',') return null
            return words[j].lower
        }

        val w0 = lw(0)
        if (w0.isNullOrEmpty()) return null
        val today = ctx.today
        var best: Match? = null
        fun consider(count: Int, result: DateParseResult) {
            if (best == null || count > best!!.count) best = Match(count, result)
        }
        fun consider(count: Int, date: LocalDate?) {
            if (date != null) consider(count, DateParseResult.Date(date))
        }
        fun addDays(n: Int, to: LocalDate = today): LocalDate = to.plusDays(n.toLong())
        val todayWeekday = swiftWeekday(today) // 1 = Sunday ... 7 = Saturday
        fun upcoming(weekday: Int) = addDays((weekday - todayWeekday + 7) % 7)
        fun mondayOfNextWeek(): LocalDate {
            var d = (2 - todayWeekday + 7) % 7
            if (d == 0) d = 7
            return addDays(d)
        }
        fun upcomingWeekend() = if (todayWeekday == 1) today else upcoming(7)

        // no date
        if (w0 == "no") {
            if (lw(1) == "date") consider(2, DateParseResult.NoDate)
            if (lw(1) == "due" && lw(2) == "date") consider(3, DateParseResult.NoDate)
        }

        when (w0) {
            "today", "tod" -> consider(1, today)
            "tomorrow", "tom", "tmr", "tmrw" -> consider(1, addDays(1))
            "yesterday" -> consider(1, addDays(-1))
            "overmorrow" -> consider(1, addDays(2))
            "weekend" -> consider(1, upcomingWeekend())
        }
        if (w0 == "day" && lw(1) == "after" && lw(2) == "tomorrow") consider(3, addDays(2))

        weekdays[w0]?.let { consider(1, upcoming(it)) }

        if (w0 == "this") {
            lw(1)?.let { w1 ->
                weekdays[w1]?.let { consider(2, upcoming(it)) }
                if (w1 == "weekend") consider(2, upcomingWeekend())
            }
        }

        if (w0 == "next") {
            lw(1)?.let { w1 ->
                weekdays[w1]?.let { consider(2, addDays((it - 2 + 7) % 7, mondayOfNextWeek())) }
                when (w1) {
                    "week" -> consider(2, mondayOfNextWeek())
                    "weekend" -> consider(2, addDays(5, mondayOfNextWeek()))
                    "month" -> consider(2, today.withDayOfMonth(1).plusMonths(1))
                    "year" -> consider(2, makeDate(today.year + 1, 1, 1))
                }
            }
        }

        if (w0 == "in") {
            val n = lw(1)?.let(::count)
            val unit = lw(2)?.let(::unit)
            if (n != null && unit != null) {
                // plusMonths/plusYears clamp (Jan 31 + 1 month = Feb 28), as Foundation does.
                when (unit) {
                    Unit.DAY -> consider(3, addDays(n))
                    Unit.WEEK -> consider(3, addDays(7 * n))
                    Unit.MONTH -> consider(3, today.plusMonths(n.toLong()))
                    Unit.YEAR -> consider(3, today.plusYears(n.toLong()))
                }
            }
        }

        // month day [year]
        val m0 = months[w0]
        val d1 = lw(1)?.let(::dayNumber)
        if (m0 != null && d1 != null) {
            lwAfterComma(2)?.let(::year)?.let { consider(3, makeDate(it, m0, d1)) }
            consider(2, futureDate(m0, d1, today))
        }
        // day month [year], day "of" month [year]
        dayNumber(w0)?.let { d ->
            val k = if (lw(1) == "of") 2 else 1
            lw(k)?.let { months[it] }?.let { m ->
                lwAfterComma(k + 1)?.let(::year)?.let { consider(k + 2, makeDate(it, m, d)) }
                consider(k + 1, futureDate(m, d, today))
            }
        }

        // ISO yyyy-mm-dd
        numericParts(w0, '-')?.let { p ->
            if (p.size == 3 && p[0].digits == 4) consider(1, makeDate(p[0].value, p[1].value, p[2].value))
        }
        // d/m or m/d, optional year
        numericParts(w0, '/')?.let { p ->
            if ((p.size == 2 || p.size == 3) && p[0].digits <= 2 && p[1].digits <= 2) {
                val m = if (ctx.dayFirst) p[1].value else p[0].value
                val d = if (ctx.dayFirst) p[0].value else p[1].value
                if (p.size == 3) {
                    val y = when (p[2].digits) {
                        4 -> p[2].value
                        2 -> 2000 + p[2].value
                        else -> null
                    }
                    if (y != null) consider(1, makeDate(y, m, d))
                } else {
                    consider(1, futureDate(m, d, today))
                }
            }
        }

        return best
    }

    /** Foundation's weekday numbering: 1 = Sunday ... 7 = Saturday. */
    private fun swiftWeekday(d: LocalDate) = d.dayOfWeek.value % 7 + 1

    // Vocabulary

    private val weekdays = mapOf(
        "sun" to 1, "sunday" to 1,
        "mon" to 2, "monday" to 2,
        "tue" to 3, "tues" to 3, "tuesday" to 3,
        "wed" to 4, "weds" to 4, "wednesday" to 4,
        "thu" to 5, "thur" to 5, "thurs" to 5, "thursday" to 5,
        "fri" to 6, "friday" to 6,
        "sat" to 7, "saturday" to 7,
    )

    private val months = mapOf(
        "jan" to 1, "january" to 1, "feb" to 2, "february" to 2, "mar" to 3, "march" to 3,
        "apr" to 4, "april" to 4, "may" to 5, "jun" to 6, "june" to 6, "jul" to 7, "july" to 7,
        "aug" to 8, "august" to 8, "sep" to 9, "sept" to 9, "september" to 9, "oct" to 10, "october" to 10,
        "nov" to 11, "november" to 11, "dec" to 12, "december" to 12,
    )

    private val numberWords = mapOf(
        "a" to 1, "an" to 1, "one" to 1, "two" to 2, "three" to 3, "four" to 4, "five" to 5, "six" to 6,
        "seven" to 7, "eight" to 8, "nine" to 9, "ten" to 10, "eleven" to 11, "twelve" to 12,
    )

    private enum class Unit { DAY, WEEK, MONTH, YEAR }

    private fun isDigits(s: String) = s.isNotEmpty() && s.all { it in '0'..'9' }

    private fun count(w: String): Int? {
        numberWords[w]?.let { return it }
        if (w.length > 4 || !isDigits(w)) return null
        val n = w.toInt()
        return if (n > 0) n else null
    }

    private fun unit(w: String): Unit? = when (w) {
        "day", "days" -> Unit.DAY
        "week", "weeks", "wk", "wks" -> Unit.WEEK
        "month", "months" -> Unit.MONTH
        "year", "years", "yr", "yrs" -> Unit.YEAR
        else -> null
    }

    /** "5", "5th", "1st", "22nd", "3rd" → 1...31. */
    private fun dayNumber(w: String): Int? {
        var s = w
        for (suffix in listOf("st", "nd", "rd", "th")) {
            if (s.endsWith(suffix)) {
                s = s.dropLast(2)
                break
            }
        }
        if (s.length !in 1..2 || !isDigits(s)) return null
        return s.toInt().takeIf { it in 1..31 }
    }

    private fun year(w: String): Int? {
        if (w.length != 4 || !isDigits(w)) return null
        return w.toInt().takeIf { it in 1900..2999 }
    }

    private class NumericPart(val value: Int, val digits: Int)

    private fun numericParts(w: String, separator: Char): List<NumericPart>? {
        val parts = w.split(separator)
        if (parts.size < 2) return null
        return parts.map { p ->
            if (p.length > 4 || !isDigits(p)) return null
            NumericPart(p.toInt(), p.length)
        }
    }

    /** Valid date only (no rollover: "feb 30" is null). Year 0 does not exist in Foundation's calendar. */
    private fun makeDate(year: Int, month: Int, day: Int): LocalDate? {
        if (year < 1 || month !in 1..12 || day !in 1..31) return null
        return try {
            LocalDate.of(year, month, day)
        } catch (_: DateTimeException) {
            null
        }
    }

    /** This year's month/day, or next year's when that is before today (Feb 29: the next leap year). */
    private fun futureDate(month: Int, day: Int, today: LocalDate): LocalDate? {
        makeDate(today.year, month, day)?.let { if (!it.isBefore(today)) return it }
        for (offset in 1..4) makeDate(today.year + offset, month, day)?.let { return it }
        return null
    }
}

/** A whitespace-separated word, with trailing punctuation split off for matching. */
internal class DateWord(
    /** Start of the word in the text (UTF-16 index). */
    val start: Int,
    /** End of the word without trailing punctuation (exclusive). */
    val end: Int,
    val original: String,
    val lower: String,
    /** Trailing punctuation that was removed (",", "." ...), or null. */
    val trailingPunct: Char?,
) {
    val hasTrailingPunct: Boolean get() = trailingPunct != null

    companion object {
        private val punctuation = setOf(',', '.', ';', ':', '!', '?', ')')

        fun split(text: String): List<DateWord> = pieceRanges(text).map { make(text, it.first, it.last + 1) }

        /** The whitespace-separated pieces of [text] (Swift's `split(whereSeparator: \.isWhitespace)`). */
        fun pieces(text: String): List<String> = pieceRanges(text).map { text.substring(it) }

        private fun pieceRanges(text: String): List<IntRange> {
            val out = mutableListOf<IntRange>()
            var i = 0
            while (i < text.length) {
                if (text[i].isWhitespace()) { i++; continue }
                var j = i
                while (j < text.length && !text[j].isWhitespace()) j++
                out.add(i until j)
                i = j
            }
            return out
        }

        private fun make(text: String, start: Int, wordEnd: Int): DateWord {
            var end = wordEnd
            while (end > start && text[end - 1] in punctuation) end--
            if (end == start) { // all punctuation: keep as an unmatched word
                return DateWord(start, wordEnd, text.substring(start, wordEnd), "", null)
            }
            val core = text.substring(start, end)
            // Report the first removed punctuation character (the one adjacent to the word).
            val first = if (end < wordEnd) text[end] else null
            return DateWord(start, end, core, core.lowercase(), first)
        }
    }
}
