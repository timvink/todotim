package app.todotim.android.data

import app.todotim.core.dav.SyncError
import app.todotim.core.store.Database
import app.todotim.core.store.TodoStore
import app.todotim.core.sync.SyncController
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger

/** State of the last or running sync, for the pull-to-refresh spinner and Settings. */
data class SyncStatus(
    val isSyncing: Boolean = false,
    /** Message of the last sync's failure; null when it succeeded or none ran. */
    val error: String? = null,
    /** Problems the last sync reported without failing (lists it could not write, …). */
    val warnings: List<String> = emptyList(),
)

/**
 * The process's one entry point for syncing: the UI (start, resume, pull-to-refresh, after edits) and the
 * WorkManager job all call this instance, and [SyncController] runs one sync at a time.
 */
class SyncManager(
    private val scope: CoroutineScope,
    private val store: TodoStore,
    private val controller: SyncController,
    /** The account, or null when none is set up (then there is nothing to sync). */
    private val credentials: suspend () -> Credentials?,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val state = MutableStateFlow(SyncStatus())
    val status: StateFlow<SyncStatus> = state.asStateFlow()

    private val errorEvents = MutableSharedFlow<String>(extraBufferCapacity = 4)

    /** Errors worth a snackbar: every failure of a sync the user asked for, and a new failure of an automatic one. */
    val errors: SharedFlow<String> = errorEvents.asSharedFlow()

    private val running = AtomicInteger()
    @Volatile private var lastAttemptAt: Long? = null
    @Volatile private var afterLastSync: Database? = null

    /** Runs one sync (or waits for the running one, then runs). Returns whether it succeeded. */
    suspend fun sync(manual: Boolean = false): Boolean {
        val account = credentials()
        if (account == null) {
            if (manual) errorEvents.tryEmit("No server set up. Add one in Settings.")
            return false
        }
        lastAttemptAt = clock()
        running.incrementAndGet()
        state.update { it.copy(isSyncing = true) }
        try {
            val result = controller.syncNow(account.settings, account.password)
            state.update { it.copy(error = null, warnings = result.warnings) }
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val message = messageFor(e)
            val previous = state.value.error
            state.update { it.copy(error = message, warnings = emptyList()) }
            if (manual || message != previous) errorEvents.tryEmit(message)
            return false
        } finally {
            afterLastSync = store.database.value
            if (running.decrementAndGet() == 0) state.update { it.copy(isSyncing = false) }
        }
    }

    fun launchSync(manual: Boolean = false): Job = scope.launch { sync(manual) }

    /** Syncs unless a sync started less than [maxAgeMillis] ago (app start and resume). */
    fun syncIfStale(maxAgeMillis: Long = 60_000) {
        val last = lastAttemptAt
        if (last == null || clock() - last >= maxAgeMillis) launchSync()
    }

    /**
     * Syncs [debounceMillis] after the last local edit. Changes a sync itself makes are not edits: the database
     * is compared with the one the last sync left behind.
     */
    @OptIn(FlowPreview::class)
    fun syncAfterEdits(debounceMillis: Long = 3_000): Job = scope.launch {
        store.database.drop(1).debounce(debounceMillis).collect { db ->
            if (db !== afterLastSync && store.snapshot.value.unsyncedCount > 0) sync()
        }
    }

    companion object {
        fun messageFor(e: Exception): String = when (e) {
            is SyncError -> e.message ?: e.toString()
            is java.io.IOException -> "Network error: ${e.message ?: e::class.java.simpleName}"
            else -> "Sync failed: ${e.message ?: e::class.java.simpleName}"
        }
    }
}
