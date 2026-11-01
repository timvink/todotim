package app.todotim.core.parsing

import java.time.LocalDate
import java.time.temporal.ChronoUnit

/**
 * Due-date labels (port of `DueDateFormatting.swift`; checked against `fixtures/dates.json`).
 * [today] is the user's local date (pass `LocalDate.now(zone)`).
 */
object DueDateFormatting {
    private val weekdayNames = listOf("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
    private val monthNames = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

    /** Whole days from [today] to [due] (negative = past). */
    fun daysFromToday(due: LocalDate, today: LocalDate): Long = ChronoUnit.DAYS.between(today, due)

    /**
     * Todoist-style label (English): "Today", "Tomorrow", "Yesterday", the weekday name
     * ("Monday") for 2–6 days ahead, otherwise "Nov 3", or "Nov 3 2027" when the year differs
     * from the current one.
     */
    fun displayString(due: LocalDate, today: LocalDate): String = when (val diff = daysFromToday(due, today)) {
        0L -> "Today"
        1L -> "Tomorrow"
        -1L -> "Yesterday"
        in 2L..6L -> weekdayNames[due.dayOfWeek.value - 1]
        else -> {
            val label = "${monthNames[due.monthValue - 1]} ${due.dayOfMonth}"
            if (due.year == today.year) label else "$label ${due.year}"
        }
    }

    /** True if [due] is before [today]. */
    fun isOverdue(due: LocalDate, today: LocalDate): Boolean = due.isBefore(today)
}
