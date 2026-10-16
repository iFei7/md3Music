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
import com.gracemusic.player.offline.NetworkAvailabilityProvider
import com.gracemusic.player.offline.PlaybackCacheKeys
import com.gracemusic.player.offline.PlaybackCacheResolver
import com.gracemusic.player.session.PlaybackSessionRegistry
import com.gracemusic.player.state.PlaybackEvent
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.player.state.PlaybackState
import com.gracemusic.testutil.idsOf
import com.gracemusic.testutil.testSong
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * [PlaybackStore] 的**离线前进判定**（S-B，产品需求 2026-10-15）集成测试。
 *
 * ## 覆盖对象（`PlaybackStore` 私有路径 → 本类逐一断言）
 * `tryOfflineAdvance` / `startOfflineAdvance` / `offlineAdvanceCandidates` /
 * `playCachedCandidate` / `cancelOfflineAdvance` 此前**零直接测试**，
 * `PlaybackIntent.OfflineNoPlayableCache` 在 `src/test/` 中**零引用**——
 * 本类补齐这些缺口，只驱动**公开**入口（`dispatch(intent)` / `dispatch(event)`），
 * 通过最终状态 / 引擎调用序列 / 缓存查询序列三面断言。
 *
 * ## 需求映射（R-1 ~ R-4，逐字对应产品需求）
 * | 需求 | 语义 | 本类用例 |
 * |---|---|---|
 * | **R-1** | 离线 + 当前曲之后未缓存 → 绕到下一首已缓存曲 | `R1_R2_离线Next_...` / `R1_R2_离线自然播完_...` / `循环矩阵_ALL_...` |
 * | **R-2** | 存在可播缓存曲 → 继续播放该曲 | 同上（断言引擎 `prepare` + `isPlaying`） |
 * | **R-3** | 无任何可播缓存 → 停止播放（保留队列 + 错误态） | `R3_...` / `循环矩阵_OFF_...` / `单曲_未缓存则停止` |
 * | **R-4** | 网络恢复**不**自动恢复播放 / 重试 | `R4_...` |
 *
 * ## 运行器（偏离登记，同 `PlaybackStoreTest`）
 * Store 的效果执行器对 TODO 类效果调 `android.util.Log`（纯 JUnit 下抛 `Stub!`），
 * 故用 [RobolectricTestRunner] 承载；**编排断言不依赖 Robolectric 语义**——全部行为
 * 由假引擎 / 假缓存 / 假网络端口驱动，时间经 `store.clock` 注入虚拟值、
 * 经 [Harness.advance] 推进，无 sleep、无真实网络、无真实音频。
 *
 * ## 测试基建说明（偏离登记：未复用 `PlaybackStoreTest` 的 fake）
 * 任务建议「同一包内复用既有 fake」，但 `PlaybackStoreTest.FakePlaybackEngine` /
 * `FakeKeepAlive` 均为其 `private` 嵌套类（同包不可见），且 `HighFrequencyChannelTest`
 * / `RecoveryOrchestratorTest` 亦各自持有私有 fake（本工程既有约定）。故本类按同款
 * 约定新建最小 fake，**未复制整个 Harness**，仅保留本类所需能力。
 *
 * ## 契约用例（S-B 生产修复后，见交付报告）
 * 1. `R1_R2_*` 用例把候选曲的队列 `url` 构造为**与记忆源相同**，以隔离「候选枚举」
 *    逻辑本身；「回写记忆源」的独立验证见
 *    `R1_R2_离线前进回写记忆源生效_候选url为空时以记忆源起播`——归约器把回写与起播
 *    合并为一次状态迁移（`Song.equals` 仅比 id → 纯字段级更新会被 `MutableStateFlow`
 *    去重吞掉，故必须合并）。
 * 2. `候选探测_命中后短路_不再探测后续候选`：`OfflineAdvancePolicy` 声明的「惰性短路
 *    由调用方保证」已由 `PlaybackStore.startOfflineAdvance` 兑现（首个命中即 `break`）。
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class OfflineAdvanceStoreTest {

    // ───────────────────────── 测试常量 ─────────────────────────

    /** 占位源（安全纪律：不得使用含鉴权参数的真实 URL）。 */
    private val srcA = "https://cdn.example/a"
    private val srcB = "https://cdn.example/b"
    private val srcC = "https://cdn.example/c"
    private val srcD = "https://cdn.example/d"

    /** 离线无缓存错误原始串（与 `PlaybackReducer.OFFLINE_NO_PLAYABLE_CACHE_ERROR` 同源）。 */
    private val offlineErrorRaw = "网络不可用且歌单中无已缓存歌曲"

    /** 离线无缓存错误展示串（`safePlaybackErrorMessage` 映射结果）。 */
    private val offlineErrorDisplay = "网络不可用，歌单中无已缓存歌曲"

    // ───────────────────────── 测试基建 ─────────────────────────

    /** 记录调用序列 + 可控状态 + 可触发回调的假引擎（release 摘除监听）。 */
    private class FakePlaybackEngine : PlaybackEngine {

        val calls = CopyOnWriteArrayList<String>()

        /** `prepare` 收到的完整曲目（断言回写源是否随 `Prepare` 下发）。 */
        val preparedSongs = CopyOnWriteArrayList<Song>()

        private val _positionFlow = MutableStateFlow(Duration.ZERO)
        override val positionFlow: StateFlow<Duration> = _positionFlow.asStateFlow()

        override var isPlaying: Boolean = false
        override var playbackState: Int = 1
        override var durationMs: Long? = null
        override var bufferedPositionMs: Long = 0L

        private val listeners = CopyOnWriteArrayList<EngineListener>()

        override fun prepare(song: Song, startPositionMs: Long?, playWhenReady: Boolean) {
            calls += "prepare:${song.id}:$startPositionMs:$playWhenReady"
            preparedSongs += song
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

        // —— 测试驱动：模拟引擎上报 ——

        fun emitIsPlayingChanged(isPlaying: Boolean) {
            this.isPlaying = isPlaying
            listeners.forEach { it.onIsPlayingChanged(isPlaying) }
        }

        fun emitCompleted() {
            listeners.forEach { it.onPlaybackCompleted() }
        }
    }

    /** 假保活：记录启停调用序列。 */
    private class FakeKeepAlive : PlaybackKeepAlive {
        val calls = CopyOnWriteArrayList<String>()

        override fun start() {
            calls += "start"
        }

        override fun stop() {
            calls += "stop"
        }
    }

    /**
     * 假缓存解析器：以 `"songId|quality"` 映射驱动 [resolveCachedSource]，
     * 记录**查询顺序**以便断言短路 / 代次（[resolveCalls]），并可经 [gate] 把查询
     * 钉在「在途」态以编排取消 / 迟到枚举。
     */
    private class FakePlaybackCacheResolver : PlaybackCacheResolver {

        /** 键（`PlaybackCacheKeys.key`）→ 可播源。 */
        val sources: MutableMap<String, String> = mutableMapOf()

        /** 查询顺序（songId, quality），键与调用次数即事实。 */
        val resolveCalls = CopyOnWriteArrayList<Pair<String, String>>()

        /** 源记忆写入调用（songId, quality, source）——离线前进只应**读**，不应写。 */
        val rememberCalls = CopyOnWriteArrayList<Triple<String, String, String>>()

        /** 非空时每次查询挂起等待 complete（模拟缓存 I/O 在途）。 */
        var gate: CompletableDeferred<Unit>? = null

        /** 预置一条「已完整缓存」的曲目（quality 为 null 时用兜底档）。 */
        fun cache(songId: String, source: String, quality: String? = null) {
            sources[PlaybackCacheKeys.key(songId, quality ?: PlaybackCacheKeys.DEFAULT_QUALITY)] = source
        }

        override suspend fun resolveCachedSource(songId: String, quality: String): String? {
            resolveCalls += songId to quality
            gate?.await()
            return sources[PlaybackCacheKeys.key(songId, quality)]
        }

        override suspend fun rememberResolvedSource(songId: String, quality: String, source: String) {
            rememberCalls += Triple(songId, quality, source)
            sources[PlaybackCacheKeys.key(songId, quality)] = source
        }
    }

    /** 可控网络可用性端口（`fun interface` 实现）。 */
    private class FakeNetworkAvailabilityProvider(var available: Boolean) : NetworkAvailabilityProvider {
        override fun isNetworkAvailable(): Boolean = available
    }

    /** 恒失败的假 KugouApi（离线用例不应真的解析；如误走解析路径即暴露）。 */
    private class FakeKugouApi : KugouApi {
        val songUrlRequests = CopyOnWriteArrayList<SongUrlRequest>()

        override suspend fun songUrl(request: SongUrlRequest): SongUrlAttempt {
            songUrlRequests += request
            return SongUrlAttempt.Unavailable
        }

        override suspend fun cloudUrl(request: CloudUrlRequest): CloudUrlAttempt = CloudUrlAttempt.Unavailable
    }

    private class FakeLoudnessStore : LoudnessStore {
        override fun load(): List<Triple<String, Double, Double?>> = emptyList()
        override fun save(entries: List<Triple<String, Double, Double?>>) = Unit
    }

    /** 被测组合 + 驱动辅助。 */
    private class Harness(
        val store: PlaybackStore,
        val engine: FakePlaybackEngine,
        val keepAlive: FakeKeepAlive,
        val cache: FakePlaybackCacheResolver,
        val network: FakeNetworkAvailabilityProvider,
        val api: FakeKugouApi,
        val scope: TestScope,
    ) {
        /** 排空调度器当前排队任务（不推进虚拟时间）。 */
        fun drain() {
            scope.testScheduler.runCurrent()
        }

        /** 推进虚拟时间（毫秒）——驱动退避 / 看门狗 ticker。 */
        fun advance(ms: Long) {
            scope.testScheduler.advanceTimeBy(ms)
        }

        /**
         * 装载在线歌单并从 [index] 起播，随后模拟引擎上报 `isPlaying = true`。
         *
         * **不**上报 duration / position：保持 `duration == null` 使
         * `isAbnormalCompletion` 恒为假（避免 ONE 播完走「异常结束重解析」分支），
         * 也让 CDN 看门狗的位置门（< 45s）恒拦截，测试时序不被看门狗污染。
         */
        fun beginPlayback(songs: List<Song>, index: Int = 0) {
            store.dispatch(PlaybackIntent.PlayPlaylistFrom(songs, index))
            engine.emitIsPlayingChanged(true)
        }
    }

    /**
     * 构造一套被测组合。
     *
     * [networkAvailable] 默认 `false`（离线，本类绝大多数用例的前提）；
     * 作用域用 [UnconfinedTestDispatcher]（立即启动 + 虚拟时间，无 sleep）；
     * `store.clock` 绑定测试调度器虚拟时间（看门狗 / 节流窗口确定性）。
     */
    private fun newHarness(
        networkAvailable: Boolean = false,
        cache: FakePlaybackCacheResolver = FakePlaybackCacheResolver(),
    ): Harness {
        val engine = FakePlaybackEngine()
        val keepAlive = FakeKeepAlive()
        val api = FakeKugouApi()
        val loudnessCache = LoudnessCache(FakeLoudnessStore())
        val network = FakeNetworkAvailabilityProvider(networkAvailable)
        val scope = TestScope(UnconfinedTestDispatcher())
        val store = PlaybackStore(
            engine = engine,
            registry = PlaybackSessionRegistry(),
            keepAlive = keepAlive,
            songUrlResolver = SongUrlResolver(api, loudnessCache),
            loudnessCache = loudnessCache,
            cacheResolver = cache,
            networkAvailability = network,
            scope = scope,
        )
        store.clock = { scope.testScheduler.currentTime }
        return Harness(store, engine, keepAlive, cache, network, api, scope)
    }

    private fun online(id: String, url: String): Song = testSong(id, url = url)

    private fun songIds(h: Harness): List<String> = idsOf(h.store.state.value.playlist)

    // ═══════════════════════ R-1 / R-2：绕到已缓存曲并继续播放 ═══════════════════════

    @Test
    fun `R1_R2_离线Next_跳过连续未缓存_绕到下一首已缓存曲并继续播放`() {
        val h = newHarness()
        h.cache.cache("c", srcC)
        // url 与记忆源相同：隔离「候选枚举」逻辑，回写源另测（见类 KDoc 偏离 1）。
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        val state = h.store.state.value
        assertEquals("落到已缓存曲 c 的下标", 2, state.currentIndex)
        assertEquals("c", state.currentSong?.id)
        assertTrue("R-2：继续播放", state.isPlaying)
        assertTrue("新播放请求在途", state.awaitingPlaybackProgress)
        assertNull(state.resolveError)
        // 引擎只收到 a（起播）与 c（绕到的已缓存曲）；b 从未被 prepare（离线过滤）。
        assertEquals(listOf("prepare:a:null:true", "prepare:c:null:true"), h.engine.calls)
        assertEquals(srcC, h.engine.preparedSongs.last().url)
        // 缓存查询按候选顺序：b 未命中 → c 命中。
        assertEquals(listOf("b", "c"), h.cache.resolveCalls.map { it.first })
        // 离线前进只**读**源记忆，不写（写入口仅在解析成功路径）。
        assertTrue(h.cache.rememberCalls.isEmpty())
    }

    @Test
    fun `R1_R2_离线自然播完_绕到下一首已缓存曲`() {
        val h = newHarness()
        h.cache.cache("c", srcC)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))

        h.engine.emitCompleted()
        h.drain()

        val state = h.store.state.value
        assertEquals(2, state.currentIndex)
        assertEquals("c", state.currentSong?.id)
        assertTrue(state.isPlaying)
        assertEquals(listOf("prepare:a:null:true", "prepare:c:null:true"), h.engine.calls)
    }

    // ═══════════════════════ R-3：无任何可播缓存 → 停止（保留队列 + 错误态） ═══════════════════════

    @Test
    fun `R3_离线候选全未缓存_停止播放_保留队列与当前索引_发离线错误态`() {
        val h = newHarness()
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        val state = h.store.state.value
        assertFalse("R-3：停止播放", state.isPlaying)
        assertTrue(state.playbackNotReady)
        assertEquals(offlineErrorRaw, state.resolveError)
        assertEquals(offlineErrorDisplay, state.resolveErrorForDisplay)
        // 队列与当前索引原样保留（与 Stop 的「清播放态」相反）。
        assertEquals(listOf("a", "b", "c"), songIds(h))
        assertEquals(0, state.currentIndex)
        assertEquals("a", state.currentSong?.id)
        assertFalse(state.awaitingPlaybackProgress)
        assertFalse(state.isResolvingUrl)
        assertFalse(state.manualRetryInFlight)
        // 效果恰为 Pause + StopKeepAlive：不发 Stop、不发 Play、无重试。
        assertEquals(listOf("prepare:a:null:true", "pause"), h.engine.calls)
        assertEquals(listOf("start", "stop"), h.keepAlive.calls)
        assertTrue("不得走网络解析（离线无可播缓存是终态，不经恢复链）", h.api.songUrlRequests.isEmpty())
    }

    @Test
    fun `R3_离线失败后重复Next_仍为停止态且不派发重试`() {
        val h = newHarness()
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB)))
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()
        val callsAfterFirst = h.engine.calls.toList()

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        // 第二次 Next 的归约结果是「前进」（Prepare(b)）→ 再次进入离线枚举 → 仍全未缓存 → 停止。
        assertEquals(offlineErrorRaw, h.store.state.value.resolveError)
        assertFalse(h.store.state.value.isPlaying)
        assertEquals("仅追加一次 pause（第二次停止态），无 play / 无重试", callsAfterFirst + "pause", h.engine.calls)
    }

    // ═══════════════════════ R-4：网络恢复不自动恢复播放 / 重试 ═══════════════════════

    @Test
    fun `R4_网络恢复_退避窗口内不自动恢复播放或重试`() {
        val h = newHarness()
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB)))
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()
        // 引擎如实收敛为停止（真实引擎 pause 后会回调 isPlaying=false）。
        h.engine.emitIsPlayingChanged(false)
        assertFalse(h.store.state.value.isPlaying)
        val callsAfterFailure = h.engine.calls.toList()

        // 网络恢复：Store 已移除 NetworkChanged → onExternalRecoveryTrigger 连线。
        h.network.available = true
        h.store.dispatch(PlaybackEvent.NetworkChanged(isWifi = true))
        // 推进 30 / 60 / 120s（恢复退避三档）后仍不得有任何播放 / 重试动作。
        h.advance(30_000)
        h.advance(60_000)
        h.advance(120_000)
        h.drain()

        assertEquals("R-4：不得产生任何新的引擎动作", callsAfterFailure, h.engine.calls)
        assertFalse(h.store.state.value.isPlaying)
        assertNotNull("错误态保留，等用户手动操作", h.store.state.value.resolveError)
    }

    // ═══════════════════════ 循环模式矩阵 ═══════════════════════

    @Test
    fun `循环矩阵_ALL_离线队尾绕回队首命中已缓存曲`() {
        val h = newHarness()
        h.cache.cache("a", srcA)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)), index = 2)
        h.store.dispatch(PlaybackEvent.LoopModeChanged(AppLoopMode.ALL))

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        assertEquals("ALL：队尾绕回队首", 0, h.store.state.value.currentIndex)
        assertEquals("a", h.store.state.value.currentSong?.id)
        assertEquals("prepare:a:null:true", h.engine.calls.last())
    }

    @Test
    fun `循环矩阵_OFF_离线队尾无可播缓存则停止`() {
        val h = newHarness()
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)), index = 2)

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        val state = h.store.state.value
        assertFalse(state.isPlaying)
        assertTrue(state.playbackNotReady)
        assertEquals(offlineErrorRaw, state.resolveError)
        assertEquals("队列保留在队尾", 2, state.currentIndex)
        assertEquals(listOf("prepare:c:null:true", "pause"), h.engine.calls)
    }

    @Test
    fun `循环矩阵_ONE_播完且当前曲已缓存_重播当前曲`() {
        val h = newHarness()
        h.cache.cache("a", srcA)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB)))
        h.store.dispatch(PlaybackEvent.LoopModeChanged(AppLoopMode.ONE))

        h.engine.emitCompleted()
        h.drain()

        assertEquals("ONE：当前曲已缓存 → 重播当前曲", 0, h.store.state.value.currentIndex)
        assertEquals("a", h.store.state.value.currentSong?.id)
        // 首候选为当前曲（replayCurrentFirst），故先探测 a。
        assertTrue(h.cache.resolveCalls.any { it.first == "a" })
        assertEquals(listOf("prepare:a:null:true", "prepare:a:null:true"), h.engine.calls)
    }

    @Test
    fun `循环矩阵_ONE_当前曲未缓存_前进到后续已缓存曲`() {
        val h = newHarness()
        h.cache.cache("b", srcB)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB)))
        h.store.dispatch(PlaybackEvent.LoopModeChanged(AppLoopMode.ONE))

        h.engine.emitCompleted()
        h.drain()

        assertEquals("ONE：当前曲未缓存 → 不原地重播，前进到已缓存曲", 1, h.store.state.value.currentIndex)
        assertEquals("b", h.store.state.value.currentSong?.id)
        assertEquals("prepare:b:null:true", h.engine.calls.last())
    }

    // ═══════════════════════ 退化队列：空队列 / 无效索引 ═══════════════════════

    @Test
    fun `空队列_离线Next不启动枚举不写状态`() {
        val h = newHarness()

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        assertTrue("不得启动候选枚举", h.cache.resolveCalls.isEmpty())
        assertTrue("不得产生引擎调用", h.engine.calls.isEmpty())
        assertEquals(PlaybackState(), h.store.state.value)
    }

    @Test
    fun `无效索引_空队列自然播完不启动枚举`() {
        val h = newHarness()

        h.engine.emitCompleted()
        h.drain()

        assertTrue(h.cache.resolveCalls.isEmpty())
        assertTrue(h.engine.calls.isEmpty())
        assertEquals(PlaybackState(), h.store.state.value)
    }

    // ═══════════════════════ 单曲队列 ═══════════════════════

    @Test
    fun `单曲_ONE_已缓存则重播当前曲`() {
        val h = newHarness()
        h.cache.cache("a", srcA)
        h.beginPlayback(listOf(online("a", srcA)))
        h.store.dispatch(PlaybackEvent.LoopModeChanged(AppLoopMode.ONE))

        h.engine.emitCompleted()
        h.drain()

        assertEquals(0, h.store.state.value.currentIndex)
        assertEquals("a", h.store.state.value.currentSong?.id)
        assertEquals(listOf("prepare:a:null:true", "prepare:a:null:true"), h.engine.calls)
    }

    @Test
    fun `单曲_ONE_未缓存则停止`() {
        val h = newHarness()
        h.beginPlayback(listOf(online("a", srcA)))
        h.store.dispatch(PlaybackEvent.LoopModeChanged(AppLoopMode.ONE))

        h.engine.emitCompleted()
        h.drain()

        val state = h.store.state.value
        assertFalse(state.isPlaying)
        assertTrue(state.playbackNotReady)
        assertEquals(offlineErrorRaw, state.resolveError)
        assertEquals("单曲队列保留", listOf("a"), songIds(h))
        assertEquals(0, state.currentIndex)
        assertEquals(listOf("prepare:a:null:true", "pause"), h.engine.calls)
    }

    // ═══════════════════════ 代次校验（迟到枚举被丢弃） ═══════════════════════

    @Test
    fun `代次_枚举在途时新播放族意图_迟到枚举被丢弃不写状态`() {
        val h = newHarness()
        h.cache.gate = CompletableDeferred()
        h.cache.cache("c", srcC)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        // 枚举挂在候选 b 的查询上（未完成）。
        assertEquals(listOf("b"), h.cache.resolveCalls.map { it.first })
        assertEquals("本轮归约未落地", 0, h.store.state.value.currentIndex)

        // 用户发出新的播放族意图：issue 新代次 + 取消在途枚举。
        h.store.dispatch(PlaybackIntent.PlayAt(0))
        h.cache.gate?.complete(Unit)
        h.drain()

        // 迟到枚举不得改动状态、不得产生多余的 prepare/PlayAt。
        assertEquals(0, h.store.state.value.currentIndex)
        assertEquals("a", h.store.state.value.currentSong?.id)
        assertEquals("仅停在第一个候选，未继续探测 c", listOf("b"), h.cache.resolveCalls.map { it.first })
        assertTrue(h.engine.calls.none { it.startsWith("prepare:c") })
        assertNull(h.store.state.value.resolveError)
    }

    // ═══════════════════════ 取消与资源释放 ═══════════════════════

    @Test
    fun `取消_Stop到达_在途枚举被取消且不写状态`() {
        val h = newHarness()
        h.cache.gate = CompletableDeferred()
        h.cache.cache("c", srcC)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        assertEquals(listOf("b"), h.cache.resolveCalls.map { it.first })

        h.store.dispatch(PlaybackIntent.Stop)
        h.cache.gate?.complete(Unit)
        h.drain()

        assertTrue("枚举被取消，未继续探测 c", h.cache.resolveCalls.none { it.first == "c" })
        assertTrue(h.engine.calls.none { it.startsWith("prepare:c") })
        assertTrue("Stop 语义生效", h.engine.calls.contains("stop"))
        assertEquals(0, h.store.state.value.currentIndex)
    }

    @Test
    fun `取消_ClearQueue到达_在途枚举被取消且队列清空`() {
        val h = newHarness()
        h.cache.gate = CompletableDeferred()
        h.cache.cache("c", srcC)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))

        h.store.dispatch(PlaybackIntent.ClearQueue)
        h.cache.gate?.complete(Unit)
        h.drain()

        assertTrue(h.cache.resolveCalls.none { it.first == "c" })
        assertTrue(h.engine.calls.none { it.startsWith("prepare:c") })
        assertTrue(h.store.state.value.playlist.isEmpty())
    }

    @Test
    fun `取消_作用域取消后不再有任何发射`() {
        val h = newHarness()
        h.cache.gate = CompletableDeferred()
        h.cache.cache("c", srcC)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        val callsBeforeCancel = h.engine.calls.toList()

        // 作用域取消（进程级拆卸 / Service 销毁）：在途枚举随作用域释放。
        h.scope.cancel()
        h.cache.gate?.complete(Unit)

        assertEquals(callsBeforeCancel, h.engine.calls)
        assertTrue(h.cache.resolveCalls.none { it.first == "c" })
    }

    @Test
    fun `取消_连续两次Next只保留最后一轮枚举`() {
        val h = newHarness()
        h.cache.gate = CompletableDeferred()
        h.cache.cache("c", srcC)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true)) // 第一轮（挂起）
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true)) // 第二轮（取消第一轮）
        h.cache.gate?.complete(Unit)
        h.drain()

        // 只有最后一轮落地：c 恰被 prepare 一次。
        assertEquals(1, h.engine.calls.count { it == "prepare:c:null:true" })
        assertEquals(2, h.store.state.value.currentIndex)
    }

    // ═══════════════════════ 用户显式选曲不做缓存过滤 ═══════════════════════

    @Test
    fun `用户显式选曲_离线PlayAt走既有在线路径不启动枚举`() {
        val h = newHarness()
        h.cache.cache("c", srcC) // 即便 c 已缓存，用户显式选曲也不做过滤。
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB), online("c", srcC)))

        h.store.dispatch(PlaybackIntent.PlayAt(2))
        h.drain()

        assertTrue("不得启动离线枚举", h.cache.resolveCalls.isEmpty())
        assertEquals(2, h.store.state.value.currentIndex)
        assertEquals("c", h.store.state.value.currentSong?.id)
        assertEquals("prepare:c:null:true", h.engine.calls.last())
    }

    @Test
    fun `用户显式选曲_离线PlaySingleSong走既有在线路径不启动枚举`() {
        val h = newHarness()
        h.cache.cache("x", srcA)
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB)))

        h.store.dispatch(PlaybackIntent.PlaySingleSong(online("x", srcA)))
        h.drain()

        assertTrue(h.cache.resolveCalls.isEmpty())
        assertEquals(listOf("x"), songIds(h))
        assertEquals("x", h.store.state.value.currentSong?.id)
    }

    // ═══════════════════════ 缓存键一致性（三处键同源） ═══════════════════════

    @Test
    fun `缓存键一致性_无音质档回落DEFAULT_QUALITY`() {
        val h = newHarness()
        h.cache.cache("b", srcB) // 键 = b|DEFAULT_QUALITY
        h.beginPlayback(listOf(online("a", srcA), online("b", srcB)))

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        assertEquals(
            "查询键必须与 PlaybackCacheKeys.key(songId, quality ?: DEFAULT_QUALITY) 逐字一致",
            PlaybackCacheKeys.DEFAULT_QUALITY,
            h.cache.resolveCalls.first { it.first == "b" }.second,
        )
        assertEquals(1, h.store.state.value.currentIndex)
    }

    @Test
    fun `缓存键一致性_有音质档用该曲音质档`() {
        val h = newHarness()
        val songs = listOf(
            online("a", srcA),
            testSong("b", url = srcB, quality = "320"),
            online("c", srcC),
        )
        h.cache.cache("b", srcB, quality = "320")
        h.beginPlayback(songs)

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        assertEquals(
            "查询键用 Song.quality 而非用户设置档",
            "320",
            h.cache.resolveCalls.first { it.first == "b" }.second,
        )
        assertEquals(1, h.store.state.value.currentIndex)
        assertEquals("b", h.store.state.value.currentSong?.id)
    }

    // ═══════════════════════ 听书章节边界 ═══════════════════════

    @Test
    fun `边界_听书章节_离线前进仍按缓存过滤_不因isLongAudio阻断`() {
        val h = newHarness()
        h.cache.cache("c", srcC)
        val songs = listOf(
            testSong("a", url = srcA, isLongAudio = true),
            online("b", srcB),
            online("c", srcC),
        )
        h.beginPlayback(songs)

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        // isLongAudio 的「不自动跳」守卫在 RecoveryOrchestrator.maybeAutoSkip（错误驱动、
        // 与离线无关）；离线前进（Next / 播完）本就应受 R-1/R-2 管辖，不被该守卫阻断。
        assertEquals(2, h.store.state.value.currentIndex)
        assertEquals("c", h.store.state.value.currentSong?.id)
        assertEquals("prepare:c:null:true", h.engine.calls.last())
    }

    // ═══════════════════════ 契约（S-B 生产修复后，原「已知偏离」已翻转） ═══════════════════════

    /**
     * **契约（S-B 生产修复后）**：`PlaybackStore.playCachedCandidate` 把记忆源作为
     * `PlayAt(index, source)` 一并下发，由归约器把「回写记忆源」与「起播」**合并为一次
     * 状态迁移**（`PlaybackReducer.playAt`）。
     *
     * 为什么必须合并：`Song.equals` 仅比 id（`Song.kt:123-127`）→ 纯字段级更新使
     * `state.copy(queue = updated)` 与旧 state **结构性相等** → `PlaybackStore.apply`
     * 的 `_state.value = transition.state` 被 `MutableStateFlow` 相等去重**吞掉**；
     * 合并进 `launchSong` 承载的迁移后必然改变 `isResolvingUrl` /
     * `awaitingPlaybackProgress` / `position` / `queueRevision`，故回写与起播一并落地。
     *
     * 修复前此路径击穿 R-1/R-2：候选 `url` 为空 → `needsUrlResolution` 为真 → 走离线
     * 必失败的 `ResolveSongUrl` → 落离线错误态（旧用例名
     * `已知偏离_离线前进回写记忆源未生效_候选url为空时击穿R1R2` 固化该缺陷）。
     */
    @Test
    fun `R1_R2_离线前进回写记忆源生效_候选url为空时以记忆源起播`() {
        val h = newHarness()
        h.cache.cache("c", srcC)
        // 候选曲 c 的队列 url 为空（data 层 API 不返回 url 的真实形态）。
        h.beginPlayback(listOf(online("a", srcA), testSong("b"), testSong("c")))

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        val state = h.store.state.value
        // 候选枚举：b 未命中 → c 命中即短路（不再探测后续）。
        assertEquals(listOf("b", "c"), h.cache.resolveCalls.map { it.first })
        // 落到已缓存候选 c。
        assertEquals("落到已缓存候选 c 的下标", 2, state.currentIndex)
        assertEquals("c", state.currentSong?.id)
        // 以**记忆源** prepare（而非走 ResolveSongUrl）：全程不出网。
        assertEquals("prepare:c:null:true", h.engine.calls.last())
        assertEquals("以记忆源起播", srcC, h.engine.preparedSongs.last().url)
        // R-2：继续播放、无错误态。
        assertTrue("R-2：继续播放", state.isPlaying)
        assertNull(state.resolveError)
        // 回写真的落进 state（而非被 StateFlow 去重吞掉）。
        assertEquals("回写落进队列项", srcC, state.queue.playlist[2].url)
        // 离线前进只**读**源记忆，不写（写入口仅在解析成功路径）。
        assertTrue(h.cache.rememberCalls.isEmpty())
        // 不得走网络解析（离线无可播缓存才允许落错误态；此处已命中缓存）。
        assertTrue("不得走网络解析", h.api.songUrlRequests.isEmpty())
    }

    /**
     * **契约（S-B 生产修复后）**：候选曲 `url` 为**陈旧值**（非 null 但与记忆源不同）时，
     * 同样以**记忆源**起播并把队列项回写为记忆源——避免用可能已过期的签名 URL 装载。
     */
    @Test
    fun `R1_R2_离线前进_候选url为陈旧值_以记忆源起播并回写队列项`() {
        val h = newHarness()
        val stale = "https://cdn.example/stale-c"
        h.cache.cache("c", srcC)
        h.beginPlayback(
            listOf(online("a", srcA), testSong("b"), testSong("c", url = stale)),
        )

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        val state = h.store.state.value
        assertEquals(2, state.currentIndex)
        assertEquals("c", state.currentSong?.id)
        assertEquals("以记忆源（而非陈旧 url）起播", srcC, h.engine.preparedSongs.last().url)
        assertTrue(state.isPlaying)
        assertNull(state.resolveError)
        assertEquals("队列项回写为记忆源", srcC, state.queue.playlist[2].url)
    }

    /**
     * **契约（S-B 生产修复后）**：`OfflineAdvancePolicy` KDoc 声明「惰性短路由调用方保证」
     * （`OfflineAdvancePolicy.kt`：`首个命中即停止查询`），`PlaybackStore.startOfflineAdvance`
     * 已兑现——命中首个可播缓存候选后立即 `break`，不再探测后续候选。
     *
     * 旧用例名 `已知偏离_缓存查询按候选顺序逐个探测_命中后不短路` 固化修复前行为
     * （逐个探测全部候选）；决策结果本就不变（策略仍取首个命中），此处锁死「不再多查」。
     */
    @Test
    fun `候选探测_命中后短路_不再探测后续候选`() {
        val h = newHarness()
        h.cache.cache("c", srcC)
        h.cache.cache("d", srcD)
        h.beginPlayback(
            listOf(online("a", srcA), online("b", srcB), online("c", srcC), online("d", srcD)),
        )

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        // b 未命中 → c 命中即短路：d **不再**被探测。
        assertEquals(listOf("b", "c"), h.cache.resolveCalls.map { it.first })
        // 决策仍取首个命中：落到 c。
        assertEquals(2, h.store.state.value.currentIndex)
        assertEquals("c", h.store.state.value.currentSong?.id)
    }

    /**
     * **契约（刻意，非意外）**：`AppLoopMode.OFF` + 当前索引为**队尾**时，离线枚举沿用
     * `PlaybackQueue.nextCandidateIndices()` 的 Dart `(_currentIndex + 1) % n` 语义，
     * **仍会绕回队首方向**——对应产品需求原文「**循环到**歌单下一首已缓存歌曲，若存在可
     * 播放的缓存歌曲则继续播放，若无任何可播放的歌曲则停止播放」的**全歌单存在性**判定
     * （而非「仅看当前索引之后」）。故离线路径**不**复用 `nextBoundary` 的
     * `HintAndPause` 守卫。
     *
     * 该用例独立于 `循环矩阵_OFF_离线队尾无可播缓存则停止`（那条在「全未缓存」下停止，
     * 无法区分「候选为空」与「绕回后仍未命中」）；本用例在队首方向**放一首已缓存曲**，
     * 断言确实绕回并起播。
     */
    @Test
    fun `OFF_离线队尾_绕回队首方向命中已缓存曲并起播`() {
        val h = newHarness()
        h.cache.cache("a", srcA)
        h.beginPlayback(
            listOf(online("a", srcA), online("b", srcB), online("c", srcC)),
            index = 2,
        )

        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.drain()

        val state = h.store.state.value
        assertEquals("OFF 队尾仍绕回队首方向", 0, state.currentIndex)
        assertEquals("a", state.currentSong?.id)
        assertEquals("prepare:a:null:true", h.engine.calls.last())
        assertTrue(state.isPlaying)
        assertNull(state.resolveError)
    }
}
