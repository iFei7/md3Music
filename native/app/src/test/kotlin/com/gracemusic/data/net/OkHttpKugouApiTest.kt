package com.gracemusic.data.net

import com.gracemusic.kugou.KugouServerGateway
import com.gracemusic.kugou.KugouServerManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration.Companion.milliseconds

/**
 * [OkHttpKugouApi] MockWebServer 单测（纯 JVM）。
 *
 * 服务器端口注入经 [KugouServerEndpoint] seam（MockWebServer 端口冒充
 * Rust 服务器监听端口），生命周期链路（懒启动 / 就绪等待）用真
 * [KugouServerManager] + FakeGateway 覆盖（模式同 KugouServerManagerTest）。
 *
 * 方法名即断言；响应体均为酷狗 /song/url 真实结构的裁剪版。
 */
class OkHttpKugouApiTest {

    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /** 默认 API：端口 seam 直接指向 MockWebServer。 */
    private fun api(endpoint: KugouServerEndpoint = KugouServerEndpoint { server.port }): OkHttpKugouApi =
        OkHttpKugouApi(endpoint)

    private fun respond(body: String, status: Int = 200): MockResponse =
        MockResponse().setResponseCode(status).setBody(body)

    /** 标准成功响应：data 层带 url（Rust stamp_quality 已回写 quality）。 */
    private fun okSongUrl(
        url: String = "http://cdn.example.com/audio.mp3",
        extra: String = "",
    ): String = """{"data":{"url":["$url"],"quality":"320"$extra}}"""

    private fun recordedPath(request: RecordedRequest): String = request.path.orEmpty()

    private fun query(request: RecordedRequest, key: String): String? =
        request.requestUrl?.queryParameter(key)

    private val songRequest = SongUrlRequest(
        hash = "ABCdef123",
        quality = "320",
        albumId = null,
        albumAudioId = null,
        downgrade = false,
    )

    // ------------------------------------------------------------------
    // 参数编码与透传
    // ------------------------------------------------------------------

    @Test
    fun `songUrl builds segment path and passes params with lowercased hash`() = runTest {
        server.enqueue(respond(okSongUrl()))
        val result = api().songUrl(
            songRequest.copy(
                hash = "ABCdef123",
                quality = "flac",
                albumId = "123",
                albumAudioId = "456",
                ppageId = "356753938",
            ),
        )

        assertTrue(result is SongUrlAttempt.Resolved)
        val request = server.takeRequest()
        // 路径必须逐段拼接：整段 "song/url" 会被编码成 %2F → 404
        assertTrue(recordedPath(request).startsWith("/song/url?"))
        assertEquals("abcdef123", query(request, "hash"))
        assertEquals("flac", query(request, "quality"))
        assertEquals("123", query(request, "album_id"))
        assertEquals("456", query(request, "album_audio_id"))
        assertEquals("356753938", query(request, "ppage_id"))
    }

    @Test
    fun `songUrl omits blank album ids and absent ppageId`() = runTest {
        server.enqueue(respond(okSongUrl()))
        api().songUrl(songRequest.copy(albumId = "", albumAudioId = "", ppageId = null))

        val request = server.takeRequest()
        assertNull(query(request, "album_id"))
        assertNull(query(request, "album_audio_id"))
        assertNull(query(request, "ppage_id"))
    }

    // ------------------------------------------------------------------
    // 响应别名解析
    // ------------------------------------------------------------------

    @Test
    fun `play_url alias list first is used when url missing`() = runTest {
        server.enqueue(
            respond("""{"data":{"play_url":["http://cdn.example.com/a.flac","http://backup"],"quality":"flac"}}"""),
        )

        val result = api().songUrl(songRequest.copy(quality = "flac"))

        val resolved = result as SongUrlAttempt.Resolved
        assertEquals("http://cdn.example.com/a.flac", resolved.url)
        assertEquals("flac", resolved.quality)
    }

    @Test
    fun `url path quality falls back to requested quality when server omits it`() = runTest {
        server.enqueue(respond("""{"data":{"url":["http://cdn.example.com/a.mp3"]}}"""))

        val result = api().songUrl(songRequest.copy(quality = "320"))

        assertEquals("320", (result as SongUrlAttempt.Resolved).quality)
    }

    @Test
    fun `missing data layer falls back to root object`() = runTest {
        server.enqueue(
            respond("""{"url":["http://cdn.example.com/a.mp3"],"quality":"high","bitRate":320,"fileSize":10485760}"""),
        )

        val result = api().songUrl(songRequest.copy(quality = "high"))

        val resolved = result as SongUrlAttempt.Resolved
        assertEquals("http://cdn.example.com/a.mp3", resolved.url)
        assertEquals("high", resolved.quality)
        assertEquals(320L, resolved.bitRate)
        assertEquals(10485760L, resolved.fileSize)
    }

    @Test
    fun `isTrial is true when fail_process contains buy`() = runTest {
        // quality=128 时不触发 buy→standard 重试，url 检查可直达
        server.enqueue(respond(okSongUrl(extra = ""","fail_process":["buy"]""")))

        val result = api().songUrl(songRequest.copy(quality = "128"))

        assertTrue((result as SongUrlAttempt.Resolved).isTrial)
    }

    @Test
    fun `isTrial is true when fileSize is under 200KiB and positive`() = runTest {
        server.enqueue(
            respond("""{"data":{"url":["http://cdn.example.com/a.mp3"],"quality":"320","fileSize":102400}}"""),
        )

        val result = api().songUrl(songRequest)

        assertTrue((result as SongUrlAttempt.Resolved).isTrial)
    }

    @Test
    fun `isTrial is false when fileSize is large and fail_process clean`() = runTest {
        server.enqueue(
            respond("""{"data":{"url":["http://cdn.example.com/a.mp3"],"quality":"320","fileSize":10485760}}"""),
        )

        val result = api().songUrl(songRequest)

        val resolved = result as SongUrlAttempt.Resolved
        assertTrue(!resolved.isTrial)
    }

    @Test
    fun `loudness aliases volume_lufs and volumePeak are parsed`() = runTest {
        server.enqueue(
            respond("""{"data":{"url":["http://cdn.example.com/a.mp3"],"quality":"320","volume_lufs":-14.5,"volumePeak":0.9}}"""),
        )

        val result = api().songUrl(songRequest)

        val resolved = result as SongUrlAttempt.Resolved
        assertEquals(-14.5, resolved.lufs!!, 1e-9)
        assertEquals(0.9, resolved.peakDb!!, 1e-9)
    }

    @Test
    fun `loudness prefers volume over volume_lufs alias`() = runTest {
        server.enqueue(
            respond("""{"data":{"url":["http://cdn.example.com/a.mp3"],"quality":"320","volume":-12.0,"volume_lufs":-14.5,"volume_peak":0.8}}"""),
        )

        val result = api().songUrl(songRequest)

        val resolved = result as SongUrlAttempt.Resolved
        assertEquals(-12.0, resolved.lufs!!, 1e-9)
        assertEquals(0.8, resolved.peakDb!!, 1e-9)
    }

    @Test
    fun `malformed json body maps to Unavailable without crash`() = runTest {
        server.enqueue(respond("not-json{"))

        val result = api().songUrl(songRequest.copy(downgrade = false))

        assertEquals(SongUrlAttempt.Unavailable, result)
    }

    // ------------------------------------------------------------------
    // buy → standard 重试（先于 url 检查）
    // ------------------------------------------------------------------

    @Test
    fun `buy fail_process retries standard before url check`() = runTest {
        // 第一响应带 url + buy：若实现先查 url 会错误返回试听 URL，必须先拦 buy
        server.enqueue(respond(okSongUrl(extra = ""","fail_process":["buy"]""")))
        server.enqueue(respond(okSongUrl()))

        val result = api().songUrl(songRequest.copy(quality = "320", downgrade = true))

        val resolved = result as SongUrlAttempt.Resolved
        assertEquals("http://cdn.example.com/audio.mp3", resolved.url)
        assertEquals("320", resolved.quality)
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertEquals("320", query(first, "quality"))
        assertEquals("128", query(second, "quality"))
    }

    @Test
    fun `buy fail_process without downgrade returns Unavailable without retry`() = runTest {
        server.enqueue(respond(okSongUrl(extra = ""","fail_process":["buy"]""")))

        val result = api().songUrl(songRequest.copy(quality = "320", downgrade = false))

        assertEquals(SongUrlAttempt.Unavailable, result)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `buy at standard quality keeps trial flag without retry`() = runTest {
        server.enqueue(respond(okSongUrl(extra = ""","fail_process":["buy"]""")))

        val result = api().songUrl(songRequest.copy(quality = "128"))

        val resolved = result as SongUrlAttempt.Resolved
        assertTrue(resolved.isTrial)
        assertEquals(1, server.requestCount)
    }

    // ------------------------------------------------------------------
    // HTTP 层失败 downgrade 重试
    // ------------------------------------------------------------------

    @Test
    fun `http failure with downgrade retries standard once`() = runTest {
        server.enqueue(respond("""{"error":"upstream","errcode":502}""", status = 502))
        server.enqueue(respond(okSongUrl()))

        val result = api().songUrl(songRequest.copy(quality = "320", downgrade = true))

        val resolved = result as SongUrlAttempt.Resolved
        assertEquals("http://cdn.example.com/audio.mp3", resolved.url)
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertEquals("320", query(first, "quality"))
        assertEquals("128", query(second, "quality"))
    }

    @Test
    fun `http failure without downgrade returns Unavailable`() = runTest {
        server.enqueue(respond("""{"error":"upstream","errcode":502}""", status = 502))

        val result = api().songUrl(songRequest.copy(downgrade = false))

        assertEquals(SongUrlAttempt.Unavailable, result)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `http failure with downgrade failing twice returns Unavailable`() = runTest {
        server.enqueue(respond("""{"error":"upstream"}""", status = 502))
        server.enqueue(respond("""{"error":"upstream"}""", status = 502))

        val result = api().songUrl(songRequest.copy(quality = "320", downgrade = true))

        assertEquals(SongUrlAttempt.Unavailable, result)
        assertEquals(2, server.requestCount)
    }

    // ------------------------------------------------------------------
    // free_part 试听（恒非 VIP）
    // ------------------------------------------------------------------

    @Test
    fun `no url triggers single free_part trial and forces isTrial`() = runTest {
        server.enqueue(respond("""{"data":{"quality":"320"}}"""))
        server.enqueue(respond(okSongUrl()))

        val result = api().songUrl(songRequest.copy(quality = "320"))

        val resolved = result as SongUrlAttempt.Resolved
        assertTrue(resolved.isTrial)
        assertEquals("http://cdn.example.com/audio.mp3", resolved.url)
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertNull(query(first, "free_part"))
        assertEquals("1", query(second, "free_part"))
        assertEquals("320", query(second, "quality"))
    }

    @Test
    fun `trial without url returns Unavailable`() = runTest {
        server.enqueue(respond("""{"data":{}}"""))
        server.enqueue(respond("""{"data":{}}"""))

        val result = api().songUrl(songRequest)

        assertEquals(SongUrlAttempt.Unavailable, result)
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `trial quality defaults to 128 when server omits it`() = runTest {
        server.enqueue(respond("""{"data":{}}"""))
        server.enqueue(respond("""{"data":{"url":["http://cdn.example.com/a.mp3"]}}"""))

        val result = api().songUrl(songRequest)

        assertEquals("128", (result as SongUrlAttempt.Resolved).quality)
    }

    // ------------------------------------------------------------------
    // 本地失败分流
    // ------------------------------------------------------------------

    @Test
    fun `503 local_server_busy maps to SERVER_BUSY without retry`() = runTest {
        server.enqueue(respond("""{"error":"local_server_busy","retryable":true}""", status = 503))

        val result = api().songUrl(songRequest.copy(quality = "320", downgrade = true))

        assertEquals(
            SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY),
            result,
        )
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `503 with other body does not map to SERVER_BUSY`() = runTest {
        server.enqueue(respond("""{"error":"other"}""", status = 503))

        val result = api().songUrl(songRequest.copy(downgrade = false))

        assertEquals(SongUrlAttempt.Unavailable, result)
    }

    @Test
    fun `2xx errcode body falls through to trial and Unavailable`() = runTest {
        // 31863 no free part info：2xx 业务错误 → 无 url → 试听一次 → 仍无 → Unavailable
        server.enqueue(respond("""{"errcode":31863,"data":{}}"""))
        server.enqueue(respond("""{"data":{}}"""))

        val result = api().songUrl(songRequest.copy(quality = "320"))

        assertEquals(SongUrlAttempt.Unavailable, result)
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `connection refused maps to SERVER_UNAVAILABLE`() = runTest {
        val socket = ServerSocket(0)
        val deadPort = socket.localPort
        socket.close()

        val result = api(KugouServerEndpoint { deadPort }).songUrl(songRequest)

        assertEquals(
            SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE),
            result,
        )
    }

    @Test
    fun `endpoint without port fails fast as SERVER_UNAVAILABLE`() = runTest {
        val result = api(KugouServerEndpoint { null }).songUrl(songRequest)

        assertEquals(
            SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE),
            result,
        )
        assertEquals(0, server.requestCount)
    }

    // ------------------------------------------------------------------
    // 云盘 /user/cloud/url
    // ------------------------------------------------------------------

    @Test
    fun `cloudUrl builds segment path resolves data url and passes params`() = runTest {
        server.enqueue(respond("""{"data":{"url":["http://cloud.example.com/file.mp3"]}}"""))

        val result = api().cloudUrl(
            CloudUrlRequest(
                hash = "cloudHash1",
                albumId = "99",
                name = "我的云盘歌",
                albumAudioId = null,
            ),
        )

        assertEquals(
            CloudUrlAttempt.Resolved("http://cloud.example.com/file.mp3"),
            result,
        )
        val request = server.takeRequest()
        assertTrue(recordedPath(request).startsWith("/user/cloud/url?"))
        assertEquals("cloudHash1", query(request, "hash"))
        assertEquals("99", query(request, "album_id"))
        assertEquals("我的云盘歌", query(request, "name"))
        assertNull(query(request, "album_audio_id"))
    }

    @Test
    fun `cloudUrl http failure maps to Unavailable`() = runTest {
        server.enqueue(respond("""{"error":"upstream"}""", status = 502))

        val result = api().cloudUrl(
            CloudUrlRequest(hash = "h", albumId = null, name = "n", albumAudioId = null),
        )

        assertEquals(CloudUrlAttempt.Unavailable, result)
    }

    @Test
    fun `cloudUrl connection refused maps to SERVER_UNAVAILABLE`() = runTest {
        val socket = ServerSocket(0)
        val deadPort = socket.localPort
        socket.close()

        val result = api(KugouServerEndpoint { deadPort }).cloudUrl(
            CloudUrlRequest(hash = "h", albumId = null, name = "n", albumAudioId = null),
        )

        assertEquals(
            CloudUrlAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE),
            result,
        )
    }

    // ------------------------------------------------------------------
    // 懒启动链（真 KugouServerManager + FakeGateway）
    // ------------------------------------------------------------------

    @Test
    fun `lazy start endpoint triggers ensureStarted and api uses manager port`() = runTest {
        val scheduler = TestCoroutineScheduler()
        val scope = CoroutineScope(UnconfinedTestDispatcher(scheduler))
        val gateway = FakeGateway(startResult = server.port)
        val manager = KugouServerManager(gateway, scope, "/data/data/com.gracemusic.app/files")
        try {
            server.enqueue(respond(okSongUrl()))
            val result = api(ManagerKugouServerEndpoint(manager)).songUrl(songRequest)

            assertTrue(result is SongUrlAttempt.Resolved)
            assertEquals(1, gateway.startCalls.get())
            assertEquals("/data/data/com.gracemusic.app/files", gateway.lastDataDir)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `ready wait timeout maps to SERVER_UNAVAILABLE`() = runTest {
        val scheduler = TestCoroutineScheduler()
        val scope = CoroutineScope(UnconfinedTestDispatcher(scheduler))
        // start 永远失败（返回 0）→ FAILED 态 → 就绪等待超时
        val gateway = FakeGateway(startResult = 0)
        val manager = KugouServerManager(gateway, scope, "/data/data/com.gracemusic.app/files")
        try {
            val endpoint = ManagerKugouServerEndpoint(manager, readyTimeout = 100.milliseconds)
            val result = api(endpoint).songUrl(songRequest)

            assertEquals(
                SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE),
                result,
            )
        } finally {
            scope.cancel()
        }
    }

    // ------------------------------------------------------------------
    // Fake
    // ------------------------------------------------------------------

    private class FakeGateway(private val startResult: Int) : KugouServerGateway {
        val startCalls = AtomicInteger()
        var lastDataDir: String? = null

        override suspend fun start(dataDir: String): Int {
            startCalls.incrementAndGet()
            lastDataDir = dataDir
            return startResult
        }

        override suspend fun stop() = Unit

        override suspend fun isRunning(): Boolean = startResult > 0
    }
}
