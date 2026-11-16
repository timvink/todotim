package app.todotim.core.sync

import app.todotim.core.dav.CalDAVClient
import app.todotim.core.dav.CalDAVServer
import app.todotim.core.dav.CalendarHome
import app.todotim.core.dav.SyncError
import app.todotim.core.dav.WebDAVClient
import app.todotim.core.store.Account
import app.todotim.core.store.Persistence
import app.todotim.core.store.TodoStore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient
import java.time.ZoneId

/** The account to sync with. The password is the app's to store (and pass to [SyncController.syncNow]). */
data class SyncSettings(val serverUrl: String, val username: String)

/** What a sync needs. An empty [password] makes the sync fail with [SyncError.MissingPassword]. */
data class Credentials(val settings: SyncSettings, val password: String)

/**
 * Runs syncs for one [TodoStore], one at a time: connects with the cached calendar home (discovering it only the
 * first time, for another account, or when the home answers 404/403), syncs, records the home, and saves the
 * database ([persistence]) before returning.
 *
 * [connect] makes the server for a home (null: discover); tests replace it.
 */
class SyncController(
    private val store: TodoStore,
    private val persistence: Persistence? = null,
    private val zone: ZoneId = ZoneId.systemDefault(),
    private val httpClient: OkHttpClient? = null,
    private val connect: suspend (SyncSettings, String, CalendarHome?) -> CalDAVServer = { s, password, home ->
        CalDAVClient.connect(s.serverUrl, s.username, password, home, httpClient)
    },
) {
    private val running = Mutex()

    /** Syncs now; waits for a sync already running. Throws [SyncError] when the sync could not run at all. */
    suspend fun syncNow(settings: SyncSettings, password: String, now: () -> Long = System::currentTimeMillis): SyncResult =
        syncNow({ Credentials(settings, password) }, now)!!

    /**
     * Syncs with the account [credentials] gives, read once the sync running before has finished, so a sync never
     * runs with an account that Settings replaced while it waited. Returns null when there is no account.
     *
     * For another account, the store is reset ([TodoStore.resetAccount]) only after the new server answered (its
     * calendars listed): a mistyped URL or username never drops local data.
     */
    suspend fun syncNow(credentials: suspend () -> Credentials?, now: () -> Long = System::currentTimeMillis): SyncResult? =
        running.withLock {
            val (settings, password) = credentials() ?: return@withLock null
            if (password.isEmpty()) throw SyncError.MissingPassword
            val account = Account(normalizedServerUrl(settings.serverUrl), settings.username.trim())
            val stored = store.database.value.account
            val sameAccount = stored != null && Account(normalizedServerUrl(stored.serverUrl), stored.username) == account
            val cached = if (sameAccount) store.database.value.home else null
            try {
                var server = connect(settings, password, cached)
                if (!sameAccount) {
                    server.calendars() // Discovery can fall back to a guessed home: check it before dropping anything.
                    store.resetAccount(account)
                }
                val result = try {
                    store.setHome(server.calendarHome)
                    CalDAVSync(store, server, zone).run(now())
                } catch (e: SyncError) {
                    // The stored home moved or went away: discover it again, once.
                    if (cached == null || !isHomeGone(e, server)) throw e
                    server = connect(settings, password, null)
                    store.setHome(server.calendarHome)
                    CalDAVSync(store, server, zone).run(now())
                }
                result
            } finally {
                // A failed save is reported by [persistence] and retried; it must not replace the sync's outcome.
                persistence?.flushQuietly(store)
            }
        }

    companion object {
        /**
         * [serverUrl] as the sync uses it ([WebDAVClient.normalizedBaseURL]: trimmed, trailing slash, lowercase
         * host, no default port), so spellings of one server are one account. A URL the sync refuses is only trimmed.
         */
        fun normalizedServerUrl(serverUrl: String): String = try {
            WebDAVClient.normalizedBaseURL(serverUrl).toString()
        } catch (e: SyncError) {
            serverUrl.trim()
        }
    }

    private fun isHomeGone(e: SyncError, server: CalDAVServer): Boolean = when (e) {
        is SyncError.NotFound -> e.path.trimEnd('/') == server.home.trimEnd('/')
        is SyncError.Forbidden -> e.path.trimEnd('/') == server.home.trimEnd('/')
        is SyncError.BaseNotFound -> server.home.isEmpty()
        else -> false
    }
}
