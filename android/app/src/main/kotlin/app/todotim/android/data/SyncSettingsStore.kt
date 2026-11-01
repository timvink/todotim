package app.todotim.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import app.todotim.core.dav.SyncError
import app.todotim.core.dav.WebDAVClient
import app.todotim.core.sync.SyncSettings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Server settings shown in Settings. The password is write-only for the UI. */
data class ServerSettings(
    /** CalDAV server URL, e.g. `https://cloud.example.com/remote.php/dav/`. */
    val serverUrl: String = "",
    val username: String = "",
    val hasPassword: Boolean = false,
) {
    val isConfigured: Boolean get() = serverUrl.isNotBlank() && username.isNotBlank()
}

/** What a sync needs. An empty [password] makes the sync fail with [SyncError.MissingPassword]. */
data class Credentials(val settings: SyncSettings, val password: String)

/**
 * Checks what Settings is about to save; returns the message to show, or null when it is fine. The URL rules are
 * the sync's own ([WebDAVClient.normalizedBaseURL]: https, or http:// for localhost only).
 */
fun validateServerSettings(serverUrl: String, username: String): String? {
    try {
        WebDAVClient.normalizedBaseURL(serverUrl)
    } catch (e: SyncError) {
        return e.message
    }
    if (username.isBlank()) return "Enter your username."
    return null
}

/**
 * Server URL and username in SharedPreferences; the password encrypted with an AES-GCM key that lives in the
 * Android Keystore (it never leaves the device; the preferences hold only IV and ciphertext). Backups and device
 * transfer are off for the app, and a restored ciphertext would be unreadable without the key anyway.
 */
class SyncSettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val state = MutableStateFlow(read())
    val settings: StateFlow<ServerSettings> = state.asStateFlow()

    /**
     * Saves URL and username, and the password unless it is null (null keeps the stored one).
     * Throws [IllegalArgumentException] with a message for the user when [validateServerSettings] refuses them.
     */
    fun save(serverUrl: String, username: String, password: String?) {
        validateServerSettings(serverUrl, username)?.let { throw IllegalArgumentException(it) }
        val edit = prefs.edit()
            .putString(KEY_URL, serverUrl.trim())
            .putString(KEY_USER, username.trim())
        if (password != null) {
            if (password.isEmpty()) edit.remove(KEY_PASSWORD) else edit.putString(KEY_PASSWORD, PasswordCipher.encrypt(password))
        }
        edit.apply()
        state.value = read()
    }

    /** The account to sync with, or null when no server is set up. Decrypts the password (call off the main thread). */
    fun credentials(): Credentials? {
        val s = state.value
        if (!s.isConfigured) return null
        val password = prefs.getString(KEY_PASSWORD, null)?.let(PasswordCipher::decrypt).orEmpty()
        return Credentials(SyncSettings(s.serverUrl, s.username), password)
    }

    private fun read() = ServerSettings(
        serverUrl = prefs.getString(KEY_URL, null).orEmpty(),
        username = prefs.getString(KEY_USER, null).orEmpty(),
        hasPassword = prefs.contains(KEY_PASSWORD),
    )

    private companion object {
        const val PREFS = "sync"
        const val KEY_URL = "server_url"
        const val KEY_USER = "username"
        const val KEY_PASSWORD = "password"
    }
}

/** AES-256-GCM with a non-exportable Android Keystore key. Stored form: base64(iv) ":" base64(ciphertext+tag). */
private object PasswordCipher {
    private const val ALIAS = "todotim-sync-password"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return b64(cipher.iv) + ":" + b64(sealed)
    }

    /** null when the value is damaged or the key is gone (e.g. after a restore); Settings then asks again. */
    fun decrypt(stored: String): String? = try {
        val (iv, sealed) = stored.split(':', limit = 2).map { Base64.decode(it, Base64.NO_WRAP) }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        String(cipher.doFinal(sealed), Charsets.UTF_8)
    } catch (e: GeneralSecurityException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    } catch (e: IndexOutOfBoundsException) {
        null
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
}
