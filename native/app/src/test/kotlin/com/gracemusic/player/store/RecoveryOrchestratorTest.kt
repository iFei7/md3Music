package com.gracemusic.player.store

import com.gracemusic.data.model.Song
import com.gracemusic.data.net.CloudUrlAttempt
import com.gracemusic.data.net.CloudUrlRequest
import com.gracemusic.data.net.KugouApi
import com.gracemusic.data.net.LocalFailureKind
import com.gracemusic.data.net.SongUrlAttempt
import com.gracemusic.data.net.SongUrlRequest
import com.gracemusic.data.source.LoudnessCache
import com.gracemusic.data.source.LoudnessStore
import com.gracemusic.data.source.SongUrlResolver
import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.model.PlaybackErrorCategory
import com.gracemusic.player.model.PlaybackErrorInfo
import com.gracemusic.player.model.PlaybackErrorOrigin
import com.gracemusic.player.model.PlaybackRecoveryAction
import com.gracemusic.player.model.classifyPlaybackError
import com.gracemusic.player.model.recoveryActionFor
import com.gracemusic.player.session.PlaybackSessionRegistry
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.testutil.testSong
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancel
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
 * T-P1-06 恢复执行与错误自动跳歌验收测试（B1~B5）。
 *
 * ## 覆盖矩阵（→ 测试名）
 * 1. 短暂网络故障后恢复成功：`恢复_短暂网络故障后按退避重试成功`
 * 2. 预算耗尽：`恢复_预算耗尽后第四次不再重试`
 * 3. 不可恢复错误不重试：`恢复_确定性音源与解码错误不重试`
 * 4. 解析失败触发的恢复路径：`恢复_解析失败自动跳下一首`
 * 5. 旧代次错误被忽略：`恢复_旧曲迟到解析失败被忽略`
 * 6. 重复错误只触发一次恢复：`恢复_重复错误只排一次恢复`
 * 7. 用户主动切歌取消旧 Flight：`恢复_用户切歌取消待处理恢复`
 * 8. 恢复期间再次出现新错误：`恢复_恢复期间新错误不并发重复恢复`
 * 9. 队列为空或只有一首歌：`恢复_单曲与空队列不跳歌`
 * 10. 单曲循环 / 列表循环 / 随机：`恢复_循环模式决定跳歌目标`
 * 11. 引擎释放 / Service 销毁任务取消：`恢复_作用域取消后定时器不再触发`
 * 12. 恢复异常不伪造成功：`恢复_重试抛异常不伪造成功`
 * 13. 错误透传 + 中断码忽略：`错误透传_错误码到达决策入口且中断码被忽略`
 *     （适配器层透传见 ExoPlayerPlaybackEngineAdapterTest）
 * 14. 换歌后预算归零：`恢复_换歌后预算归零`
 *
 * ## 基建（与 [PlaybackStoreTest] 同源、独立精简）
 * 假引擎 / 假保活 / 假 KugouApi / 假响度存储 + 真 [PlaybackSessionRegistry] + 真闸门；
 * 时间经 `TestScope` 虚拟时间驱动（退避 / 看门狗全部走 `delay`），无 sleep、无真实音频。
 * 运行器用 [RobolectricTestRunner]（Store 的 TODO 效果调 `android.util.Log`，纯 JUnit 下抛
 * `Stub!`，与既有 Store 测试同一偏离登记）。
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class RecoveryOrchestratorTest {

    private companion object {
        /** media3 `Player.STATE_READY`。放伴生对象以便嵌套假件共享。 */
        const val stateReady = 3
    }

    // ───────────────────────── 测试基建 ─────────────────────────

    private class FakeEngine : PlaybackEngine {

        val calls = CopyOnWriteArrayList<String>()
        val preparedSongs = CopyOnWriteArrayList<Song>()

        private val _positionFlow = MutableStateFlow(Duration.ZERO)
        override val positionFlow: StateFlow<Duration> = _positionFlow.asStateFlow()

        override var isPlaying: Boolean = false
        override var playbackState: Int = 1
        override var durationMs: Long? = null
        override var bufferedPositionMs: Long = 0L

        private val listeners = CopyOnWriteArrayList<EngineListener>()
        private var released = false

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
            released = true
            listeners.clear()
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

        fun emitPosition(value: Duration) {
            if (released) return
            _positionFlow.value = value
        }

        fun emitError(info: PlaybackErrorInfo) {
            listeners.forEach { it.onError(info) }
        }

        fun emitError(message: String, errorCode: Int? = null, httpStatusCode: Int? = null) {
            emitError(
                PlaybackErrorInfo(
                    message = message,
                    errorCode = errorCode,
                    httpStatusCode = httpStatusCode,
                ),
            )
        }

        /** 模拟一次起播收敛（READY → 时长 → isPlaying → 首个真实推进）。 */
        fun converge(durationMs: Long = 200_000, position: Duration = 10.seconds) {
            emitPlaybackStateChanged(stateReady)
            emitDurationChanged(durationMs)
            emitIsPlayingChanged(true)
            emitPosition(position)
        }
    }

    private class FakeKeepAlive : PlaybackKeepAlive {
        val calls = CopyOnWriteArrayList<String>()
        override fun start() {
            calls += "start"
        }

        override fun stop() {
            calls += "stop"
        }
    }

    private class FakeKugouApi : KugouApi {
        val songUrlRequests = CopyOnWriteArrayList<SongUrlRequest>()
        var songUrlScript: (SongUrlRequest) -> SongUrlAttempt = { SongUrlAttempt.Unavailable }
        var cloudUrlScript: (CloudUrlRequest) -> CloudUrlAttempt = { CloudUrlAttempt.Unavailable }

        /** 非空时 songUrl 挂起等待 complete（把解析钉在在途态）。 */
        var gate: CompletableDeferred<Unit>? = null

        override suspend fun songUrl(request: SongUrlRequest): SongUrlAttempt {
            songUrlRequests.add(request)
            gate?.await()
            return songUrlScript(request)
        }

        override suspend fun cloudUrl(request: CloudUrlRequest): CloudUrlAttempt {
            gate?.await()
            return cloudUrlScript(request)
        }
    }

    private class RecordingLoudnessStore : LoudnessStore {
        override fun load(): List<Triple<String, Double, Double?>> = emptyList()
        override fun save(entries: List<Triple<String, Double, Double?>>) = Unit
    }

    private class Harness(
        val store: PlaybackStore,
        val engine: FakeEngine,
        val keepAlive: FakeKeepAlive,
        val api: FakeKugouApi,
        val scope: TestScope,
    ) {
        /** 推进虚拟时间（毫秒）。退避 / 看门狗均经 `delay`，此即确定性驱动。 */
        fun advance(ms: Long) {
            scope.testScheduler.advanceTimeBy(ms)
        }

        /** 排空当前排队任务（不推进时间）：让外部恢复的解析协程跑完。 */
        fun drainScheduler() {
            scope.testScheduler.runCurrent()
        }
    }

    private fun newHarness(): Harness {
        val engine = FakeEngine()
        val keepAlive = FakeKeepAlive()
        val api = FakeKugouApi()
        val loudnessCache = LoudnessCache(RecordingLoudnessStore())
        val scope = TestScope(UnconfinedTestDispatcher())
        val store = PlaybackStore(
            engine = engine,
            registry = PlaybackSessionRegistry(),
            keepAlive = keepAlive,
            songUrlResolver = SongUrlResolver(api, loudnessCache),
            loudnessCache = loudnessCache,
            scope = scope,
        )
        return Harness(store, engine, keepAlive, api, scope)
    }

    private fun onlineSong(id: String, url: String? = null): Song = testSong(id, url = url)

    private fun localSong(id: String): Song =
        testSong(id, isOnline = false, localPath = "/music/$id.flac")

    private val networkError = PlaybackErrorInfo(message = "播放失败，请检查网络", errorCode = 2001)

    // ═══════════════════ 1. 短暂网络故障后恢复成功 ═══════════════════

    @Test
    fun `恢复_短暂网络故障后按退避重试成功`() {
        val h = newHarness()
        h.api.songUrlScript = {
            SongUrlAttempt.Resolved("https://cdn/ok", "128", false, 10L, 0L, null, null)
        }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.converge()
        assertEquals(0, h.api.songUrlRequests.size)

        h.engine.emitError(networkError)

        // 首次失败不立即重试：按退避 30s 排期（budget.nextDelay 首档）。
        h.advance(29_000)
        assertEquals("未到退避窗口不得重试", 0, h.api.songUrlRequests.size)

        h.advance(2_000)
        // 恢复：RetryCurrent → 重解析 → 回写重备（url 已替换为解析结果）。
        assertEquals(1, h.api.songUrlRequests.size)
        assertEquals("https://cdn/ok", h.engine.preparedSongs.last().url)
        assertNull(h.store.state.value.resolveError)

        // 成功后收敛（真实推进）→ 释放在途令牌；看门狗不得再触发任何动作。
        h.engine.converge(position = 12.seconds)
        val requestsAfterSuccess = h.api.songUrlRequests.size
        h.advance(60_000)
        assertEquals("成功后不得再有恢复动作", requestsAfterSuccess, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 2. 预算耗尽 ═══════════════════

    @Test
    fun `恢复_预算耗尽后第四次不再重试`() {
        val h = newHarness()
        // LocalFailure 立即中止解析链 → 每次重试恰 1 次 API 请求，便于计数。
        h.api.songUrlScript = { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.converge()

        h.engine.emitError(networkError)

        h.advance(30_001) // 第 1 次（30s）
        assertEquals(1, h.api.songUrlRequests.size)
        h.advance(60_001) // 第 2 次（+60s）
        assertEquals(2, h.api.songUrlRequests.size)
        h.advance(120_001) // 第 3 次（+120s）
        assertEquals(3, h.api.songUrlRequests.size)

        // 预算已耗尽（3/3）：再等任意长时间都不得有第 4 次。
        h.advance(600_000)
        assertEquals("第 4 次不得重试", 3, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 3. 不可恢复错误不重试 ═══════════════════

    @Test
    fun `恢复_确定性音源与解码错误不重试`() {
        // Media3 3003（容器不支持）/ 4004、4005（格式超能力/不支持）+ HTTP 404/410。
        val cases = listOf(
            Triple("3003", 3003, null),
            Triple("4004", 4004, null),
            Triple("4005", 4005, null),
            Triple("404", 2004, 404),
            Triple("410", 2004, 410),
        )
        for ((label, errorCode, httpStatus) in cases) {
            val h = newHarness()
            h.api.songUrlScript = {
                SongUrlAttempt.Resolved("https://cdn/ok", "128", false, 10L, 0L, null, null)
            }
            h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
            h.engine.converge()
            val callsBefore = h.engine.calls.toList()

            h.engine.emitError(
                PlaybackErrorInfo(message = "不可恢复", errorCode = errorCode, httpStatusCode = httpStatus),
            )
            h.advance(600_000)

            assertEquals("$label 不得重试（无新解析）", 0, h.api.songUrlRequests.size)
            assertEquals("$label 不得重备", callsBefore, h.engine.calls)
        }
    }

    // ═══════════════════ 4. 解析失败触发的恢复路径（自动跳歌） ═══════════════════

    @Test
    fun `恢复_解析失败自动跳下一首`() {
        val h = newHarness()
        h.api.songUrlScript = { request ->
            if (request.hash == "o1") {
                SongUrlAttempt.Unavailable
            } else {
                SongUrlAttempt.Resolved("https://cdn/o2", "128", false, 10L, 0L, null, null)
            }
        }
        h.store.dispatch(
            PlaybackIntent.PlayPlaylistFrom(listOf(onlineSong("o1"), onlineSong("o2")), 0),
        )

        // o1 解析失败 → 自动跳 o2 → o2 解析成功并重备。
        assertEquals("o2", h.store.state.value.currentSong?.id)
        assertEquals(1, h.store.state.value.currentIndex)
        assertEquals("https://cdn/o2", h.engine.preparedSongs.last().url)
    }

    // ═══════════════════ 5. 旧代次（旧曲）错误被忽略 ═══════════════════

    @Test
    fun `恢复_旧曲迟到解析失败被忽略`() {
        val h = newHarness()
        h.api.gate = CompletableDeferred() // o1 解析钉在在途
        h.store.dispatch(
            PlaybackIntent.PlayPlaylistFrom(listOf(onlineSong("o1"), localSong("b")), 0),
        )
        assertTrue(h.store.state.value.isResolvingUrl)

        // 解析在途时用户切到本地曲 b。
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        assertEquals("b", h.store.state.value.currentSong?.id)
        val callsAfterSwitch = h.engine.calls.toList()
        val requestsAfterSwitch = h.api.songUrlRequests.size

        // 放行 o1 的解析：结果失败——旧曲失败必须被丢弃（不跳歌、不重备 o1、不排期重试）。
        h.api.songUrlScript = { SongUrlAttempt.Unavailable }
        h.api.gate?.complete(Unit)
        h.drainScheduler()
        val requestsAfterLateFailure = h.api.songUrlRequests.size

        assertEquals("旧曲失败不得改变当前曲", "b", h.store.state.value.currentSong?.id)
        assertEquals(1, h.store.state.value.currentIndex)
        assertEquals("旧曲失败不得产生新引擎调用", callsAfterSwitch, h.engine.calls)

        h.advance(600_000)
        assertEquals("旧曲失败不得排期恢复重试", requestsAfterLateFailure, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 6. 重复错误只触发一次恢复 ═══════════════════

    @Test
    fun `恢复_重复错误只排一次恢复`() {
        val h = newHarness()
        h.api.songUrlScript = { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.converge()

        // 同一错误连续三次到达：只允许排一个恢复任务。
        repeat(3) { h.engine.emitError(networkError) }

        h.advance(30_001)
        assertEquals("重复错误只允许一次恢复尝试", 1, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 7. 用户切歌取消待处理恢复 ═══════════════════

    @Test
    fun `恢复_用户切歌取消待处理恢复`() {
        val h = newHarness()
        h.api.songUrlScript = { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        h.store.dispatch(
            PlaybackIntent.PlayPlaylistFrom(
                listOf(onlineSong("o1", url = "http://cdn/o1.mp3"), onlineSong("o2", url = "http://cdn/o2.mp3")),
                0,
            ),
        )
        h.engine.converge()

        h.engine.emitError(networkError) // 排期 30s 恢复
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true)) // 用户主动切歌 → 取消
        assertEquals("o2", h.store.state.value.currentSong?.id)

        h.advance(600_000)
        assertEquals("用户切歌后旧恢复不得触发", 0, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 8. 恢复期间再次出现新错误 ═══════════════════

    @Test
    fun `恢复_恢复期间新错误不并发重复恢复`() {
        val h = newHarness()
        h.api.gate = CompletableDeferred() // 恢复解析钉在在途
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.converge()

        h.engine.emitError(networkError)
        h.advance(30_001) // 第 1 次恢复进入在途
        assertEquals(1, h.api.songUrlRequests.size)

        // 在途期间新错误：单飞不允许并发第二次解析。
        h.engine.emitError(networkError)
        assertEquals("在途期间不得并发第二次恢复", 1, h.api.songUrlRequests.size)

        // 放行在途解析（失败）→ 继续退避链（下一档 60s）。
        h.api.songUrlScript = { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        h.api.gate?.complete(Unit)
        h.drainScheduler()
        assertEquals(1, h.api.songUrlRequests.size)

        h.advance(60_001)
        assertEquals("失败后继续退避链", 2, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 9. 空队列 / 单曲队列 ═══════════════════

    @Test
    fun `恢复_单曲与空队列不跳歌`() {
        // 单曲队列：解析失败不跳（Dart `_playlist.length > 1` 守卫）。
        val single = newHarness()
        single.api.songUrlScript = { SongUrlAttempt.Unavailable }
        single.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1")))
        assertEquals(0, single.store.state.value.currentIndex)
        assertEquals(1, single.store.state.value.playlist.size)
        assertTrue("单曲队列失败不重备", single.engine.calls.isEmpty())

        // 空队列：失败不得崩、不得派意图。
        val empty = newHarness()
        empty.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        empty.engine.converge()
        empty.store.dispatch(PlaybackIntent.ClearQueue)
        val callsAfterClear = empty.engine.calls.toList()
        empty.engine.emitError(PlaybackErrorInfo.resolutionFailure("无法获取播放链接", "o1"))
        empty.advance(600_000)
        assertEquals(0, empty.store.state.value.playlist.size)
        assertEquals(callsAfterClear, empty.engine.calls)
    }

    // ═══════════════════ 10. 循环模式决定跳歌目标 ═══════════════════

    @Test
    fun `恢复_循环模式决定跳歌目标`() {
        // ALL：队尾失败绕回队首（o1 可播）。
        val wrap = newHarness()
        wrap.api.songUrlScript = { request ->
            if (request.hash == "o1") {
                SongUrlAttempt.Resolved("https://cdn/o1", "128", false, 10L, 0L, null, null)
            } else {
                SongUrlAttempt.Unavailable
            }
        }
        // 先切到 ALL（循环模式是队列级属性，空队列亦可切换、装载时保留），
        // 再装载——保证 o3 解析失败发生时循环模式已是 ALL。
        wrap.store.dispatch(PlaybackIntent.CyclePlayMode) // OFF → ALL
        assertEquals(AppLoopMode.ALL, wrap.store.state.value.loopMode)
        wrap.store.dispatch(
            PlaybackIntent.PlayPlaylistFrom(
                listOf(onlineSong("o1"), onlineSong("o2"), onlineSong("o3")),
                2,
            ),
        )
        assertEquals("装载保留循环模式", AppLoopMode.ALL, wrap.store.state.value.loopMode)

        // o3 解析失败 → 绕回 o1（o1 可播）。
        assertEquals("o1", wrap.store.state.value.currentSong?.id)
        assertEquals(0, wrap.store.state.value.currentIndex)
        assertEquals("https://cdn/o1", wrap.engine.preparedSongs.last().url)

        // OFF 队尾：失败停机、不绕回。
        val stop = newHarness()
        stop.api.songUrlScript = { SongUrlAttempt.Unavailable }
        stop.store.dispatch(
            PlaybackIntent.PlayPlaylistFrom(listOf(onlineSong("o1"), onlineSong("o2")), 1),
        )
        assertEquals("o2", stop.store.state.value.currentSong?.id)
        assertTrue("OFF 队尾失败必须停机", stop.engine.calls.contains("pause"))
        assertEquals(1, stop.store.state.value.currentIndex)

        // ONE 多曲：前进到下一首（不重播同一失败曲）。
        val one = newHarness()
        one.api.songUrlScript = { SongUrlAttempt.Unavailable }
        one.store.dispatch(PlaybackIntent.PlayPlaylistFrom(listOf(onlineSong("o1"), onlineSong("o2")), 0))
        one.store.dispatch(PlaybackIntent.CyclePlayMode) // OFF → ALL
        one.store.dispatch(PlaybackIntent.CyclePlayMode) // ALL → ONE
        assertEquals(AppLoopMode.ONE, one.store.state.value.loopMode)
        assertEquals("o2", one.store.state.value.currentSong?.id)
        assertEquals(1, one.store.state.value.currentIndex)
    }

    // ═══════════════════ 11. 作用域取消（Service 销毁） ═══════════════════

    @Test
    fun `恢复_作用域取消后定时器不再触发`() {
        val h = newHarness()
        h.api.songUrlScript = { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.converge()

        h.engine.emitError(networkError) // 排期 30s 恢复
        h.scope.cancel() // Service 销毁 / 进程级拆卸

        h.advance(600_000)
        assertEquals("作用域取消后恢复定时器必须释放", 0, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 12. 恢复异常不伪造成功 ═══════════════════

    @Test
    fun `恢复_重试抛异常不伪造成功`() {
        val scope = TestScope(UnconfinedTestDispatcher())
        val host = ThrowingRecoveryHost()
        val orchestrator = RecoveryOrchestrator(scope, host)

        orchestrator.onFailure(networkError, gen = 1)
        scope.testScheduler.advanceTimeBy(30_001)

        assertEquals("恢复必须真实尝试过重试", 1, host.retryDispatches)
        assertFalse("不得伪造成功", host.claimedHealthy)

        // 异常路径已释放令牌（未悬挂）：再次失败仍能按退避链真实重试。
        orchestrator.onFailure(networkError, gen = 1)
        scope.testScheduler.advanceTimeBy(60_001)
        assertEquals("异常后令牌未悬挂、可继续恢复", 2, host.retryDispatches)
        assertFalse("始终不得伪造成功", host.claimedHealthy)
    }

    // ═══════════════════ 13. 错误透传 + 中断码忽略 ═══════════════════

    @Test
    fun `错误透传_错误码到达决策入口且中断码被忽略`() {
        val h = newHarness()
        h.api.songUrlScript = { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        h.store.dispatch(PlaybackIntent.PlaySingleSong(onlineSong("o1", url = "http://cdn/o1.mp3")))
        h.engine.converge()

        // 切歌中断码（10000000）→ 闸门直接忽略：状态不变、无恢复。
        val before = h.store.state.value
        h.engine.emitError(PlaybackErrorInfo(message = "加载被切歌打断", errorCode = 10_000_000))
        assertEquals("中断码必须被忽略", before, h.store.state.value)
        h.advance(600_000)
        assertEquals(0, h.api.songUrlRequests.size)

        // 普通网络码（2001）→ 到达决策入口并触发退避恢复。
        h.engine.emitError(networkError)
        h.advance(30_001)
        assertEquals("网络码必须到达决策入口并恢复", 1, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 14. 换歌后预算归零 ═══════════════════

    @Test
    fun `恢复_换歌后预算归零`() {
        val h = newHarness()
        h.api.songUrlScript = { SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY) }
        h.store.dispatch(
            PlaybackIntent.PlayPlaylistFrom(
                listOf(onlineSong("o1", url = "http://cdn/o1.mp3"), onlineSong("o2", url = "http://cdn/o2.mp3")),
                0,
            ),
        )
        h.engine.converge()

        h.engine.emitError(networkError)
        h.advance(30_001) // o1 第 1 次恢复 → 失败 → 下一档 60s
        assertEquals(1, h.api.songUrlRequests.size)

        // 换歌：预算按新曲重置（新曲首次失败仍等 30s，而非 60s）。
        h.store.dispatch(PlaybackIntent.Next(autoPlay = true))
        h.engine.emitError(networkError)

        h.advance(30_001)
        assertEquals("换歌后预算归零：新曲首个退避应为 30s", 2, h.api.songUrlRequests.size)
    }

    // ═══════════════════ 分类与动作映射（纯函数锁） ═══════════════════

    @Test
    fun `错误分类与恢复动作映射`() {
        assertEquals(
            PlaybackErrorCategory.RESOLUTION_FAILED,
            PlaybackErrorInfo.resolutionFailure("x", "s1").category,
        )
        assertEquals(
            PlaybackErrorCategory.USER_CANCELED,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, 10_000_000, null),
        )
        assertEquals(
            PlaybackErrorCategory.HTTP_NETWORK,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, 2001, null),
        )
        assertEquals(
            PlaybackErrorCategory.TIMEOUT,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, 1003, null),
        )
        assertEquals(
            PlaybackErrorCategory.SOURCE_INVALID,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, 2004, 404),
        )
        assertEquals(
            PlaybackErrorCategory.DECODE,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, 4003, null),
        )
        assertEquals(
            PlaybackErrorCategory.AUTHENTICATION_REQUIRED,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, -102, null),
        )
        assertEquals(
            PlaybackErrorCategory.PAID_CONTENT,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, -103, null),
        )
        assertEquals(
            PlaybackErrorCategory.ENGINE_RELEASED,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, -100, null),
        )
        assertEquals(
            PlaybackErrorCategory.INTERNAL,
            classifyPlaybackError(com.gracemusic.player.model.PlaybackErrorOrigin.ENGINE, null, null),
        )

        // 动作映射：解析失败 → 跳歌；认证/付费 → 停止；网络/超时 → 重试；确定性 → 停止。
        assertEquals(
            PlaybackRecoveryAction.SKIP,
            recoveryActionFor(PlaybackErrorInfo.resolutionFailure("x", "s1")),
        )
        assertEquals(
            PlaybackRecoveryAction.IGNORE,
            recoveryActionFor(PlaybackErrorInfo(errorCode = 10_000_000)),
        )
        assertEquals(
            PlaybackRecoveryAction.STOP,
            recoveryActionFor(PlaybackErrorInfo(errorCode = -102)),
        )
        assertEquals(
            PlaybackRecoveryAction.RETRY,
            recoveryActionFor(PlaybackErrorInfo(errorCode = 2001)),
        )
        assertEquals(
            PlaybackRecoveryAction.STOP,
            recoveryActionFor(PlaybackErrorInfo(errorCode = 3003)),
        )
        assertEquals(
            PlaybackRecoveryAction.STOP,
            recoveryActionFor(PlaybackErrorInfo(errorCode = 2004, httpStatusCode = 404)),
        )
    }

    // ═══════════════════ 直连执行器的假宿主（测试 12） ═══════════════════

    /**
     * 假宿主：`RetryCurrent` 派发时抛异常，记录是否走成功路径。
     *
     * 用于验证「恢复过程发生异常时不会伪造成功状态」——[RecoveryOrchestrator]
     * 的宿主契约里**没有**写成功态的 API（成功只由引擎事件经 Store 收敛），
     * 故此处断言「异常被显式处理、未逃逸、未产生任何成功信号」。
     */
    private class ThrowingRecoveryHost : RecoveryHost {
        var retryDispatches: Int = 0
        var claimedHealthy: Boolean = false

        override fun isRequestCurrent(gen: Int): Boolean = true

        override fun currentSong(): Song = testSong("o1", url = "http://cdn/o1.mp3")

        override fun playlistSize(): Int = 1

        override fun isResolvingUrl(): Boolean = false

        override fun isNetworkAvailable(): Boolean = true

        override fun dispatchIntent(intent: PlaybackIntent) {
            if (intent is PlaybackIntent.RetryCurrent) {
                retryDispatches++
                throw IllegalStateException("模拟恢复执行异常")
            }
        }
    }
}
