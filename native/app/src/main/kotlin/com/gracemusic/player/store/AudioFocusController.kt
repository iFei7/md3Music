package com.gracemusic.player.store

import android.media.AudioManager
import com.gracemusic.player.gate.AudioFocusEventListener
import com.gracemusic.player.gate.AudioFocusEventSource
import com.gracemusic.player.gate.AudioFocusInterruptionMode

/**
 * 焦点运行时向宿主（[PlaybackStore]）索取的上下文与动作（T-P1-08）。
 *
 * 刻意保持窄接口（同 [RecoveryHost] 的取向）：控制器只「读事实、派意图」，
 * 不直接写状态、不碰引擎——状态变化一律经既有 Store/Reducer 契约。
 * 测试可用假宿主单独驱动 [AudioFocusController] 的三模式决策。
 */
internal interface AudioFocusHost {

    /** 当前是否在播放（决策「是否要暂停」的唯一依据）。 */
    fun isPlaying(): Boolean

    /**
     * 系统中断导致的暂停（**非**用户意图）。
     *
     * 语义要求（T-P1-08 关键契约）：必须与用户主动暂停**可区分**，
     * 以便：
     * 1. 不消耗 [com.gracemusic.player.gate.PlaybackRecoveryBudget]；
     * 2. 不产生任何引擎错误（因此不会被 [RecoveryOrchestrator] 误判为播放故障）；
     * 3. 中断结束后可被 [resumeAfterInterruption] 精确恢复（仅恢复被中断打断的播放）。
     */
    fun pauseByInterruption()

    /** 中断结束、恢复此前被中断打断的播放（**不得**覆盖用户主动暂停）。 */
    fun resumeAfterInterruption()
}

/**
 * 音频焦点运行时控制器（T-P1-08）——三模式决策的**执行者**。
 *
 * ## 对位关系（逐分支，勿重推）
 * 1:1 移植自 lite `lib/core/services/audio_service_io.dart:595-645`
 * （`_handleMedia3FocusChange`）与 `:541-558`（`_syncNativeFocusFlags`）。
 *
 * | 模式 | 短暂中断（`LOSS_TRANSIENT` / `CAN_DUCK`） | 独占中断（`LOSS`） | 恢复（`GAIN`） |
 * |---|---|---|---|
 * | [AudioFocusInterruptionMode.KEEP_PLAYING] | 保持播放（fork 跳过内置处理） | **主动暂停**让路 | 不自动恢复（Dart 同） |
 * | [AudioFocusInterruptionMode.PAUSE_AND_RESUME] | 暂停 + 记「中断暂停」 | 暂停 + 记「中断暂停」 | 仅当「中断暂停」时恢复 |
 * | [AudioFocusInterruptionMode.DUCK_AND_RESTORE] | **不干预**（Media3 系统级自动 duck 0.2 → `GAIN` 自动恢复） | 同左 | 同左 |
 *
 * `DUCK_AND_RESTORE` 在 Dart 里**没有**分支（`_handleMedia3FocusChange` 只处理
 * keepPlaying / pauseAndResume 两模式），实现方式是把
 * [AudioFocusEventSource.setForcedWillPauseWhenDucked] 置 `false`，让 Media3
 * 保留系统级自动 duck。native 保持同一分工，**不**在宿主侧重造音量斜坡。
 *
 * ## 与 Media3 内置处理的分工（不得双重控制）
 * 本控制器**不**注册自己的 `AudioManager.OnAudioFocusChangeListener`。
 * 它消费 fork 转发的原始事件，并通过
 * [AudioFocusEventSource] 的三个开关**改写** Media3 内置处理：
 * - `ignoreAudioFocus` → 内置处理全跳过；
 * - `KEEP_PLAYING` → 短暂中断跳过内置处理（独占 `LOSS` 仍走内置 `DO_NOT_PLAY`，
 *   本控制器再补一次显式暂停以同步状态）；
 * - 非 `DUCK_AND_RESTORE` → `willPauseWhenDucked = true`，让系统派发
 *   `LOSS_TRANSIENT` 事件而非静默 duck（宿主才能感知并决策）。
 *
 * ## 用户主动暂停不被自动恢复（验收项）
 * [pausedByInterruption] 只在**系统中断**导致的暂停时置位；
 * [onUserTransportIntent] 在任何用户传输类意图（起播/暂停/切歌/seek/停止/清空队列）
 * 时清位。因此「用户暂停 → 来电 → 挂断 `GAIN`」不会自动播放。
 *
 * **相对 Dart 的收紧（登记）**：Dart 只在 `play()` 里清标志
 * （`audio_service_io.dart:668-671`），用户 `pause()` 不清——于是
 * 「中断暂停 → 用户暂停 → `GAIN`」会被错误恢复。native 把清位点扩到
 * 全部用户传输意图，堵住该路径。
 *
 * ## 系统中断不被误判为播放故障（验收项）
 * 本控制器只经 [AudioFocusHost.pauseByInterruption] 派**暂停**意图，
 * 从不投递 `PlaybackEvent.EngineError`，因此不进入 [RecoveryOrchestrator]
 * 的失败分类，也不消耗恢复预算。
 *
 * ## 生命周期
 * [attach] / [detach] 必须成对；[detach] 后任何迟到回调都不再产生动作
 * （引擎释放 / Service 销毁路径）。进程级单例，不随 UI 重建。
 */
internal class AudioFocusController(
    private val eventSource: AudioFocusEventSource,
    private val host: AudioFocusHost,
) {

    /** 当前「忽略音频焦点」偏好（由 Store 在归约后同步，见 [onPreferenceChanged]）。 */
    private var ignoreAudioFocus: Boolean = false

    /** 当前中断处理模式（同上）。 */
    private var mode: AudioFocusInterruptionMode = AudioFocusInterruptionMode.KEEP_PLAYING

    /**
     * 「当前暂停是系统中断造成的」标记。
     *
     * 唯一置位点：`PAUSE_AND_RESUME` 模式收到非 `GAIN` 事件且当时在播放。
     * 唯一清除点：`GAIN` 恢复后、以及用户主动起播（[onUserPlayRequested]）。
     * `KEEP_PLAYING` 的独占 `LOSS` 暂停**不**置位——Dart 同（该分支直接 return，
     * 不记标志），语义是「永久失去焦点，不自动恢复」。
     */
    private var pausedByInterruption: Boolean = false

    /** 是否已注册监听（[attach] / [detach] 幂等）。 */
    private var attached: Boolean = false

    /** 转发给 fork 的监听实例（固定引用，便于 [detach] 精确注销）。 */
    private val listener = AudioFocusEventListener { focusChange ->
        handleFocusChange(focusChange)
    }

    // ─────────────────────────── 生命周期 ───────────────────────────

    /** 注册焦点监听并下发一次当前标志（幂等）。 */
    fun attach() {
        if (attached) return
        attached = true
        eventSource.addListener(listener)
        syncNativeFlags()
    }

    /**
     * 注销焦点监听（幂等）。
     *
     * 注销后 [handleFocusChange] 不再被调用；即使 fork 侧因竞态仍有迟到回调，
     * 也因 [attached] 为 false 而被丢弃（不产生任何播放动作）。
     */
    fun detach() {
        if (!attached) return
        attached = false
        eventSource.removeListener(listener)
    }

    // ─────────────────────────── 偏好同步 ───────────────────────────

    /**
     * 偏好变化（归约后由 Store 调用）：更新内部态并重下发 fork 标志。
     *
     * 幂等：值与当前一致时仍会重下发（fork 侧写的是 volatile 字段，代价可忽略），
     * 这样 Store 无需自己维护「是否变化」的判据。
     */
    fun onPreferenceChanged(ignore: Boolean, mode: AudioFocusInterruptionMode) {
        ignoreAudioFocus = ignore
        this.mode = mode
        if (attached) syncNativeFlags()
    }

    /**
     * 用户传输类意图（起播/暂停/切歌/重试/seek/停止/清空队列）—— 清除「中断暂停」标记。
     *
     * 对位 Dart `play()` 开头的 `_pausedByInterruption = false`
     * （`audio_service_io.dart:668-671`）：避免后续一个无关的 `GAIN`
     * 把用户刚做的暂停又变成播放。
     *
     * **必须覆盖用户 `pause()`**：否则「中断暂停 → 用户暂停 → `GAIN`」会被
     * 错误恢复（Dart 未覆盖，见类 KDoc 的收紧登记）。
     */
    fun onUserTransportIntent() {
        pausedByInterruption = false
    }

    /** 当前是否处于「被系统中断暂停」态（供测试与诊断；不对外暴露为状态字段）。 */
    fun isPausedByInterruption(): Boolean = pausedByInterruption

    // ─────────────────────────── 决策与执行 ───────────────────────────

    /**
     * 下发 fork 的焦点处理标志（对位 Dart `_syncNativeFocusFlags`，`:541-558`）。
     *
     * - `forceKeepPlaying` = 非忽略 **且** `KEEP_PLAYING`
     *   （短暂中断跳过内置处理；独占 `LOSS` 仍让路）；
     * - `willPauseWhenDucked` = 忽略 **或** 非 `DUCK_AND_RESTORE`
     *   （系统派发 `LOSS_TRANSIENT` 事件而非静默 duck，宿主才能感知；
     *   仅 `DUCK_AND_RESTORE` 保留系统级自动 duck）。
     */
    private fun syncNativeFlags() {
        eventSource.setIgnoreAudioFocus(ignoreAudioFocus)
        eventSource.setForceKeepPlaying(
            !ignoreAudioFocus && mode == AudioFocusInterruptionMode.KEEP_PLAYING,
        )
        eventSource.setForcedWillPauseWhenDucked(
            ignoreAudioFocus || mode != AudioFocusInterruptionMode.DUCK_AND_RESTORE,
        )
    }

    /**
     * 原始焦点事件处理（主线程）——三模式运行时。
     *
     * 逐分支对位 Dart `_handleMedia3FocusChange`（`audio_service_io.dart:595-645`）：
     * 1. 忽略模式：直接返回（fork 已跳过内置处理，播放与音量完全保持）；
     * 2. `KEEP_PLAYING`：仅独占 `LOSS`（`-1`）主动暂停；其余不干预；
     * 3. `PAUSE_AND_RESUME`：非 `GAIN`（`!= 1`）→ 暂停并记标志；`GAIN` 且已记标志 → 恢复；
     * 4. `DUCK_AND_RESTORE`：不干预（Media3 系统级自动 duck 与恢复）。
     *
     * 注意 Dart 在 `abortCrossfade()` 处的调用：native 的交叉淡化（T-P1-07）
     * **尚未落地**，故此处不调用（登记为差异，T-P1-07 落地时必须补
     * `abortCrossfade()`，否则淡化中收到焦点事件会留下未收敛的 incoming 播放器）。
     */
    private fun handleFocusChange(focusChange: Int) {
        if (!attached) return
        // 忽略模式：不响应任何中断（对位 Dart `:601` 的首行 return）。
        if (ignoreAudioFocus) return

        when (mode) {
            AudioFocusInterruptionMode.KEEP_PLAYING -> {
                // 独占型 LOSS：主动暂停让路（否则对方 App 拿不到焦点）。
                if (focusChange == AudioManager.AUDIOFOCUS_LOSS && host.isPlaying()) {
                    host.pauseByInterruption()
                }
            }

            AudioFocusInterruptionMode.PAUSE_AND_RESUME -> {
                if (focusChange != AudioManager.AUDIOFOCUS_GAIN) {
                    if (host.isPlaying()) {
                        pausedByInterruption = true
                        host.pauseByInterruption()
                    }
                } else if (pausedByInterruption) {
                    pausedByInterruption = false
                    host.resumeAfterInterruption()
                }
            }

            // 系统级自动 duck / 恢复，宿主不干预。
            AudioFocusInterruptionMode.DUCK_AND_RESTORE -> Unit
        }
    }
}
