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
}
