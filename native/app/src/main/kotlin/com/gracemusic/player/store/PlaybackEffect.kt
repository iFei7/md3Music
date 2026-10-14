package com.gracemusic.player.store

import com.gracemusic.data.model.Song

/**
 * 播放域副作用（MVI 的 `Effect`）——[com.gracemusic.player.state.PlaybackIntent] 归约的
 * **产出物之一**，由 PlaybackStore 消费执行；归约器本身不执行任何效果。
 *
 * 设计契约（台本 §3.2）：**字段名即引擎方法签名**——引擎类效果的字段与
 * [PlaybackEngine] 的形参一一对应，Store 的效果执行器据此直调，不再做二次翻译：
 *
 * | 效果 | 引擎/系统入口 |
 * |---|---|
 * | [Prepare] | `PlaybackEngine.prepare(song, startPositionMs, playWhenReady)` |
 * | [Play] / [Pause] / [Stop] | `play()` / `pause()` / `stop()` |
 * | [SeekTo] / [SeekBy] | `seekTo(positionMs)` / `seekBy(deltaMs)` |
 * | [SetVolume] / [SetSpeed] | `setVolume(volume)` / `setSpeed(speed)` |
 *
 * ## 与事件的分界
 * [com.gracemusic.player.state.PlaybackEvent] 不产生副作用（不触发网络解析、
 * 不落盘）；只有意图经归约产生本接口的实例。唯一的例外是播放命令类效果
 * （[Play] / [Pause] / [SeekTo] / [Prepare] 等）：播完（`EnginePlaybackCompleted`）
 * 驱动循环语义时必须指挥引擎，这与 Dart `_handlePlaybackCompleted` 调用
 * `playCommand()` 的结构一致。
 *
 * ## 执行标注（禁止伪造成功）
 * 数据/系统类效果在本阶段没有真实执行器，按任务编号标注 TODO；执行器落到
 * Store 侧，未实现前只记录、不对外伪造成功态。
 */
sealed interface PlaybackEffect {

    // ───────────────────────── 引擎类 ─────────────────────────

    /**
     * 装载曲目并（可选）起播（单曲时间线：mediaId = [Song.id]）。
     *
     * @property song 目标曲目（音源取其 `url`（在线）/ `localPath`（本地）；
     *   二者皆空时引擎拒绝装载并记录，不伪造成功——音源解析属 T-P1-05）。
     * @property startPositionMs 起始位置（毫秒）；null = 不 seek（保持 0）。
     * @property playWhenReady 装载后是否立即起播。
     */
    data class Prepare(
        val song: Song,
        val startPositionMs: Long?,
        val playWhenReady: Boolean,
    ) : PlaybackEffect

    /** 起播（playWhenReady = true）。 */
    data object Play : PlaybackEffect

    /** 暂停（playWhenReady = false）。 */
    data object Pause : PlaybackEffect

    /** 停止播放（保留当前媒体项，非 reset 版 stop）。 */
    data object Stop : PlaybackEffect

    /** 绝对定位（毫秒）。 */
    data class SeekTo(val positionMs: Long) : PlaybackEffect

    /** 相对定位（毫秒，可为负；通知栏 / 蓝牙的 ±10s、±15s）。 */
    data class SeekBy(val deltaMs: Long) : PlaybackEffect

    /** 设置播放音量（0.0..1.0）。 */
    data class SetVolume(val volume: Float) : PlaybackEffect

    /** 设置播放速率（0.25..4.0）。 */
    data class SetSpeed(val speed: Float) : PlaybackEffect

    // ───────────────────────── 服务类 ─────────────────────────

    /** 启动播放保活服务（进程级单例，播放会话期间常驻）。 */
    data object StartKeepAlive : PlaybackEffect

    /** 停止播放保活服务（暂停 / 停止 / 清空队列 / 队尾停机）。 */
    data object StopKeepAlive : PlaybackEffect

    // ─────────────────────── 数据/系统类 ───────────────────────

    /**
     * 解析当前曲目的播放地址（在线曲目走酷狗 API，云盘曲目走 /user/cloud/url）。
     *
     * 执行器（T-P1-05 C 行）已接线：Store 经 [SongUrlResolver]（data/source）
     * 异步解析，成功后经 [com.gracemusic.player.state.PlaybackIntent.UpdateSong]
     * 回写队列并重备（见 PlaybackReducer 对 UpdateSong 的「解析回写收尾」规则），
     * 失败投 `EngineError`（文案已在 resolver 收敛）。
     */
    data class ResolveSongUrl(val song: Song) : PlaybackEffect

    /**
     * 重新播放指定曲目（恢复链决策后的重备入口）。
     *
     * 目标语义：恢复链（`PlaybackRecoveryBudget` + `PlaybackRecoveryFlight`，
     * 台本 §3.6）放行后重新 prepare——本地曲目真实可用，在线曲目依赖 T-P1-05
     * 解析器。**当前无生产者**：归约器不产生本效果，Store 的恢复链本阶段
     * （T-P1-02）未接线，执行器只记 TODO 日志（T-P1-06）。
     * 待恢复链接线时必须明确生产者（二者择一：恢复链决策后派发
     * `RetryCurrent` 意图，或由归约器产出本效果），并回写本 KDoc。
     */
    data class RetryPlayback(val songId: String) : PlaybackEffect

    /**
     * 刷新媒体通知（封面 / 收藏态 / 播放态）。
     *
     * TODO T-P1-03+：session 刷新接线（当前由 Store 观察状态变化后代发）。
     */
    data object RefreshSystemNotification : PlaybackEffect

    /**
     * 立即落盘播放游标（当前曲 / 队列 / 位置 / 循环模式）。
     *
     * TODO T-P1-10：持久化执行器（PlayerStateRepository 等价物）落地前只登记。
     */
    data object PersistPlaybackCursor : PlaybackEffect

    /**
     * 切换指定曲目的收藏态并落盘。
     *
     * TODO T-P2 数据层：收藏仓库（Dart 侧由 FavoritesProvider 独立承担；
     * native 纳入播放域是因为通知栏收藏按钮必须经 MediaSession 回转）。
     */
    data class PersistFavoriteToggle(val songId: String) : PlaybackEffect

    /**
     * 写入一项设置偏好（键语义见 [PlaybackReducer] 的键名约定 KDoc）。
     *
     * TODO T-P2 设置层：SettingsRepository 等价物落地前只登记。
     */
    data class PersistPreference(val key: String) : PlaybackEffect

    /** 展示一条提示（Toast / Snackbar 出口；文案已收敛，不含 URL 与堆栈）。 */
    data class ShowMessage(val message: String) : PlaybackEffect
}
