package app.todotim.android.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Server settings shown in Settings. The password is write-only for the UI. */
data class SyncSettings(
    /** CalDAV server URL, e.g. `https://cloud.example.com/remote.php/dav/`. */
    val serverUrl: String = "",
    val username: String = "",
    val hasPassword: Boolean = false,
)

/** Where Settings reads and saves the server settings. The real one keeps the password in the Android Keystore. */
interface SyncSettingsStore {
    val settings: StateFlow<SyncSettings>

    /** Saves URL and username; [password] null keeps the stored one. */
    fun save(serverUrl: String, username: String, password: String?)
}

/** Keeps settings in memory only. TODO: replace with persistent, Keystore-backed storage. */
class InMemorySyncSettingsStore : SyncSettingsStore {
    private val state = MutableStateFlow(SyncSettings())
    override val settings: StateFlow<SyncSettings> = state.asStateFlow()

    override fun save(serverUrl: String, username: String, password: String?) {
        state.value = SyncSettings(
            serverUrl = serverUrl.trim(),
            username = username.trim(),
            hasPassword = if (password != null) password.isNotEmpty() else state.value.hasPassword,
        )
    }
}
