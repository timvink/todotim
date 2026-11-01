package app.todotim.android

import app.todotim.android.data.Credentials
import app.todotim.android.data.SyncManager
import app.todotim.core.dav.CalDAVServer
import app.todotim.core.dav.CalendarChanges
import app.todotim.core.dav.CalendarHome
import app.todotim.core.dav.CalendarProperty
import app.todotim.core.dav.RemoteCalendar
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

    @Test
    fun anEditDuringThePushGetsAFollowUpSync() = runTest {
        val server = AcceptingServer()
        val sync = SyncManager(backgroundScope, store, SyncController(store) { _, _, _ -> server }, credentials = { account })
        sync.syncAfterEdits(debounceMillis = 3_000)
        runCurrent()
        val t = store.addTask("A")
        var edited = false
        server.onPut = {
            if (!edited) {
                edited = true
                store.updateTask(t.id) { copy(content = "B") }
            }
        }
        advanceTimeBy(3_500)
        assertEquals(1, server.puts)
        assertEquals(1, store.snapshot.value.unsyncedCount)
        advanceTimeBy(3_500)
        assertEquals(2, server.puts)
        assertEquals(0, store.snapshot.value.unsyncedCount)
        advanceTimeBy(30_000)
        assertEquals(2, server.puts)
    }

    @Test
    fun refusedWritesGetOneFollowUpOnly() = runTest {
        val server = AcceptingServer().apply { refused = true }
        val sync = SyncManager(backgroundScope, store, SyncController(store) { _, _, _ -> server }, credentials = { account })
        sync.syncAfterEdits(debounceMillis = 3_000)
        runCurrent()
        store.addTask("A")
        advanceTimeBy(3_500)
        assertEquals(1, server.puts)
        advanceTimeBy(60_000)
        assertEquals(2, server.puts)
    }
}

/** A server with an empty inbox that accepts writes unless [refused]; [onPut] runs before each write. */
private class AcceptingServer : CalDAVServer {
    override val home = "calendars/tim"
    override val calendarHome = CalendarHome("https://dav.example.com/calendars/tim/")
    var puts = 0
    var refused = false
    var onPut: () -> Unit = {}
    private var etag = 0

    override suspend fun calendars() = listOf(RemoteCalendar("$home/todotim-inbox", "Inbox", syncToken = "tok"))
    override suspend fun changes(calendar: String, since: String?) = CalendarChanges("tok", emptyList(), emptyList(), true)
    override suspend fun createCalendar(path: String, name: String, color: String, order: String) = emptySet<CalendarProperty>()
    override suspend fun setProperties(path: String, values: Map<CalendarProperty, String?>) = emptySet<CalendarProperty>()
    override suspend fun deleteCalendar(path: String) {}
    override suspend fun share(path: String, user: String) {}
    override suspend fun put(path: String, ics: String, ifMatch: String?): String? {
        puts++
        onPut()
        if (refused) throw SyncError.Forbidden(path)
        return "\"${++etag}\""
    }
    override suspend fun move(path: String, destination: String, ifMatch: String?) {}
    override suspend fun delete(path: String, ifMatch: String?) {}
}
