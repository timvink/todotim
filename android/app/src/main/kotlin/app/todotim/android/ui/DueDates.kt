package app.todotim.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import app.todotim.android.ui.theme.todoColors
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters
import java.util.Locale

/** Todoist-style due-date wording and colours. Due dates are local calendar dates. */
object DueDates {
    private val sameYear = DateTimeFormatter.ofPattern("d MMM", Locale.ENGLISH)
    private val otherYear = DateTimeFormatter.ofPattern("d MMM yyyy", Locale.ENGLISH)
    private val weekdayDate = DateTimeFormatter.ofPattern("EEE d MMM", Locale.ENGLISH)

    enum class Kind { Overdue, Today, Tomorrow, ThisWeek, Later }

    fun kind(due: LocalDate, today: LocalDate): Kind {
        val days = ChronoUnit.DAYS.between(today, due)
        return when {
            days < 0 -> Kind.Overdue
            days == 0L -> Kind.Today
            days == 1L -> Kind.Tomorrow
            days < 7 -> Kind.ThisWeek
            else -> Kind.Later
        }
    }

    /** "Today", "Tomorrow", "Yesterday", "Friday" (within a week), "12 Nov", "12 Nov 2027". */
    fun label(due: LocalDate, today: LocalDate): String {
        val days = ChronoUnit.DAYS.between(today, due)
        return when {
            days == 0L -> "Today"
            days == 1L -> "Tomorrow"
            days == -1L -> "Yesterday"
            days in 2..6 -> weekday(due)
            due.year == today.year -> due.format(sameYear)
            else -> due.format(otherYear)
        }
    }

    fun weekday(date: LocalDate): String = date.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.ENGLISH)

    fun shortWeekday(date: LocalDate): String = date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.ENGLISH)

    /** "Mon 9 Nov". */
    fun shortDate(date: LocalDate): String = date.format(weekdayDate)

    /** Monday of next week, like Todoist's "Next week". */
    fun nextWeek(today: LocalDate): LocalDate = today.with(TemporalAdjusters.next(DayOfWeek.MONDAY))

    /** Material's date picker works in UTC midnight milliseconds. */
    fun toPickerMillis(date: LocalDate): Long = date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()

    fun fromPickerMillis(millis: Long): LocalDate = LocalDate.ofEpochDay(Math.floorDiv(millis, 86_400_000L))

    /** "every day", "every 2 weeks", … for the simple RRULEs; the raw rule otherwise. */
    fun describeRecurrence(rule: String): String {
        val parts = rule.split(';').mapNotNull { p -> p.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0].uppercase() to it[1] } }.toMap()
        val unit = when (parts["FREQ"]?.uppercase()) {
            "DAILY" -> "day"; "WEEKLY" -> "week"; "MONTHLY" -> "month"; "YEARLY" -> "year"; else -> return rule
        }
        if (parts.keys.any { it !in setOf("FREQ", "INTERVAL") }) return rule
        val n = parts["INTERVAL"]?.toIntOrNull() ?: 1
        return if (n <= 1) "every $unit" else "every $n ${unit}s"
    }
}

@Composable
fun dueColor(due: LocalDate, today: LocalDate): Color = when (DueDates.kind(due, today)) {
    DueDates.Kind.Overdue -> todoColors.overdue
    DueDates.Kind.Today -> todoColors.today
    DueDates.Kind.Tomorrow -> todoColors.tomorrow
    DueDates.Kind.ThisWeek -> todoColors.thisWeek
    DueDates.Kind.Later -> todoColors.later
}
