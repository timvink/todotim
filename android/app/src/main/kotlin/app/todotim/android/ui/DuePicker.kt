package app.todotim.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.todotim.android.R
import app.todotim.core.parsing.DueDateFormatting
import app.todotim.android.ui.theme.todoColors
import java.time.LocalDate

/**
 * Bottom sheet with Todoist's quick choices (Today, Tomorrow, Next week, No date) and "Pick date…".
 * [onPick] gets the new due date (null = no date); the sheet then closes via [onDismiss].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RescheduleSheet(current: LocalDate?, today: LocalDate, onPick: (LocalDate?) -> Unit, onDismiss: () -> Unit) {
    var picking by remember { mutableStateOf(false) }
    if (picking) {
        DueDatePickerDialog(current ?: today, onPick = { onPick(it); onDismiss() }, onDismiss = onDismiss)
        return
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(bottom = 16.dp)) {
            Text(
                current?.let { DueDateFormatting.displayString(it, today) } ?: "No date",
                fontWeight = FontWeight.Bold,
                fontSize = 16.sp,
                color = current?.let { dueColor(it, today) } ?: MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            )
            HorizontalDivider(color = todoColors.divider)
            val tomorrow = today.plusDays(1)
            val nextWeek = DueDates.nextWeek(today)
            Choice(painterIcon = R.drawable.ic_calendar, tint = todoColors.today, title = "Today", trailing = DueDates.shortWeekday(today)) { onPick(today); onDismiss() }
            Choice(painterIcon = R.drawable.ic_calendar, tint = todoColors.tomorrow, title = "Tomorrow", trailing = DueDates.shortWeekday(tomorrow)) { onPick(tomorrow); onDismiss() }
            Choice(painterIcon = R.drawable.ic_calendar, tint = todoColors.thisWeek, title = "Next week", trailing = DueDates.shortDate(nextWeek)) { onPick(nextWeek); onDismiss() }
            Choice(vectorIcon = Icons.Filled.Clear, tint = todoColors.secondaryText, title = "No date") { onPick(null); onDismiss() }
            Choice(vectorIcon = Icons.Filled.DateRange, tint = todoColors.secondaryText, title = "Pick date…") { picking = true }
        }
    }
}

@Composable
private fun Choice(
    title: String,
    tint: Color,
    painterIcon: Int? = null,
    vectorIcon: ImageVector? = null,
    trailing: String? = null,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            painterIcon != null -> Icon(painterResource(painterIcon), null, Modifier.size(20.dp), tint = tint)
            vectorIcon != null -> Icon(vectorIcon, null, Modifier.size(20.dp), tint = tint)
        }
        Spacer(Modifier.width(16.dp))
        Text(title, fontSize = 16.sp, modifier = Modifier.weight(1f))
        trailing?.let { Text(it, color = todoColors.secondaryText, fontSize = 14.sp) }
    }
}

/** Material date picker for a local due date. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DueDatePickerDialog(initial: LocalDate, onPick: (LocalDate) -> Unit, onDismiss: () -> Unit) {
    val state = rememberDatePickerState(initialSelectedDateMillis = DueDates.toPickerMillis(initial))
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                onClick = { state.selectedDateMillis?.let { onPick(DueDates.fromPickerMillis(it)) } ?: onDismiss() },
            ) { Text("OK") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    ) {
        DatePicker(state = state)
    }
}
