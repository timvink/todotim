package app.todotim.core.store

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Stores the [Database] as `db.json` in [directory] (the app's files directory).
 *
 * Saves are atomic (a temp file, synced, then renamed over the old one) and coalesced: [attach] saves
 * [debounceMillis] after the last change, on [dispatcher]. [flush] saves at once (after a sync, or when the app goes
 * to the background). A file that cannot be decoded is moved aside as `db.json.corrupt-<UTC time>`, never
 * overwritten, and the store starts empty.
 */
class Persistence(
    val directory: File,
    private val debounceMillis: Long = 500,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    val file: File get() = File(directory, FILE_NAME)

    /** Where the last [load] moved a corrupt file, if it did. */
    var movedAside: File? = null
        private set

    private val writeLock = Mutex()
    @Volatile private var lastSaved: Database? = null
    /** The store [attach] and [flush] save; [save] writes its newest database, so writes never go back in time. */
    @Volatile private var source: TodoStore? = null

    /**
     * The stored database; an empty one when there is none. A corrupt file is moved aside ([movedAside]).
     * Throws [IOException] when the file exists but cannot be read (so it is not mistaken for missing).
     */
    fun load(): Database {
        val f = file
        if (!f.exists()) return Database()
        val text = f.readText()
        val db = try {
            json.decodeFromString(Database.serializer(), text)
        } catch (e: SerializationException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }
        if (db == null) {
            val stamp = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC).format(Instant.now())
            var target = File(directory, "$FILE_NAME.corrupt-$stamp")
            var n = 1
            while (target.exists()) target = File(directory, "$FILE_NAME.corrupt-$stamp-${n++}")
            Files.move(f.toPath(), target.toPath())
            movedAside = target
            return Database()
        }
        lastSaved = db
        return db
    }

    /** Saves [store]'s database [debounceMillis] after each burst of changes, in [scope], until the scope ends. */
    @OptIn(FlowPreview::class)
    fun attach(store: TodoStore, scope: CoroutineScope): Job {
        source = store
        return scope.launch(dispatcher) {
            store.database.debounce(debounceMillis).collect { save(it) }
        }
    }

    /** Saves [store]'s current database now, unless it is already saved. */
    suspend fun flush(store: TodoStore) {
        source = store
        save(store.database.value)
    }

    /**
     * Writes [db] atomically, unless it is the database last written. After [attach] or [flush], the store's
     * current database is written instead (read under the write lock), so a save that captured [db] and then
     * waited never overwrites a newer database another save already wrote.
     */
    suspend fun save(db: Database) = withContext(dispatcher) {
        writeLock.withLock {
            val latest = source?.database?.value ?: db
            if (latest == lastSaved) return@withLock
            write(latest)
            lastSaved = latest
        }
    }

    private fun write(db: Database) {
        directory.mkdirs()
        val tmp = File(directory, "$FILE_NAME.tmp")
        FileOutputStream(tmp).use { out ->
            out.write(json.encodeToString(Database.serializer(), db).toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
        try {
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (e: AtomicMoveNotSupportedException) {
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    companion object {
        const val FILE_NAME = "db.json"

        internal val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
            allowSpecialFloatingPointValues = true
        }
    }
}
