package app.todotim.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.todotim.android.R
import app.todotim.core.store.Snapshot
import app.todotim.android.ui.theme.todoColors
import app.todotim.core.EntityID
import app.todotim.core.Label
import app.todotim.core.Priority

fun priorityName(p: Priority): String = "Priority ${p.level}"

/** Dropdown of p1–p4 with coloured flags. */
@Composable
fun PriorityMenu(expanded: Boolean, current: Priority, onPick: (Priority) -> Unit, onDismiss: () -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        Priority.entries.forEach { p ->
            DropdownMenuItem(
                text = { Text(priorityName(p)) },
                leadingIcon = { Icon(painterResource(R.drawable.ic_flag), null, tint = todoColors.priority(p)) },
                trailingIcon = { if (p == current) Icon(Icons.Filled.Check, null) },
                onClick = { onPick(p); onDismiss() },
            )
        }
    }
}

/** Dropdown of projects with their sections indented. */
@Composable
fun ProjectSectionMenu(
    expanded: Boolean,
    snapshot: Snapshot,
    currentProject: EntityID,
    currentSection: EntityID?,
    onPick: (projectId: EntityID, sectionId: EntityID?) -> Unit,
    onDismiss: () -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, modifier = Modifier.heightIn(max = 420.dp)) {
        snapshot.projects.forEach { p ->
            DropdownMenuItem(
                text = { Text(p.name) },
                leadingIcon = {
                    if (p.isInbox) Icon(painterResource(R.drawable.ic_inbox), null, Modifier.size(18.dp), tint = todoColors.p3)
                    else Text("#", color = paletteColor(p.color))
                },
                trailingIcon = { if (p.id == currentProject && currentSection == null) Icon(Icons.Filled.Check, null) },
                onClick = { onPick(p.id, null); onDismiss() },
            )
            snapshot.sections(p.id).forEach { s ->
                DropdownMenuItem(
                    text = { Text(s.name, color = todoColors.secondaryText) },
                    leadingIcon = { Text("/", color = todoColors.secondaryText) },
                    trailingIcon = { if (s.id == currentSection) Icon(Icons.Filled.Check, null) },
                    onClick = { onPick(p.id, s.id); onDismiss() },
                    modifier = Modifier.padding(start = 20.dp),
                )
            }
        }
    }
}

/**
 * Checklist of labels plus a field to add a new one; [onDone] gets the chosen label names. A new name needs no
 * label entry: it is saved on the task, and the snapshot lists every label name a task uses.
 */
@Composable
fun LabelsDialog(labels: List<Label>, selected: List<String>, onDone: (List<String>) -> Unit, onDismiss: () -> Unit) {
    val chosen = remember { mutableStateListOf<String>().apply { addAll(selected) } }
    val names = remember { mutableStateListOf<String>().apply { addAll((labels.sortedBy { it.order }.map { it.name } + selected).distinct()) } }
    var newName by remember { mutableStateOf("") }
    fun addNew() {
        val n = newName.trim().removePrefix("@").replace(' ', '_')
        if (n.isNotEmpty()) {
            if (n !in names) names.add(n)
            if (n !in chosen) chosen.add(n)
        }
        newName = ""
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Labels") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                names.forEach { name ->
                    Row(
                        Modifier.fillMaxWidth().clickable { if (name in chosen) chosen.remove(name) else chosen.add(name) },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(checked = name in chosen, onCheckedChange = null, modifier = Modifier.padding(12.dp))
                        Icon(painterResource(R.drawable.ic_label), null, Modifier.size(16.dp),
                            tint = paletteColor(labels.firstOrNull { it.name == name }?.color ?: "charcoal"))
                        Text(name, Modifier.padding(start = 8.dp))
                    }
                }
                OutlinedTextField(
                    value = newName,
                    onValueChange = { newName = it },
                    placeholder = { Text("New label") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { addNew() }),
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
            }
        },
        confirmButton = { TextButton(onClick = { addNew(); onDone(chosen.toList()); onDismiss() }) { Text("Done") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
