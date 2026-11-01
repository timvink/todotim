package app.todotim.android

import app.todotim.android.data.Credentials
import app.todotim.android.data.SyncManager
import app.todotim.core.dav.SyncError
import app.todotim.core.store.TodoStore
import app.todotim.core.sync.SyncController
import app.todotim.core.sync.SyncSettings
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SyncManagerTest {
    private val store = TodoStore()
    private var connects = 0
    private val controller = SyncController(store, connect = { _, _, _ ->
        connects++
        throw SyncError.Unauthorized
    })
    private val account = Credentials(SyncSettings("https://dav.example.com/", "tim"), "secret")

    @Test
    fun withoutAccountNothingRunsAndOnlyManualSyncComplains() = runTest {
        val sync = SyncManager(backgroundScope, store, controller, credentials = { null })
        val error = async(start = CoroutineStart.UNDISPATCHED) { sync.errors.first() }
        assertFalse(sync.sync())
        assertFalse(sync.sync(manual = true))
        assertEquals(0, connects)
        assertEquals("No server set up. Add one in Settings.", error.await())
    }

    @Test
    fun failureLandsInStatus() = runTest {
        val sync = SyncManager(backgroundScope, store, controller, credentials = { account })
        assertFalse(sync.sync())
        assertEquals(1, connects)
        assertEquals(SyncError.Unauthorized.message, sync.status.value.error)
        assertFalse(sync.status.value.isSyncing)
    }

    @Test
    fun localEditsTriggerOneDebouncedSync() = runTest {
        val sync = SyncManager(backgroundScope, store, controller, credentials = { account })
        sync.syncAfterEdits(debounceMillis = 3_000)
        runCurrent()
        val t = store.addTask("A")
        advanceTimeBy(1_000)
        store.updateTask(t.id) { copy(content = "B") }
        advanceTimeBy(2_500)
        assertEquals(0, connects)
        advanceTimeBy(1_000)
        assertEquals(1, connects)
        // The failed sync changed nothing, so nothing triggers again.
        advanceTimeBy(10_000)
        assertEquals(1, connects)
    }
}
