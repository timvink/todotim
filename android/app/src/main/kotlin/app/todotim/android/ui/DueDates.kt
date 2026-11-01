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

/**
 * Due-date colours and date-picker helpers. Due dates are local calendar dates; their labels come from core
 * `DueDateFormatting` (shared with the Mac app).
 */
object DueDates {
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

    fun shortWeekday(date: LocalDate): String = date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.ENGLISH)

    /** "Mon 9 Nov". */
    fun shortDate(date: LocalDate): String = date.format(weekdayDate)

    /** Monday of next week, like Todoist's "Next week". */
    fun nextWeek(today: LocalDate): LocalDate = today.with(TemporalAdjusters.next(DayOfWeek.MONDAY))

    /** Material's date picker works in UTC midnight milliseconds. */
    fun toPickerMillis(date: LocalDate): Long = date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()

    fun fromPickerMillis(millis: Long): LocalDate = LocalDate.ofEpochDay(Math.floorDiv(millis, 86_400_000L))
}

@Composable
fun dueColor(due: LocalDate, today: LocalDate): Color = when (DueDates.kind(due, today)) {
    DueDates.Kind.Overdue -> todoColors.overdue
    DueDates.Kind.Today -> todoColors.today
    DueDates.Kind.Tomorrow -> todoColors.tomorrow
    DueDates.Kind.ThisWeek -> todoColors.thisWeek
    DueDates.Kind.Later -> todoColors.later
}
