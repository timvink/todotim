package app.todotim.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.todotim.android.ui.theme.todoColors
import java.time.LocalDate

/** A pull-to-refresh list of headers and swipeable task rows, with an empty state. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskListContent(
    items: List<ListItem>,
    today: LocalDate,
    actions: TaskRowActions,
    labelColor: (String) -> Color,
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    emptyTitle: String,
    emptyText: String,
    modifier: Modifier = Modifier,
) {
    PullToRefreshBox(isRefreshing = isRefreshing, onRefresh = onRefresh, modifier = modifier.fillMaxSize()) {
        if (items.isEmpty()) {
            // Scrollable so pull-to-refresh still works on an empty list.
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.padding(top = 120.dp))
                Text(emptyTitle, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                Text(
                    emptyText,
                    style = MaterialTheme.typography.bodyMedium,
                    color = todoColors.secondaryText,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 96.dp)) {
                items(items, key = { it.key }, contentType = { it::class }) { item ->
                    when (item) {
                        is ListItem.Header -> GroupHeader(item)
                        is ListItem.TaskItem -> SwipeableTaskRow(item, today, actions, labelColor)
                    }
                }
            }
        }
    }
}
