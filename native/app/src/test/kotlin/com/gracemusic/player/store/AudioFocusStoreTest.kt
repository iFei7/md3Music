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
import com.gracemusic.player.gate.AppForegroundListener
import com.gracemusic.player.gate.AppForegroundMonitor
import com.gracemusic.player.gate.AudioFocusEventListener
import com.gracemusic.player.gate.AudioFocusEventSource
import com.gracemusic.player.gate.AudioFocusInterruptionMode
import com.gracemusic.player.session.PlaybackSessionRegistry
import com.gracemusic.player.state.PlaybackEvent
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.testutil.testSong
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
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

/**
 * 音频焦点运行时与 [PlaybackStore] 的接线测试（T-P1-08）。
 *
 * 覆盖验收项：
 * - 系统焦点中断暂停**不**被误判为播放故障（无 `EngineError`、无重试动作）；
 * - 用户主动暂停后，焦点恢复**不**自动播放；
 * - 系统中断暂停可被 `GAIN` 精确恢复；
 * - `AppForegroundChanged` 只写事实字段，**不**驱动任何播放/重试动作（R-4 复核）；
 * - 焦点偏好意图写状态并下发 fork 标志。
 *
 * 用本地歌曲（`localPath` 非空）规避在线解析路径，使断言只聚焦焦点编排。
 */
@RunWith(RobolectricTestRunner::class)
class AudioFocusStoreTest {

    // ═══════════════════════ 焦点中断 → 暂停 ═══════════════════════

    @Test
    fun `系统中断暂停_引擎收到pause且不产生错误`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        h.startPlayingLocalSong()

        h.focus.emit(LOSS_TRANSIENT)
        h.engine.emitIsPlayingChanged(false)

        assertEquals(listOf("prepare:s1:null:true", "pause"), h.engine.calls)
        assertFalse(h.store.state.value.isPlaying)
        // 验收项：系统中断不得被误判为播放故障。
        assertNull(h.store.state.value.resolveError)
    }

    @Test
    fun `系统中断暂停_不触发任何重试动作_即使推进退避窗口`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        h.startPlayingLocalSong()

        h.focus.emit(LOSS_TRANSIENT)
        h.engine.emitIsPlayingChanged(false)
        val callsAfterPause = h.engine.calls.toList()
        h.scope.testScheduler.advanceTimeBy(300_000) // 远超 30/60/120s 退避档

        // 无 RetryCurrent、无重新 prepare、无 play。
        assertEquals(callsAfterPause, h.engine.calls)
        assertFalse(h.store.state.value.isPlaying)
    }

    @Test
    fun `系统中断暂停_清等待进度标志且不停留在解析中`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        h.startPlayingLocalSong()

        h.focus.emit(LOSS_TRANSIENT)

        assertFalse(h.store.state.value.awaitingPlaybackProgress)
        assertFalse(h.store.state.value.isResolvingUrl)
    }

    @Test
    fun `KEEP_PLAYING_短暂中断不暂停`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.KEEP_PLAYING)
        h.startPlayingLocalSong()

        h.focus.emit(LOSS_TRANSIENT)
        h.focus.emit(CAN_DUCK)

        assertEquals(listOf("prepare:s1:null:true"), h.engine.calls)
        assertTrue(h.store.state.value.isPlaying)
    }

    @Test
    fun `KEEP_PLAYING_独占LOSS暂停让路`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.KEEP_PLAYING)
        h.startPlayingLocalSong()

        h.focus.emit(LOSS)
        h.engine.emitIsPlayingChanged(false)

        assertEquals(listOf("prepare:s1:null:true", "pause"), h.engine.calls)
        assertFalse(h.store.state.value.isPlaying)
    }

    @Test
    fun `DUCK_AND_RESTORE_中断不改变播放态`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE)
        h.startPlayingLocalSong()

        h.focus.emit(LOSS_TRANSIENT)
        h.focus.emit(LOSS)

        assertEquals(listOf("prepare:s1:null:true"), h.engine.calls)
        assertTrue(h.store.state.value.isPlaying)
    }

    @Test
    fun `忽略模式_中断不暂停`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        h.store.dispatch(PlaybackIntent.SetIgnoreAudioFocus(enabled = true))
        h.startPlayingLocalSong()

        h.focus.emit(LOSS)
        h.focus.emit(LOSS_TRANSIENT)

        assertEquals(listOf("prepare:s1:null:true"), h.engine.calls)
        assertTrue(h.store.state.value.isPlaying)
    }

    // ═══════════════════════ 中断恢复 ═══════════════════════

    @Test
    fun `中断暂停后GAIN_自动恢复播放`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        h.startPlayingLocalSong()
        h.focus.emit(LOSS_TRANSIENT)
        h.engine.emitIsPlayingChanged(false)
        assertFalse(h.store.state.value.isPlaying)

        h.focus.emit(GAIN)
        h.engine.emitIsPlayingChanged(true)

        assertEquals(listOf("prepare:s1:null:true", "pause", "play"), h.engine.calls)
        assertTrue(h.store.state.value.isPlaying)
    }

    @Test
    fun `用户主动暂停后GAIN_不自动播放`() {
        // 验收项：用户主动暂停不会被焦点恢复错误地自动播放。
        val h = newHarness(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        h.startPlayingLocalSong()

        h.store.dispatch(PlaybackIntent.Pause) // 用户按下暂停
        h.engine.emitIsPlayingChanged(false)
        val callsAfterUserPause = h.engine.calls.toList()

        h.focus.emit(LOSS_TRANSIENT)
        h.focus.emit(GAIN)

        assertEquals(callsAfterUserPause, h.engine.calls)
        assertFalse(h.store.state.value.isPlaying)
    }

    @Test
    fun `用户切歌后GAIN_不恢复旧曲`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        h.store.dispatch(
            PlaybackIntent.PlayPlaylistFrom(listOf(localSong("a"), localSong("b")), 0),
        )
        h.engine.converge()
        h.focus.emit(LOSS_TRANSIENT)
        h.engine.emitIsPlayingChanged(false)

        h.store.dispatch(PlaybackIntent.Next(autoPlay = false)) // 用户切歌
        val callsAfterNext = h.engine.calls.toList()

        h.focus.emit(GAIN)

        assertEquals(callsAfterNext, h.engine.calls)
    }

    @Test
    fun `未曾中断时GAIN不恢复`() {
        val h = newHarness(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        h.startPlayingLocalSong()
        h.store.dispatch(PlaybackIntent.Pause)
        h.engine.emitIsPlayingChanged(false)
        val calls = h.engine.calls.toList()

        h.focus.emit(GAIN)

        assertEquals(calls, h.engine.calls)
    }

    // ═══════════════════ 前后台信号（R-4 复核） ═══════════════════

    @Test
    fun `回前台_只写事实字段_不触发任何播放或重试`() {
        val h = newHarness()
        h.startPlayingLocalSong()
        h.store.dispatch(PlaybackIntent.Pause)
        h.engine.emitIsPlayingChanged(false)
        val calls = h.engine.calls.toList()

        h.foreground.emit(backgrounded = true)
        h.foreground.emit(backgrounded = false)
        h.scope.testScheduler.advanceTimeBy(300_000)

        assertEquals(calls, h.engine.calls)
        assertFalse(h.store.state.value.isAppBackgrounded)
    }

    @Test
    fun `切后台_写后台事实字段`() {
        val h = newHarness()
        h.startPlayingLocalSong()

        h.foreground.emit(backgrounded = true)

        assertTrue(h.store.state.value.isAppBackgrounded)
    }

    @Test
    fun `前后台事件_同值不重复写状态`() {
        val h = newHarness()
        h.foreground.emit(backgrounded = true)
        val snapshot = h.store.state.value

        h.foreground.emit(backgrounded = true)

        // 归约 no-op（同值）→ 状态对象引用不变。
        assertTrue(snapshot === h.store.state.value)
    }

    // ═══════════════════ 焦点偏好意图 → 状态 + 标志 ═══════════════════

    @Test
    fun `SetIgnoreAudioFocus_写状态并下发fork标志`() {
        val h = newHarness()

        h.store.dispatch(PlaybackIntent.SetIgnoreAudioFocus(enabled = true))

        assertTrue(h.store.state.value.ignoreAudioFocus)
        assertEquals(true, h.focus.ignoreAudioFocus)
        assertEquals(false, h.focus.forceKeepPlaying)
        assertEquals(true, h.focus.lastForcedWillPauseWhenDucked)
    }

    @Test
    fun `SetAudioFocusInterruptionMode_写状态并下发fork标志`() {
        val h = newHarness()

        h.store.dispatch(
            PlaybackIntent.SetAudioFocusInterruptionMode(AudioFocusInterruptionMode.DUCK_AND_RESTORE),
        )

        assertEquals(
            AudioFocusInterruptionMode.DUCK_AND_RESTORE,
            h.store.state.value.audioFocusInterruptionMode,
        )
        assertEquals(false, h.focus.forceKeepPlaying)
        assertEquals(false, h.focus.lastForcedWillPauseWhenDucked)
    }

    @Test
    fun `启动即装配_监听已注册且标志已下发`() {
        val h = newHarness()

        assertEquals(1, h.focus.listeners.size)
        // 默认 KEEP_PLAYING + 非忽略。
        assertEquals(true, h.focus.forceKeepPlaying)
        assertEquals(false, h.focus.ignoreAudioFocus)
    }

    // ═══════════════════════ 测试基建 ═══════════════════════

    private val GAIN = android.media.AudioManager.AUDIOFOCUS_GAIN
    private val LOSS = android.media.AudioManager.AUDIOFOCUS_LOSS
    private val LOSS_TRANSIENT = android.media.AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
    private val CAN_DUCK = android.media.AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK

    private class Harness(
        val store: PlaybackStore,
        val engine: FakePlaybackEngine,
        val focus: FakeAudioFocusEventSource,
        val foreground: FakeAppForegroundMonitor,
        val scope: TestScope,
    ) {
        /** 装载并起播一首本地歌曲，使 `state.isPlaying` 为真。 */
        fun startPlayingLocalSong() {
            store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
            engine.converge()
        }
    }

    private fun newHarness(
        mode: AudioFocusInterruptionMode = AudioFocusInterruptionMode.KEEP_PLAYING,
    ): Harness {
        val engine = FakePlaybackEngine()
        val focus = FakeAudioFocusEventSource()
        val foreground = FakeAppForegroundMonitor()
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
            audioFocusEventSource = focus,
            appForegroundMonitor = foreground,
            scope = scope,
        )
        // 默认模式由偏好意图设置（模拟设置层冷启动回灌）。
        if (mode != AudioFocusInterruptionMode.KEEP_PLAYING) {
            store.dispatch(PlaybackIntent.SetAudioFocusInterruptionMode(mode))
        }
        return Harness(store, engine, focus, foreground, scope)
    }

    private class FakeAudioFocusEventSource : AudioFocusEventSource {
        val listeners = CopyOnWriteArrayList<AudioFocusEventListener>()
        var ignoreAudioFocus: Boolean? = null
        var forceKeepPlaying: Boolean? = null
        var lastForcedWillPauseWhenDucked: Boolean? = null

        override fun addListener(listener: AudioFocusEventListener) {
            if (!listeners.contains(listener)) listeners.add(listener)
        }

        override fun removeListener(listener: AudioFocusEventListener) {
            listeners.remove(listener)
        }

        override fun setIgnoreAudioFocus(ignore: Boolean) {
            ignoreAudioFocus = ignore
        }

        override fun setForceKeepPlaying(keepPlaying: Boolean) {
            forceKeepPlaying = keepPlaying
        }

        override fun setForcedWillPauseWhenDucked(force: Boolean?) {
            lastForcedWillPauseWhenDucked = force
        }

        /** 模拟 fork 派发一次原始焦点事件。 */
        fun emit(focusChange: Int) {
            listeners.toList().forEach { it.onAudioFocusChanged(focusChange) }
        }
    }

    private class FakeAppForegroundMonitor : AppForegroundMonitor {
        private var listener: AppForegroundListener? = null

        override fun start(listener: AppForegroundListener) {
            this.listener = listener
        }

        override fun stop() {
            listener = null
        }

        fun emit(backgrounded: Boolean) {
            listener?.onForegroundChanged(backgrounded)
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

        /**
         * 模拟引擎对一次起播的收敛：READY → 时长 → isPlaying(true) → 首个位置采样
         * （末者经进度闸门首真确认，把 `awaitingPlaybackProgress` 收敛）。
         */
        fun converge(
            durationMs: Long = 200_000,
            position: Duration = 10.seconds,
        ) {
            emitPlaybackStateChanged(STATE_READY)
            emitDurationChanged(durationMs)
            emitIsPlayingChanged(true)
            emitPosition(position)
        }
    }

    private companion object {
        const val STATE_IDLE = 1
        const val STATE_READY = 3
    }
}

/**
 * 本地歌曲构造器（文件级）。
 *
 * 刻意放在**顶层**而非测试类的成员：嵌套类 [AudioFocusStoreTest.Harness] 不是
 * `inner`，无法访问外层类的成员函数。放在顶层后两类都能调用。
 */
private fun localSong(id: String): Song =
    testSong(id, isOnline = false, localPath = "/music/$id.flac")

