package app.todotim.core.dav

import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okio.Buffer
import java.util.Collections

/** A request as the client sent it, with the URL before [TestServer] redirected it to the mock server. */
class SentRequest(val url: String, val method: String, val headers: Headers, val body: String) {
    fun header(name: String): String? = headers[name]
}

/** A canned answer: status, headers, body. [chunked] sends the body without Content-Length. */
class Reply(val status: Int, val headers: Map<String, String> = emptyMap(), val body: ByteArray = ByteArray(0), val chunked: Boolean = false) {
    constructor(status: Int, headers: Map<String, String> = emptyMap(), body: String) : this(status, headers, body.toByteArray())
}

/**
 * A [MockWebServer] that answers every request through [handler], whatever host the client addressed: the
 * [client] sends all requests to the mock server and passes the original URL in a header. So tests can use
 * `https://cloud.example.com/…` URLs while the bytes travel over a real local HTTP connection.
 */
class TestServer : AutoCloseable {
    private val server = MockWebServer()
    val requests: MutableList<SentRequest> = Collections.synchronizedList(ArrayList())

    @Volatile
    var handler: (SentRequest) -> Reply = { Reply(500) }

    val client: OkHttpClient

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val original = request.headers[ORIGINAL_URL] ?: request.url.toString()
                val headers = request.headers.newBuilder().removeAll(ORIGINAL_URL).build()
                val sent = SentRequest(original, request.method, headers, request.body?.utf8() ?: "")
                requests.add(sent)
                val reply = handler(sent)
                val builder = MockResponse.Builder().code(reply.status)
                for ((k, v) in reply.headers) builder.addHeader(k, v)
                if (reply.chunked) builder.chunkedBody(Buffer().write(reply.body), 8192) else builder.body(Buffer().write(reply.body))
                return builder.build()
            }
        }
        server.start()
        val target = server.url("/")
        client = OkHttpClient.Builder()
            .addInterceptor { chain ->
                val req = chain.request()
                val rewritten = req.url.newBuilder().scheme("http").host(target.host).port(target.port).build()
                chain.proceed(req.newBuilder().url(rewritten).header(ORIGINAL_URL, req.url.toString()).build())
            }
            .build()
    }

    val urls: List<String> get() = synchronized(requests) { requests.map { it.url } }

    fun reset() = requests.clear()

    override fun close() = server.close()

    fun webdav(serverURL: String = "https://cloud.example.com/remote.php/dav/", user: String = "tim", password: String = "app-pass") =
        WebDAVClient(serverURL, user, password, client)

    companion object {
        const val ORIGINAL_URL = "X-Test-Original-URL"
    }
}

fun String.toUrl() = toHttpUrl()
