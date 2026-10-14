package com.gracemusic.player.store

import com.gracemusic.data.model.Song
import com.gracemusic.player.model.PlaybackErrorInfo
import kotlin.time.Duration

/**
 * 播放引擎最小接口（台本 §3.3 契约，两侧严格按此签名）。
 *
 * 上层（PlaybackStore / 归约器 / 闸门）只依赖本接口，不依赖 media3：
 * 引擎实现（ExoPlayer 适配器）与消费方（Store）经由此契约解耦，
 * Store 测试用假引擎即可验证全部编排逻辑，无需 Robolectric。
 *
 * ## 线程模型（铁律）
 * 一切方法必须在**应用主线程**调用：media3 的 `ExoPlayerImpl` 内部
 * `verifyApplicationThread()` 实证（vendored 源码 `ExoPlayerImpl.java:1521-1523`
 * 的 `setAudioSessionId`；其余 setter/getter 同样有该断言）。
 * 适配器在公开方法入口以 `IllegalStateException` 显式失败，不静默出错。
 *
 * ## 单曲时间线模型（与 lite `setUrl` 模型一致）
 * 引擎循环恒关（`AppLoopMode` KDoc：Dart 侧 just_audio LoopMode 恒 off，
 * 重复播放不触发 completed，循环逻辑全部由应用层接管）。native 保持同一约定：
 * 每次 [prepare] 用**单个** [MediaItem][androidx.media3.common.MediaItem] 重建时间线，
 * 队列推进由 App 层负责。禁止把整个队列塞进时间线让 media3 自动推进
 * （会绕过 App 队列边界语义：队尾提示、空队列停机、循环模式三态）。
 *
 * ## 回调语义（EngineListener）
 * 全部回调在主线程派发。适配器对「同一事实」不重复转发
 * （状态/playing/duration/曲目身份均按值去重），上层可直接消费。
 */
interface PlaybackEngine {

    /**
     * 播放位置热流（[kotlinx.coroutines.flow.StateFlow]），约 200ms 采样一次，主线程更新。
     *
     * 仅当引擎处于活跃播放态（`isPlaying` 或 `STATE_BUFFERING`）时采样；
     * 暂停/停止时不写值（停止空转）。高频消费方（进度条、进度闸门）直接 collect，
     * 不经过 [EngineListener] 事件通道。
     */
    val positionFlow: kotlinx.coroutines.flow.StateFlow<Duration>

    /** 是否正在播放（媒体3 `Player.isPlaying` 的权威值；通知层 PLAY_PAUSE 由其直接驱动）。 */
    val isPlaying: Boolean

    /** 播放状态（媒体3 `Player.STATE_*`：IDLE / BUFFERING / READY / ENDED）。 */
    val playbackState: Int

    /** 当前曲目时长（毫秒）；未知（未装载/直播）时为 null（媒体3 `C.TIME_UNSET` 的映射）。 */
    val durationMs: Long?

    /** 已缓冲位置（毫秒）。 */
    val bufferedPositionMs: Long

    /**
     * 装载曲目并（可选）起播。
     *
     * 单曲时间线：[MediaItem][androidx.media3.common.MediaItem] 的 mediaId = [Song.id]。
     * 音源取 `isOnline` 时的 `url`、否则 `localPath`（与 lite `_createAudioSource`
     * 同序，player_provider.dart:5585）；裸绝对路径转 `file://` URI，其余原样透传。
     *
     * **拒绝语义**：无可用音源（在线曲目 url 为 null、本地曲目 localPath 与 url 皆空）时
     * **不执行、不伪造成功、不崩溃**——记录日志后直接返回，引擎状态保持原样。
     * 上层必须自行处理「装载被拒绝」（音源解析属 T-P1-05，引擎不越界）。
     *
     * @param song 目标曲目。
     * @param startPositionMs 起始位置（毫秒）；null 表示不 seek（保持 0）。
     * @param playWhenReady 装载后是否立即起播。
     */
    fun prepare(song: Song, startPositionMs: Long?, playWhenReady: Boolean)

    /** 起播（playWhenReady=true）。 */
    fun play()

    /** 暂停（playWhenReady=false）。 */
    fun pause()

    /**
     * 停止播放（保留当前媒体项，非 reset 版 stop）。
     *
     * 与 fork 换源路径一致（`AudioPlayer.java:981/984` 用 `player.stop()`）：
     * 停止后当前 MediaItem 仍可读，恢复播放/重新装载同一首歌无需重建时间线。
     */
    fun stop()

    /** 跳转到指定位置（毫秒）。 */
    fun seekTo(positionMs: Long)

    /** 相对跳转（毫秒，可为负）。 */
    fun seekBy(deltaMs: Long)

    /** 设置播放音量（媒体3 语义：0=静音，1=原音量，可 >1 增益）。 */
    fun setVolume(volume: Float)

    /** 设置播放速度（媒体3 要求 >0）。 */
    fun setSpeed(speed: Float)

    /** 注册事件监听（主线程）。 */
    fun addListener(listener: EngineListener)

    /** 移除事件监听（主线程）。 */
    fun removeListener(listener: EngineListener)

    /**
     * 释放引擎（幂等）。
     *
     * 释放后：监听全部摘除、回调全部丢弃、位置流停止采样。
     * 进程级单例引擎不随 UI 重建而释放——release 仅用于测试与显式拆卸路径。
     */
    fun release()
}

/**
 * 播放引擎事件监听（全部默认空实现，按需覆写；主线程回调）。
 *
 * 与媒体3 `Player.Listener` 的桥接规则（适配器保证）：
 * - 同一事实不重复转发：状态/playing/duration/曲目身份均按**值**去重；
 * - [onPlaybackCompleted] 仅在进入 `STATE_ENDED` 时触发一次
 *   （引擎循环恒关，ENDED 语义 = 当前曲目自然播完，队列推进由 App 层决定）；
 * - [onCurrentSongChanged] 按 mediaId 身份对账（与台本 §3.5 的
 *   `EngineMediaItemTransition` 身份检查一致：重复通知同一曲目不产生事件）。
 */
interface EngineListener {

    /** 播放状态变化（媒体3 `Player.STATE_*`）。 */
    fun onPlaybackStateChanged(playbackState: Int) {}

    /** 播放/暂停态变化（`Player.isPlaying` 权威值；通知层图标由 media3 直接驱动）。 */
    fun onIsPlayingChanged(isPlaying: Boolean) {}

    /** 时长变化；null = 时长未知（未装载/直播/已停止）。 */
    fun onDurationChanged(durationMs: Long?) {}

    /**
     * 当前曲目切换确认（按 mediaId 身份；null = 时间线已空，如 stop reset 路径）。
     *
     * 注意：重复 prepare 同一首歌不产生本事件（身份相同，无信息量）。
     */
    fun onCurrentSongChanged(songId: String?) {}

    /** 当前曲目自然播完（STATE_ENDED，仅一次）。 */
    fun onPlaybackCompleted() {}

    /**
     * 播放错误（T-P1-06 B1：透传错误码与分类，文案经 `safePlaybackErrorMessage`
     * 收敛，绝不外泄 URL/堆栈/Token）。
     *
     * [PlaybackErrorInfo] 携带原始 `errorCode` / `errorCodeName` / `httpStatusCode`
     * 与语义分类，供恢复决策入口（`RecoveryOrchestrator`）区分可重试网络错误、
     * 确定性音源失效、解码错误、用户取消等；`message` 仍是已收敛文案。
     *
     * 装载被拒绝（无音源）**不**走本通道——那是调用方的输入问题，
     * 引擎只记录日志（见 [PlaybackEngine.prepare]）。
     */
    fun onError(info: PlaybackErrorInfo) {}
}
