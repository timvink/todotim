package app.todotim.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.todotim.android.AppViewModel
import app.todotim.android.R
import app.todotim.android.Screen
import app.todotim.android.data.SyncManager
import app.todotim.android.data.SyncSettingsStore
import app.todotim.android.data.edit
import app.todotim.core.EntityID
import app.todotim.core.INBOX_ID
import app.todotim.core.TodoTask
import app.todotim.core.store.TodoStore
import kotlinx.coroutines.launch
import java.time.LocalDate

/** Root: bottom navigation (Inbox / Search / Browse), FAB, the current screen and the sheets. */
@Composable
fun TodoTimApp(vm: AppViewModel, store: TodoStore, sync: SyncManager, settingsStore: SyncSettingsStore) {
    val snapshot by store.snapshot.collectAsState()
    val syncStatus by sync.status.collectAsState()
    val settings by settingsStore.settings.collectAsState()
    val today = LocalDate.now()
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var rescheduleId by remember { mutableStateOf<EntityID?>(null) }
    val labelColors = remember(snapshot) { snapshot.labels.associate { it.name to paletteColor(it.color) } }

    BackHandler(enabled = vm.canGoBack) { vm.back() }

    // Sync failures as a snackbar (successes stay quiet; Settings shows the status).
    LaunchedEffect(sync) {
        sync.errors.collect { message ->
            snackbar.currentSnackbarData?.dismiss()
            snackbar.showSnackbar(message, duration = SnackbarDuration.Long)
        }
    }

    fun toggle(task: TodoTask) {
        if (task.isCompleted) {
            store.reopen(task.id)
            return
        }
        val undo = vm.complete(store, task.id)
        val message = if (task.recurrence != null) "Moved to the next date" else "Completed"
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            val result = snackbar.showSnackbar(message, actionLabel = "Undo", duration = SnackbarDuration.Short)
            if (result == SnackbarResult.ActionPerformed) undo()
        }
    }

    val rowActions = TaskRowActions(
        onToggle = { toggle(it.task) },
        onOpen = { vm.detailTaskId = it.task.id },
        onToggleCollapsed = { item -> store.setCollapsed(item.task.id, !item.task.collapsed) },
        onReschedule = { rescheduleId = it.task.id },
    )
    val listState = ListScreenState(
        today = today,
        showCompleted = vm.showCompleted,
        isRefreshing = syncStatus.isSyncing,
        canGoBack = vm.canGoBack,
        labelColor = { name -> labelColors[name] ?: paletteColor("charcoal") },
    )
    val listCallbacks = ListScreenCallbacks(
        rows = rowActions,
        onRefresh = { sync.launchSync(manual = true) },
        onToggleShowCompleted = { vm.showCompleted = !vm.showCompleted },
        onBack = vm::back,
    )
    val screen = vm.screen

    Scaffold(
        bottomBar = { if (screen != Screen.Settings) BottomBar(vm.tab, vm::selectTab) },
        floatingActionButton = {
            if (screen != Screen.Settings && screen != Screen.Search) {
                FloatingActionButton(
                    onClick = vm::openQuickAdd,
                    shape = RoundedCornerShape(16.dp),
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = Color.White,
                ) { Icon(Icons.Filled.Add, "Add task") }
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
        containerColor = MaterialTheme.colorScheme.surface,
        // Screens apply the status-bar inset themselves (top bars); the bottom one is the navigation bar's.
        contentWindowInsets = WindowInsets(0),
    ) { inner ->
        Box(Modifier.fillMaxSize().padding(inner).consumeWindowInsets(inner)) {
            when (screen) {
                Screen.Inbox -> TaskListScreen(
                    title = snapshot.inbox.name,
                    items = remember(snapshot, vm.showCompleted) { TaskLists.project(snapshot, INBOX_ID, vm.showCompleted) },
                    state = listState, callbacks = listCallbacks,
                    emptyTitle = "Your inbox is empty", emptyText = "Tap + to add a task.",
                )
                is Screen.ProjectTasks -> TaskListScreen(
                    title = snapshot.project(screen.projectId)?.name ?: "Project",
                    items = remember(snapshot, screen, vm.showCompleted) {
                        TaskLists.project(snapshot, screen.projectId, vm.showCompleted)
                    },
                    state = listState, callbacks = listCallbacks,
                )
                is Screen.LabelTasks -> TaskListScreen(
                    title = "@${screen.label}",
                    items = remember(snapshot, screen) { TaskLists.label(snapshot, screen.label) },
                    state = listState, callbacks = listCallbacks,
                    emptyTitle = "No tasks", emptyText = "No open task has this label.",
                )
                Screen.Search -> SearchScreen(snapshot, listState, listCallbacks)
                Screen.Browse -> BrowseScreen(
                    snapshot,
                    onOpenProject = { p -> if (p.isInbox) vm.selectTab(Screen.Inbox) else vm.open(Screen.ProjectTasks(p.id)) },
                    onOpenLabel = { vm.open(Screen.LabelTasks(it.name)) },
                    onOpenSettings = { vm.open(Screen.Settings) },
                )
                Screen.Settings -> SettingsScreen(
                    settings, syncStatus, lastSyncedAt = snapshot.lastSyncAt, unsyncedCount = snapshot.unsyncedCount,
                    onSave = { url, user, password ->
                        try {
                            settingsStore.save(url, user, password)
                            sync.launchSync(manual = true)
                            null
                        } catch (e: IllegalArgumentException) {
                            e.message
                        }
                    },
                    onSyncNow = { sync.launchSync(manual = true) },
                    onBack = vm::back,
                )
            }
        }
    }

    vm.detailTaskId?.let { id ->
        TaskDetailSheet(
            taskId = id, snapshot = snapshot, store = store, today = today,
            onComplete = ::toggle,
            onOpenTask = { vm.detailTaskId = it },
            onDismiss = { vm.detailTaskId = null },
        )
    }
    vm.quickAdd?.let { defaults ->
        QuickAddSheet(
            defaults = defaults, snapshot = snapshot, store = store, today = today,
            onDismiss = { vm.quickAdd = null },
        )
    }
    rescheduleId?.let { id ->
        RescheduleSheet(
            current = snapshot.task(id)?.due, today = today,
            onPick = { due -> store.edit(id) { it.copy(due = due) } },
            onDismiss = { rescheduleId = null },
        )
    }
}

@Composable
private fun BottomBar(tab: Screen, onSelect: (Screen) -> Unit) {
    val colors = NavigationBarItemDefaults.colors(
        selectedIconColor = MaterialTheme.colorScheme.primary,
        selectedTextColor = MaterialTheme.colorScheme.primary,
        indicatorColor = MaterialTheme.colorScheme.secondaryContainer,
    )
    NavigationBar(containerColor = MaterialTheme.colorScheme.surfaceContainer) {
        NavigationBarItem(
            selected = tab == Screen.Inbox, onClick = { onSelect(Screen.Inbox) },
            icon = { Icon(painterResource(R.drawable.ic_inbox), null) }, label = { Text("Inbox") }, colors = colors,
        )
        NavigationBarItem(
            selected = tab == Screen.Search, onClick = { onSelect(Screen.Search) },
            icon = { Icon(Icons.Filled.Search, null) }, label = { Text("Search") }, colors = colors,
        )
        NavigationBarItem(
            selected = tab == Screen.Browse, onClick = { onSelect(Screen.Browse) },
            icon = { Icon(Icons.Filled.Menu, null) }, label = { Text("Browse") }, colors = colors,
        )
    }
}
