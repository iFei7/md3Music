package com.gracemusic.player.engine

import android.annotation.SuppressLint
import android.net.Uri
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import com.gracemusic.data.model.Song
import com.gracemusic.player.model.PlaybackErrorInfo
import com.gracemusic.player.model.extractHttpStatusCode
import com.gracemusic.player.model.safePlaybackErrorMessage
import com.gracemusic.player.store.EngineListener
import com.gracemusic.player.store.PlaybackEngine
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * [PlaybackEngine] 的 media3 ExoPlayer 适配器——真实 API 调用，零空操作桩。
 *
 * 构造参数只有 [AudioEngine]（引擎实例的封装）：播放控制、时间线投射、事件桥接
 * 全部落在此类；上层（PlaybackStore）只依赖 [PlaybackEngine] 接口。
 * DI 绑定已落地（T-P1-02）：`di/PlayerModule.kt` 的 `providePlaybackEngine`
 * （@Singleton @MainThread）等处提供本类实例；本类自身不标注 DI 注解。
 *
 * ## 实现要点（与台本 §3.3「适配器语义要点」逐条对应）
 * 1. **单曲时间线**：每次 [prepare] 以单个 `MediaItem`（mediaId = `song.id`）重建时间线；
 *    引擎循环恒关（`AppLoopMode` KDoc），队列推进由 App 层负责。
 * 2. **拒绝语义**：无可用音源时记录日志后返回，不投射、不伪造成功、不崩溃。
 * 3. **事件桥接**：`Player.Listener` → [EngineListener]，同一事实按值去重
 *    （STATE_READY 与 duration 回调重叠时也只各发一次）。
 * 4. **位置采样**：主线程协程按 ~200ms 节流写 [PlaybackEngine.positionFlow]，
 *    仅在播放态（isPlaying 或 BUFFERING）采样，暂停即停（不空转）。
 * 5. **释放安全**：[release] 后监听摘除、scope 取消、回调全部丢弃（含迟到回调路径）。
 *
 * ## 线程模型
 * media3 的 `ExoPlayerImpl` 对 setter/getter 均有 `verifyApplicationThread()`
 * （vendored 源码 `ExoPlayerImpl.java:1521-1523` 实证），故一切公开方法入口
 * 执行 [checkMainThread]，非主线程调用抛 [IllegalStateException] 而非静默出错。
 * 监听回调本身由 media3 在主线程派发（`ListenerSet` 挂在 applicationLooper 上）。
 */
@SuppressLint("UnsafeOptInUsageError")
@OptIn(UnstableApi::class)
class ExoPlayerPlaybackEngineAdapter(
    private val engine: AudioEngine,
) : PlaybackEngine, Player.Listener {

    private val player: Player get() = engine.player

    /** 引擎监听者；主线程增删，CopyOnWrite 避免回调迭代与并发增删相互踩踏。 */
    private val listeners = CopyOnWriteArrayList<EngineListener>()

    private val _positionFlow = MutableStateFlow(Duration.ZERO)

    override val positionFlow: StateFlow<Duration> = _positionFlow.asStateFlow()

    /** 位置采样协程 scope（主线程 immediate：采样写入与状态读取同线程，无锁）。 */
    private val scope = CoroutineScope(Dispatchers.Main.immediate)

    private var samplingJob: Job? = null

    /** 释放标志：置位后一切回调与命令直接丢弃。 */
    private var released = false

    // —— 「同一事实不重复转发」的去重缓存（按值对账）——
    private var lastNotifiedPlaybackState: Int = Player.STATE_IDLE
    private var lastNotifiedIsPlaying: Boolean = false
    private var lastNotifiedDurationMs: Long? = null
    private var lastNotifiedMediaId: String? = null

    init {
        player.addListener(this)
        syncPositionSampling()
    }

    // ------------------------------------------------------------------
    // 状态查询
    // ------------------------------------------------------------------

    override val isPlaying: Boolean get() = player.isPlaying

    override val playbackState: Int get() = player.playbackState

    override val durationMs: Long?
        get() = player.duration.takeIf { it != C.TIME_UNSET }

    override val bufferedPositionMs: Long get() = player.bufferedPosition

    // ------------------------------------------------------------------
    // 装载与播放控制
    // ------------------------------------------------------------------

    override fun prepare(song: Song, startPositionMs: Long?, playWhenReady: Boolean) {
        checkMainThread()
        if (released) return
        val uri = resolvePlaybackUri(song)
        if (uri == null) {
            // 拒绝执行并记录日志（不得伪造成功、不得崩）。
            // 在线曲目无 url = 音源未解析（T-P1-05 职责）；本地曲目无路径 = 数据不完整。
            Log.w(
                TAG,
                "prepare 被拒绝：歌曲无可用音源，id=${song.id}, isOnline=${song.isOnline}, " +
                    "localPath=${song.localPath}, url=${song.url}。引擎状态保持原样。",
            )
            return
        }
        // 单曲时间线：单个 MediaItem 重建（mediaId = song.id）。
        val mediaItem = MediaItem.Builder()
            .setMediaId(song.id)
            .setUri(uri)
            .build()
        player.setMediaItem(mediaItem)
        player.prepare()
        if (startPositionMs != null) {
            player.seekTo(startPositionMs.coerceAtLeast(0L))
        }
        player.playWhenReady = playWhenReady
    }

    override fun play() {
        checkMainThread()
        if (released) return
        player.play()
        syncPositionSampling()
    }

    override fun pause() {
        checkMainThread()
        if (released) return
        player.pause()
        syncPositionSampling()
    }

    override fun stop() {
        checkMainThread()
        if (released) return
        // 非 reset 版 stop：保留当前 MediaItem（恢复播放/重备同一首歌无需重建时间线）。
        // fork 换源路径同样用 player.stop()（AudioPlayer.java:981/984）。
        player.stop()
        syncPositionSampling()
    }

    override fun seekTo(positionMs: Long) {
        checkMainThread()
        if (released) return
        player.seekTo(positionMs.coerceAtLeast(0L))
    }

    override fun seekBy(deltaMs: Long) {
        checkMainThread()
        if (released) return
        // media3 1.4.1（含 :media3fork）无 Player.seekBy —— 该 API 1.5.0 才引入
        // （fork 源码 Player.java / ExoPlayer.java 均无此方法，已逐字核验）。
        // 以 currentPosition + delta 的 seekTo 等价实现；负向越界由 coerceAtLeast 兜底，
        // 正向越界由 media3 自行 clamp 到当前窗口时长。
        player.seekTo((player.currentPosition + deltaMs).coerceAtLeast(0L))
    }

    override fun setVolume(volume: Float) {
        checkMainThread()
        if (released) return
        player.volume = volume
    }

    override fun setSpeed(speed: Float) {
        checkMainThread()
        if (released) return
        player.setPlaybackSpeed(speed)
    }

    // ------------------------------------------------------------------
    // 监听管理
    // ------------------------------------------------------------------

    override fun addListener(listener: EngineListener) {
        checkMainThread()
        if (released) return
        listeners.add(listener)
    }

    override fun removeListener(listener: EngineListener) {
        checkMainThread()
        listeners.remove(listener)
    }

    override fun release() {
        checkMainThread()
        if (released) return
        released = true
        player.removeListener(this)
        samplingJob?.cancel()
        scope.cancel()
        listeners.clear()
        engine.close()
    }

    // ------------------------------------------------------------------
    // Player.Listener 桥接（media3 事件 → EngineListener）
    // ------------------------------------------------------------------

    override fun onPlaybackStateChanged(playbackState: Int) {
        if (released) return
        if (playbackState == lastNotifiedPlaybackState) return
        lastNotifiedPlaybackState = playbackState
        listeners.forEach { it.onPlaybackStateChanged(playbackState) }
        // 引擎循环恒关 → ENDED 即当前曲目自然播完（去重保证只发一次）。
        if (playbackState == Player.STATE_ENDED) {
            listeners.forEach { it.onPlaybackCompleted() }
        }
        syncPositionSampling()
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        if (released) return
        if (isPlaying == lastNotifiedIsPlaying) return
        lastNotifiedIsPlaying = isPlaying
        listeners.forEach { it.onIsPlayingChanged(isPlaying) }
        syncPositionSampling()
    }

    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
        if (released) return
        // 按 mediaId 身份对账（台本 §3.5 EngineMediaItemTransition）：重复通知同一
        // 曲目不产生事件（重复 prepare 同一首歌 / REPEAT reason 均属此类）。
        val mediaId = mediaItem?.mediaId
        if (mediaId == lastNotifiedMediaId) return
        lastNotifiedMediaId = mediaId
        listeners.forEach { it.onCurrentSongChanged(mediaId) }
    }

    override fun onPlayerError(error: PlaybackException) {
        if (released) return
        // 文案经 safePlaybackErrorMessage 收敛；原始 message 为 null/空时用兜底折叠值
        // （与 safePlaybackErrorMessage 的 else 分支一致，绝不外泄原始异常细节）。
        val message = safePlaybackErrorMessage(error.message) ?: FALLBACK_ERROR_MESSAGE
        // T-P1-06 B1：透传原始错误码/码名与 HTTP 状态码（后者从 cause 链取，取不到 null），
        // 供恢复决策入口分类；分类为纯函数，在消费侧（Store/归约器）计算。
        val info = PlaybackErrorInfo(
            message = message,
            errorCode = error.errorCode,
            errorCodeName = error.errorCodeName,
            httpStatusCode = extractHttpStatusCode(error.cause),
        )
        listeners.forEach { it.onError(info) }
    }

    override fun onEvents(player: Player, events: Player.Events) {
        if (released) return
        // media3 无独立 duration 回调（时长随 timeline/媒体项加载变化，经事件汇总暴露）。
        // 在任何事件后按值对账：STATE_READY 与 duration 回调重叠时也只各发一次。
        val durationMs = player.duration.takeIf { it != C.TIME_UNSET }
        if (durationMs != lastNotifiedDurationMs) {
            lastNotifiedDurationMs = durationMs
            listeners.forEach { it.onDurationChanged(durationMs) }
        }
    }

    // ------------------------------------------------------------------
    // 内部实现
    // ------------------------------------------------------------------

    /**
     * 主线程校验（`IllegalStateException` 显式失败，不静默出错）。
     *
     * media3 `verifyApplicationThread()` 的适配器侧镜像：提前在公开入口失败，
     * 错误信息比 media3 的 "Player is accessed on the wrong thread" 更易定位。
     */
    private fun checkMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "ExoPlayerPlaybackEngineAdapter 必须在应用主线程调用（media3 线程模型约束）"
        }
    }

    /**
     * 解析播放音源 URI；无可用音源返回 null（调用方拒绝执行）。
     *
     * 与 lite `_createAudioSource`（player_provider.dart:5585）同序：
     * 在线取 `url`，本地取 `localPath`；本地曲目在 localPath 缺失时退回 `url`
     * （NAS 按需下载回写等场景，任务措辞「url 非空且非在线占位」）。
     *
     * 裸绝对路径 → `file://` URI（lite `_resolvePlaybackUrlImpl:5665-5669` 的
     * `Uri.file` 语义；media3 侧同样不接受裸路径）。已带 scheme 的
     * （`file://` / `content://` / `http(s)://`）原样透传——lite 的 content://
     * 解析是 just_audio 的限制，media3 DataSource 原生支持，不适用于原生栈。
     */
    private fun resolvePlaybackUri(song: Song): String? {
        val raw = when {
            song.isOnline -> song.url
            !song.localPath.isNullOrEmpty() -> song.localPath
            else -> song.url
        }
        if (raw.isNullOrEmpty()) return null
        return if (raw.startsWith("/")) toFileUri(raw) else raw
    }

    /**
     * 裸绝对路径 → `file://` URI（逐段 percent-encode，`/` 保留）。
     *
     * 不用 `Uri.fromFile(File(path))`：它依赖 `File.getAbsolutePath()` 的文件系统
     * 语义（Windows JVM 上会给裸 `/` 路径加盘符前缀），而本方法的输入来自
     * MediaStore/扫描器，已是规范绝对路径——纯字符串构造行为可预期，
     * 且与 Dart `Uri.file` 的编码语义逐字符一致（空格 → %20，`/` 不编码）。
     */
    private fun toFileUri(path: String): String =
        "file://" + path.split('/').joinToString("/") { Uri.encode(it) }

    /**
     * 位置采样启停（按「已知播放态」对账，暂停即停、不空转）。
     *
     * 采样条件用去重缓存（lastNotified*）而非实时查询 player：play/pause/stop 等命令
     * 不一定触发 media3 回调，缓存状态是适配器自身维护的事实源；真实播放中暂停会经
     * onIsPlayingChanged/onPlaybackStateChanged 取消本 job。
     */
    private fun syncPositionSampling() {
        if (released) return
        val shouldSample = lastNotifiedIsPlaying || lastNotifiedPlaybackState == Player.STATE_BUFFERING
        if (shouldSample) {
            if (samplingJob?.isActive != true) {
                samplingJob = scope.launch {
                    while (isActive) {
                        delay(POSITION_SAMPLING_INTERVAL_MS)
                        if (released) break
                        // 音频在 Robolectric/无解码环境不真正推进；此处只搬运引擎
                        // 报告的 currentPosition（seek 后的值同样真实可见）。
                        _positionFlow.value = player.currentPosition.milliseconds
                    }
                }
            }
        } else {
            samplingJob?.cancel()
            samplingJob = null
        }
    }

    private companion object {
        const val TAG = "ExoPlayerEngineAdapter"

        /** 位置采样节流间隔（台本 §3.3：~200ms）。 */
        const val POSITION_SAMPLING_INTERVAL_MS = 200L

        /**
         * onError 兜底文案：与 `safePlaybackErrorMessage` 的 else 折叠值一致
         * （PlaybackException.message 为 null/空时使用，绝不外泄原始细节）。
         */
        const val FALLBACK_ERROR_MESSAGE = "播放失败，请重试"
    }
}
