package app.todotim.core.dav

/** Sync and network errors, with user-facing messages (mirrors `SyncError` in the Swift TodoCore). */
sealed class SyncError(message: String) : Exception(message) {
    data class InvalidURL(val url: String) : SyncError("Invalid server URL “$url”. $URL_HINT")
    data object Unauthorized : SyncError("Wrong username or app password")
    data class Forbidden(val path: String) : SyncError("Access denied to “${path.ifEmpty { "/" }}”")
    data object BaseNotFound : SyncError("Server URL not found. $URL_HINT")
    data class NotFound(val path: String) : SyncError("Not found on server: “$path”")
    data object NotCalDAV : SyncError("This URL is not a CalDAV server. $URL_HINT")
    data class PreconditionFailed(val path: String) : SyncError("“$path” was changed by another device during sync")
    data class Conflict(val path: String) : SyncError("Could not write “$path”: its calendar does not exist")

    /** MKCALENDAR found something at the path that is not one of the user's task lists (for example a
     *  deleted calendar still in Nextcloud's trash bin). */
    data class CalendarExists(val path: String) : SyncError(
        "Could not create the list “$path”: something with that name already exists on the server. If you deleted it " +
            "in Nextcloud, empty it from the trash bin (Calendar › Trash bin).",
    )

    data object InsufficientStorage : SyncError("The server is out of storage space")

    /** 429. Nextcloud limits calendar creation (by default 10 per hour, and 30 calendars and subscriptions per user). */
    data class RateLimited(val path: String) : SyncError(
        "The server refused “$path” for now (too many requests). Nextcloud allows 10 new lists per hour and 30 in " +
            "total by default; the rest follow in later syncs.",
    )

    data class Http(val status: Int, val path: String) :
        SyncError("Server returned HTTP $status for “${path.ifEmpty { "/" }}”")

    data class Network(val description: String) : SyncError(description)
    data class BadRemoteData(val path: String, val reason: String) : SyncError("Could not read “$path” from the server: $reason")
    data object MissingPassword : SyncError("No app password saved. Enter it in Settings.")
    data object TooManyConflicts : SyncError("Sync kept conflicting with changes from another device. It will retry.")

    /** The server URL uses plain http:// for a host other than localhost. */
    data class InsecureURL(val url: String) : SyncError(
        "“$url” uses http://. TodoTim only sends your password over https:// (http:// is allowed for localhost " +
            "only). Use the https:// address of your server.",
    )

    /** A remote path with empty, "." or ".." segments, or one that would leave the server URL. */
    data class InvalidPath(val path: String) : SyncError("Refused to use the unsafe remote path “$path”")

    /** The server redirected outside the configured server URL (other scheme, host, port or path). */
    data class RedirectRejected(val target: String) : SyncError(
        "The server redirected to “$target”, outside the configured server URL. Check the server URL in Settings " +
            "(use the final https:// address).",
    )

    /** Discovery found the principal or calendar home on another origin than the server URL (as iCloud does);
     *  TodoTim does not follow it. */
    data class OtherServer(val target: String) : SyncError(
        "The server says your calendars are at “$target”, on another server. TodoTim only sends your password to " +
            "the server URL in Settings. If you trust that server, use its address as the server URL.",
    )

    /** The server has no Nextcloud-style sharing (`share_with`). */
    data object SharingUnsupported :
        SyncError("this server does not support sharing lists (share_with works with Nextcloud)")

    /** Remote data exceeds a `SyncLimits` bound. */
    data class LimitExceeded(val what: String) : SyncError("The data on the server is too large to sync safely: $what")

    /** Errors about one list or task (rather than the connection), which sync reports and skips. */
    val isPerResource: Boolean
        get() = when (this) {
            is CalendarExists, is Forbidden, is Conflict, is Http, is BadRemoteData, is RateLimited -> true
            else -> false
        }

    companion object {
        /** What a server URL looks like, for messages. */
        const val URL_HINT = "Use the address of your CalDAV server, for example https://cloud.example.com/remote.php/dav/ " +
            "for Nextcloud or https://dav.example.com/ for Radicale."
    }
}
