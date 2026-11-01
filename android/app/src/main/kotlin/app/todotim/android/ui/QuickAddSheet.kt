package app.todotim.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.todotim.android.QuickAddDefaults
import app.todotim.android.R
import app.todotim.core.parsing.DueDateFormatting
import app.todotim.core.parsing.ParsedTask
import app.todotim.core.parsing.ParsedToken
import app.todotim.core.parsing.QuickAddParser
import app.todotim.core.store.Snapshot
import app.todotim.core.store.TodoStore
import app.todotim.android.ui.theme.TodoColors
import app.todotim.android.ui.theme.todoColors
import app.todotim.core.EntityID
import app.todotim.core.Priority
import java.time.LocalDate

/**
 * Todoist-style quick add: one auto-focused field whose date, priority, @label, #project and /section
 * tokens are highlighted as they are recognised, with chips to set the same things by tapping.
 * A token in the text wins over a chip choice. The sheet stays open after adding, for the next task.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuickAddSheet(
    defaults: QuickAddDefaults,
    snapshot: Snapshot,
    store: TodoStore,
    today: LocalDate,
    onDismiss: () -> Unit,
) {
    var field by remember { mutableStateOf(TextFieldValue(defaults.text, TextRange(defaults.text.length))) }
    var description by remember { mutableStateOf("") }
    var chipDue by remember { mutableStateOf<LocalDate?>(null) }
    var chipPriority by remember { mutableStateOf<Priority?>(null) }
    var chipLabels by remember { mutableStateOf<List<String>>(emptyList()) }
    var chipProject by remember { mutableStateOf(defaults.projectId to defaults.sectionId) }
    var picker by remember { mutableStateOf<QuickAddPicker?>(null) }

    val (parsed, tokens) = remember(field.text, today, snapshot, chipProject.first) {
        parseQuickAdd(field.text, today, snapshot, chipProject.first)
    }
    val (projectId, sectionId) = resolvePlace(parsed, snapshot, chipProject)
    val due = if (parsed.noDate) null else parsed.due ?: chipDue
    val priority = parsed.priority ?: chipPriority ?: Priority.P4
    val labels = (chipLabels + parsed.labels).distinct()
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) {
        focus.requestFocus()
        keyboard?.show()
    }

    fun submit() {
        if (parsed.content.isBlank()) return
        // Label names need no label entry: the snapshot lists every name a task uses.
        store.addTask(
            content = parsed.content, projectId = projectId, sectionId = sectionId, description = description.trim(),
            priority = priority, due = due, labels = labels,
        )
        field = TextFieldValue(defaults.text, TextRange(defaults.text.length))
        description = ""
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        dragHandle = null,
    ) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            val colors = todoColors
            val textColor = MaterialTheme.colorScheme.onSurface
            BasicTextField(
                value = field,
                onValueChange = { field = it.copy(text = it.text.replace("\n", " ")) },
                textStyle = TextStyle(fontSize = 18.sp, color = textColor),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                visualTransformation = TokenHighlight(tokens, colors),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                decorationBox = { inner ->
                    if (field.text.isEmpty()) Text("e.g. Call Anna tomorrow p1 #Work @calls", color = colors.secondaryText, fontSize = 18.sp)
                    inner()
                },
                modifier = Modifier.fillMaxWidth().focusRequester(focus).padding(vertical = 6.dp),
            )
            BasicTextField(
                value = description,
                onValueChange = { description = it },
                textStyle = TextStyle(fontSize = 14.sp, color = textColor),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                decorationBox = { inner ->
                    if (description.isEmpty()) Text("Description", color = colors.secondaryText, fontSize = 14.sp)
                    inner()
                },
                modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
            )
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val dueTint = due?.let { dueColor(it, today) } ?: colors.secondaryText
                QuickChip(R.drawable.ic_calendar, due?.let { DueDateFormatting.displayString(it, today) } ?: "Date", dueTint, due != null) { picker = QuickAddPicker.Date }
                Box {
                    QuickChip(R.drawable.ic_flag, if (priority == Priority.P4) "Priority" else "P${priority.level}", colors.priority(priority), priority != Priority.P4) {
                        picker = QuickAddPicker.Priority
                    }
                    PriorityMenu(picker == QuickAddPicker.Priority, priority, onPick = { chipPriority = it }, onDismiss = { picker = null })
                }
                QuickChip(R.drawable.ic_label, if (labels.isEmpty()) "Labels" else labels.joinToString(" ") { "@$it" }, colors.secondaryText, labels.isNotEmpty()) {
                    picker = QuickAddPicker.Labels
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    val project = snapshot.project(projectId)
                    val section = sectionId?.let { sid -> snapshot.sections(projectId).firstOrNull { it.id == sid } }
                    QuickChip(
                        if (project?.isInbox == true) R.drawable.ic_inbox else null,
                        listOfNotNull(project?.name ?: "Inbox", section?.name).joinToString(" / "),
                        if (project?.isInbox == true) colors.p3 else paletteColor(project?.color ?: "charcoal"),
                        selected = false,
                    ) { picker = QuickAddPicker.Project }
                    ProjectSectionMenu(
                        picker == QuickAddPicker.Project, snapshot, projectId, sectionId,
                        onPick = { p, s -> chipProject = p to s }, onDismiss = { picker = null },
                    )
                }
                IconButton(
                    onClick = { submit() },
                    enabled = parsed.content.isNotBlank(),
                    colors = IconButtonDefaults.iconButtonColors(
                        containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = Color.White,
                        disabledContainerColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.35f),
                        disabledContentColor = Color.White,
                    ),
                ) { Icon(Icons.AutoMirrored.Filled.Send, "Add task") }
            }
        }
    }

    when (picker) {
        QuickAddPicker.Date -> RescheduleSheet(due, today, onPick = { chipDue = it }, onDismiss = { picker = null })
        QuickAddPicker.Labels -> LabelsDialog(snapshot.labels, chipLabels, onDone = { chipLabels = it }, onDismiss = { picker = null })
        else -> Unit
    }
}

private enum class QuickAddPicker { Date, Priority, Labels, Project }

/**
 * Where the task goes: the project of a `#project` token (else [chosen]'s), and the section of a `/section` token
 * in it (else [chosen]'s section when the project is the chosen one). Names match case-insensitively.
 */
/**
 * Parses quick-add [text] with the section names of the project the task goes to: the one a #project token names,
 * else [chosenProjectId]. Sections of other projects would make `/Planning review` match a longer name that the
 * target project does not have. When the #project token changes the target, the text is parsed again with its
 * sections.
 */
internal fun parseQuickAdd(
    text: String,
    today: LocalDate,
    snapshot: Snapshot,
    chosenProjectId: EntityID,
): Pair<ParsedTask, List<ParsedToken>> {
    val projectNames = snapshot.projects.map { it.name }
    fun analyse(projectId: EntityID): Pair<ParsedTask, List<ParsedToken>> {
        val sectionNames = snapshot.sections(projectId).map { it.name }
        return QuickAddParser.parse(text, today, projectNames = projectNames, sectionNames = sectionNames) to
            QuickAddParser.tokens(text, today, projectNames = projectNames, sectionNames = sectionNames)
    }
    val first = analyse(chosenProjectId)
    val target = resolvePlace(first.first, snapshot, chosenProjectId to null).first
    return if (target == chosenProjectId) first else analyse(target)
}

internal fun resolvePlace(parsed: ParsedTask, snapshot: Snapshot, chosen: Pair<EntityID, EntityID?>): Pair<EntityID, EntityID?> {
    val project = parsed.projectName?.let { name -> snapshot.projects.firstOrNull { it.name.equals(name, ignoreCase = true) } }
    val projectId = project?.id ?: chosen.first
    val section = parsed.sectionName?.let { name ->
        snapshot.sections(projectId).firstOrNull { it.name.equals(name, ignoreCase = true) }
    }
    return projectId to (section?.id ?: chosen.second.takeIf { projectId == chosen.first })
}

@Composable
private fun QuickChip(icon: Int?, text: String, tint: Color, selected: Boolean, onClick: () -> Unit) {
    AssistChip(
        onClick = onClick,
        label = { Text(text, maxLines = 1, color = if (selected) tint else MaterialTheme.colorScheme.onSurface) },
        leadingIcon = {
            if (icon != null) {
                Icon(painterResource(icon), null, Modifier.size(16.dp), tint = tint)
            } else {
                Text("#", color = tint)
            }
        },
        colors = AssistChipDefaults.assistChipColors(containerColor = MaterialTheme.colorScheme.surface),
    )
}

/** Highlights recognised tokens with a tinted background; the text itself is unchanged. */
private class TokenHighlight(private val tokens: List<ParsedToken>, private val colors: TodoColors) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        if (tokens.isEmpty()) return TransformedText(text, OffsetMapping.Identity)
        val styled = buildAnnotatedString {
            append(text)
            for (t in tokens) {
                if (t.start < 0 || t.end > text.length || t.start >= t.end) continue
                val color = when (t.kind) {
                    ParsedToken.Kind.DATE -> colors.today
                    ParsedToken.Kind.PRIORITY -> colors.p1
                    ParsedToken.Kind.LABEL -> colors.p3
                    ParsedToken.Kind.PROJECT, ParsedToken.Kind.SECTION -> colors.thisWeek
                }
                addStyle(SpanStyle(color = color, background = color.copy(alpha = 0.15f)), t.start, t.end)
            }
        }
        return TransformedText(styled, OffsetMapping.Identity)
    }

    override fun equals(other: Any?) = other is TokenHighlight && other.tokens == tokens && other.colors == colors
    override fun hashCode() = tokens.hashCode()
}
