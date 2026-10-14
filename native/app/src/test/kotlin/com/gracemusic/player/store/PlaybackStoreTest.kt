package com.gracemusic.player.store

import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.session.DispatchOutcome
import com.gracemusic.player.session.PlaybackSessionRegistry
import com.gracemusic.player.session.PlayerCommand
import com.gracemusic.player.state.PlaybackEvent
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.player.state.PlaybackState
import com.gracemusic.testutil.testSong
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
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
 * [PlaybackStore] 编排层测试：假引擎 + 假保活 + 真 [PlaybackSessionRegistry] + 真闸门。
 *
 * ## 运行器说明（偏离登记）
 * 任务措辞为「纯 JUnit」，但 Store 的效果执行器按契约对 TODO 类效果调
 * `android.util.Log`（如 ToggleFavorite → PersistFavoriteToggle → Log.w）。
 * AGP 的 mockable-android.jar 默认让 `android.util.Log` 抛
 * `RuntimeException("Stub!")`（探针实测：纯 JUnit 下 Log.w 直接失败，
 * 既不支持 returnDefaultValues 也不改构建配置），故本测试类以
 * [RobolectricTestRunner] 承载（Robolectric 为 Log 提供 shadow 实现）。
 * **编排断言不依赖 Robolectric 语义**：全部行为由假引擎/假保活驱动，
 * 时间经 `store.clock` 注入虚拟值、看门狗 tick 经 [Harness.advanceTicker]
 * 推进虚拟时钟，无 sleep、无真实音频。
 *
 * ## 覆盖矩阵（→ 测试名）
 * - **命令翻译表 10 条**：`命令_Play映射Resume` / `命令_Pause映射Pause` /
 *   `命令_TogglePlayPause播放中映射Pause` / `命令_TogglePlayPause暂停中映射Resume` /
 *   `命令_Next映射不带自动播放的Next` / `命令_Previous映射不带自动播放的Previous` /
 *   `命令_Stop映射Stop` / `命令_ToggleFavorite只发落盘效果` / `命令_SeekTo映射SeekTo` /
 *   `命令_SeekBy映射SeekBy` / `命令_SetPlayWhenReady真假分别映射Resume与Pause`；
 *   空队列：`命令_空队列上播放族命令为无操作`（Play/TogglePlayPause/Next/Previous/
 *   SeekTo/SeekBy/ToggleFavorite；Pause/Stop 由归约器无条件下发，见测试 KDoc）。
 * - **桥接 attach/重放**：`attach前_命令进缓冲_attach后按序重放`。
 * - **意图→引擎调用序列**：`意图序列_本地曲目全链路引擎调用`。
 * - **保活两路**：`保活_意图路径效果驱动` / `保活_事件路径对账通知栏PLAY_PAUSE`。
 * - **位置管线**：`位置管线_装载窗内抑制假回退且首真推进后确认`。
 * - **过期事件**：`过期事件_快速切歌后迟到旧曲transition被丢弃`。
 * - **释放**：`释放_引擎release后迟到回调全部无状态变化`。
 * - **重复事件幂等**：`重复事件_相同事实重复投递幂等`。
 * - **错误入口**：`错误入口_装载完成后错误落状态` / `错误入口_停机后迟到错误被闸门过滤` /
 *   `错误入口_装载前错误被闸门过滤` / `错误入口_RetryCurrent重新prepare`。
 * - **Completed 队列语义**：`Completed_列表循环自动推进下一首` /
 *   `Completed_单曲循环重播当前曲`。
 * - **CDN 看门狗**：`看门狗_限速且缓冲不足触发RetryCurrent` /
 *   `看门狗_触发后受最小间隔约束` / `看门狗_平台未播放不评估` /
 *   `看门狗_本地曲目不评估` / `看门狗_位置未到45秒不评估` / `看门狗_装载保护窗内不评估`。
 * - **StateFlow 可观察**：`状态面_state与position流可观察`。
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class PlaybackStoreTest {

    // ───────────────────────── 测试基建 ─────────────────────────

    /** media3 `Player.STATE_*` 镜像（归约器同样以零依赖常量镜像，保持一致）。 */
    private val stateIdle = 1
    private val stateBuffering = 2
    private val stateReady = 3
    private val stateEnded = 4

    /** 记录调用序列 + 可控状态 + 可触发回调的假引擎（release 摘除监听、停止采样）。 */
    private class FakePlaybackEngine : PlaybackEngine {

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

        // —— 测试驱动：模拟引擎上报（主线程回调语义由适配器保证，此处直调监听者）——

        fun emitPosition(value: Duration) {
            // release 后真实适配器取消采样协程、不再产出采样；假引擎同款建模。
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
            listeners.forEach { it.onError(message) }
        }
    }

    /** 假保活：记录启停调用序列（顺序即事实）。 */
    private class FakeKeepAlive : PlaybackKeepAlive {
        val calls = CopyOnWriteArrayList<String>()

        override fun start() {
            calls += "start"
        }

        override fun stop() {
            calls += "stop"
        }
    }

    private class Harness(
        val store: PlaybackStore,
        val engine: FakePlaybackEngine,
        val keepAlive: FakeKeepAlive,
        val registry: PlaybackSessionRegistry,
        private val scope: TestScope,
    ) {
        /**
         * 推进看门狗 ticker 的虚拟时间（毫秒）。
         *
         * 看门狗不在位置采集通道上驱动（StateFlow 合并相等值，位置冻结即无新
         * 采样），而是自有周期协程；测试经 [TestScope] 的虚拟时间确定性地逐
         * 窗推进，无需 sleep。非看门狗测试不调用本方法（不推进即无 tick）。
         * 默认比检测间隔多 1ms：兼容 `advanceTimeBy` 的边界语义（恰好到点 /
         * 严格小于都只触发一个 tick）。
         */
        fun advanceTicker(ms: Long = 2_001) {
            scope.testScheduler.advanceTimeBy(ms)
        }
    }

    /**
     * 构造一套被测组合。
     *
     * 作用域用 [UnconfinedTestDispatcher]：兼具 `Dispatchers.Unconfined` 的
     * 立即启动语义（位置采样写入即在当前线程同步驱动 Store 收集协程，无
     * sleep、无调度不确定性）与虚拟时间（看门狗 ticker 可经
     * [Harness.advanceTicker] 逐窗推进）。生产注入 `Dispatchers.Main.immediate`。
     */
    private fun newHarness(registry: PlaybackSessionRegistry = PlaybackSessionRegistry()): Harness {
        val engine = FakePlaybackEngine()
        val keepAlive = FakeKeepAlive()
        val scope = TestScope(UnconfinedTestDispatcher())
        val store = PlaybackStore(
            engine = engine,
            registry = registry,
            keepAlive = keepAlive,
            scope = scope,
        )
        return Harness(store, engine, keepAlive, registry, scope)
    }

    private fun localSong(id: String): com.gracemusic.data.model.Song =
        testSong(id, isOnline = false, localPath = "/music/$id.flac")

    private fun localSongs(vararg ids: String): List<com.gracemusic.data.model.Song> =
        ids.map { localSong(it) }

    private fun onlineSong(id: String, url: String? = null): com.gracemusic.data.model.Song =
        testSong(id, url = url)

    /**
     * 模拟引擎对一次起播的收敛：READY → 时长 → isPlaying(true) → 首个位置采样
     * （末者经进度闸门首真确认，把 `awaitingPlaybackProgress` 收敛、快照落位）。
     */
    private fun FakePlaybackEngine.converge(
        durationMs: Long = 200_000,
        position: Duration = 10.seconds,
    ) {
        emitPlaybackStateChanged(stateReady)
        emitDurationChanged(durationMs)
        emitIsPlayingChanged(true)
        emitPosition(position)
    }

    // ═══════════════════════ 命令翻译表 ═══════════════════════

    @Test
    fun `命令_Play映射Resume`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        h.store.dispatch(PlayerCommand.Play)

        assertEquals(listOf("prepare:s1:null:true", "play"), h.engine.calls)
    }

    @Test
    fun `命令_Pause映射Pause`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        h.store.dispatch(PlayerCommand.Pause)

        assertEquals(listOf("prepare:s1:null:true", "pause"), h.engine.calls)
    }

    @Test
    fun `命令_TogglePlayPause播放中映射Pause`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        assertTrue(h.store.state.value.isPlaying)

        h.store.dispatch(PlayerCommand.TogglePlayPause)

        assertEquals(listOf("prepare:s1:null:true", "pause"), h.engine.calls)
    }

    @Test
    fun `命令_TogglePlayPause暂停中映射Resume`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        h.store.dispatch(PlayerCommand.Pause)
        h.engine.emitIsPlayingChanged(false)
        assertFalse(h.store.state.value.isPlaying)

        h.store.dispatch(PlayerCommand.TogglePlayPause)

        // READY 未失效 → Resume 走直接起播（无重备）。
        assertEquals(listOf("prepare:s1:null:true", "pause", "play"), h.engine.calls)
    }

    @Test
    fun `命令_Next映射不带自动播放的Next`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b", "c"), 0))
        h.engine.converge()

        h.store.dispatch(PlayerCommand.Next)

        assertEquals(listOf("prepare:a:null:true", "prepare:b:null:false"), h.engine.calls)
        assertEquals(1, h.store.state.value.currentIndex)
        assertFalse("系统侧下一首只装载不出声", h.store.state.value.awaitingPlaybackProgress)
    }

    @Test
    fun `命令_Previous映射不带自动播放的Previous`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b", "c"), 0))
        h.engine.converge()
        h.store.dispatch(PlayerCommand.Next)

        h.store.dispatch(PlayerCommand.Previous)

        assertEquals(
            listOf("prepare:a:null:true", "prepare:b:null:false", "prepare:a:null:false"),
            h.engine.calls,
        )
        assertEquals(0, h.store.state.value.currentIndex)
    }

    @Test
    fun `命令_Stop映射Stop`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        h.store.dispatch(PlayerCommand.Stop)

        assertEquals(listOf("prepare:s1:null:true", "stop"), h.engine.calls)
        assertEquals(listOf("start", "stop"), h.keepAlive.calls)
    }

    @Test
    fun `命令_ToggleFavorite只发落盘效果`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        val callsBefore = h.engine.calls.toList()

        // 收藏仓库属 P2 数据层：只登记 TODO 日志，不碰引擎、不伪造成功。
        h.store.dispatch(PlayerCommand.ToggleFavorite)

        assertEquals(callsBefore, h.engine.calls)
        assertEquals(0, h.store.state.value.currentIndex)
        assertEquals("s1", h.store.state.value.currentSong?.id)
    }

    @Test
    fun `命令_SeekTo映射SeekTo`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        h.store.dispatch(PlayerCommand.SeekTo(60_000))

        assertEquals(listOf("prepare:s1:null:true", "seekTo:60000"), h.engine.calls)
        assertEquals(60.seconds, h.store.state.value.position)
    }

    @Test
    fun `命令_SeekBy映射SeekBy`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        h.store.dispatch(PlayerCommand.SeekBy(-10_000))

        // 基准 10s（converge 落位）+ (-10s) → 钳位到 0；引擎收到原始增量。
        assertEquals(listOf("prepare:s1:null:true", "seekBy:-10000"), h.engine.calls)
        assertEquals(Duration.ZERO, h.store.state.value.position)
    }

    @Test
    fun `命令_SetPlayWhenReady真假分别映射Resume与Pause`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        h.store.dispatch(PlayerCommand.SetPlayWhenReady(false))
        assertEquals(listOf("prepare:s1:null:true", "pause"), h.engine.calls)
        h.engine.emitIsPlayingChanged(false)

        h.store.dispatch(PlayerCommand.SetPlayWhenReady(true))
        assertEquals(listOf("prepare:s1:null:true", "pause", "play"), h.engine.calls)
    }

    @Test
    fun `命令_空队列上播放族命令为无操作`() {
        val h = newHarness()
        val commands = listOf(
            PlayerCommand.Play,
            PlayerCommand.TogglePlayPause,
            PlayerCommand.Next,
            PlayerCommand.Previous,
            PlayerCommand.ToggleFavorite,
            PlayerCommand.SeekTo(1_000),
            PlayerCommand.SeekBy(1_000),
        )
        for (command in commands) {
            assertTrue(h.store.dispatch(command))
        }

        // 播放族命令在空队列上全部被归约器明确拒绝：无引擎调用、无状态变化。
        assertTrue(h.engine.calls.isEmpty())
        assertEquals(PlaybackState(), h.store.state.value)
        // 注意：Pause / Stop / SetPlayWhenReady(false) 不在此列——归约器对二者
        // 无条件下发（Dart pause/stop 同为无条件方法），引擎收到即无害空操作。
    }

    // ═══════════════════════ 桥接 attach 与重放 ═══════════════════════

    @Test
    fun `attach前_命令进缓冲_attach后按序重放`() {
        val registry = PlaybackSessionRegistry()
        // 播放域尚未就绪（Store 未构造）：命令全部暂存。
        assertEquals(DispatchOutcome.BUFFERED, registry.dispatch(PlayerCommand.Play))
        assertEquals(DispatchOutcome.BUFFERED, registry.dispatch(PlayerCommand.Pause))
        assertEquals(2, registry.pendingCount)
        assertFalse(registry.isReady)

        // 构造即 attach（init 最后一步）：缓冲命令按 FIFO 重放。
        val h = newHarness(registry)

        assertEquals(0, registry.pendingCount)
        assertTrue(registry.isReady)
        // 空队列上重放的 Play 是归约器已定义的 no-op（安全）；Pause 有真实引擎调用。
        assertEquals(listOf("pause"), h.engine.calls)
        // 就绪后直投，不再暂存。
        assertEquals(DispatchOutcome.DISPATCHED, registry.dispatch(PlayerCommand.Stop))
        assertEquals(listOf("pause", "stop"), h.engine.calls)
    }

    // ═══════════════════════ 意图 → 引擎调用序列 ═══════════════════════

    @Test
    fun `意图序列_本地曲目全链路引擎调用`() {
        val h = newHarness()

        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b", "c"), 0))
        assertEquals(listOf("prepare:a:null:true"), h.engine.calls)
        h.engine.converge()

        h.store.dispatch(PlaybackIntent.Resume) // READY 未失效 → 直接起播
        h.store.dispatch(PlaybackIntent.Pause)
        h.engine.emitIsPlayingChanged(false)
        h.store.dispatch(PlaybackIntent.Stop)

        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b", "c"), 0))
        h.engine.converge()
        h.store.dispatch(PlaybackIntent.SeekTo(60.seconds))
        h.store.dispatch(PlaybackIntent.SeekBy((-10).seconds))
        h.store.dispatch(PlaybackIntent.SetVolume(0.5))
        h.store.dispatch(PlaybackIntent.SetSpeed(1.5))
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.store.dispatch(PlaybackIntent.Previous(autoPlay = true))
        h.engine.converge(position = 15.seconds) // 上一首重备后引擎再次收敛（位置 15s）
        h.store.dispatch(PlaybackIntent.RetryCurrent)

        assertEquals(
            listOf(
                "prepare:a:null:true", // PlayPlaylistFrom 起播
                "play", // Resume（READY 直接起播）
                "pause", // Pause
                "stop", // Stop
                "prepare:a:null:true", // 重新起播
                "seekTo:60000", // SeekTo
                "seekBy:-10000", // SeekBy
                "setVolume:0.5", // SetVolume
                "setSpeed:1.5", // SetSpeed
                "prepare:b:null:true", // Next(autoPlay=true)
                "prepare:a:null:true", // Previous(autoPlay=true)
                "prepare:a:15000:true", // RetryCurrent（带当前位置 15s 重备）
            ),
            h.engine.calls,
        )
        val state = h.store.state.value
        assertEquals(0, state.currentIndex)
        assertTrue(state.manualRetryInFlight)
        assertFalse(state.isResolvingUrl)
        assertNull(state.resolveError)
    }

    // ═══════════════════════ 保活（两路） ═══════════════════════

    @Test
    fun `保活_意图路径效果驱动`() {
        val h = newHarness()

        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        assertEquals(listOf("start"), h.keepAlive.calls)

        h.store.dispatch(PlaybackIntent.Pause)
        assertEquals(listOf("start", "stop"), h.keepAlive.calls)

        h.engine.emitIsPlayingChanged(false)
        h.store.dispatch(PlaybackIntent.Resume)
        assertEquals(listOf("start", "stop", "start"), h.keepAlive.calls)
    }

    @Test
    fun `保活_事件路径对账通知栏PLAY_PAUSE`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        assertEquals(listOf("start"), h.keepAlive.calls)

        // 通知栏 PLAY_PAUSE 由 media3 直接驱动 ExoPlayer、不经意图（台本 §1.3）：
        // 唯一可见信号是引擎 isPlaying 回调，Store 据此对账保活。
        h.engine.emitIsPlayingChanged(false)
        assertEquals(listOf("start", "stop"), h.keepAlive.calls)
        assertFalse(h.store.state.value.isPlaying)

        h.engine.emitIsPlayingChanged(true)
        assertEquals(listOf("start", "stop", "start"), h.keepAlive.calls)
        assertTrue(h.store.state.value.isPlaying)
        // 对账路径不产生任何引擎命令（不起播、不重备）。
        assertEquals(listOf("prepare:s1:null:true"), h.engine.calls)
    }

    // ═══════════════════════ 位置管线 ═══════════════════════

    @Test
    fun `位置管线_装载窗内抑制假回退且首真推进后确认`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge(position = 30.seconds)
        assertEquals(30.seconds, h.store.position.value)
        assertEquals(30.seconds, h.store.state.value.position)
        assertFalse(h.store.state.value.awaitingPlaybackProgress)

        // 引擎重新缓冲 → 播放流未就绪 → Resume 触发带当前位置重备。
        h.engine.emitPlaybackStateChanged(stateBuffering)
        assertTrue(h.store.state.value.playbackNotReady)
        h.store.dispatch(PlaybackIntent.Resume)
        assertEquals("prepare:s1:30000:true", h.engine.calls.last())
        assertTrue(h.store.state.value.awaitingPlaybackProgress)

        // 装载窗内的假回退采样（< 30s）：整条丢弃——位置流与快照都不闪回。
        h.engine.emitPosition(2.seconds)
        assertEquals(30.seconds, h.store.position.value)
        assertEquals(30.seconds, h.store.state.value.position)

        // 首次超过基线的真实推进：确认等待标志 + 刷新快照基准 + 解除回退闸门。
        h.engine.emitPosition(31.seconds)
        assertEquals(31.seconds, h.store.position.value)
        assertFalse(h.store.state.value.awaitingPlaybackProgress)
        assertEquals(31.seconds, h.store.state.value.position)
        assertEquals(31.seconds, h.store.state.value.platformPosition)

        // 闸门解除后常规采样直达位置流。
        h.engine.emitPosition(32.seconds)
        assertEquals(32.seconds, h.store.position.value)
    }

    // ═══════════════════════ 过期事件 ═══════════════════════

    @Test
    fun `过期事件_快速切歌后迟到旧曲transition被丢弃`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b", "c"), 0))
        h.engine.converge()
        h.store.dispatch(PlaybackIntent.Next())
        h.store.dispatch(PlaybackIntent.Next())
        assertEquals(2, h.store.state.value.currentIndex)
        assertEquals("c", h.store.state.value.currentSong?.id)

        val settled = h.store.state.value
        // 旧曲（a，index 0）的迟到 transition：身份对账不符 → 忽略，状态不被拽回。
        h.engine.emitCurrentSongChanged("a")
        assertEquals(settled, h.store.state.value)
        // 当前曲（c，index 2）的确认：相符 → 无变化。
        h.engine.emitCurrentSongChanged("c")
        assertEquals(settled, h.store.state.value)
        // 队列外曲目 / 时间线已空：Store 侧解析不到下标，丢弃。
        h.engine.emitCurrentSongChanged("not-in-queue")
        h.engine.emitCurrentSongChanged(null)
        assertEquals(settled, h.store.state.value)
        assertEquals(2, h.store.state.value.currentIndex)
    }

    // ═══════════════════════ 释放 ═══════════════════════

    @Test
    fun `释放_引擎release后迟到回调全部无状态变化`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        val stateBefore = h.store.state.value
        val positionBefore = h.store.position.value

        h.engine.release()

        // release 后监听摘除、采样停止：一切迟到回调/采样都被丢弃。
        h.engine.emitPlaybackStateChanged(stateReady)
        h.engine.emitIsPlayingChanged(false)
        h.engine.emitCurrentSongChanged("s1")
        h.engine.emitCompleted()
        h.engine.emitError("boom")
        h.engine.emitPosition(99.seconds)

        assertEquals(stateBefore, h.store.state.value)
        assertEquals(positionBefore, h.store.position.value)
    }

    // ═══════════════════════ 重复事件幂等 ═══════════════════════

    @Test
    fun `重复事件_相同事实重复投递幂等`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        val stateBefore = h.store.state.value
        val engineCallsBefore = h.engine.calls.toList()
        val keepAliveCallsBefore = h.keepAlive.calls.toList()

        // 同一事实重复到达（真实适配器按值去重不会重发；此处验证 Store/归约器
        // 对重复投递同样幂等：无新状态发射、无额外引擎命令、无额外保活切换）。
        h.engine.emitIsPlayingChanged(true)
        h.engine.emitPlaybackStateChanged(stateReady)
        h.engine.emitDurationChanged(200_000)

        assertEquals(stateBefore, h.store.state.value)
        assertEquals(engineCallsBefore, h.engine.calls)
        assertEquals(keepAliveCallsBefore, h.keepAlive.calls)
    }

    // ═══════════════════════ 错误入口 ═══════════════════════

    @Test
    fun `错误入口_装载完成后错误落状态`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()

        h.engine.emitError("boom")

        // 闸门放行（当前代次 + 装载已完成）→ 原始错误串入状态。
        assertEquals("boom", h.store.state.value.resolveError)
        assertFalse(h.store.state.value.awaitingPlaybackProgress)
    }

    @Test
    fun `错误入口_停机后迟到错误被闸门过滤`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        h.store.dispatch(PlaybackIntent.Stop)

        h.engine.emitError("late-error")

        // Stop invalidate 后代次失效 + 装载事实作废 → 迟到错误不得覆盖新状态。
        assertNull(h.store.state.value.resolveError)
    }

    @Test
    fun `错误入口_装载前错误被闸门过滤`() {
        val h = newHarness()

        h.engine.emitError("early-error")

        // 从未发出过 Prepare/Play → loadCompleted 为假 → 装载阶段错误不上浮。
        assertNull(h.store.state.value.resolveError)
    }

    @Test
    fun `错误入口_RetryCurrent重新prepare`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge()
        h.engine.emitError("boom")

        h.store.dispatch(PlaybackIntent.RetryCurrent)

        // 手动恢复：本地曲目真实可用——带当前位置（converge 落位 10s）重新 prepare。
        assertEquals(
            listOf("prepare:s1:null:true", "prepare:s1:10000:true"),
            h.engine.calls,
        )
        val state = h.store.state.value
        assertNull(state.resolveError)
        assertTrue(state.manualRetryInFlight)
        assertTrue(state.awaitingPlaybackProgress)
    }

    // ═══════════════════ Completed 队列语义 ═══════════════════

    @Test
    fun `Completed_列表循环自动推进下一首`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b", "c"), 0))
        h.engine.converge()

        h.engine.emitCompleted()

        assertEquals(
            listOf("prepare:a:null:true", "prepare:b:null:true"),
            h.engine.calls,
        )
        assertEquals(1, h.store.state.value.currentIndex)
        assertTrue(h.store.state.value.awaitingPlaybackProgress)
    }

    @Test
    fun `Completed_单曲循环重播当前曲`() {
        val h = newHarness()
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.store.dispatch(PlaybackIntent.CyclePlayMode) // OFF → ALL
        h.store.dispatch(PlaybackIntent.CyclePlayMode) // ALL → ONE
        assertEquals(AppLoopMode.ONE, h.store.state.value.loopMode)
        h.engine.converge()

        h.engine.emitCompleted()

        assertEquals(
            listOf("prepare:s1:null:true", "seekTo:0", "play"),
            h.engine.calls,
        )
        assertEquals(Duration.ZERO, h.store.state.value.position)
    }

    // ═══════════════════ CDN 看门狗 ═══════════════════

    @Test
    fun `看门狗_限速且缓冲不足触发RetryCurrent`() {
        val h = newHarness()
        h.store.clock = { 0 }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        assertEquals(listOf("prepare:o1:null:true"), h.engine.calls)
        h.engine.isPlaying = true
        h.engine.bufferedPositionMs = 50_000
        h.engine.emitPosition(46.seconds) // 引擎当前位置 46s（ticker 读 flow 当前值）

        // 第一个检测窗（时钟 5s）：46s / 5s 墙钟 = 9.2x ≥ 0.5x → 速率达标，不动作。
        h.store.clock = { 5_000 }
        h.advanceTicker()
        assertFalse(h.store.state.value.manualRetryInFlight)

        // 第二个检测窗（时钟 7s）：位置零前进 + 剩余缓冲 4s ≤ 10s → REFRESH_SOURCE。
        h.store.clock = { 7_000 }
        h.advanceTicker()

        // 在线曲目的换源依赖 T-P1-05 解析器：决策路径已接通（RetryCurrent 派发），
        // 终端动作为 ResolveSongUrl TODO——以归约结果标志断言「已触发」。
        assertTrue(h.store.state.value.manualRetryInFlight)
        assertTrue(h.store.state.value.isResolvingUrl)
    }

    @Test
    fun `看门狗_触发后受最小间隔约束`() {
        val h = newHarness()
        h.store.clock = { 0 }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.isPlaying = true
        h.engine.bufferedPositionMs = 50_000
        h.engine.emitPosition(46.seconds)
        h.store.clock = { 5_000 }
        h.advanceTicker()
        h.store.clock = { 7_000 }
        h.advanceTicker()
        assertTrue(h.store.state.value.manualRetryInFlight)

        // 清掉在途标志（错误事件经闸门落状态，与 Dart 恢复前的清理同效），
        // 使下一次 RetryCurrent 若发生即可被观测。
        h.store.dispatch(PlaybackEvent.EngineError("boom"))
        assertFalse(h.store.state.value.isResolvingUrl)

        // 间隔仅 2s（< 10s 最小间隔）：停滞再现但不触发。
        h.store.clock = { 9_000 }
        h.advanceTicker()
        assertFalse(h.store.state.value.manualRetryInFlight)

        // 越过最小间隔（距上次换源 13s）：恢复触发。
        h.store.dispatch(PlaybackEvent.EngineError("boom2"))
        h.store.clock = { 20_000 }
        h.advanceTicker()
        assertTrue(h.store.state.value.manualRetryInFlight)
    }

    @Test
    fun `看门狗_平台未播放不评估`() {
        val h = newHarness()
        h.store.clock = { 0 }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.bufferedPositionMs = 50_000
        h.engine.emitPosition(46.seconds)
        // engine.isPlaying 保持 false（平台未播放，不用状态缓存判定）。

        h.store.clock = { 5_000 }
        h.advanceTicker()
        h.store.clock = { 7_000 }
        h.advanceTicker()

        assertFalse(h.store.state.value.manualRetryInFlight)
    }

    @Test
    fun `看门狗_本地曲目不评估`() {
        val h = newHarness()
        h.store.clock = { 0 }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.isPlaying = true
        h.engine.bufferedPositionMs = 50_000
        h.engine.emitPosition(46.seconds)

        h.store.clock = { 5_000 }
        h.advanceTicker()
        h.store.clock = { 7_000 }
        h.advanceTicker()

        assertFalse(h.store.state.value.manualRetryInFlight)
    }

    @Test
    fun `看门狗_位置未到45秒不评估`() {
        val h = newHarness()
        h.store.clock = { 0 }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.isPlaying = true
        h.engine.bufferedPositionMs = 50_000
        h.engine.emitPosition(30.seconds)

        // 30s 处停滞：第二窗起 REFRESH_SOURCE 决策会成立，但位置门（< 45s）先行拦截。
        h.store.clock = { 5_000 }
        h.advanceTicker()
        h.store.clock = { 7_000 }
        h.advanceTicker()

        assertFalse(h.store.state.value.manualRetryInFlight)
    }

    @Test
    fun `看门狗_装载保护窗内不评估`() {
        val h = newHarness()
        h.store.clock = { 0 }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.isPlaying = true
        h.engine.bufferedPositionMs = 50_000
        h.engine.emitPosition(46.seconds)

        // 装载后 1s / 2s：均在 3s 装载保护窗内，不评估（避免把首次缓冲误判为限速）。
        h.store.clock = { 1_000 }
        h.advanceTicker()
        h.store.clock = { 2_000 }
        h.advanceTicker()

        assertFalse(h.store.state.value.manualRetryInFlight)
    }

    // ═══════════════════ 状态面可观察 ═══════════════════

    @Test
    fun `状态面_state与position流可观察`() {
        val h = newHarness()
        val states = CopyOnWriteArrayList<PlaybackState>()
        val positions = CopyOnWriteArrayList<Duration>()
        val collectors = CoroutineScope(Dispatchers.Unconfined)
        val stateJob: Job = collectors.launch { h.store.state.collect { states += it } }
        val positionJob: Job = collectors.launch { h.store.position.collect { positions += it } }

        h.store.dispatch(PlaybackIntent.PlaySingleSong(localSong("s1")))
        h.engine.converge(position = 42.seconds)
        h.store.dispatch(PlaybackIntent.Pause)

        stateJob.cancel()
        positionJob.cancel()

        // StateFlow 语义：初始值 + 每次去重后的变化都可观测，末值即当前值。
        assertTrue("至少观测到初始态与若干次变化：${states.size}", states.size >= 3)
        assertEquals(h.store.state.value, states.last())
        assertEquals(h.store.position.value, positions.last())
        assertTrue("高频位置采样必须进入 position 流", positions.contains(42.seconds))
        assertEquals(Duration.ZERO, positions.first())
    }
}
