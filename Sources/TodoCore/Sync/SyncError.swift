import Foundation

public enum SyncError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case unauthorized
    case forbidden(String)
    case baseNotFound
    case notFound(String)
    case notCalDAV
    case preconditionFailed(String)
    case conflict(String)
    /// MKCALENDAR found something at the path that is not one of the user's task lists (for
    /// example a deleted calendar still in Nextcloud's trash bin).
    case calendarExists(String)
    case insufficientStorage
    /// 429. Nextcloud limits calendar creation (by default 10 per hour, and 30 calendars and
    /// subscriptions per user).
    case rateLimited(String)
    case http(status: Int, path: String)
    case network(String)
    case badRemoteData(path: String, reason: String)
    case missingPassword
    case tooManyConflicts
    /// The server URL uses plain http:// for a host other than localhost.
    case insecureURL(String)
    /// A remote path with empty, "." or ".." segments, or one that would leave the server URL.
    case invalidPath(String)
    /// The server redirected outside the configured server URL (other scheme, host, port or path).
    case redirectRejected(String)
    /// Discovery found the principal or calendar home on another origin than the server URL (as
    /// iCloud does); TodoTim does not follow it.
    case otherServer(String)
    /// The server has no Nextcloud-style sharing (`share_with`).
    case sharingUnsupported
    /// Remote data exceeds a `SyncLimits` bound.
    case limitExceeded(String)

    /// Errors about one list or task (rather than the connection), which sync reports and skips.
    var isPerResource: Bool {
        switch self {
        case .calendarExists, .forbidden, .conflict, .http, .badRemoteData, .rateLimited: true
        default: false
        }
    }

    /// What a server URL looks like, for messages.
    static let urlHint = "Use the address of your CalDAV server, for example https://cloud.example.com/remote.php/dav/ "
        + "for Nextcloud or https://dav.example.com/ for Radicale."

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s):
            return "Invalid server URL “\(s)”. \(Self.urlHint)"
        case .unauthorized:
            return "Wrong username or app password"
        case .forbidden(let p):
            return "Access denied to “\(p.isEmpty ? "/" : p)”"
        case .baseNotFound:
            return "Server URL not found. \(Self.urlHint)"
        case .notFound(let p):
            return "Not found on server: “\(p)”"
        case .notCalDAV:
            return "This URL is not a CalDAV server. \(Self.urlHint)"
        case .preconditionFailed(let p):
            return "“\(p)” was changed by another device during sync"
        case .conflict(let p):
            return "Could not write “\(p)”: its calendar does not exist"
        case .calendarExists(let p):
            return "Could not create the list “\(p)”: something with that name already exists on the server. If you deleted it in Nextcloud, empty it from the trash bin (Calendar › Trash bin)."
        case .insufficientStorage:
            return "The server is out of storage space"
        case .rateLimited(let p):
            return "The server refused “\(p)” for now (too many requests). Nextcloud allows 10 new lists per hour and 30 in total by default; the rest follow in later syncs. An admin can raise the limits with occ config:app:set dav rateLimitCalendarCreation / maximumCalendarsSubscriptions."
        case .http(let status, let p):
            return "Server returned HTTP \(status) for “\(p.isEmpty ? "/" : p)”"
        case .network(let msg):
            return msg
        case .badRemoteData(let p, let reason):
            return "Could not read “\(p)” from the server: \(reason)"
        case .missingPassword:
            return "No app password saved. Enter it in Settings."
        case .tooManyConflicts:
            return "Sync kept conflicting with changes from another device. It will retry."
        case .insecureURL(let s):
            return "“\(s)” uses http://. TodoTim only sends your password over https:// (http:// is allowed for localhost only). Use the https:// address of your server."
        case .invalidPath(let p):
            return "Refused to use the unsafe remote path “\(p)”"
        case .redirectRejected(let target):
            return "The server redirected to “\(target)”, outside the configured server URL. Check the server URL in Settings (use the final https:// address)."
        case .sharingUnsupported:
            return "this server does not support sharing lists (share_with works with Nextcloud)"
        case .otherServer(let target):
            return "The server says your calendars are at “\(target)”, on another server. TodoTim only sends your password to the server URL in Settings. If you trust that server, use its address as the server URL."
        case .limitExceeded(let what):
            return "The data on the server is too large to sync safely: \(what)"
        }
    }
}
