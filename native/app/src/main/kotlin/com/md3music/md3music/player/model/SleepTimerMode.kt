package com.md3music.md3music.player.model

import kotlin.time.Duration

/**
 * 睡眠定时模式（与倒计时互斥，同一时刻只保留一种）。
 *
 * 1:1 移植自 lib/providers/player_provider.dart:56-68 的 enum SleepTimerMode。
 *
 * **倒计时时长不属于本枚举**：Dart 侧由 provider 的 `_sleepTimerEndTime` /
 * `sleepTimerRemaining` 表达（player_provider.dart:383,729），native 侧同样
 * 由播放器状态层持有（P1-5 挂点），本文件只固定三态与迁移语义。
 */
enum class SleepTimerMode {
    /** 未启用。 */
    OFF,

    /** 倒计时：到点自动暂停。 */
    COUNTDOWN,

    /**
     * 「定时结束后播完当前歌曲」的到点等待态：定时已到点但**不打断**当前
     * 播放，等正在播的这首自然播完（下一个正常 completed）时再暂停
     * （见 _handlePlaybackCompleted）。
     */
    END_OF_TRACK,
    ;

    companion object {
        /**
         * 设置 / 取消睡眠定时后的模式：[duration] 为 null 表示取消（→ [OFF]），
         * 非 null 表示倒计时进行中（→ [COUNTDOWN]）。
         *
         * 1:1 移植自 player_provider.dart:5266-5269（setSleepTimer 的赋值）：
         * ```dart
         * // mode 表达倒计时进行中；到点后的 endOfTrack 等待态由 ticker 分支设置。
         * // 「关闭定时」(null) 连同到点等待态与勾选偏好一起清掉。
         * _sleepTimerMode = duration == null ? SleepTimerMode.off : SleepTimerMode.countdown;
         * ```
         */
        fun forTimerStart(duration: Duration?): SleepTimerMode =
            if (duration == null) OFF else COUNTDOWN

        /**
         * 倒计时到点时的模式迁移：勾选了「播完当前歌曲」→ [END_OF_TRACK]
         * 等待态（不打断播放）；否则 → [OFF]（调用方照旧执行暂停）。
         *
         * 1:1 移植自 player_provider.dart:5286-5296（ticker 到点分支）：
         * ```dart
         * if (_stopAfterTimerEnds) {
         *   _sleepTimerMode = SleepTimerMode.endOfTrack;
         * } else {
         *   _sleepTimerMode = SleepTimerMode.off;
         *   _audioService?.pause();
         * }
         * ```
         */
        fun forTimerFired(stopAfterCurrentTrack: Boolean): SleepTimerMode =
            if (stopAfterCurrentTrack) END_OF_TRACK else OFF
    }
}

/**
 * 取消「定时结束后播完当前歌曲」偏好时的模式迁移：撤销已到点的
 * 等待态（[SleepTimerMode.END_OF_TRACK] → [SleepTimerMode.OFF]，但不打断
 * 播放）；其余状态不变。
 *
 * 1:1 移植自 player_provider.dart:5316-5320（setStopAfterCurrentTrack）。
 */
fun SleepTimerMode.afterStopAfterCurrentTrackDisabled(): SleepTimerMode =
    if (this == SleepTimerMode.END_OF_TRACK) SleepTimerMode.OFF else this
