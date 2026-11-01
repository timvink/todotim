package app.todotim.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.todotim.android.R
import app.todotim.core.store.Snapshot
import app.todotim.android.ui.theme.TodoTimTheme
import app.todotim.android.ui.theme.todoColors
import app.todotim.core.Label
import app.todotim.core.Project

/** Projects (inbox first) and labels with their open task counts; the gear opens Settings. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BrowseScreen(
    snapshot: Snapshot,
    onOpenProject: (Project) -> Unit,
    onOpenLabel: (Label) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val projects = snapshot.projects
    val inbox = projects.firstOrNull { it.isInbox }
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Browse", fontWeight = FontWeight.Bold, fontSize = 24.sp) },
            actions = { IconButton(onClick = onOpenSettings) { Icon(Icons.Filled.Settings, "Settings") } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
        )
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 96.dp)) {
            inbox?.let { p ->
                item(key = "inbox") {
                    BrowseRow(
                        icon = { Icon(painterResource(R.drawable.ic_inbox), null, Modifier.size(20.dp), tint = todoColors.p3) },
                        title = p.name, count = snapshot.openCount(p.id), onClick = { onOpenProject(p) },
                    )
                }
            }
            item(key = "projects-header") { BrowseHeader("My projects") }
            items(projects.filterNot { it.isInbox }, key = { "p-${it.id}" }) { p ->
                BrowseRow(
                    icon = { HashIcon(paletteColor(p.color)) },
                    title = p.name, count = snapshot.openCount(p.id), onClick = { onOpenProject(p) },
                )
            }
            if (snapshot.labels.isNotEmpty()) {
                item(key = "labels-header") { BrowseHeader("Labels") }
                items(snapshot.labels, key = { "l-${it.id}" }) { l ->
                    BrowseRow(
                        icon = { Icon(painterResource(R.drawable.ic_label), null, Modifier.size(20.dp), tint = paletteColor(l.color)) },
                        title = l.name, count = snapshot.openLabelCount(l.name), onClick = { onOpenLabel(l) },
                    )
                }
            }
        }
    }
}

@Composable
private fun HashIcon(color: Color) {
    Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
        Text("#", color = color, fontSize = 20.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun BrowseHeader(title: String) {
    Text(
        title,
        fontWeight = FontWeight.Bold,
        fontSize = 16.sp,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 24.dp, bottom = 8.dp),
    )
}

@Composable
private fun BrowseRow(icon: @Composable () -> Unit, title: String, count: Int, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon()
        Box(Modifier.width(16.dp))
        Text(title, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (count > 0) Text("$count", color = todoColors.secondaryText, fontSize = 14.sp)
    }
}

@Preview(showBackground = true, heightDp = 700)
@Composable
private fun BrowsePreview() {
    TodoTimTheme(darkTheme = false) { BrowseScreen(PreviewData.snapshot(), {}, {}, {}) }
}
