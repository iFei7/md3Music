package com.gracemusic.data.source

import com.gracemusic.data.model.Song
import com.gracemusic.data.net.CloudUrlAttempt
import com.gracemusic.data.net.CloudUrlRequest
import com.gracemusic.data.net.KugouApi
import com.gracemusic.data.net.LocalFailureKind
import com.gracemusic.data.net.SongUrlAttempt
import com.gracemusic.data.net.SongUrlRequest
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SongUrlResolver] 全分支锁测试（纯 JUnit4 + 假 [KugouApi]，无网络）。
 *
 * 语义基准：lite `kugou_api_client.dart:1338-1507`（降级链/链驱动/三段兜底）、
 * `player_provider.dart:3602-3686`（云盘先行）、`:5674-5677`（本地直返）。
 * 方法名即断言，覆盖矩阵见各测试 KDoc。
 */
class SongUrlResolverTest {

    // ------------------------------------------------------------------
    // 假 KugouApi：记录请求、按脚本回放，可注入延迟测超时。
    // ------------------------------------------------------------------

    /** 脚本化假 API：与真实实现仅经 §2 冻结契约耦合。 */
    private class FakeKugouApi : KugouApi {
        /** 收到的 /song/url 请求序列（按到达顺序）。 */
        val songUrlRequests: MutableList<SongUrlRequest> = mutableListOf()

        /** 收到的 /user/cloud/url 请求序列。 */
        val cloudUrlRequests: MutableList<CloudUrlRequest> = mutableListOf()

        /** /song/url 回放脚本。 */
        var songUrlScript: (SongUrlRequest) -> SongUrlAttempt = { SongUrlAttempt.Unavailable }

        /** /user/cloud/url 回放脚本。 */
        var cloudUrlScript: (CloudUrlRequest) -> CloudUrlAttempt = { CloudUrlAttempt.Unavailable }

        /** 每次songUrl 调用前的人为延迟（虚拟时间），用于 45s 总超时测试。 */
        var songUrlDelay: Duration = Duration.ZERO

        override suspend fun songUrl(request: SongUrlRequest): SongUrlAttempt {
            songUrlRequests.add(request)
            if (songUrlDelay > Duration.ZERO) delay(songUrlDelay)
            return songUrlScript(request)
        }

        override suspend fun cloudUrl(request: CloudUrlRequest): CloudUrlAttempt {
            cloudUrlRequests.add(request)
            return cloudUrlScript(request)
        }
    }

    private fun fakeApi(script: (SongUrlRequest) -> SongUrlAttempt): FakeKugouApi =
        FakeKugouApi().apply { songUrlScript = script }

    /** 构造在线曲目（带 albumId / albumAudioId，供请求参数断言）。 */
    private fun onlineSong(
        id: String = "HashAbC123",
        albumId: String? = "album_1",
        albumAudioId: String? = "audio_1",
    ): Song = Song(
        id = id,
        title = "曲目$id",
        artist = "歌手",
        album = "专辑",
        duration = 200.seconds,
        isOnline = true,
        albumId = albumId,
        albumAudioId = albumAudioId,
    )

    /** 全档不可用脚本：链与兜底全部判死。 */
    private fun allUnavailable(): (SongUrlRequest) -> SongUrlAttempt = { SongUrlAttempt.Unavailable }

    // ------------------------------------------------------------------
    // 降级链（lite kugou_api_client.dart:1342-1386）
    // ------------------------------------------------------------------

    @Test
    fun `downgradeChain_viper_tape_请求返回五档完整链`() {
        assertEquals(
            listOf("viper_tape", "high", "flac", "320", "128"),
            SongUrlResolver.downgradeChain("viper_tape"),
        )
    }

    @Test
    fun `downgradeChain_high_请求返回四档链`() {
        assertEquals(
            listOf("high", "flac", "320", "128"),
            SongUrlResolver.downgradeChain("high"),
        )
    }

    @Test
    fun `downgradeChain_flac_请求返回三档链`() {
        assertEquals(
            listOf("flac", "320", "128"),
            SongUrlResolver.downgradeChain("flac"),
        )
    }

    @Test
    fun `downgradeChain_320_请求返回两档链`() {
        assertEquals(listOf("320", "128"), SongUrlResolver.downgradeChain("320"))
    }

    @Test
    fun `downgradeChain_128与未知码_只请求128单档`() {
        assertEquals(listOf("128"), SongUrlResolver.downgradeChain("128"))
        assertEquals(listOf("128"), SongUrlResolver.downgradeChain("mystery_code"))
    }

    @Test
    fun `qualityRank_五档严格递减_非法码无证据返回null`() {
        assertEquals(4, SongUrlResolver.qualityRank("viper_tape"))
        assertEquals(3, SongUrlResolver.qualityRank("high"))
        assertEquals(2, SongUrlResolver.qualityRank("flac"))
        assertEquals(1, SongUrlResolver.qualityRank("320"))
        assertEquals(0, SongUrlResolver.qualityRank("128"))
        assertNull(SongUrlResolver.qualityRank("weird"))
    }

    // ------------------------------------------------------------------
    // 链驱动：请求顺序与逐档语义（lite :1414-1455）
    // ------------------------------------------------------------------

    @Test
    fun `resolve_viper_tape请求_逐档请求顺序为五档链`() = runTest {
        val api = fakeApi(allUnavailable())
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Failure)
        // 前 5 条为链序；全败后链后兜底还会追加 ppage（128）与 final（128）共 7 条。
        assertEquals(
            listOf("viper_tape", "high", "flac", "320", "128"),
            api.songUrlRequests.take(5).map { it.quality },
        )
        assertEquals(7, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_请求参数_携带小写hash与专辑三元组且不带ppage`() = runTest {
        val api = fakeApi(allUnavailable())
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        resolver.resolve(onlineSong(id = "MiXeDcAsE9"), "high")
        val request = api.songUrlRequests.first()
        assertEquals("mixedcase9", request.hash)
        assertEquals("album_1", request.albumId)
        assertEquals("audio_1", request.albumAudioId)
        assertEquals(false, request.downgrade)
        assertNull(request.ppageId)
    }

    @Test
    fun `resolve_精确命中请求档_立即返回且不请求后续档`() = runTest {
        // 首档 viper_tape 请求即精确回写 viper_tape → 直接成功，不再请求 high/flac/320/128。
        val api = fakeApi { SongUrlAttempt.Resolved("https://cdn/ok", "viper_tape", false, 10L, 0L, null, null) }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Success)
        assertEquals(1, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_非精确命中_按rank留更高档为best并最终采用`() = runTest {
        // 各档回写均不等于请求档：viper→high(3，成为 best)、high→flac(2，不替换)、
        // flac→320(1，不替换)、320→flac(2，不替换)、128→Unavailable。
        // 最终 best = viper 档那条（回写档 rank=3 最高，先到先得）。
        val urls = mapOf(
            "viper_tape" to "https://cdn/high-q",
            "high" to "https://cdn/flac-q",
            "flac" to "https://cdn/320-q",
            "320" to "https://cdn/flac-again",
        )
        val writtenQuality: Map<String, String> = mapOf(
            "viper_tape" to "high",
            "high" to "flac",
            "flac" to "320",
            "320" to "flac",
        )
        val api = fakeApi { request ->
            urls[request.quality]?.let { url ->
                SongUrlAttempt.Resolved(url, writtenQuality[request.quality]!!, false, 10L, 0L, null, null)
            } ?: SongUrlAttempt.Unavailable
        }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Success)
        val success = result as ResolutionResult.Success
        assertEquals("https://cdn/high-q", success.url)
        assertEquals("high", success.actualQuality)
        // 五档全部走完（无精确命中，不短路），best 采用后不触发 ppage/final。
        assertEquals(5, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_回写档非法字符串_按无证据处理不参与best竞争`() = runTest {
        // viper→"weird"（无证据，不设 best）；high→"320"（rank=1，成为 best）；
        // flac→"weird2"（无证据，不替换）；后续 Unavailable。
        // 偏离 lite（lite rank 默认 0 可为 best）→ Sonify「没有证据就不猜」收紧，见实现 KDoc。
        val script: (SongUrlRequest) -> SongUrlAttempt = { request ->
            when (request.quality) {
                "viper_tape" -> SongUrlAttempt.Resolved("https://cdn/w1", "weird", false, 10L, 0L, null, null)
                "high" -> SongUrlAttempt.Resolved("https://cdn/320-q", "320", false, 10L, 0L, null, null)
                "flac" -> SongUrlAttempt.Resolved("https://cdn/w2", "weird2", false, 10L, 0L, null, null)
                else -> SongUrlAttempt.Unavailable
            }
        }
        val api = fakeApi(script)
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Success)
        assertEquals("320", (result as ResolutionResult.Success).actualQuality)
        assertEquals("https://cdn/320-q", result.url)
    }

    @Test
    fun `resolve_isTrial结果跳过_继续降级下一档`() = runTest {
        // 链内试听不被接受（lite :1430-1436）：viper 档回试听 → 跳过，high 档精确命中才采用。
        val script: (SongUrlRequest) -> SongUrlAttempt = { request ->
            if (request.quality == "viper_tape") {
                SongUrlAttempt.Resolved("https://cdn/trial", "viper_tape", true, 100L, 0L, null, null)
            } else {
                SongUrlAttempt.Resolved("https://cdn/ok", request.quality, false, 10L, 0L, null, null)
            }
        }
        val api = fakeApi(script)
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Success)
        assertEquals("https://cdn/ok", (result as ResolutionResult.Success).url)
        assertEquals(2, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_空url结果跳过_继续降级下一档`() = runTest {
        val script: (SongUrlRequest) -> SongUrlAttempt = { request ->
            if (request.quality == "viper_tape") {
                SongUrlAttempt.Resolved("", "viper_tape", false, 10L, 0L, null, null)
            } else {
                SongUrlAttempt.Resolved("https://cdn/ok", request.quality, false, 10L, 0L, null, null)
            }
        }
        val api = fakeApi(script)
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Success)
        assertEquals(2, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_单档抛异常_继续下一档`() = runTest {
        val script: (SongUrlRequest) -> SongUrlAttempt = { request ->
            if (request.quality == "viper_tape") error("上游炸了")
            SongUrlAttempt.Resolved("https://cdn/ok", request.quality, false, 10L, 0L, null, null)
        }
        val api = fakeApi(script)
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Success)
        assertEquals(2, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_CancellationException_原样重抛不吞`() = runTest {
        val api = fakeApi { throw CancellationException("外部取消") }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        try {
            resolver.resolve(onlineSong(), "128")
            org.junit.Assert.fail("应当重抛 CancellationException")
        } catch (expected: CancellationException) {
            assertEquals("外部取消", expected.message)
        }
    }

    @Test
    fun `resolve_本地失败busy_中止整链返回失败且只请求一档`() = runTest {
        val api = fakeApi { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Failure)
        assertEquals(1, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_本地失败unavailable_中止整链返回失败且只请求一档`() = runTest {
        val api = fakeApi { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE) }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Failure)
        assertEquals(1, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_本地失败_文案收敛不含URL与上游细节`() = runTest {
        val api = fakeApi { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "128")
        val message = (result as ResolutionResult.Failure).message
        assertTrue(message.isNotEmpty())
        assertTrue(!message.contains("http"))
    }

    // ------------------------------------------------------------------
    // 链后三段兜底（lite :1457-1503）
    // ------------------------------------------------------------------

    @Test
    fun `resolve_链全败_先采用best再走ppage兜底与final降级`() = runTest {
        // best 有值时直接采用，不触发 ppage/final。
        val script: (SongUrlRequest) -> SongUrlAttempt = { request ->
            if (request.quality == "320") {
                SongUrlAttempt.Resolved("https://cdn/best", "flac", false, 10L, 0L, null, null)
            } else {
                SongUrlAttempt.Unavailable
            }
        }
        val api = fakeApi(script)
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "320")
        assertTrue(result is ResolutionResult.Success)
        assertEquals("https://cdn/best", (result as ResolutionResult.Success).url)
        // 链两档即止，无 ppage/final 请求。
        assertEquals(2, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_全链无best_依次请求ppage兜底`() = runTest {
        // 全链 Unavailable → best 为空 → ppage_id=356753938 standard（downgrade=false）成功。
        val api = fakeApi { request ->
            if (request.ppageId == "356753938") {
                SongUrlAttempt.Resolved("https://cdn/ppage", "128", false, 10L, 0L, null, null)
            } else {
                SongUrlAttempt.Unavailable
            }
        }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "128")
        assertTrue(result is ResolutionResult.Success)
        assertEquals("https://cdn/ppage", (result as ResolutionResult.Success).url)
        // 链 1 档 + ppage 1 次。
        assertEquals(2, api.songUrlRequests.size)
        val ppageRequest = api.songUrlRequests.last()
        assertEquals("356753938", ppageRequest.ppageId)
        assertEquals("128", ppageRequest.quality)
        assertEquals(false, ppageRequest.downgrade)
    }

    @Test
    fun `resolve_ppage兜底试听被跳过_继续final降级`() = runTest {
        // ppage 返回试听 → 跳过（lite :1483）；final（downgrade=true）返回完整链接 → 采用。
        val api = fakeApi { request ->
            when {
                request.ppageId == "356753938" ->
                    SongUrlAttempt.Resolved("https://cdn/ppage-trial", "128", true, 100L, 0L, null, null)
                request.downgrade ->
                    SongUrlAttempt.Resolved("https://cdn/final", "128", false, 10L, 0L, null, null)
                else -> SongUrlAttempt.Unavailable
            }
        }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "128")
        assertTrue(result is ResolutionResult.Success)
        assertEquals("https://cdn/final", (result as ResolutionResult.Success).url)
        // 链 1 档（全败）+ ppage 1（试听跳过）+ final 1。
        assertEquals(3, api.songUrlRequests.size)
        assertEquals("128", api.songUrlRequests[0].quality)
        assertEquals("356753938", api.songUrlRequests[1].ppageId)
        assertEquals(true, api.songUrlRequests[2].downgrade)
    }

    @Test
    fun `resolve_全链与ppage失败_final试听被接受为最后手段`() = runTest {
        // lite :1491-1500：final 请求 downgrade=true，试听可接受。
        val api = fakeApi { request ->
            if (request.downgrade) {
                SongUrlAttempt.Resolved("https://cdn/final-trial", "128", true, 100L, 0L, null, null)
            } else {
                SongUrlAttempt.Unavailable
            }
        }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Success)
        val success = result as ResolutionResult.Success
        assertEquals("https://cdn/final-trial", success.url)
        assertTrue(success.isTrial)
        // 链 5 档 + ppage 1 + final 1。
        assertEquals(7, api.songUrlRequests.size)
        val finalRequest = api.songUrlRequests.last()
        assertEquals(true, finalRequest.downgrade)
        assertNull(finalRequest.ppageId)
    }

    @Test
    fun `resolve_全败含final_返回暂无可用音源`() = runTest {
        val api = fakeApi(allUnavailable())
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "128")
        assertTrue(result is ResolutionResult.Failure)
        assertEquals("暂无可用音源", (result as ResolutionResult.Failure).message)
        // 链 1 档 + ppage + final。
        assertEquals(3, api.songUrlRequests.size)
        val message = result.message
        assertTrue(!message.contains("http"))
    }

    // ------------------------------------------------------------------
    // 总超时（lite :1400-1406 cancelToken，native 用 withTimeout 注入）
    // ------------------------------------------------------------------

    @Test
    fun `resolve_总超时_返回失败且中止后续档`() = runTest {
        val api = FakeKugouApi().apply {
            songUrlDelay = 5.seconds
            songUrlScript = { SongUrlAttempt.Unavailable }
        }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()), totalTimeout = 100.milliseconds)
        val result = resolver.resolve(onlineSong(), "viper_tape")
        assertTrue(result is ResolutionResult.Failure)
        // 超时后不再发第二档。
        assertEquals(1, api.songUrlRequests.size)
    }

    // ------------------------------------------------------------------
    // 三分流（lite 三段：本地直返 / 云盘先行 / 在线链）
    // ------------------------------------------------------------------

    @Test
    fun `resolve_本地曲localPath非空_直接返回路径且不发任何请求`() = runTest {
        val api = fakeApi(allUnavailable())
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val song = Song(
            id = "local1", title = "本地歌", artist = "歌手", album = "专辑",
            duration = 100.seconds, localPath = "/storage/emulated/0/a.mp3", isOnline = false,
        )
        val result = resolver.resolve(song, "flac")
        assertTrue(result is ResolutionResult.Success)
        val success = result as ResolutionResult.Success
        assertEquals("/storage/emulated/0/a.mp3", success.url)
        // 本地曲无服务端回写 → actualQuality 保持调用方值。
        assertEquals("flac", success.actualQuality)
        assertTrue(api.songUrlRequests.isEmpty())
        assertTrue(api.cloudUrlRequests.isEmpty())
    }

    @Test
    fun `resolve_本地曲localPath为空_返回本地文件不可用且不发请求`() = runTest {
        val api = fakeApi(allUnavailable())
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val song = Song(
            id = "local2", title = "本地歌", artist = "歌手", album = "专辑",
            duration = 100.seconds, localPath = "", isOnline = false,
        )
        val result = resolver.resolve(song, "128")
        assertTrue(result is ResolutionResult.Failure)
        assertEquals("本地文件不可用", (result as ResolutionResult.Failure).message)
        assertTrue(api.songUrlRequests.isEmpty())
    }

    @Test
    fun `resolve_云盘cloudUrl成功_直接返回且不触发songUrl`() = runTest {
        val api = fakeApi(allUnavailable())
        api.cloudUrlScript = { CloudUrlAttempt.Resolved("https://cloud/ok") }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val song = Song(
            id = "cloud1", title = "云盘歌.mp3", artist = "我", album = "云盘",
            duration = 100.seconds, isOnline = true, isCloud = true,
            albumId = "c_alb", albumAudioId = "c_audio",
        )
        val result = resolver.resolve(song, "flac")
        assertTrue(result is ResolutionResult.Success)
        val success = result as ResolutionResult.Success
        assertEquals("https://cloud/ok", success.url)
        // 云盘无服务端音质回写 → actualQuality 保持调用方值。
        assertEquals("flac", success.actualQuality)
        assertTrue(api.songUrlRequests.isEmpty())
        assertEquals(1, api.cloudUrlRequests.size)
        // 云盘请求参数（lite player_provider.dart:3652-3657）。
        val cloudRequest = api.cloudUrlRequests.first()
        assertEquals("cloud1", cloudRequest.hash)
        assertEquals("c_alb", cloudRequest.albumId)
        assertEquals("云盘歌.mp3", cloudRequest.name)
        assertEquals("c_audio", cloudRequest.albumAudioId)
    }

    @Test
    fun `resolve_云盘Unavailable_回退在线降级链`() = runTest {
        val api = fakeApi { SongUrlAttempt.Resolved("https://cdn/fallback", "128", false, 10L, 0L, null, null) }
        api.cloudUrlScript = { CloudUrlAttempt.Unavailable }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val song = Song(
            id = "cloud2", title = "云盘歌", artist = "我", album = "云盘",
            duration = 100.seconds, isOnline = true, isCloud = true,
        )
        val result = resolver.resolve(song, "128")
        assertTrue(result is ResolutionResult.Success)
        assertEquals("https://cdn/fallback", (result as ResolutionResult.Success).url)
        assertEquals(1, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_云盘LocalFailure_同样回退在线降级链`() = runTest {
        val api = fakeApi { SongUrlAttempt.Resolved("https://cdn/fallback", "128", false, 10L, 0L, null, null) }
        api.cloudUrlScript = { CloudUrlAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE) }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val song = Song(
            id = "cloud3", title = "云盘歌", artist = "我", album = "云盘",
            duration = 100.seconds, isOnline = true, isCloud = true,
        )
        val result = resolver.resolve(song, "128")
        assertTrue(result is ResolutionResult.Success)
        assertEquals(1, api.songUrlRequests.size)
    }

    @Test
    fun `resolve_云盘失败且回退链本地失败_中止整链返回失败`() = runTest {
        val api = fakeApi { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        api.cloudUrlScript = { CloudUrlAttempt.Unavailable }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val song = Song(
            id = "cloud4", title = "云盘歌", artist = "我", album = "云盘",
            duration = 100.seconds, isOnline = true, isCloud = true,
        )
        val result = resolver.resolve(song, "128")
        assertTrue(result is ResolutionResult.Failure)
        assertEquals(1, api.songUrlRequests.size)
    }

    // ------------------------------------------------------------------
    // 成功即写响度缓存（lite kugou_models.dart:822-838 _rememberLoudness 时机）
    // ------------------------------------------------------------------

    @Test
    fun `resolve_成功且响度有效_写入响度缓存并持久化`() = runTest {
        val store = RecordingStore()
        val api = fakeApi { SongUrlAttempt.Resolved("https://cdn/ok", "128", false, 10L, 0L, -14.5, -1.0) }
        val cache = LoudnessCache(store)
        val resolver = SongUrlResolver(api, cache)
        val result = resolver.resolve(onlineSong(), "128")
        assertTrue(result is ResolutionResult.Success)
        assertEquals(Pair(-14.5, -1.0 as Double?), cache.loudnessForUrl("https://cdn/ok"))
        assertEquals(1, store.saved.size)
    }

    @Test
    fun `resolve_成功但响度缺失_不写缓存`() = runTest {
        val store = RecordingStore()
        val cache = LoudnessCache(store)
        val api = fakeApi { SongUrlAttempt.Resolved("https://cdn/ok", "128", false, 10L, 0L, null, null) }
        val resolver = SongUrlResolver(api, cache)
        assertTrue(resolver.resolve(onlineSong(), "128") is ResolutionResult.Success)
        assertNull(cache.loudnessForUrl("https://cdn/ok"))
        assertEquals(0, store.saved.size)
    }

    @Test
    fun `resolve_成功但响度为NaN_不写缓存`() = runTest {
        val store = RecordingStore()
        val api = fakeApi { SongUrlAttempt.Resolved("https://cdn/ok", "128", false, 10L, 0L, Double.NaN, null) }
        val resolver = SongUrlResolver(api, LoudnessCache(store))
        assertTrue(resolver.resolve(onlineSong(), "128") is ResolutionResult.Success)
        assertEquals(0, store.saved.size)
    }

    @Test
    fun `resolve_成功结果_携带服务端响度字段`() = runTest {
        val api = fakeApi { SongUrlAttempt.Resolved("https://cdn/ok", "flac", false, 10L, 0L, -15.2, -2.1) }
        val resolver = SongUrlResolver(api, LoudnessCache(RecordingStore()))
        val result = resolver.resolve(onlineSong(), "flac")
        val success = result as ResolutionResult.Success
        assertEquals(-15.2, success.lufs!!, 1e-9)
        assertEquals(-2.1, success.peakDb!!, 1e-9)
        assertEquals("flac", success.actualQuality)
        assertNotNull(success.song)
    }

    // ------------------------------------------------------------------
    // 测试工具：记录型假持久化存储。
    // ------------------------------------------------------------------

    /** 记录型假 store：save 载荷可断言，load 默认空。 */
    private class RecordingStore : LoudnessStore {
        val saved: MutableList<List<Triple<String, Double, Double?>>> = mutableListOf()
        var loaded: List<Triple<String, Double, Double?>> = emptyList()
        var loadCount: Int = 0

        override fun load(): List<Triple<String, Double, Double?>> {
            loadCount += 1
            return loaded
        }

        override fun save(entries: List<Triple<String, Double, Double?>>) {
            saved.add(entries)
        }
    }
}
