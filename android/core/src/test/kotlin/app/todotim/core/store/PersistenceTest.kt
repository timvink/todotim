package app.todotim.core.store

import app.todotim.core.Priority
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.LocalDate

class PersistenceTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun roundTrips() = runTest {
        val dir = tmp.newFolder()
        val store = TodoStore()
        val p = store.addTask("Milk", due = LocalDate.of(2027, 1, 2), priority = Priority.P2, labels = listOf("home"))
        store.addTask("Sub", parentId = p.id)
        val persistence = Persistence(dir, dispatcher = Dispatchers.Unconfined)
        persistence.flush(store)
        assertFalse(File(dir, "db.json.tmp").exists())
        val loaded = Persistence(dir).load()
        assertEquals(store.database.value, loaded)
        assertEquals(LocalDate.of(2027, 1, 2), TodoStore(loaded).snapshot.value.task(p.id)!!.due)
    }

    @Test fun missingFileIsAnEmptyDatabase() {
        assertEquals(Database(), Persistence(tmp.newFolder()).load())
    }

    @Test fun corruptFileIsMovedAsideNotOverwritten() = runTest {
        val dir = tmp.newFolder()
        File(dir, "db.json").writeText("{\"tasks\": [oops")
        val persistence = Persistence(dir, dispatcher = Dispatchers.Unconfined)
        val db = persistence.load()
        assertEquals(Database(), db)
        val aside = persistence.movedAside
        assertNotNull(aside)
        assertTrue(aside!!.name.startsWith("db.json.corrupt-"))
        assertEquals("{\"tasks\": [oops", aside.readText())
        val store = TodoStore(db)
        store.addTask("New")
        persistence.flush(store)
        assertEquals("{\"tasks\": [oops", aside.readText())
        assertEquals(store.database.value, Persistence(dir).load())
    }

    @Test fun savesAreCoalesced() {
        val dir = tmp.newFolder()
        val dispatcher = StandardTestDispatcher()
        val scope = TestScope(dispatcher)
        val store = TodoStore()
        val persistence = Persistence(dir, debounceMillis = 500, dispatcher = dispatcher)
        val job = persistence.attach(store, scope)
        scope.runCurrent()
        val file = File(dir, "db.json")
        file.delete()
        store.addTask("A")
        scope.advanceTimeBy(200)
        store.addTask("B")
        scope.advanceTimeBy(200)
        scope.runCurrent()
        assertFalse(file.exists())
        scope.advanceTimeBy(400)
        scope.runCurrent()
        assertTrue(file.exists())
        assertEquals(2, Persistence(dir).load().tasks.size)
        job.cancel()
    }

    /** Makes every write fail (the temp file's name is taken by a non-empty directory) until [unblock]. */
    private fun block(dir: File): File = File(dir, "db.json.tmp").apply { mkdirs(); File(this, "x").writeText("x") }

    private fun unblock(blocker: File) {
        blocker.deleteRecursively()
    }

    @Test fun aFailedSaveIsReportedKeptAndRetried() {
        val dir = tmp.newFolder()
        val dispatcher = StandardTestDispatcher()
        val scope = TestScope(dispatcher)
        val store = TodoStore()
        val persistence = Persistence(dir, debounceMillis = 500, dispatcher = dispatcher)
        val blocker = block(dir)
        val job = persistence.attach(store, scope, retryMillis = 1_000)
        store.addTask("A")
        scope.advanceTimeBy(600)
        scope.runCurrent()
        assertTrue(job.isActive) // the failure did not end the saving
        assertNotNull(persistence.saveError.value)
        assertFalse(File(dir, "db.json").exists())
        unblock(blocker)
        scope.advanceTimeBy(1_100)
        scope.runCurrent()
        assertEquals(null, persistence.saveError.value)
        assertEquals(store.database.value, Persistence(dir).load())
        job.cancel()
    }

    @Test fun flushQuietlyReportsInsteadOfThrowing() = runTest {
        val dir = tmp.newFolder()
        val store = TodoStore()
        store.addTask("A")
        val persistence = Persistence(dir, dispatcher = Dispatchers.Unconfined)
        val blocker = block(dir)
        assertFalse(persistence.flushQuietly(store))
        assertNotNull(persistence.saveError.value)
        unblock(blocker)
        assertTrue(persistence.flushQuietly(store))
        assertEquals(null, persistence.saveError.value)
    }

    @Test fun aStaleSaveNeverOverwritesANewerWrite() = runTest {
        val dir = tmp.newFolder()
        val store = TodoStore()
        val persistence = Persistence(dir, dispatcher = Dispatchers.Unconfined)
        store.addTask("A")
        val older = store.database.value // what a debounced save captured
        store.addTask("B")
        persistence.flush(store)
        persistence.save(older) // the debounced save resumes late
        assertEquals(store.database.value, Persistence(dir).load())
    }
}
