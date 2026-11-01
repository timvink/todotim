package app.todotim.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import app.todotim.android.data.SampleData
import app.todotim.android.data.TodoSnapshot
import app.todotim.android.ui.theme.TodoTimTheme
import java.time.LocalDate

/** Search open tasks by title and description; results grouped by project. */
@Composable
fun SearchScreen(snapshot: TodoSnapshot, state: ListScreenState, callbacks: ListScreenCallbacks) {
    var query by rememberSaveable { mutableStateOf("") }
    val results = TaskLists.search(snapshot, query)
    Column(Modifier.fillMaxSize()) {
        TextField(
            value = query,
            onValueChange = { query = it },
            placeholder = { Text("Search tasks") },
            leadingIcon = { Icon(Icons.Filled.Search, null) },
            trailingIcon = {
                if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Filled.Clear, "Clear") }
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            shape = RoundedCornerShape(12.dp),
            colors = TextFieldDefaults.colors(
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            ),
            modifier = Modifier.statusBarsPadding().fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        )
        TaskListContent(
            items = results,
            today = state.today,
            actions = callbacks.rows,
            labelColor = state.labelColor,
            isRefreshing = state.isRefreshing,
            onRefresh = callbacks.onRefresh,
            emptyTitle = if (query.isBlank()) "Search" else "No results",
            emptyText = if (query.isBlank()) "Find tasks by title or description." else "No open task matches “$query”.",
        )
    }
}


@Preview(showBackground = true, heightDp = 600)
@Composable
private fun SearchPreview() {
    val today = LocalDate.of(2026, 11, 2)
    TodoTimTheme(darkTheme = false) {
        SearchScreen(
            SampleData.snapshot(today),
            ListScreenState(today, false, false, false) { Color.Gray },
            ListScreenCallbacks(TaskRowActions({}, {}, {}, {}), {}, {}, {}),
        )
    }
}
