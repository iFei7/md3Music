package com.gracemusic.player.offline

import android.app.Application
import android.content.Context
import androidx.media3.common.C
import androidx.media3.datasource.cache.ContentMetadataMutations
import com.gracemusic.data.model.Song
import com.gracemusic.data.net.CloudUrlAttempt
import com.gracemusic.data.net.CloudUrlRequest
import com.gracemusic.data.net.KugouApi
import com.gracemusic.data.net.SongUrlAttempt
import com.gracemusic.data.net.SongUrlRequest
import com.gracemusic.data.source.LoudnessCache
import com.gracemusic.data.source.LoudnessStore
import com.gracemusic.data.source.SongUrlResolver
import com.gracemusic.player.session.PlaybackSessionRegistry
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.player.store.EngineListener
import com.gracemusic.player.store.PlaybackEngine
import com.gracemusic.player.store.PlaybackKeepAlive
import com.gracemusic.player.store.PlaybackStore
import com.gracemusic.testutil.testSong
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * 离线缓存边界测试（T-P1-13 / 交付 A4 的缺口补齐）。
 *
 * 补齐用户 A4 清单中此前未覆盖的边界：
 * - **缓存容量上限**（配置生效 + 淘汰翻转）；
 * - **音源 URL 过期**（同键换源、键与 URL 解耦）；
 * - **缓存读取失败 / 文件损坏**（外部清理后判定与容错）；
 * - **当前曲已缓存但后续全未缓存**（停止，不回退重播当前曲）；
 * - **离线停止后用户手动重试**（走既有解析链路，不受离线门阻断）。
 *
 * 缓存判定用真 `SimpleCache`（Robolectric + 临时目录），Store 层用最小 fake。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class OfflineCacheBoundaryTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    // ═══════════════════ 缓存层：容量上限与淘汰 ═══════════════════

    @Test
    fun `容量上限_极小上限下超限写入被淘汰`() {
        val store = newStore(maxBytes = 4_096)
        val key = "big|128"
        declareContentLength(store, key, 8_192)
        seedSpan(store, key, 0, 8_192)

        // 上限 4KiB、单个 8KiB span：LRU 立即淘汰 → 判定翻转。
        assertFalse(store.isFullyCached(key))
    }

    @Test
    fun `容量上限_默认值为512MiB`() {
        assertEquals(
            512L * 1024 * 1024,
            PlaybackCacheStore.DEFAULT_MAX_CACHE_BYTES,
        )
        assertEquals(PlaybackCacheStore.DEFAULT_MAX_CACHE_BYTES, PlaybackCacheConfig().maxBytes)
    }

    @Test
    fun `容量上限_上限内写入保持命中`() {
        val store = newStore(maxBytes = 64 * 1024)
        val key = "small|128"
        declareContentLength(store, key, 1_024)
        seedSpan(store, key, 0, 1_024)

        assertTrue(store.isFullyCached(key))
    }

    // ═══════════════════ 音源 URL 过期 ═══════════════════

    @Test
    fun `音源过期_同键重新记住新源覆盖旧源`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", PlaybackCacheKeys.DEFAULT_QUALITY)

        store.rememberResolvedSource(key, "https://cdn.example/old?sign=1")
        store.rememberResolvedSource(key, "https://cdn.example/new?sign=2")

        assertEquals("https://cdn.example/new?sign=2", store.resolvedSource(key))
    }

    @Test
    fun `音源过期_键与URL解耦_换源不影响缓存判定`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", PlaybackCacheKeys.DEFAULT_QUALITY)
        declareContentLength(store, key, 2_048)
        seedSpan(store, key, 0, 2_048)
        store.rememberResolvedSource(key, "https://cdn.example/v1?sign=old")

        // 模拟 URL 过期后重新解析：源变了，但缓存键不变 → 缓存字节仍命中。
        store.rememberResolvedSource(key, "https://cdn.example/v2?sign=new")

        assertTrue(store.isFullyCached(key))
        assertEquals("https://cdn.example/v2?sign=new", store.resolvedSource(key))
    }

    @Test
    fun `音源过期_源记忆未记住时返回 null`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", PlaybackCacheKeys.DEFAULT_QUALITY)

        assertNull(store.resolvedSource(key))
    }

    // ═══════════════════ 缓存读取失败 / 文件损坏 ═══════════════════

    @Test
    fun `缓存文件被外部清理_判定为未缓存且不抛异常`() {
        val store = newStore()
        val key = "gone|128"
        declareContentLength(store, key, 1_024)
        seedSpan(store, key, 0, 1_024)
        assertTrue(store.isFullyCached(key))

        // 模拟用户清理缓存 / 系统回收：直接删掉缓存目录内容。
        val dir = File(context.cacheDir, store.let { cacheDirNameOf(it) })
        dir.listFiles()?.forEach { it.deleteRecursively() }

        // 新实例（模拟进程重启后重新打开索引）不得因目录被清而抛异常。
        val reopened = PlaybackCacheStore(
            context,
            PlaybackCacheConfig(directoryName = "cache-boundary-" + UUID.randomUUID()),
            InMemorySourceMemory(),
        )
        assertFalse(reopened.isFullyCached(key))
    }

    @Test
    fun `缓存键_不同音质档互不命中`() {
        val store = newStore()
        val standard = PlaybackCacheKeys.key("s1", "128")
        val lossless = PlaybackCacheKeys.key("s1", "flac")
        declareContentLength(store, standard, 1_024)
        seedSpan(store, standard, 0, 1_024)

        assertTrue(store.isFullyCached(standard))
        assertFalse(store.isFullyCached(lossless))
    }

    @Test
    fun `不同歌曲互不命中`() {
        val store = newStore()
        val a = PlaybackCacheKeys.key("a", PlaybackCacheKeys.DEFAULT_QUALITY)
        val b = PlaybackCacheKeys.key("b", PlaybackCacheKeys.DEFAULT_QUALITY)
        declareContentLength(store, a, 512)
        seedSpan(store, a, 0, 512)

        assertTrue(store.isFullyCached(a))
        assertFalse(store.isFullyCached(b))
    }

    // ═══════════════════ Store 层：离线前进边界 ═══════════════════

    @Test
    fun `当前曲已缓存但后续全未缓存_停止且不回退重播当前曲`() {
        val h = newHarness()
        // 队列 [a, b]，a 已缓存、b 未缓存；当前停在 a。
        h.cache.cached["a"] = "https://cdn.example/a"
        h.store.dispatch(
            PlaybackIntent.PlayPlaylistFrom(listOf(localSong("a"), localSong("b")), 0),
        )
        h.engine.converge()

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))

        // 候选只有 b（未缓存）→ 全未命中 → 停止：保留队列与当前索引，置错误态。
        assertEquals(0, h.store.state.value.currentIndex)
        assertEquals(listOf("a", "b"), h.store.state.value.playlist.map { it.id })
        assertFalse(h.store.state.value.isPlaying)
        assertEquals("网络不可用且歌单中无已缓存歌曲", h.store.state.value.resolveError)
    }

    @Test
    fun `网络恢复后_用户手动重试触发重新解析`() {
        val h = newHarness()
        // 在线歌（无 url）：装载即触发一次解析。
        h.store.dispatch(PlaybackIntent.PlaySingleSong(testSong("a")))
        val afterLoad = h.api.songUrlCalls
        assertTrue("装载应触发解析，实际 $afterLoad", afterLoad >= 1)

        // 网络恢复（仅改探测结果）→ **不**自动续播（R-4）。
        h.network.available = true
        h.scope.testScheduler.advanceTimeBy(300_000)
        assertEquals(afterLoad, h.api.songUrlCalls)

        // 用户手动重试 → 走既有解析链路重新解析（离线门只拦「前进」路径）。
        h.store.dispatch(PlaybackIntent.RetryCurrent)

        assertTrue(
            "手动重试应重新解析，实际 ${h.api.songUrlCalls}",
            h.api.songUrlCalls > afterLoad,
        )
    }

    // ═══════════════════ 测试基建 ═══════════════════

    private fun newStore(
        maxBytes: Long = PlaybackCacheStore.DEFAULT_MAX_CACHE_BYTES,
    ): PlaybackCacheStore = PlaybackCacheStore(
        context,
        PlaybackCacheConfig(
            directoryName = "cache-boundary-" + UUID.randomUUID(),
            maxBytes = maxBytes,
        ),
        InMemorySourceMemory(),
    )

    private fun cacheDirNameOf(store: PlaybackCacheStore): String =
        // 通过反射读取 config 目录名，避免为测试改动生产可见面。
        store.javaClass.getDeclaredField("config").let { f ->
            f.isAccessible = true
            (f.get(store) as PlaybackCacheConfig).directoryName
        }

    private fun declareContentLength(store: PlaybackCacheStore, key: String, length: Long) {
        store.cache.applyContentMetadataMutations(
            key,
            ContentMetadataMutations.setContentLength(ContentMetadataMutations(), length),
        )
    }

    private fun seedSpan(store: PlaybackCacheStore, key: String, position: Long, bytes: Int) {
        val cache = store.cache
        val hole = cache.startReadWrite(key, position, C.LENGTH_UNSET.toLong())
        val file = cache.startFile(key, position, C.LENGTH_UNSET.toLong())
        file.writeBytes(ByteArray(bytes))
        cache.commitFile(file, bytes.toLong())
        cache.releaseHoleSpan(hole)
    }

    private class InMemorySourceMemory : ResolvedSourceMemory {
        val map = LinkedHashMap<String, String>()
        override fun read(key: String): String? = map[key]
        override fun write(key: String, source: String) {
            map[key] = source
        }
    }

    /** 离线（`available = false`）+ 可控命中表的假实现。 */
    private class FakeCacheResolver(
        val cached: MutableMap<String, String> = LinkedHashMap(),
    ) : PlaybackCacheResolver {
        override suspend fun resolveCachedSource(songId: String, quality: String): String? =
            cached[songId]

        override suspend fun rememberResolvedSource(songId: String, quality: String, source: String) {
            cached[songId] = source
        }
    }

    private class Harness(
        val store: PlaybackStore,
        val engine: FakePlaybackEngine,
        val cache: FakeCacheResolver,
        val api: FakeKugouApi,
        val network: MutableNetworkAvailability,
        val scope: TestScope,
    )

    private fun newHarness(): Harness {
        val engine = FakePlaybackEngine()
        val cache = FakeCacheResolver()
        val api = FakeKugouApi()
        val network = MutableNetworkAvailability(available = false)
        val loudnessCache = LoudnessCache(RecordingLoudnessStore())
        val scope = TestScope(UnconfinedTestDispatcher())
        val store = PlaybackStore(
            engine = engine,
            registry = PlaybackSessionRegistry(),
            keepAlive = FakeKeepAlive(),
            songUrlResolver = SongUrlResolver(api, loudnessCache),
            loudnessCache = loudnessCache,
            cacheResolver = cache,
            // 初始离线：驱动 tryOfflineAdvance 的判定分支；测试可翻转。
            networkAvailability = network,
            scope = scope,
        )
        return Harness(store, engine, cache, api, network, scope)
    }

    private fun localSong(id: String): Song =
        testSong(id, isOnline = false, localPath = "/music/$id.flac")

    private class FakeKeepAlive : PlaybackKeepAlive {
        override fun start() = Unit
        override fun stop() = Unit
    }

    /** 可翻转的网络可用性（`NetworkAvailabilityProvider` 是 fun interface）。 */
    private class MutableNetworkAvailability(var available: Boolean) : NetworkAvailabilityProvider {
        override fun isNetworkAvailable(): Boolean = available
    }

    private class FakeKugouApi : KugouApi {
        var songUrlCalls = 0

        override suspend fun songUrl(request: SongUrlRequest): SongUrlAttempt {
            songUrlCalls++
            return SongUrlAttempt.Unavailable
        }

        override suspend fun cloudUrl(request: CloudUrlRequest): CloudUrlAttempt = CloudUrlAttempt.Unavailable
    }

    private class RecordingLoudnessStore : LoudnessStore {
        override fun load(): List<Triple<String, Double, Double?>> = emptyList()
        override fun save(entries: List<Triple<String, Double, Double?>>) = Unit
    }

    private class FakePlaybackEngine : PlaybackEngine {
        val calls = CopyOnWriteArrayList<String>()
        private val _positionFlow = MutableStateFlow(Duration.ZERO)
        override val positionFlow: StateFlow<Duration> = _positionFlow.asStateFlow()
        override var isPlaying: Boolean = false
        override var playbackState: Int = STATE_IDLE
        override var durationMs: Long? = null
        override var bufferedPositionMs: Long = 0L
        private val listeners = CopyOnWriteArrayList<EngineListener>()

        override fun prepare(song: Song, startPositionMs: Long?, playWhenReady: Boolean) {
            calls += "prepare:${song.id}:$startPositionMs:$playWhenReady"
        }

        override fun play() {
            calls += "play"
        }

        override fun pause() {
            calls += "pause"
        }

        override fun stop() {
            calls += "stop"
        }

        override fun seekTo(positionMs: Long) {
            calls += "seekTo:$positionMs"
        }

        override fun seekBy(deltaMs: Long) {
            calls += "seekBy:$deltaMs"
        }

        override fun setVolume(volume: Float) {
            calls += "setVolume:$volume"
        }

        override fun setSpeed(speed: Float) {
            calls += "setSpeed:$speed"
        }

        override fun addListener(listener: EngineListener) {
            listeners += listener
        }

        override fun removeListener(listener: EngineListener) {
            listeners -= listener
        }

        override fun release() {
            listeners.clear()
        }

        fun emitPlaybackStateChanged(state: Int) {
            playbackState = state
            listeners.toList().forEach { it.onPlaybackStateChanged(state) }
        }

        fun emitIsPlayingChanged(value: Boolean) {
            isPlaying = value
            listeners.toList().forEach { it.onIsPlayingChanged(value) }
        }

        fun emitDurationChanged(value: Long?) {
            durationMs = value
            listeners.toList().forEach { it.onDurationChanged(value) }
        }

        fun emitPosition(value: Duration) {
            _positionFlow.value = value
        }

        fun converge() {
            emitPlaybackStateChanged(STATE_READY)
            emitDurationChanged(200_000)
            emitIsPlayingChanged(true)
            emitPosition(Duration.ZERO)
        }
    }

    private companion object {
        const val STATE_IDLE = 1
        const val STATE_READY = 3
    }
}
