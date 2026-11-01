package app.todotim.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.todotim.android.R
import app.todotim.core.parsing.DueDateFormatting
import app.todotim.android.ui.theme.TodoTimTheme
import app.todotim.android.ui.theme.todoColors
import app.todotim.core.Priority
import app.todotim.core.Project
import kotlinx.coroutines.launch
import java.time.LocalDate

/** Callbacks a task row needs; one instance per list. */
data class TaskRowActions(
    val onToggle: (ListItem.TaskItem) -> Unit,
    val onOpen: (ListItem.TaskItem) -> Unit,
    val onToggleCollapsed: (ListItem.TaskItem) -> Unit,
    val onReschedule: (ListItem.TaskItem) -> Unit,
)

/** Round checkbox: ring in the priority colour, lightly filled for p1–p3; filled with a check when done. */
@Composable
fun PriorityCheckbox(priority: Priority, completed: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, size: Dp = 22.dp) {
    val color = todoColors.priority(priority)
    val fill = when {
        completed -> color
        priority == Priority.P4 -> Color.Transparent
        else -> color.copy(alpha = 0.12f)
    }
    Box(
        modifier
            .size(40.dp)
            .clip(CircleShape)
            .clickable(role = Role.Checkbox, onClickLabel = if (completed) "Reopen task" else "Complete task", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(size).clip(CircleShape).background(fill).border(1.5.dp, color, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (completed) Icon(Icons.Filled.Check, null, Modifier.size(size * 0.65f), tint = Color.White)
        }
    }
}

/** A task row with swipe right = complete and swipe left = reschedule. */
@Composable
fun SwipeableTaskRow(item: ListItem.TaskItem, today: LocalDate, actions: TaskRowActions, labelColor: (String) -> Color) {
    val scope = rememberCoroutineScope()
    val state = rememberSwipeToDismissBoxState()
    SwipeToDismissBox(
        state = state,
        backgroundContent = { SwipeBackground(state.dismissDirection) },
        onDismiss = { value ->
            when (value) {
                SwipeToDismissBoxValue.StartToEnd -> actions.onToggle(item)
                SwipeToDismissBoxValue.EndToStart -> actions.onReschedule(item)
                SwipeToDismissBoxValue.Settled -> Unit
            }
            scope.launch { state.reset() }
        },
    ) {
        TaskRow(item, today, actions, labelColor)
    }
}

@Composable
private fun SwipeBackground(direction: SwipeToDismissBoxValue) {
    val (color, alignment) = when (direction) {
        SwipeToDismissBoxValue.StartToEnd -> todoColors.today to Alignment.CenterStart
        SwipeToDismissBoxValue.EndToStart -> todoColors.thisWeek to Alignment.CenterEnd
        SwipeToDismissBoxValue.Settled -> Color.Transparent to Alignment.Center
    }
    Box(Modifier.fillMaxSize().background(color).padding(horizontal = 24.dp), contentAlignment = alignment) {
        when (direction) {
            SwipeToDismissBoxValue.StartToEnd -> Icon(Icons.Filled.Check, "Complete", tint = Color.White)
            SwipeToDismissBoxValue.EndToStart -> Icon(painterResource(R.drawable.ic_calendar), "Reschedule", tint = Color.White)
            SwipeToDismissBoxValue.Settled -> Unit
        }
    }
}

@Composable
fun TaskRow(item: ListItem.TaskItem, today: LocalDate, actions: TaskRowActions, labelColor: (String) -> Color) {
    val task = item.task
    Column(Modifier.background(MaterialTheme.colorScheme.surface)) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { actions.onOpen(item) }
                .padding(start = 6.dp + 28.dp * item.depth, end = 4.dp, top = 6.dp, bottom = 8.dp),
            verticalAlignment = Alignment.Top,
        ) {
            PriorityCheckbox(task.priority, task.isCompleted, onClick = { actions.onToggle(item) })
            Column(Modifier.weight(1f).padding(top = 9.dp, start = 4.dp, end = 8.dp)) {
                Text(
                    task.content,
                    style = MaterialTheme.typography.bodyLarge.copy(fontSize = 16.sp),
                    color = if (task.isCompleted) todoColors.secondaryText else MaterialTheme.colorScheme.onSurface,
                    textDecoration = if (task.isCompleted) TextDecoration.LineThrough else null,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                if (task.description.isNotBlank()) {
                    Text(
                        task.description.lineSequence().first(),
                        style = MaterialTheme.typography.bodySmall,
                        color = todoColors.secondaryText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
                MetaLine(item, today, labelColor)
            }
            if (item.hasSubtasks) {
                IconButton(onClick = { actions.onToggleCollapsed(item) }, modifier = Modifier.size(40.dp)) {
                    Icon(
                        if (task.collapsed) Icons.AutoMirrored.Filled.KeyboardArrowRight else Icons.Filled.KeyboardArrowDown,
                        contentDescription = if (task.collapsed) "Expand subtasks" else "Collapse subtasks",
                        tint = todoColors.secondaryText,
                    )
                }
            }
        }
        HorizontalDivider(Modifier.padding(start = 16.dp + 28.dp * item.depth), color = todoColors.divider)
    }
}

/** Second line: due date, repeat, subtask count, labels; the project on the right. */
@Composable
private fun MetaLine(item: ListItem.TaskItem, today: LocalDate, labelColor: (String) -> Color) {
    val task = item.task
    val hasChips = task.due != null || task.recurrence != null || item.hasSubtasks || task.labels.isNotEmpty()
    if (!hasChips && item.project == null) return
    Row(
        Modifier.fillMaxWidth().padding(top = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            Modifier.weight(1f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            task.due?.let { due ->
                val color = dueColor(due, today)
                Chip(R.drawable.ic_calendar, DueDateFormatting.displayString(due, today), color)
                if (task.recurrence != null) Icon(painterResource(R.drawable.ic_repeat), "Repeats", Modifier.size(14.dp), tint = color)
            }
            if (task.due == null && task.recurrence != null) {
                Icon(painterResource(R.drawable.ic_repeat), "Repeats", Modifier.size(14.dp), tint = todoColors.secondaryText)
            }
            if (item.hasSubtasks) {
                Chip(R.drawable.ic_subtasks, "${item.completedSubtaskCount}/${item.subtaskCount}", todoColors.secondaryText)
            }
            task.labels.take(3).forEach { Chip(R.drawable.ic_label, it, labelColor(it)) }
        }
        item.project?.let { ProjectTag(it) }
    }
}

@Composable
private fun Chip(icon: Int, text: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(painterResource(icon), null, Modifier.size(14.dp), tint = color)
        Spacer(Modifier.width(3.dp))
        Text(text, color = color, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** "Work #" with the `#` in the project colour (inbox: the inbox icon). */
@Composable
fun ProjectTag(project: Project) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(project.name, color = todoColors.secondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.width(4.dp))
        if (project.isInbox) {
            Icon(painterResource(R.drawable.ic_inbox), null, Modifier.size(13.dp), tint = todoColors.p3)
        } else {
            Text("#", color = paletteColor(project.color), fontSize = 14.sp, fontWeight = FontWeight.Medium)
        }
    }
}

/** Bold group header (section, or project in search results). */
@Composable
fun GroupHeader(header: ListItem.Header) {
    Column {
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 24.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            header.project?.let {
                Text("#", color = paletteColor(it.color), fontWeight = FontWeight.Bold, fontSize = 16.sp)
                Spacer(Modifier.width(6.dp))
            }
            Text(header.title, fontWeight = FontWeight.Bold, fontSize = 16.sp, modifier = Modifier.weight(1f, fill = false))
            if (header.count > 0) {
                Spacer(Modifier.width(8.dp))
                Text("${header.count}", color = todoColors.secondaryText, fontSize = 13.sp)
            }
        }
        HorizontalDivider(Modifier.padding(horizontal = 16.dp), color = todoColors.divider)
    }
}

private val previewActions = TaskRowActions({}, {}, {}, {})

@Preview(showBackground = true)
@Composable
private fun TaskRowsPreview() {
    TodoTimTheme(darkTheme = false) {
        val s = PreviewData.snapshot(LocalDate.of(2026, 11, 2))
        Column {
            TaskLists.label(s, "calls").filterIsInstance<ListItem.TaskItem>().forEach {
                TaskRow(it, LocalDate.of(2026, 11, 2), previewActions) { name -> paletteColor(s.labels.firstOrNull { it.name == name }?.color ?: "charcoal") }
            }
        }
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF1E1E1E)
@Composable
private fun TaskRowsDarkPreview() {
    TodoTimTheme(darkTheme = true) {
        val s = PreviewData.snapshot(LocalDate.of(2026, 11, 2))
        Column {
            TaskLists.project(s, "inbox", showCompleted = true).take(6).forEach {
                when (it) {
                    is ListItem.Header -> GroupHeader(it)
                    is ListItem.TaskItem -> TaskRow(it, LocalDate.of(2026, 11, 2), previewActions) { Color.Gray }
                }
            }
        }
    }
}
