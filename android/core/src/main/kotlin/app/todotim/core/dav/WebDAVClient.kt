package app.todotim.core.dav

import app.todotim.core.SyncLimits
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Credentials
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.Buffer
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.random.Random

/** A WebDAV response with the body read (bounded) and the ETag normalized. */
class DAVResponse(
    val status: Int,
    val data: ByteArray,
    val etag: String?,
    /** The `Location` header (of a redirect that was not followed). */
    val location: String?,
) {
    val text: String get() = data.toString(Charsets.UTF_8)
}

/**
 * HTTP client for a WebDAV server. [baseURL] is the allowed root, e.g. the DAV root
 * `https://host/remote.php/dav/`; paths passed to the methods are relative to it, not percent-encoded, and
 * are encoded per segment here. Uses Basic auth (an app password where the server has them).
 *
 * The security rules live here (docs/caldav.md, "Limits"): https only (except localhost), no requests,
 * redirects or hrefs outside [baseURL], no dot segments, and capped bodies. OkHttp never follows a redirect
 * itself; this class follows those inside [baseURL] one hop at a time (or returns them, see [followsRedirects]).
 *
 * [httpClient] is the base client (tests add an interceptor); the redirect and cookie settings are overridden.
 */
class WebDAVClient(
    serverURL: String,
    username: String,
    password: String,
    httpClient: OkHttpClient? = null,
) {
    val baseURL: HttpUrl = normalizedBaseURL(serverURL)
    private val authorization = Credentials.basic(username, password, Charsets.UTF_8)
    private val http: OkHttpClient = (httpClient ?: defaultHttpClient).newBuilder()
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    /** Largest accepted response body in bytes (discovery and tests lower it). */
    var maxResponseBytes: Long = SyncLimits.MAX_RESPONSE_BYTES

    /** Whether redirects inside [baseURL] are followed. When false, every redirect response is returned to the
     *  caller (with [DAVResponse.location]), which checks the target itself (discovery). */
    var followsRedirects: Boolean = true

    /** First delay before a request answered 423 (Locked) is sent again; doubled each time, with jitter. */
    var lockedRetryDelayMillis: Long = 50

    // region Paths

    /**
     * URL for a relative path; [collection] adds a trailing slash. Leading and trailing slashes are ignored;
     * empty, "." and ".." segments throw [SyncError.InvalidPath], and so does any result outside [baseURL].
     */
    fun url(path: String, collection: Boolean = false): HttpUrl {
        val trimmed = path.trim('/')
        var rel = ""
        if (trimmed.isNotEmpty()) {
            val encoded = trimmed.split('/').map { segment ->
                if (segment.isEmpty() || segment == "." || segment == "..") throw SyncError.InvalidPath(path)
                encodeSegment(segment)
            }
            rel = encoded.joinToString("/")
            if (collection) rel += "/"
        }
        val url = (baseURL.toString() + rel).toHttpUrlOrNull()
        if (url == null || !isWithin(url, baseURL)) throw SyncError.InvalidPath(path)
        return url
    }

    /**
     * The path of [href] (absolute or relative, percent-encoded, from a multistatus response) relative to
     * [baseURL], decoded, without leading or trailing slash. null when it is outside the base URL, on another
     * server, or has a segment that decodes to "/", "." or "..". Segments are compared decoded: servers may
     * percent-encode differently from the base URL.
     */
    fun relativePath(ofHref: String): String? {
        if (hasDotSegment(ofHref)) return null
        val url = baseURL.resolve(ofHref) ?: return null
        if (!isWithin(url, baseURL)) return null
        val base = decodedSegments(baseURL) ?: return null
        val segments = decodedSegments(url) ?: return null
        return segments.drop(base.size).joinToString("/")
    }

    /** Absolute URL string for [path], for the `Destination` header of MOVE. */
    fun absoluteString(path: String): String = url(path).toString()

    // endregion

    // region Requests

    /** Sends a request to [path] (relative to [baseURL]). [collection] adds a trailing slash. Any status is
     *  returned; callers map errors with [error]. */
    suspend fun send(
        method: String,
        path: String,
        collection: Boolean = false,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray? = null,
    ): DAVResponse = send(method, url(path, collection), headers, body)

    /**
     * Sends a request to the absolute [url] (no query or fragment), which must be inside [baseURL]; otherwise
     * throws [SyncError.InvalidPath] without sending anything. A 423 (Locked) is sent again up to
     * [LOCKED_RETRIES] times. With [followsRedirects], a redirect inside [baseURL] is followed (at most
     * [MAX_REDIRECTS]) and any other one is refused with [SyncError.RedirectRejected].
     */
    suspend fun send(
        method: String,
        url: HttpUrl,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray? = null,
    ): DAVResponse {
        if (!isWithin(url, baseURL) || url.query != null || url.fragment != null) {
            throw SyncError.InvalidPath(displayString(url))
        }
        var target = url
        var currentMethod = method
        var currentBody = body
        repeat(MAX_REDIRECTS + 1) {
            val r = sendRetryingLocked(currentMethod, target, headers, currentBody)
            if (!followsRedirects || r.status !in REDIRECT_STATUSES) return r
            val location = r.location ?: return r
            val next = resolveHref(location, target)
            if (next == null || !isWithin(next, baseURL)) {
                throw SyncError.RedirectRejected(next?.let(::displayString) ?: "?")
            }
            if (r.status == 303) {
                currentMethod = "GET"
                currentBody = null
            }
            target = next
        }
        throw SyncError.BadRemoteData(displayString(url), "more than $MAX_REDIRECTS redirects")
    }

    private suspend fun sendRetryingLocked(
        method: String,
        url: HttpUrl,
        headers: Map<String, String>,
        body: ByteArray?,
    ): DAVResponse {
        val request = buildRequest(method, url, headers, body)
        var response = execute(request)
        var wait = lockedRetryDelayMillis
        var retries = 0
        while (response.status == 423 && retries < LOCKED_RETRIES) {
            delay((wait * Random.nextDouble(0.5, 1.5)).toLong())
            wait *= 2
            retries++
            response = execute(request)
        }
        return response
    }

    private fun buildRequest(method: String, url: HttpUrl, headers: Map<String, String>, body: ByteArray?): Request {
        val contentType = headers.entries.firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }?.value
        val requestBody = when {
            body != null -> body.toRequestBody(contentType?.toMediaTypeOrNull())
            method.uppercase() in METHODS_REQUIRING_BODY -> ByteArray(0).toRequestBody(contentType?.toMediaTypeOrNull())
            else -> null
        }
        val builder = Request.Builder().url(url).method(method, requestBody)
        for ((k, v) in headers) builder.header(k, v)
        builder.header("Authorization", authorization)
        builder.header("Cache-Control", "no-cache")
        return builder.build()
    }

    /** Sends [request] and reads at most [maxResponseBytes] of the body (also when the server sends no or a
     *  wrong Content-Length). Cancelling the coroutine cancels the call. */
    private suspend fun execute(request: Request): DAVResponse = suspendCancellableCoroutine { cont ->
        val call = http.newCall(request)
        cont.invokeOnCancellation { call.cancel() }
        val limit = maxResponseBytes
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                cont.resumeWithException(networkError(e))
            }

            override fun onResponse(call: Call, response: Response) {
                val result = runCatching { response.use { read(it, limit) } }
                result.fold(
                    onSuccess = { cont.resume(it) },
                    onFailure = { cont.resumeWithException(if (it is IOException) networkError(it) else it) },
                )
            }
        })
    }

    private fun read(response: Response, limit: Long): DAVResponse {
        val tooLarge = SyncError.LimitExceeded("a server response is larger than ${limit / 1024 / 1024} MB")
        val body = response.body
        if (body.contentLength() > limit) throw tooLarge
        val source = body.source()
        val buffer = Buffer()
        val out = ByteArrayOutputStream()
        while (true) {
            val n = source.read(buffer, 64L * 1024)
            if (n == -1L) break
            if (out.size() + buffer.size > limit) throw tooLarge
            buffer.copyTo(out)
            buffer.clear()
        }
        return DAVResponse(
            status = response.code,
            data = out.toByteArray(),
            etag = normalizeETag(response.header("ETag") ?: response.header("OC-ETag")),
            location = response.header("Location"),
        )
    }

    // endregion

    companion object {
        /** A request answered 423 (Locked) is sent again up to this many times. Xandikos locks its store while it
         *  writes and refuses concurrent writes that way. */
        const val LOCKED_RETRIES = 4

        /** Redirects followed inside the base URL before giving up. */
        const val MAX_REDIRECTS = 5

        private val REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)
        private val METHODS_REQUIRING_BODY = setOf("POST", "PUT", "PATCH", "PROPPATCH", "REPORT")

        /** Shared base client (one connection pool). No cookies, no cache, no authenticator. */
        val defaultHttpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .followRedirects(false)
                .followSslRedirects(false)
                .build()
        }

        /**
         * Trims whitespace, validates scheme and host and ensures a trailing slash. Plain http:// is accepted
         * only for localhost (127.0.0.1, ::1), so the password never travels unencrypted. URLs with credentials,
         * a query, a fragment or dot segments are rejected.
         */
        fun normalizedBaseURL(string: String): HttpUrl {
            var s = string.trim()
            if (s.isEmpty()) throw SyncError.InvalidURL(string)
            if (!s.endsWith("/")) s += "/"
            if (!s.contains("://") || hasDotSegment(s)) throw SyncError.InvalidURL(string)
            val url = s.toHttpUrlOrNull() ?: throw SyncError.InvalidURL(string)
            if (url.host.isEmpty() || url.username.isNotEmpty() || url.password.isNotEmpty() ||
                url.query != null || url.fragment != null || decodedSegments(url) == null
            ) {
                throw SyncError.InvalidURL(string)
            }
            if (url.scheme == "http" && !isLoopback(url.host)) throw SyncError.InsecureURL(string)
            return url
        }

        fun isLoopback(host: String): Boolean = host.lowercase() in setOf("localhost", "127.0.0.1", "::1", "[::1]")

        /** Whether [a] and [b] have the same origin: scheme, host and port (including the scheme's default). */
        fun isSameOrigin(a: HttpUrl, b: HttpUrl): Boolean = a.scheme == b.scheme && a.host == b.host && a.port == b.port

        /** The root of [url]'s origin: "scheme://host[:port]/". */
        fun originRoot(url: HttpUrl): HttpUrl =
            url.newBuilder().username("").password("").encodedPath("/").query(null).fragment(null).build()

        /** Whether [url] has the scheme, host and port of [base] and a path inside base's path. Paths are
         *  compared decoded: servers may percent-encode differently from the configured URL. */
        fun isWithin(url: HttpUrl, base: HttpUrl): Boolean {
            if (!isSameOrigin(url, base)) return false
            val baseSegments = decodedSegments(base) ?: return false
            val segments = decodedSegments(url) ?: return false
            return segments.size >= baseSegments.size && segments.subList(0, baseSegments.size) == baseSegments
        }

        /**
         * The decoded segments of [url]'s path, without the empty one a trailing slash adds; null when one decodes
         * to "/", "\", "." or "..", or an inner one is empty (`/dav//tim/` is not `/dav/tim/`).
         */
        fun decodedSegments(url: HttpUrl): List<String>? {
            val out = ArrayList<String>()
            val raw = url.pathSegments
            for ((i, s) in raw.withIndex()) {
                if (s.isEmpty()) {
                    if (i == raw.size - 1) continue
                    return null
                }
                if (s == "." || s == ".." || s.contains('/') || s.contains('\\')) return null
                out.add(s)
            }
            return out
        }

        /** [url] with its path segments encoded the way requests encode them, so that two spellings of the same
         *  location compare equal; [collection] adds a trailing slash. null for a URL with dot segments. */
        fun canonicalURL(url: HttpUrl, collection: Boolean): HttpUrl? {
            val segments = decodedSegments(url) ?: return null
            var path = segments.joinToString("/") { encodeSegment(it) }
            if (collection && path.isNotEmpty()) path += "/"
            return (originRoot(url).toString() + path).toHttpUrlOrNull()
        }

        /**
         * [href] resolved against [base]: an http(s) URL without credentials, query, fragment or dot segments
         * (literal or percent-encoded), or null. The origin is not checked here.
         */
        fun resolveHref(href: String, base: HttpUrl): HttpUrl? {
            val trimmed = href.trim()
            if (trimmed.isEmpty() || hasDotSegment(trimmed)) return null
            val url = base.resolve(trimmed) ?: return null
            if (url.host.isEmpty() || url.username.isNotEmpty() || url.password.isNotEmpty() ||
                url.query != null || url.fragment != null || decodedSegments(url) == null
            ) {
                return null
            }
            return url
        }

        /**
         * Whether the path of the raw URL or reference [s] has a segment that is, or percent-decodes to, "." or
         * "..", or that contains a backslash (raw or `%5C`). OkHttp resolves dot segments silently (also `%2E%2E`)
         * and reads "\" as "/", so such references are refused before parsing.
         */
        internal fun hasDotSegment(s: String): Boolean {
            if (s.contains('\\')) return true
            var rest = s.substringBefore('#').substringBefore('?')
            val scheme = rest.indexOf("://")
            if (scheme >= 0 && rest.substring(0, scheme).all { it.isLetterOrDigit() || it in "+-." }) {
                rest = rest.substring(scheme + 3)
                rest = if (rest.contains('/')) rest.substring(rest.indexOf('/')) else ""
            } else if (rest.startsWith("//")) {
                rest = rest.substring(2)
                rest = if (rest.contains('/')) rest.substring(rest.indexOf('/')) else ""
            }
            return rest.split('/').any { segment ->
                val decoded = percentDecode(segment) ?: return true
                decoded == "." || decoded == ".." || decoded.contains('\\')
            }
        }

        /** Percent-decodes [s] as UTF-8 ("+" stays "+"); null for a malformed escape. */
        internal fun percentDecode(s: String): String? {
            if (!s.contains('%')) return s
            val out = ByteArrayOutputStream()
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '%') {
                    if (i + 2 >= s.length) return null
                    val hi = Character.digit(s[i + 1], 16)
                    val lo = Character.digit(s[i + 2], 16)
                    if (hi < 0 || lo < 0) return null
                    out.write(hi * 16 + lo)
                    i += 3
                } else {
                    val end = s.indexOf('%', i).let { if (it < 0) s.length else it }
                    out.write(s.substring(i, end).toByteArray(Charsets.UTF_8))
                    i = end
                }
            }
            return out.toByteArray().toString(Charsets.UTF_8)
        }

        /** Characters allowed unescaped in a path segment (RFC 3986 pchar without "/" and ";"). */
        private const val SEGMENT_ALLOWED = "-._~!$&'()*+,=@"

        /** Percent-encodes one path segment (UTF-8). */
        internal fun encodeSegment(segment: String): String {
            val sb = StringBuilder()
            for (b in segment.toByteArray(Charsets.UTF_8)) {
                val c = b.toInt() and 0xFF
                val ch = c.toChar()
                if (c < 0x80 && (ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9' || ch in SEGMENT_ALLOWED)) {
                    sb.append(ch)
                } else {
                    sb.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 0xF])
                }
            }
            return sb.toString()
        }

        /** scheme://host[:port]/path (decoded, without trailing slash), without credentials, query or fragment. */
        fun displayString(url: HttpUrl): String {
            val host = if (url.host.contains(':')) "[${url.host}]" else url.host
            val port = if (url.port == HttpUrl.defaultPort(url.scheme)) "" else ":${url.port}"
            val segments = url.pathSegments.filter { it.isNotEmpty() }
            return "${url.scheme}://$host$port/" + segments.joinToString("/")
        }

        /**
         * Undoes what compressing reverse proxies do to a response's ETag, so it can be sent back in `If-Match`:
         * Caddy and Apache append "-gzip"/"-br"/"-zstd" inside the quotes, and nginx marks it weak (`W/`).
         * Without this, every update of a downloaded task fails with 412.
         */
        fun normalizeETag(etag: String?): String? {
            var e = etag?.trim() ?: return null
            if (e.isEmpty()) return null
            if (e.startsWith("W/")) e = e.substring(2)
            val quoted = e.length >= 2 && e.startsWith("\"") && e.endsWith("\"")
            var inner = if (quoted) e.substring(1, e.length - 1) else e
            for (suffix in listOf("-gzip", "-br", "-zstd", "-deflate")) {
                if (inner.endsWith(suffix)) {
                    inner = inner.dropLast(suffix.length)
                    break
                }
            }
            // A strong ETag is a quoted string (RFC 9110); some responses omit the quotes.
            return "\"$inner\""
        }

        /** The error for an unexpected HTTP [status] of a request to [path] ("" is the server URL itself). */
        fun error(status: Int, path: String): SyncError = when (status) {
            401 -> SyncError.Unauthorized
            403 -> SyncError.Forbidden(path)
            404 -> if (path.isEmpty()) SyncError.BaseNotFound else SyncError.NotFound(path)
            409 -> SyncError.Conflict(path)
            412 -> SyncError.PreconditionFailed(path)
            429 -> SyncError.RateLimited(path)
            507 -> SyncError.InsufficientStorage
            else -> SyncError.Http(status, path)
        }

        internal fun networkError(e: IOException): SyncError = SyncError.Network(
            when (e) {
                is UnknownHostException -> "Server not found. Check the server URL."
                is ConnectException, is NoRouteToHostException -> "Could not connect to the server"
                is SocketTimeoutException -> "The server did not respond in time"
                is SSLException -> "Secure connection to the server failed (certificate problem)"
                is InterruptedIOException -> "The server did not respond in time"
                else -> e.message ?: "Network error"
            },
        )
    }
}
