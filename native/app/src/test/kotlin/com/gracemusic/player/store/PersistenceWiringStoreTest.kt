package com.gracemusic.player.store

import com.gracemusic.data.model.Song
import com.gracemusic.data.net.CloudUrlAttempt
import com.gracemusic.data.net.CloudUrlRequest
import com.gracemusic.data.net.KugouApi
import com.gracemusic.data.net.SongUrlAttempt
import com.gracemusic.data.net.SongUrlRequest
import com.gracemusic.data.source.LoudnessCache
import com.gracemusic.data.source.LoudnessStore
import com.gracemusic.data.source.SongUrlResolver
import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.queue.PlaybackQueue
import com.gracemusic.player.session.PlaybackSessionRegistry
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.player.state.PlaybackState
import com.gracemusic.testutil.testSong
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * 持久化与 [PlaybackStore] 的接线测试（T-P1-10）。
 *
 * 覆盖：`PersistPlaybackCursor` 效果真实落盘、`FlushPersistence` 排空、
 * 冷启动恢复的完整决策链（开关 / 无数据 / 幽灵歌曲 / 只尝试一次）。
 */
@RunWith(RobolectricTestRunner::class)
class PersistenceWiringStoreTest {

    // ═══════════════════ 落盘接线 ═══════════════════

    @Test
    fun `PersistPlaybackCursor 效果触发落盘`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))

        assertTrue(h.persistence.persistedCount >= 1)
    }

    @Test
    fun `FlushPersistence 触发排空`() = runTest {
        val h = newHarness()

        h.store.dispatch(PlaybackIntent.FlushPersistence)
        h.scope.testScheduler.runCurrent()

        assertTrue(h.persistence.flushCount >= 1)
    }

    // ═══════════════════ 冷启动恢复 ═══════════════════

    @Test
    fun `恢复_成功装载队列与位置且不自动播放`() = runTest {
        val h = newHarness()
        h.persistence.toRestore = cursorOf(listOf("a", "b"), currentIndex = 1, positionMs = 42_000)

        val ok = h.store.restorePersistedPlayback(fileExists = { true })

        assertTrue(ok)
        assertEquals(listOf("a", "b"), h.store.state.value.playlist.map { it.id })
        assertEquals(1, h.store.state.value.currentIndex)
        assertEquals(42_000, h.store.state.value.position.inWholeMilliseconds)
        assertFalse(h.store.state.value.isPlaying)
        // 本地曲直接 Prepare(playWhenReady=false)。
        val prepare = h.engine.calls.single()
        assertEquals("prepare:b:42000:false", prepare)
    }

    @Test
    fun `恢复_开关关闭时清空并返回 false`() = runTest {
        val h = newHarness()
        h.persistence.toRestore = cursorOf(listOf("a"))
        h.store.dispatch(PlaybackIntent.SetRestoreMemoryEnabled(enabled = false))

        val ok = h.store.restorePersistedPlayback(fileExists = { true })

        assertFalse(ok)
        assertEquals(1, h.persistence.clearCount)
        assertTrue(h.store.state.value.playlist.isEmpty())
    }

    @Test
    fun `恢复_无数据返回 false`() = runTest {
        val h = newHarness()
        h.persistence.toRestore = null

        assertFalse(h.store.restorePersistedPlayback(fileExists = { true }))
        assertEquals(0, h.persistence.clearCount)
    }

    @Test
    fun `恢复_幽灵歌曲时清空并返回 false`() = runTest {
        val h = newHarness()
        h.persistence.toRestore = cursorOf(listOf("a"), positionMs = 1_000)

        val ok = h.store.restorePersistedPlayback(fileExists = { false })

        assertFalse(ok)
        assertEquals(1, h.persistence.clearCount)
        assertTrue(h.store.state.value.playlist.isEmpty())
    }

    @Test
    fun `恢复_只尝试一次`() = runTest {
        val h = newHarness()
        h.persistence.toRestore = cursorOf(listOf("a"))

        assertTrue(h.store.restorePersistedPlayback(fileExists = { true }))
        // 第二次调用（Service 被反复拉起）必须短路，不重复重置队列。
        assertFalse(h.store.restorePersistedPlayback(fileExists = { true }))
    }

    @Test
    fun `恢复_音量快照回灌`() = runTest {
        val h = newHarness()
        h.persistence.toRestore = cursorOf(listOf("a"), volume = 0.35)

        h.store.restorePersistedPlayback(fileExists = { true })

        assertEquals(0.35, h.store.state.value.volume, 0.0001)
        assertTrue(h.engine.calls.contains("setVolume:0.35"))
    }

    // ═══════════════════ 测试基建 ═══════════════════

    private class Harness(
        val store: PlaybackStore,
        val engine: FakePlaybackEngine,
        val persistence: FakePersistence,
        val scope: TestScope,
    )

    private fun newHarness(): Harness {
        val engine = FakePlaybackEngine()
        val persistence = FakePersistence()
        val loudnessCache = LoudnessCache(RecordingLoudnessStore())
        val scope = TestScope(UnconfinedTestDispatcher())
        val store = PlaybackStore(
            engine = engine,
            registry = PlaybackSessionRegistry(),
            keepAlive = FakeKeepAlive(),
            songUrlResolver = SongUrlResolver(FakeKugouApi(), loudnessCache),
            loudnessCache = loudnessCache,
            cacheResolver = com.gracemusic.player.offline.NoOpPlaybackCacheResolver,
            networkAvailability = com.gracemusic.player.offline.AlwaysOnlineNetworkAvailabilityProvider,
            persistence = persistence,
            scope = scope,
        )
        return Harness(store, engine, persistence, scope)
    }

    private fun localSong(id: String): Song = testSong(id, isOnline = false, localPath = "/music/$id.flac")

    private fun cursorOf(
        ids: List<String>,
        currentIndex: Int = 0,
        positionMs: Long = 0,
        volume: Double = 1.0,
    ): PersistedPlaybackCursor {
        val songs = ids.map { localSong(it) }
        return PersistedPlaybackCursor(
            queue = PlaybackQueue(
                playlist = songs,
                originalPlaylist = songs,
                currentIndex = currentIndex,
                shuffleEnabled = false,
                loopMode = AppLoopMode.OFF,
            ),
            position = positionMs.milliseconds,
            volume = volume,
        )
    }

    private class FakePersistence : PlaybackPersistence {
        var toRestore: PersistedPlaybackCursor? = null
        var persistedCount = 0
        var flushCount = 0
        var clearCount = 0
        var lastPersisted: PlaybackState? = null

        override fun persistCursor(state: PlaybackState) {
            persistedCount++
            lastPersisted = state
        }

        override suspend fun flush() {
            flushCount++
        }

        override suspend fun restore(): PersistedPlaybackCursor? = toRestore

        override suspend fun clear() {
            clearCount++
            toRestore = null
        }
    }

    private class FakeKeepAlive : PlaybackKeepAlive {
        override fun start() = Unit
        override fun stop() = Unit
    }

    private class FakeKugouApi : KugouApi {
        override suspend fun songUrl(request: SongUrlRequest): SongUrlAttempt = SongUrlAttempt.Unavailable
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
        override var playbackState: Int = 1
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
    }
}
