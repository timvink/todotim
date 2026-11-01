package app.todotim.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.sp
import app.todotim.android.data.SampleData
import app.todotim.android.ui.theme.TodoTimTheme
import java.time.LocalDate

/** Shared state and callbacks of the task-list screens. */
data class ListScreenState(
    val today: LocalDate,
    val showCompleted: Boolean,
    val isRefreshing: Boolean,
    val canGoBack: Boolean,
    val labelColor: (String) -> Color,
)

data class ListScreenCallbacks(
    val rows: TaskRowActions,
    val onRefresh: () -> Unit,
    val onToggleShowCompleted: () -> Unit,
    val onBack: () -> Unit,
)

/** A project's tasks (the Inbox tab shows the inbox project with this screen). */
@Composable
fun TaskListScreen(
    title: String,
    items: List<ListItem>,
    state: ListScreenState,
    callbacks: ListScreenCallbacks,
    emptyTitle: String = "All clear",
    emptyText: String = "Tap + to add a task.",
) {
    Column(Modifier.fillMaxSize()) {
        ListTopBar(title, state, callbacks)
        TaskListContent(
            items = items,
            today = state.today,
            actions = callbacks.rows,
            labelColor = state.labelColor,
            isRefreshing = state.isRefreshing,
            onRefresh = callbacks.onRefresh,
            emptyTitle = emptyTitle,
            emptyText = emptyText,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ListTopBar(title: String, state: ListScreenState, callbacks: ListScreenCallbacks) {
    var menu by remember { mutableStateOf(false) }
    TopAppBar(
        title = { Text(title, fontWeight = FontWeight.Bold, fontSize = 24.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = {
            if (state.canGoBack) {
                IconButton(onClick = callbacks.onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            }
        },
        actions = {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "More options") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(
                    text = { Text("Show completed") },
                    trailingIcon = { if (state.showCompleted) Icon(Icons.Filled.Check, null) },
                    onClick = { menu = false; callbacks.onToggleShowCompleted() },
                )
                DropdownMenuItem(
                    text = { Text("Sync now") },
                    leadingIcon = { Icon(Icons.Filled.Refresh, null) },
                    onClick = { menu = false; callbacks.onRefresh() },
                )
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
    )
}

@Preview(showBackground = true, heightDp = 700)
@Composable
private fun InboxPreview() {
    val today = LocalDate.of(2026, 11, 2)
    val s = SampleData.snapshot(today)
    TodoTimTheme(darkTheme = false) {
        TaskListScreen(
            title = "Inbox",
            items = TaskLists.project(s, "inbox", showCompleted = false),
            state = ListScreenState(today, showCompleted = false, isRefreshing = false, canGoBack = false) {
                Palette.color(s.labelsByName[it]?.color ?: "charcoal")
            },
            callbacks = ListScreenCallbacks(TaskRowActions({}, {}, {}, {}), {}, {}, {}),
        )
    }
}
