package app.todotim.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.todotim.android.R
import app.todotim.android.data.edit
import app.todotim.core.Recurrence
import app.todotim.core.parsing.DueDateFormatting
import app.todotim.core.store.Snapshot
import app.todotim.core.store.TodoStore
import app.todotim.android.ui.theme.todoColors
import app.todotim.core.EntityID
import app.todotim.core.TodoTask
import java.time.LocalDate

/**
 * Edits one task: title, description, due date, priority, labels, project/section, subtasks, delete.
 * Edits are saved as they are made. [onComplete] toggles completion (the caller offers undo).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskDetailSheet(
    taskId: EntityID,
    snapshot: Snapshot,
    store: TodoStore,
    today: LocalDate,
    onComplete: (TodoTask) -> Unit,
    onOpenTask: (EntityID) -> Unit,
    onDismiss: () -> Unit,
) {
    val task = snapshot.task(taskId) ?: return
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            LocationRow(task, snapshot, store, onOpenTask)
            TitleAndDescription(task, store, onComplete)
            HorizontalDivider(color = todoColors.divider, modifier = Modifier.padding(vertical = 8.dp))
            Properties(task, snapshot, store, today)
            HorizontalDivider(color = todoColors.divider, modifier = Modifier.padding(vertical = 8.dp))
            Subtasks(task, snapshot, store, onComplete, onOpenTask)
            HorizontalDivider(color = todoColors.divider, modifier = Modifier.padding(vertical = 8.dp))
            DeleteRow(task) { store.delete(task.id); onDismiss() }
        }
    }
}

/** "# Work / Planning ▾" (moves the task), and the parent of a subtask. */
@Composable
private fun LocationRow(task: TodoTask, snapshot: Snapshot, store: TodoStore, onOpenTask: (EntityID) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val project = snapshot.project(task.projectId)
    val section = task.sectionId?.let { sid -> snapshot.sections(task.projectId).firstOrNull { it.id == sid } }
    Column(Modifier.padding(horizontal = 16.dp)) {
        Box {
            Row(
                Modifier.clickable { menu = true }.padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (project?.isInbox == true) {
                    Icon(painterResource(R.drawable.ic_inbox), null, Modifier.size(16.dp), tint = todoColors.p3)
                } else {
                    Text("#", color = paletteColor(project?.color ?: "charcoal"), fontWeight = FontWeight.Bold)
                }
                Spacer(Modifier.width(6.dp))
                Text(
                    listOfNotNull(project?.name, section?.name).joinToString(" / "),
                    color = todoColors.secondaryText,
                    fontSize = 14.sp,
                )
                Icon(Icons.Filled.ArrowDropDown, "Move", tint = todoColors.secondaryText)
            }
            ProjectSectionMenu(
                expanded = menu, snapshot = snapshot, currentProject = task.projectId,
                currentSection = task.sectionId.takeIf { task.parentId == null },
                onPick = { p, s -> store.moveTask(task.id, p, s) },
                onDismiss = { menu = false },
            )
        }
        task.parentId?.let { snapshot.task(it) }?.let { parent ->
            Row(
                Modifier.clickable { onOpenTask(parent.id) }.padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(painterResource(R.drawable.ic_subtasks), null, Modifier.size(14.dp), tint = todoColors.secondaryText)
                Spacer(Modifier.width(6.dp))
                Text("Subtask of ${parent.content}", color = todoColors.secondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun TitleAndDescription(task: TodoTask, store: TodoStore, onComplete: (TodoTask) -> Unit) {
    var title by remember(task.id) { mutableStateOf(task.content) }
    var description by remember(task.id) { mutableStateOf(task.description) }
    val textColor = MaterialTheme.colorScheme.onSurface
    Row(Modifier.padding(start = 4.dp, end = 16.dp), verticalAlignment = Alignment.Top) {
        PriorityCheckbox(task.priority, task.isCompleted, onClick = { onComplete(task) }, size = 24.dp)
        Column(Modifier.weight(1f).padding(top = 8.dp, start = 4.dp)) {
            BasicTextField(
                value = title,
                onValueChange = { v ->
                    title = v.replace("\n", " ")
                    if (title.isNotBlank()) store.edit(task.id) { it.copy(content = title.trim()) }
                },
                textStyle = TextStyle(
                    fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = textColor,
                    textDecoration = if (task.isCompleted) TextDecoration.LineThrough else null,
                ),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                modifier = Modifier.fillMaxWidth(),
            )
            BasicTextField(
                value = description,
                onValueChange = { v -> description = v; store.edit(task.id) { it.copy(description = v) } },
                textStyle = TextStyle(fontSize = 15.sp, color = textColor),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                decorationBox = { inner ->
                    if (description.isEmpty()) Text("Description", color = todoColors.secondaryText, fontSize = 15.sp)
                    inner()
                },
            )
        }
    }
}

@Composable
private fun Properties(task: TodoTask, snapshot: Snapshot, store: TodoStore, today: LocalDate) {
    var reschedule by remember { mutableStateOf(false) }
    var priorityMenu by remember { mutableStateOf(false) }
    var labelsDialog by remember { mutableStateOf(false) }

    val dueTint = task.due?.let { dueColor(it, today) } ?: todoColors.secondaryText
    PropertyRow(
        icon = painterResource(R.drawable.ic_calendar), tint = dueTint,
        text = task.due?.let { DueDateFormatting.displayString(it, today) } ?: "Date",
        textColor = task.due?.let { dueTint },
        onClear = task.due?.let { { store.edit(task.id) { it.copy(due = null) } } },
        onClick = { reschedule = true },
    )
    task.recurrence?.let { rule ->
        PropertyRow(
            icon = painterResource(R.drawable.ic_repeat), tint = todoColors.secondaryText,
            text = Recurrence.summary(rule),
            onClear = { store.edit(task.id) { it.copy(recurrence = null) } },
            onClick = {},
        )
    }
    Box {
        PropertyRow(
            icon = painterResource(R.drawable.ic_flag), tint = todoColors.priority(task.priority),
            text = priorityName(task.priority),
            onClick = { priorityMenu = true },
        )
        PriorityMenu(priorityMenu, task.priority, onPick = { p -> store.edit(task.id) { it.copy(priority = p) } }, onDismiss = { priorityMenu = false })
    }
    PropertyRow(
        icon = painterResource(R.drawable.ic_label), tint = todoColors.secondaryText,
        text = if (task.labels.isEmpty()) "Labels" else task.labels.joinToString("  ") { "@$it" },
        onClick = { labelsDialog = true },
    )

    if (reschedule) {
        RescheduleSheet(task.due, today, onPick = { store.edit(task.id) { t -> t.copy(due = it) } }, onDismiss = { reschedule = false })
    }
    if (labelsDialog) {
        LabelsDialog(snapshot.labels, task.labels, onDone = { names -> store.edit(task.id) { it.copy(labels = names) } }, onDismiss = { labelsDialog = false })
    }
}

@Composable
private fun PropertyRow(
    icon: Painter,
    tint: Color,
    text: String,
    onClick: () -> Unit,
    textColor: Color? = null,
    onClear: (() -> Unit)? = null,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(start = 16.dp, end = 4.dp).padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, Modifier.size(20.dp), tint = tint)
        Spacer(Modifier.width(20.dp))
        Text(text, color = textColor ?: LocalContentColor.current, fontSize = 15.sp, modifier = Modifier.weight(1f).padding(vertical = 10.dp))
        if (onClear != null) {
            IconButton(onClick = onClear) { Icon(Icons.Filled.Clear, "Clear", tint = todoColors.secondaryText) }
        }
    }
}

@Composable
private fun Subtasks(
    task: TodoTask,
    snapshot: Snapshot,
    store: TodoStore,
    onComplete: (TodoTask) -> Unit,
    onOpenTask: (EntityID) -> Unit,
) {
    val children = snapshot.subtasks(task.id, includeCompleted = true)
    var adding by remember(task.id) { mutableStateOf(false) }
    var newTitle by remember(task.id) { mutableStateOf("") }
    Text(
        if (children.isEmpty()) "Sub-tasks" else "Sub-tasks ${children.count { it.isCompleted }}/${children.size}",
        fontWeight = FontWeight.Bold, fontSize = 15.sp,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
    children.forEach { child ->
        Row(
            Modifier.fillMaxWidth().clickable { onOpenTask(child.id) }.padding(start = 4.dp, end = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PriorityCheckbox(child.priority, child.isCompleted, onClick = { onComplete(child) }, size = 20.dp)
            Text(
                child.content,
                color = if (child.isCompleted) todoColors.secondaryText else MaterialTheme.colorScheme.onSurface,
                textDecoration = if (child.isCompleted) TextDecoration.LineThrough else null,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(start = 4.dp),
            )
        }
    }
    if (adding) {
        fun add() {
            if (newTitle.isNotBlank()) store.addTask(content = newTitle.trim(), projectId = task.projectId, parentId = task.id)
            newTitle = ""
        }
        Row(Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Add, null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(16.dp))
            BasicTextField(
                value = newTitle,
                onValueChange = { newTitle = it.replace("\n", " ") },
                singleLine = true,
                textStyle = TextStyle(fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurface),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { add() }),
                decorationBox = { inner ->
                    if (newTitle.isEmpty()) Text("Sub-task name", color = todoColors.secondaryText, fontSize = 15.sp)
                    inner()
                },
                modifier = Modifier.weight(1f).padding(vertical = 10.dp),
            )
            TextButton(onClick = { add() }, enabled = newTitle.isNotBlank()) { Text("Add") }
        }
    } else {
        Row(
            Modifier.fillMaxWidth().clickable { adding = true }.padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Add, null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(16.dp))
            Text("Add sub-task", color = todoColors.secondaryText, fontSize = 15.sp)
        }
    }
}

@Composable
private fun DeleteRow(task: TodoTask, onDelete: () -> Unit) {
    var confirm by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().clickable { confirm = true }.padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Delete, null, tint = todoColors.overdue)
        Spacer(Modifier.width(16.dp))
        Text("Delete task", color = todoColors.overdue, fontSize = 15.sp)
    }
    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Delete task?") },
            text = { Text("“${task.content}” and its sub-tasks will be deleted.") },
            confirmButton = { TextButton(onClick = { confirm = false; onDelete() }) { Text("Delete", color = todoColors.overdue) } },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
        )
    }
}
