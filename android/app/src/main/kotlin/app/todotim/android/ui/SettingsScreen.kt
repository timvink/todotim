package app.todotim.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import app.todotim.android.data.ServerSettings
import app.todotim.android.data.SyncStatus
import app.todotim.android.ui.theme.TodoTimTheme
import app.todotim.android.ui.theme.todoColors
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** CalDAV server settings and sync status. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    settings: ServerSettings,
    status: SyncStatus,
    /** Epoch milliseconds of the last complete sync. */
    lastSyncedAt: Long?,
    unsyncedCount: Int,
    /** Saves; returns the message to show when the values are refused. */
    onSave: (serverUrl: String, username: String, password: String?) -> String?,
    onSyncNow: () -> Unit,
    onBack: () -> Unit,
) {
    var url by rememberSaveable(settings.serverUrl) { mutableStateOf(settings.serverUrl) }
    var user by rememberSaveable(settings.username) { mutableStateOf(settings.username) }
    // Not rememberSaveable: the password must not land in the saved-instance-state Bundle.
    var password by remember { mutableStateOf("") }
    var saveError by rememberSaveable { mutableStateOf<String?>(null) }
    val changed = url != settings.serverUrl || user != settings.username || password.isNotEmpty()
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Settings", fontWeight = FontWeight.Bold) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
        )
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom))
                .verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("CalDAV server", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
            OutlinedTextField(
                value = url, onValueChange = { url = it },
                label = { Text("Server URL") },
                placeholder = { Text("https://cloud.example.com/remote.php/dav/") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = user, onValueChange = { user = it },
                label = { Text("Username") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = password, onValueChange = { password = it },
                label = { Text("Password") },
                placeholder = {
                    if (settings.hasPassword && url == settings.serverUrl && user == settings.username) Text("Saved — type to replace")
                },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Use an app password. http:// is only allowed for localhost.",
                style = MaterialTheme.typography.bodySmall,
                color = todoColors.secondaryText,
            )
            saveError?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = todoColors.overdue) }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(
                    onClick = {
                        saveError = onSave(url, user, password.ifEmpty { null })
                        if (saveError == null) password = ""
                    },
                    enabled = changed && url.isNotBlank() && user.isNotBlank(),
                ) { Text("Save") }
                OutlinedButton(onClick = onSyncNow, enabled = !status.isSyncing && settings.isConfigured) { Text("Sync now") }
                if (status.isSyncing) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            }
            Text(
                syncStatusText(status, lastSyncedAt, settings.isConfigured),
                style = MaterialTheme.typography.bodyMedium,
                color = if (status.error != null) todoColors.overdue else todoColors.secondaryText,
            )
            if (unsyncedCount > 0 && settings.isConfigured) {
                Text(
                    if (unsyncedCount == 1) "1 task not synced yet" else "$unsyncedCount tasks not synced yet",
                    style = MaterialTheme.typography.bodySmall,
                    color = todoColors.secondaryText,
                )
            }
            status.warnings.forEach {
                Text("⚠ $it", style = MaterialTheme.typography.bodySmall, color = todoColors.secondaryText)
            }
        }
    }
}

private val timeFormat = DateTimeFormatter.ofPattern("d MMM, HH:mm", Locale.ENGLISH)

fun syncStatusText(status: SyncStatus, lastSyncedAt: Long?, configured: Boolean): String = when {
    !configured -> "Not set up: tasks stay on this phone until you add a server."
    status.isSyncing -> "Syncing…"
    status.error != null -> "Last sync failed: ${status.error}"
    lastSyncedAt != null ->
        "Last synced " + Instant.ofEpochMilli(lastSyncedAt).atZone(ZoneId.systemDefault()).format(timeFormat)
    else -> "Not synced yet"
}

@Preview(showBackground = true)
@Composable
private fun SettingsPreview() {
    TodoTimTheme(darkTheme = false) {
        SettingsScreen(
            ServerSettings("https://cloud.example.com/remote.php/dav/", "tim", hasPassword = true),
            SyncStatus(), lastSyncedAt = 1_793_000_000_000, unsyncedCount = 2,
            { _, _, _ -> null }, {}, {},
        )
    }
}
