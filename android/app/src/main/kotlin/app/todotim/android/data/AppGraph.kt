package app.todotim.android.data

import android.content.Context
import android.util.Log
import app.todotim.core.EntityID
import app.todotim.core.TodoTask
import app.todotim.core.store.Persistence
import app.todotim.core.store.TodoStore
import app.todotim.core.sync.SyncController
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** The store and its sync, available once the database is loaded. */
class Loaded(val store: TodoStore, val sync: SyncManager)

sealed interface LoadState {
    data object Loading : LoadState
    data class Ready(val loaded: Loaded) : LoadState
    data class Failed(val message: String) : LoadState
}

/**
 * The process-wide objects, created once by the Application: settings, the database (loaded off the main thread),
 * persistence (saves on [scope], which lives as long as the process) and the one [SyncManager] shared by the UI and
 * the background worker.
 */
class AppGraph(context: Context) {
    /** A failure nothing else handles is logged, not fatal: the data stays in memory and is saved again. */
    val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default +
            CoroutineExceptionHandler { _, e -> Log.e("TodoTim", "Background work failed", e) },
    )
    val settings = SyncSettingsStore(context)
    private val persistence = Persistence(File(context.filesDir, "todotim"))

    /** Why saving the database fails, while it does (disk full, …); null once saved. */
    val saveError: StateFlow<String?> = persistence.saveError

    private val noticeState = MutableStateFlow<String?>(null)

    /** A one-time message for the user (the database file was unreadable and moved aside); null when none. */
    val notice: StateFlow<String?> = noticeState.asStateFlow()

    fun dismissNotice() {
        noticeState.value = null
    }

    private val loadState = MutableStateFlow<LoadState>(LoadState.Loading)
    val state: StateFlow<LoadState> = loadState.asStateFlow()

    private val loaded: Deferred<Loaded> = scope.async(Dispatchers.IO) {
        try {
            val store = TodoStore(persistence.load())
            persistence.movedAside?.let {
                noticeState.value = "Your task database could not be read, so TodoTim started empty. The old file " +
                    "was kept as ${it.path}. Synced tasks come back with the next sync."
            }
            persistence.attach(store, scope)
            val controller = SyncController(store, persistence)
            val sync = SyncManager(scope, store, controller, credentials = { withContext(Dispatchers.IO) { settings.credentials() } })
            sync.syncAfterEdits()
            Loaded(store, sync).also { loadState.value = LoadState.Ready(it) }
        } catch (e: Exception) {
            // An unreadable (not corrupt) file: never start empty, the next save would replace it.
            loadState.value = LoadState.Failed("Could not read the task database: ${e.message ?: e::class.java.simpleName}")
            throw e
        }
    }

    /** Waits for the database. Throws when it could not be read. */
    suspend fun await(): Loaded = loaded.await()

    /** Saves pending changes now (the app goes to the background). */
    fun flush() {
        scope.launch {
            val ready = (loadState.value as? LoadState.Ready)?.loaded ?: return@launch
            persistence.flushQuietly(ready.store) // a failure shows in saveError and is retried
        }
    }
}

/**
 * Edits a task through the store, which passes the stored task (raw structure). Never build the new value from a
 * snapshot task: those carry the display repair (moved to the inbox, parent dropped, …), which must not be saved.
 */
fun TodoStore.edit(id: EntityID, change: (TodoTask) -> TodoTask): Boolean = updateTask(id) { change(this) }
