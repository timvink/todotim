package app.todotim.core

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.YearMonth
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * The subset of iCalendar RRULEs (RFC 5545 §3.3.10) TodoTim can advance: FREQ=DAILY, WEEKLY,
 * MONTHLY or YEARLY with INTERVAL, COUNT and UNTIL (WKST is ignored). Rules with any other
 * part (BYDAY, BYMONTHDAY, …) are kept as they are, but completing such a task completes it.
 *
 * Port of `Recurrence.swift`; both are checked against `fixtures/recurrence.json`.
 */
object Recurrence {
    /** The next due date and the rule to store with it. */
    data class Next(val due: LocalDate, val rule: String)

    private enum class Freq { DAILY, WEEKLY, MONTHLY, YEARLY }

    /**
     * The next due date after [due], and the rule to store with it (COUNT counts down, because
     * the series now starts one occurrence later). null when the rule is not supported or the
     * series has ended, so the task should be completed instead.
     *
     * Monthly and yearly steps keep the day of the month: a date that does not exist (the 31st,
     * February 29) is skipped, as RFC 5545 requires, rather than clamped (so not `plusMonths`).
     * A DATE UNTIL is compared with the date. A DATE-TIME UNTIL bounds the occurrence's start
     * time, which a date-only task does not know: TodoTim advances only while the next date is at
     * least two days before it (enough for any timezone offset) and otherwise completes the task.
     * [zone] is the user's timezone, used only to read a UTC (`Z`) UNTIL as a local date.
     */
    fun advance(rule: String, due: LocalDate, zone: ZoneId = ZoneId.systemDefault()): Next? {
        var freq: Freq? = null
        var interval = 1
        var count: Long? = null
        var lastDate: String? = null
        val parts = mutableListOf<String?>() // null: the COUNT placeholder
        for (part in rule.split(';')) {
            if (part.isEmpty()) continue
            val kv = splitOnce(part)?.map { trimSpaces(it) } ?: return null
            when (kv[0].uppercase()) {
                "FREQ" -> freq = when (kv[1].uppercase()) {
                    "DAILY" -> Freq.DAILY
                    "WEEKLY" -> Freq.WEEKLY
                    "MONTHLY" -> Freq.MONTHLY
                    "YEARLY" -> Freq.YEARLY
                    else -> return null
                }
                "INTERVAL" -> {
                    val n = parseInt(kv[1])
                    if (n == null || n !in 1L..1000L) return null
                    interval = n.toInt()
                }
                "COUNT" -> {
                    val n = parseInt(kv[1])
                    if (n == null || n < 0) return null
                    count = n
                    parts.add(null)
                    continue
                }
                "UNTIL" -> lastDate = untilDate(kv[1], zone) ?: return null
                "WKST" -> {}
                else -> return null
            }
            parts.add(part)
        }
        val f = freq ?: return null
        val next = nextDate(due, f, interval) ?: return null
        count?.let { if (it <= 1) return null }
        if (lastDate != null && format(next) > lastDate) return null
        val newRule = parts.joinToString(";") { it ?: "COUNT=${count!! - 1}" }
        return Next(next, newRule)
    }

    /**
     * The last date the series may advance to, as `yyyy-MM-dd` text (compared as text, like the
     * Swift code), or null when UNTIL is not a DATE or DATE-TIME.
     */
    private fun untilDate(raw: String, zone: ZoneId): String? {
        val v = trimSpaces(raw)
        if (v.length < 8 || !v.substring(0, 8).all { it in '0'..'9' }) return null
        val y = v.substring(0, 4).toInt()
        val m = v.substring(4, 6).toInt()
        val d = v.substring(6, 8).toInt()
        if (m !in 1..12 || d !in 1..31) return null
        if (v.length == 8) return "%04d-%02d-%02d".format(y, m, d) // DATE: as written
        val t = v.substring(8)
        val digits = t.drop(1).take(6)
        if (!t.startsWith("T") || digits.length != 6 || !digits.all { it in '0'..'9' }) return null
        if (!(t.length == 7 || (t.length == 8 && t.endsWith("Z")))) return null
        // Calendar arithmetic is lenient like Foundation's: Feb 31 is March 3 (or 2).
        val day: LocalDate = if (t.endsWith("Z")) {
            val h = digits.substring(0, 2).toLong()
            val mi = digits.substring(2, 4).toLong()
            val s = digits.substring(4, 6).toLong()
            val utc = LocalDateTime.of(lenientDate(y, m, d), java.time.LocalTime.MIDNIGHT)
                .plusHours(h).plusMinutes(mi).plusSeconds(s)
            utc.atOffset(ZoneOffset.UTC).atZoneSameInstant(zone).toLocalDate()
        } else {
            lenientDate(y, m, d) // floating time: the date as written
        }
        return format(day.minusDays(2))
    }

    private fun lenientDate(y: Int, m: Int, d: Int): LocalDate = LocalDate.of(y, m, 1).plusDays(d - 1L)

    /**
     * The next instance [interval] units after [due]; for months and years, the first one whose
     * day of the month exists (at most 100 steps, which covers February 29).
     */
    private fun nextDate(due: LocalDate, freq: Freq, interval: Int): LocalDate? = when (freq) {
        Freq.DAILY -> due.plusDays(interval.toLong())
        Freq.WEEKLY -> due.plusWeeks(interval.toLong())
        Freq.MONTHLY, Freq.YEARLY -> {
            val start = YearMonth.from(due)
            (1..100).firstNotNullOfOrNull { step ->
                val ym = if (freq == Freq.MONTHLY) start.plusMonths(interval.toLong() * step)
                else start.plusYears(interval.toLong() * step)
                if (ym.isValidDay(due.dayOfMonth)) ym.atDay(due.dayOfMonth) else null
            }
        }
    }

    /**
     * Short description for the UI, e.g. "Every week" or "Every 2 months"; "Repeats" for rules
     * [advance] does not understand.
     */
    fun summary(rule: String): String {
        var freq: String? = null
        var interval = 1L
        var other = false
        for (part in rule.split(';')) {
            if (part.isEmpty()) continue
            val kv = splitOnce(part)?.map { it.uppercase() } ?: continue
            when (kv[0]) {
                "FREQ" -> freq = kv[1]
                "INTERVAL" -> interval = parseInt(kv[1]) ?: 1
                "COUNT", "UNTIL", "WKST" -> {}
                else -> other = true
            }
        }
        val unit = when (freq) {
            "DAILY" -> "day"
            "WEEKLY" -> "week"
            "MONTHLY" -> "month"
            "YEARLY" -> "year"
            else -> return "Repeats"
        }
        if (other) return "Repeats"
        return if (interval == 1L) "Every $unit" else "Every $interval ${unit}s"
    }

    private fun format(d: LocalDate) = "%04d-%02d-%02d".format(d.year, d.monthValue, d.dayOfMonth)

    /**
     * `part.split(separator: "=", maxSplits: 1)` in Swift: empty pieces are dropped, so "FREQ="
     * and "=DAILY" are one piece (null here) and "A==B" is ["A", "=B"].
     */
    private fun splitOnce(part: String): List<String>? {
        val s = part.trimStart('=')
        val i = s.indexOf('=')
        if (i < 0 || i == s.length - 1) return null
        return listOf(s.substring(0, i), s.substring(i + 1))
    }

    /** Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not newlines. */
    private fun trimSpaces(s: String) = s.trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }

    /** Swift's `Int(_:)`: an optional sign and ASCII digits only. */
    private fun parseInt(s: String): Long? {
        val body = if (s.startsWith("+") || s.startsWith("-")) s.substring(1) else s
        if (body.isEmpty() || !body.all { it in '0'..'9' }) return null
        return s.toLongOrNull()
    }
}
