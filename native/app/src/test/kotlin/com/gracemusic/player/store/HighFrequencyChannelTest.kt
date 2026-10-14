package com.gracemusic.player.store

import com.gracemusic.data.net.CloudUrlAttempt
import com.gracemusic.data.net.CloudUrlRequest
import com.gracemusic.data.net.KugouApi
import com.gracemusic.data.net.SongUrlAttempt
import com.gracemusic.data.net.SongUrlRequest
import com.gracemusic.data.source.LoudnessCache
import com.gracemusic.data.source.LoudnessStore
import com.gracemusic.data.source.SongUrlResolver
import com.gracemusic.player.model.PlaybackErrorInfo
import com.gracemusic.player.model.SleepTimerMode
import com.gracemusic.player.session.PlaybackSessionRegistry
import com.gracemusic.player.state.PlaybackEvent
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.player.state.PlaybackState
import com.gracemusic.testutil.testSong
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.abs
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
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
 * T-P1-04 高频双通道（位置流 / 定时剩余流）验收测试。
 *
 * ## 被测契约
 * [PlaybackStore] 对外三条通道，粒度严格分层：
 * - [PlaybackStore.state]：**低频**快照（切歌/暂停/seek/错误等一致性基准）；
 * - [PlaybackStore.position]：**高频**位置流（引擎 ~200ms 采样转发，逐样本）；
 * - [PlaybackStore.sleepTimerRemaining]：**高频**定时剩余流（每秒走字）。
 *
 * 核心验收（路线图 T-P1-04 完成条件）：播放中 `PlaybackState`（低频）的发射
 * 次数**不随位置采样率线性增长**；位置流单独可用。对应
 * `高频位置_低频快照发射次数不随采样率线性增长`。
 *
 * ## 基建说明（与 [PlaybackStoreTest] 同源、独立精简）
 * 不复用 [PlaybackStoreTest] 的私有内部类（改动它会波及既有 503 条断言），
 * 本文件自带一份精简假件：假引擎 / 假保活 / 假网络 / 假响度存储。时间经
 * `store.clock` + [TestScope] 虚拟时间**成对**推进（[Harness.advance]），
 * 无 sleep、无真实音频、无真实定时器。
 *
 * ## 运行器（同 [PlaybackStoreTest] 的偏离登记）
 * `android.util.Log` 在纯 JUnit 下抛 `Stub!`（Store 的效果执行器对 TODO 类
 * 效果会打日志，睡眠定时到点也打日志），故用 [RobolectricTestRunner] 承载；
 * 编排断言不依赖 Robolectric 语义。
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class HighFrequencyChannelTest {

    // ───────────────────────── 测试基建 ─────────────────────────

    /** media3 `Player.STATE_READY` 镜像（归约器以零依赖常量镜像，保持一致）。 */
    private val stateReady = 3

    /**
     * 可变时钟基值。Store 注入的 `clock()` = [offset] + 调度器虚拟时间：
     * 位置节奏测试只动 [offset]（不涉 delay），ticker 测试经 [Harness.advance]
     * 同时推进虚拟时间与时钟，保证 tick 读到的剩余量与虚拟时间严格同步。
     */
    private class MutableClock(var offset: Long)

    /** 记录型假引擎（release 后摘监听、停止采样，与真实适配器同款建模）。 */
    private class FakeEngine : PlaybackEngine {

        val calls = CopyOnWriteArrayList<String>()

        private val _positionFlow = MutableStateFlow(Duration.ZERO)
        override val positionFlow: StateFlow<Duration> = _positionFlow.asStateFlow()

        override var isPlaying: Boolean = false
        override var playbackState: Int = 1
        override var durationMs: Long? = null
        override var bufferedPositionMs: Long = 0L

        private val listeners = CopyOnWriteArrayList<EngineListener>()
        private var released = false

        override fun prepare(song: com.gracemusic.data.model.Song, startPositionMs: Long?, playWhenReady: Boolean) {
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
            released = true
            listeners.clear()
        }

        fun emitPosition(value: Duration) {
            if (released) return
            _positionFlow.value = value
        }

        fun emitPlaybackStateChanged(playbackState: Int) {
            this.playbackState = playbackState
            listeners.forEach { it.onPlaybackStateChanged(playbackState) }
        }

        fun emitIsPlayingChanged(isPlaying: Boolean) {
            this.isPlaying = isPlaying
            listeners.forEach { it.onIsPlayingChanged(isPlaying) }
        }

        fun emitDurationChanged(durationMs: Long?) {
            this.durationMs = durationMs
            listeners.forEach { it.onDurationChanged(durationMs) }
        }

        fun emitCurrentSongChanged(songId: String?) {
            listeners.forEach { it.onCurrentSongChanged(songId) }
        }

        fun emitCompleted() {
            listeners.forEach { it.onPlaybackCompleted() }
        }

        fun emitError(message: String) {
            listeners.forEach { it.onError(PlaybackErrorInfo(message = message)) }
        }
    }

    private class FakeKeepAlive : PlaybackKeepAlive {
        override fun start() = Unit
        override fun stop() = Unit
    }

    /**
     * 脚本化假 [KugouApi]：按 hash 挂起（[gates]）以锁定「解析在途」时序，
     * 用于并发/迟到回写场景；其余返回脚本结果。
     */
    private class FakeApi : KugouApi {
        val requests = CopyOnWriteArrayList<SongUrlRequest>()
        val gates = mutableMapOf<String, CompletableDeferred<Unit>>()
        var script: (SongUrlRequest) -> SongUrlAttempt = { SongUrlAttempt.Unavailable }

        override suspend fun songUrl(request: SongUrlRequest): SongUrlAttempt {
            requests.add(request)
            gates[request.hash]?.await()
            return script(request)
        }

        override suspend fun cloudUrl(request: CloudUrlRequest): CloudUrlAttempt =
            CloudUrlAttempt.Unavailable
    }

    private class FakeLoudnessStore : LoudnessStore {
        override fun load(): List<Triple<String, Double, Double?>> = emptyList()
        override fun save(entries: List<Triple<String, Double, Double?>>) = Unit
    }

    /** 流记录器：独立订阅者，记录每次去重后的发射（Unconfined → 同步可见）。 */
    private class Recorder<T>(scope: CoroutineScope, flow: Flow<T>) {
        val values = CopyOnWriteArrayList<T>()
        private val job: Job = scope.launch { flow.collect { values += it } }
        fun stop() = job.cancel()
    }

    private class Harness(
        val store: PlaybackStore,
        val engine: FakeEngine,
        val api: FakeApi,
        val clock: MutableClock,
        val scope: TestScope,
    ) {
        /**
         * 推进虚拟时间 [ms]：`clock()` 随之前进（见 [MutableClock]），
         * `advanceTimeBy` 跑窗口内任务、`runCurrent` 补跑恰在目标时刻的任务
         * （两者边界语义互补，使 tick 恰好读到整数秒剩余）。
         */
        fun advance(ms: Long) {
            scope.testScheduler.advanceTimeBy(ms)
            scope.testScheduler.runCurrent()
        }

        /** 排空调度器当前排队任务（不推进虚拟时间）。 */
        fun drain() = scope.testScheduler.runCurrent()
    }

    private fun newHarness(): Harness {
        val engine = FakeEngine()
        val api = FakeApi()
        val loudnessCache = LoudnessCache(FakeLoudnessStore())
        val scope = TestScope(UnconfinedTestDispatcher())
        val clock = MutableClock(System.currentTimeMillis())
        val store = PlaybackStore(
            engine = engine,
            registry = PlaybackSessionRegistry(),
            keepAlive = FakeKeepAlive(),
            songUrlResolver = SongUrlResolver(api, loudnessCache),
            loudnessCache = loudnessCache,
            scope = scope,
        )
        // 构造后接管时钟：使节流/倒计时全部由测试显式推进（无 sleep）。
        store.clock = { clock.offset + scope.testScheduler.currentTime }
        return Harness(store, engine, api, clock, scope)
    }

    private fun localSong(id: String): com.gracemusic.data.model.Song =
        testSong(id, isOnline = false, localPath = "/music/$id.flac")

    private fun localSongs(vararg ids: String): List<com.gracemusic.data.model.Song> =
        ids.map { localSong(it) }

    private fun onlineSong(id: String): com.gracemusic.data.model.Song = testSong(id)

    /** 引擎对一次起播的收敛：READY → 时长 → isPlaying(true)。 */
    private fun FakeEngine.converge(durationMs: Long = 600_000) {
        emitPlaybackStateChanged(stateReady)
        emitDurationChanged(durationMs)
        emitIsPlayingChanged(true)
    }

    // ═════════════════ 1. 高频进度：低频快照不随采样率线性增长 ═════════════════

    private data class CadenceRun(
        val stateEmissions: Int,
        val positionEmissions: Int,
        val samples: Int,
    )

    /**
     * 以给定采样节奏推进 [windowMs] 毫秒，返回两条通道各自的发射次数。
     *
     * 低频快照发射由 `PlaybackStore.SNAPSHOT_REFRESH_INTERVAL_MS`（1s）节流；
     * 位置流逐样本转发。两者发射次数的比值即「通道分离度」。
     */
    private fun runCadence(cadenceMs: Long, windowMs: Long): CadenceRun {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val states = Recorder(collectors, h.store.state)
        val positions = Recorder(collectors, h.store.position)
        val stateBase = states.values.size
        val positionBase = positions.values.size

        var elapsed = 0L
        var samples = 0
        while (elapsed < windowMs) {
            elapsed += cadenceMs
            h.clock.offset += cadenceMs
            h.engine.emitPosition(elapsed.milliseconds)
            samples++
        }

        states.stop()
        positions.stop()
        return CadenceRun(
            stateEmissions = states.values.size - stateBase,
            positionEmissions = positions.values.size - positionBase,
            samples = samples,
        )
    }

    @Test
    fun `高频位置_低频快照发射次数不随采样率线性增长`() {
        val fast = runCadence(cadenceMs = 50, windowMs = 10_000)
        val slow = runCadence(cadenceMs = 200, windowMs = 10_000)

        assertEquals(200, fast.samples)
        assertEquals(50, slow.samples)

        // 位置流逐样本推进：采样率越高，位置发射越多（高频通道承载高频数据）。
        assertTrue(
            "位置流必须逐样本可达：fast=${fast.positionEmissions} slow=${slow.positionEmissions}",
            fast.positionEmissions >= 200 && slow.positionEmissions >= 50,
        )
        // 低频快照由 1s 节流决定，与采样率解耦（两者仅差 1 个节流窗）。
        assertTrue(
            "低频快照发射次数必须与采样率解耦：fast=${fast.stateEmissions} slow=${slow.stateEmissions}",
            abs(fast.stateEmissions - slow.stateEmissions) <= 2,
        )
        // 且低频发射远小于位置发射（至少 10 倍分离）——这就是「防页级抖动」的量化证据。
        assertTrue(
            "高低频通道必须分离：state=${fast.stateEmissions} position=${fast.positionEmissions}",
            fast.stateEmissions * 10 <= fast.positionEmissions,
        )
    }

    @Test
    fun `高频位置_位置流末值即最新采样且低频快照不被高频覆盖`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        h.clock.offset += 200
        h.engine.emitPosition(1.seconds) // 首个 > 基线的采样 → 进度确认
        h.clock.offset += 200
        h.engine.emitPosition(2.seconds)
        h.clock.offset += 200
        h.engine.emitPosition(3.seconds)

        assertEquals(3.seconds, h.store.position.value)
        // 未满 1s 节流窗：低频快照仍停在「进度确认」那一刻的位置（1s），
        // 证明高频位置不会逐样本污染低频快照。
        assertEquals(1.seconds, h.store.state.value.position)
        assertFalse(h.store.state.value.awaitingPlaybackProgress)
    }

    // ═════════════════ 2. 并发操作：旧操作结果不覆盖新操作 ═════════════════

    @Test
    fun `并发解析_旧操作结果不覆盖新操作`() {
        val h = newHarness()
        h.api.gates["o1"] = CompletableDeferred()
        h.api.gates["o2"] = CompletableDeferred()
        h.api.script = { request ->
            SongUrlAttempt.Resolved("https://cdn/${request.hash}", "128", false, 1L, 0L, null, null)
        }

        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1")))
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o2")))
        assertEquals("o2", h.store.state.value.currentSong?.id)

        // 新操作先返回。
        h.api.gates["o2"]?.complete(Unit)
        h.drain()
        assertEquals("https://cdn/o2", h.store.state.value.currentSong?.url)
        assertFalse(h.store.state.value.isResolvingUrl)

        // 旧操作迟到返回：不得覆盖新操作的权威结果。
        h.api.gates["o1"]?.complete(Unit)
        h.drain()
        assertEquals("o2", h.store.state.value.currentSong?.id)
        assertEquals("https://cdn/o2", h.store.state.value.currentSong?.url)
        assertEquals("旧操作的迟到回写不得触发旧曲重备", "prepare:o2:null:true", h.engine.calls.last())
    }

    // ═════════════════ 3. 旧歌曲的迟到回调被忽略 ═════════════════

    @Test
    fun `迟到回调_旧曲transition被忽略`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b", "c"), 0))
        h.engine.converge()
        h.store.dispatch(PlaybackIntent.Next())
        h.store.dispatch(PlaybackIntent.Next())
        assertEquals("c", h.store.state.value.currentSong?.id)

        val settled = h.store.state.value
        h.engine.emitCurrentSongChanged("a") // 旧曲迟到 transition
        assertEquals(settled, h.store.state.value)
        h.engine.emitCurrentSongChanged("not-in-queue") // 队列外
        assertEquals(settled, h.store.state.value)
        h.engine.emitCurrentSongChanged(null) // 时间线已空
        assertEquals(settled, h.store.state.value)
        assertEquals(2, h.store.state.value.currentIndex)
    }

    // ═════════════════ 4. 队列切换 + 进度回退抑制 ═════════════════

    @Test
    fun `队列切换_进度回退被抑制`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        h.clock.offset += 200
        h.engine.emitPosition(30.seconds)
        assertEquals(30.seconds, h.store.position.value)

        // 引擎重新缓冲 → Resume 触发带当前位置重备（arm 回退闸门，floor = 30s）。
        h.engine.emitPlaybackStateChanged(2) // STATE_BUFFERING
        h.store.dispatch(PlaybackIntent.Resume)
        assertEquals("prepare:s1:30000:true", h.engine.calls.last())

        // 装载窗内假回退（< 30s）：整条丢弃——高频位置流与低频快照都不闪回。
        h.clock.offset += 200
        h.engine.emitPosition(2.seconds)
        assertEquals(30.seconds, h.store.position.value)
        assertEquals(30.seconds, h.store.state.value.position)

        // 真实推进越过基线：确认 + 解除闸门，此后常规采样直达位置流。
        h.clock.offset += 200
        h.engine.emitPosition(31.seconds)
        assertEquals(31.seconds, h.store.position.value)
        h.clock.offset += 200
        h.engine.emitPosition(32.seconds)
        assertEquals(32.seconds, h.store.position.value)
    }

    // ═════════════════ 5. 重复订阅 / 重复事件幂等 ═════════════════

    @Test
    fun `重复订阅与重复事件_幂等`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        h.clock.offset += 200
        h.engine.emitPosition(5.seconds)

        // 重复订阅：两个独立订阅者都拿到同一当前值。
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val a = Recorder(collectors, h.store.state)
        val b = Recorder(collectors, h.store.state)
        assertEquals(h.store.state.value, a.values.last())
        assertEquals(h.store.state.value, b.values.last())

        val settled = h.store.state.value
        val positionSettled = h.store.position.value
        val aCount = a.values.size
        val bCount = b.values.size

        // 重复事件：同一事实重复投递 → 无新发射、无新引擎调用。
        h.engine.emitIsPlayingChanged(true)
        h.engine.emitPlaybackStateChanged(stateReady)
        h.engine.emitDurationChanged(600_000)
        h.engine.emitPosition(5.seconds) // 与当前采样同值

        assertEquals(settled, h.store.state.value)
        assertEquals(positionSettled, h.store.position.value)
        assertEquals(aCount, a.values.size)
        assertEquals(bCount, b.values.size)
        a.stop()
        b.stop()
    }

    // ═════════════════ 6. 取消后的迟到事件不写状态 ═════════════════

    @Test
    fun `取消后_引擎释放与作用域取消后迟到事件不写状态`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        h.clock.offset += 200
        h.engine.emitPosition(5.seconds)
        val settled = h.store.state.value
        val positionSettled = h.store.position.value

        // 引擎释放：监听摘除 + 采样停止 → 迟到回调全部丢弃。
        h.engine.release()
        h.engine.emitPlaybackStateChanged(stateReady)
        h.engine.emitIsPlayingChanged(false)
        h.engine.emitCurrentSongChanged("s1")
        h.engine.emitCompleted()
        h.engine.emitError("late")
        h.engine.emitPosition(99.seconds)
        assertEquals(settled, h.store.state.value)
        assertEquals(positionSettled, h.store.position.value)

        // 作用域取消（Service 销毁 / 进程级拆卸）：位置收集协程停止，迟到采样不入流。
        h.scope.cancel()
        h.engine.emitPosition(120.seconds)
        assertEquals(positionSettled, h.store.position.value)
    }

    // ═════════════════ 7. 空队列 / 无效索引 ═════════════════

    @Test
    fun `空队列与无效索引_无操作且不发射`() {
        val h = newHarness()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val states = Recorder(collectors, h.store.state)

        h.store.dispatch(PlaybackIntent.PlayAt(0))
        h.store.dispatch(PlaybackIntent.PlayAt(-1))
        h.store.dispatch(PlaybackIntent.Next())
        h.engine.emitCurrentSongChanged("ghost")
        assertEquals(PlaybackState(), h.store.state.value)
        assertEquals("空队列上不得有任何状态发射", 1, states.values.size)

        // 有队列但索引越界：拒绝且不发射。
        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b"), 0))
        val loaded = h.store.state.value
        val countAfterLoad = states.values.size
        h.store.dispatch(PlaybackIntent.PlayAt(5))
        h.store.dispatch(PlaybackIntent.PlayAt(-1))
        assertEquals(loaded, h.store.state.value)
        assertEquals(countAfterLoad, states.values.size)
        states.stop()
    }

    // ═════════════════ 8. 定时剩余通道（ticker 生命周期） ═════════════════

    @Test
    fun `睡眠定时通道_初始为null且设置后立即有值并每秒递减`() {
        val h = newHarness()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val channel = Recorder(collectors, h.store.sleepTimerRemaining)
        assertNull(channel.values.last())

        h.store.dispatch(PlaybackIntent.SetSleepTimer(10.seconds))
        assertEquals(10.seconds, channel.values.last()) // 设置即写满额（Dart 同）

        h.advance(1_000)
        assertEquals(9.seconds, channel.values.last())
        h.advance(1_000)
        assertEquals(8.seconds, channel.values.last())
        channel.stop()
    }

    @Test
    fun `睡眠定时通道_低频快照不随倒计时每秒发射`() {
        val h = newHarness()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val states = Recorder(collectors, h.store.state)
        val channel = Recorder(collectors, h.store.sleepTimerRemaining)

        h.store.dispatch(PlaybackIntent.SetSleepTimer(30.seconds))
        val stateCountAfterSet = states.values.size

        h.advance(10_000) // 倒计时走 10 秒

        assertEquals("每秒走字只走高频道", 20.seconds, channel.values.last())
        assertEquals(
            "低频快照不得随倒计时每秒发射",
            stateCountAfterSet,
            states.values.size,
        )
        assertEquals(
            "低频快照保持设置时的值（到点迁移属 T-P1-09）",
            30.seconds,
            h.store.state.value.sleepTimerRemaining,
        )
        states.stop()
        channel.stop()
    }

    @Test
    fun `睡眠定时通道_取消后置null且不再有任何发射`() {
        val h = newHarness()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val channel = Recorder(collectors, h.store.sleepTimerRemaining)

        h.store.dispatch(PlaybackIntent.SetSleepTimer(10.seconds))
        h.advance(1_000)
        assertEquals(9.seconds, channel.values.last())

        h.store.dispatch(PlaybackIntent.SetSleepTimer(null))
        assertNull(channel.values.last())
        val countAfterCancel = channel.values.size

        h.advance(5_000)
        assertEquals("取消后不得再有任何发射", countAfterCancel, channel.values.size)
        assertNull(h.store.state.value.sleepTimerRemaining)
        assertEquals(SleepTimerMode.OFF, h.store.state.value.sleepTimerMode)
        channel.stop()
    }

    @Test
    fun `睡眠定时通道_重设取消旧ticker并以新时长重启`() {
        val h = newHarness()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val channel = Recorder(collectors, h.store.sleepTimerRemaining)

        h.store.dispatch(PlaybackIntent.SetSleepTimer(10.seconds))
        h.advance(3_000)
        assertEquals(7.seconds, channel.values.last())

        h.store.dispatch(PlaybackIntent.SetSleepTimer(20.seconds))
        assertEquals(20.seconds, channel.values.last())
        val resetIndex = channel.values.size - 1

        h.advance(2_000)
        // 旧 ticker 的 6s / 5s 不得出现——只允许新 ticker 的 19s / 18s。
        val afterReset = channel.values.drop(resetIndex + 1)
        assertEquals(listOf(19.seconds, 18.seconds), afterReset)
        channel.stop()
    }

    @Test
    fun `睡眠定时通道_到点写null并停止且不暂停不改mode`() {
        val h = newHarness()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val channel = Recorder(collectors, h.store.sleepTimerRemaining)

        h.store.dispatch(PlaybackIntent.SetSleepTimer(3.seconds))
        h.advance(1_000)
        assertEquals(2.seconds, channel.values.last())
        h.advance(1_000)
        assertEquals(1.seconds, channel.values.last())

        val engineCallsBeforeExpiry = h.engine.calls.toList()
        h.advance(1_000) // 到点

        assertNull("到点通道写 null（Dart `_scheduleSleepNotifier(null)`）", channel.values.last())
        val countAtExpiry = channel.values.size
        assertEquals(
            "到点不得自动暂停（T-P1-09 语义）",
            engineCallsBeforeExpiry,
            h.engine.calls,
        )
        assertEquals(
            "到点不得迁移 sleepTimerMode（T-P1-09 语义）",
            SleepTimerMode.COUNTDOWN,
            h.store.state.value.sleepTimerMode,
        )

        h.advance(5_000)
        assertEquals("到点后 ticker 停止，不得再有发射", countAtExpiry, channel.values.size)

        // 到点后再设新定时：ticker 必须能重新启动（到点自停已清引用）。
        h.store.dispatch(PlaybackIntent.SetSleepTimer(2.seconds))
        assertEquals(2.seconds, channel.values.last())
        h.advance(1_000)
        assertEquals(1.seconds, channel.values.last())
        channel.stop()
    }

    @Test
    fun `睡眠定时通道_切歌与停止不取消倒计时`() {
        val h = newHarness()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val channel = Recorder(collectors, h.store.sleepTimerRemaining)

        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b"), 0))
        h.store.dispatch(PlaybackIntent.SetSleepTimer(30.seconds))
        h.advance(1_000)
        assertEquals(29.seconds, channel.values.last())

        h.store.dispatch(PlaybackIntent.Next())
        h.store.dispatch(PlaybackIntent.Stop)

        h.advance(1_000)
        assertEquals(
            "睡眠定时是墙钟倒计时，切歌/停止不打断（Dart player_provider.dart:5297-5320）",
            28.seconds,
            channel.values.last(),
        )
        channel.stop()
    }

    @Test
    fun `睡眠定时通道_作用域取消后ticker释放不再发射`() {
        val h = newHarness()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val channel = Recorder(collectors, h.store.sleepTimerRemaining)

        h.store.dispatch(PlaybackIntent.SetSleepTimer(30.seconds))
        h.advance(1_000)
        assertEquals(29.seconds, channel.values.last())

        h.scope.cancel() // 进程级拆卸（Service 销毁）等价物
        val countAfterTeardown = channel.values.size

        h.advance(5_000)
        assertEquals("作用域取消后 ticker 必须释放", countAfterTeardown, channel.values.size)
        channel.stop()
    }

    // ═════════════════ 9. 不可被高频通道吞掉的事件 ═════════════════

    @Test
    fun `高频节流_错误事件仍完整到达归约器`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        // 高频采样期间（未满节流窗）投错误：必须完整到达，不被节流吃掉。
        repeat(4) { i ->
            h.clock.offset += 50
            h.engine.emitPosition(((i + 1) * 50).milliseconds)
        }
        h.engine.emitError("boom")

        assertEquals("boom", h.store.state.value.resolveError)
        assertFalse(h.store.state.value.awaitingPlaybackProgress)
    }

    @Test
    fun `高频节流_播放结束与队列切换事件仍完整到达归约器`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b", "c"), 0))
        h.engine.converge()

        repeat(4) { i ->
            h.clock.offset += 50
            h.engine.emitPosition(((i + 1) * 50).milliseconds)
        }
        // MediaItemTransition（队列切换）在高频节流下仍须到达。
        h.engine.emitCurrentSongChanged("a")
        assertEquals(0, h.store.state.value.currentIndex)

        // 播放结束（Completed）：队列自动推进到下一首，不被高频通道吞掉。
        h.engine.emitCompleted()
        assertEquals(1, h.store.state.value.currentIndex)
        assertEquals("b", h.store.state.value.currentSong?.id)
        assertTrue(h.store.state.value.awaitingPlaybackProgress)
    }
}
