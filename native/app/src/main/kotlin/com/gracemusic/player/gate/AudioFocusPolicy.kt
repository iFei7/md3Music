package com.gracemusic.player.gate

/**
 * 短暂失去音频焦点（如来电、语音助手等临时中断）时的处理策略。
 *
 * 1:1 移植自 lib/core/services/audio_service_io.dart:15-24。
 */
enum class AudioFocusInterruptionMode {
    /** 保持当前音量与播放状态：不暂停、不降音量、不做任何响应。 */
    KEEP_PLAYING,

    /** 暂停播放，重新获得焦点后自动恢复（仅恢复被中断打断的播放，不覆盖用户主动暂停）。 */
    PAUSE_AND_RESUME,

    /** 临时降低音量（降到 duck 音量），重新获得焦点后恢复原音量。 */
    DUCK_AND_RESTORE,
}

/**
 * 音频焦点中断类型。
 *
 * 1:1 移植自 audio_session 0.1.25 的 AudioInterruptionType
 * （lib/src/core.dart：pause / duck / unknown 三值）。
 */
enum class AudioInterruptionType {
    PAUSE,
    DUCK,
    UNKNOWN,
}

/**
 * 音频焦点中断的决策动作（纯逻辑层，便于单测）。
 *
 * 1:1 移植自 lib/core/services/audio_service_io.dart:27-56。
 */
sealed class AudioFocusAction {
    /** 不做任何响应：保持当前音量与播放状态。 */
    object KeepPlayingAction : AudioFocusAction()

    /** 降低音量到 [targetVolume]（相对当前音量的 [DUCK_VOLUME_RATIO] 倍）。 */
    data class DuckVolumeAction(val targetVolume: Double) : AudioFocusAction()

    /** 恢复 [targetVolume]（中断前记录的原始音量）。 */
    data class RestoreVolumeAction(val targetVolume: Double) : AudioFocusAction()

    /** 暂停播放（调用方仅在正在播放时执行）。 */
    object PausePlaybackAction : AudioFocusAction()

    /** 尝试恢复播放（调用方内部校验「中断暂停」标志与播放器就绪态）。 */
    object ResumePlaybackAction : AudioFocusAction()
}

/** duck 降音量的相对比例（当前音量的 0.5 倍）。 */
const val DUCK_VOLUME_RATIO = 0.5

/**
 * 决策函数：按 [mode] 策略与中断事件，返回应执行的动作。
 *
 * 1:1 移植自 lib/core/services/audio_service_io.dart:66-129。
 *
 * 纯函数（无副作用、不触碰播放器），由 AudioService 的
 * interruptionEventStream 监听器调用并执行返回的动作，
 * 使三模式策略逻辑可独立单测。
 *
 * 语义契约（与 Dart 逐分支一致）：
 * - 中断结束（begin = false）且 type = DUCK：keepPlaying → KeepPlayingAction；
 *   pauseAndResume → ResumePlaybackAction；duckAndRestore →
 *   RestoreVolumeAction(volumeBeforeDuck ?: currentVolume)；
 * - 中断结束且 type 非 DUCK：keepPlaying → KeepPlayingAction；
 *   pauseAndResume → ResumePlaybackAction；duckAndRestore → 同上回退音量；
 * - 中断开始且 type = DUCK：keepPlaying → KeepPlayingAction；
 *   pauseAndResume → isPlaying ? Pause : KeepPlaying；
 *   duckAndRestore → isPlaying ? Duck(currentVolume * 0.5) : KeepPlaying；
 * - 中断开始且 type 非 DUCK（pause / unknown）：keepPlaying → KeepPlayingAction；
 *   pauseAndResume → isPlaying ? Pause : KeepPlaying；
 *   duckAndRestore → isPlaying ? Duck(currentVolume * 0.5) : KeepPlaying
 *   （暂停型中断也降音量处理：播放不中断，仅压低音量）。
 */
fun decideInterruptionAction(
    mode: AudioFocusInterruptionMode,
    begin: Boolean,
    type: AudioInterruptionType,
    isPlaying: Boolean,
    currentVolume: Double,
    volumeBeforeDuck: Double? = null,
): AudioFocusAction {
    if (!begin) {
        // —— 中断结束 ——
        if (type == AudioInterruptionType.DUCK) {
            return when (mode) {
                AudioFocusInterruptionMode.KEEP_PLAYING ->
                    AudioFocusAction.KeepPlayingAction
                AudioFocusInterruptionMode.PAUSE_AND_RESUME ->
                    AudioFocusAction.ResumePlaybackAction
                AudioFocusInterruptionMode.DUCK_AND_RESTORE ->
                    AudioFocusAction.RestoreVolumeAction(
                        volumeBeforeDuck ?: currentVolume,
                    )
            }
        }
        return when (mode) {
            AudioFocusInterruptionMode.KEEP_PLAYING ->
                AudioFocusAction.KeepPlayingAction
            AudioFocusInterruptionMode.PAUSE_AND_RESUME ->
                AudioFocusAction.ResumePlaybackAction
            AudioFocusInterruptionMode.DUCK_AND_RESTORE ->
                AudioFocusAction.RestoreVolumeAction(
                    volumeBeforeDuck ?: currentVolume,
                )
        }
    }

    // —— 中断开始 ——
    if (type == AudioInterruptionType.DUCK) {
        return when (mode) {
            AudioFocusInterruptionMode.KEEP_PLAYING ->
                // 保持播放、保持音量
                AudioFocusAction.KeepPlayingAction
            AudioFocusInterruptionMode.PAUSE_AND_RESUME ->
                // 「暂停后自动恢复」对 duck 型中断（导航提示音等）同样暂停，
                // 中断结束后自动恢复（用户明确预期：选了暂停就暂停）
                if (isPlaying) {
                    AudioFocusAction.PausePlaybackAction
                } else {
                    AudioFocusAction.KeepPlayingAction
                }
            AudioFocusInterruptionMode.DUCK_AND_RESTORE ->
                if (isPlaying) {
                    AudioFocusAction.DuckVolumeAction(currentVolume * DUCK_VOLUME_RATIO)
                } else {
                    AudioFocusAction.KeepPlayingAction
                }
        }
    }
    // pause / unknown 开始
    return when (mode) {
        AudioFocusInterruptionMode.KEEP_PLAYING ->
            AudioFocusAction.KeepPlayingAction // 保持播放、保持音量
        AudioFocusInterruptionMode.PAUSE_AND_RESUME ->
            if (isPlaying) {
                AudioFocusAction.PausePlaybackAction
            } else {
                AudioFocusAction.KeepPlayingAction
            }
        AudioFocusInterruptionMode.DUCK_AND_RESTORE ->
            // 暂停型中断也改为降音量处理：播放不中断，仅压低音量
            if (isPlaying) {
                AudioFocusAction.DuckVolumeAction(currentVolume * DUCK_VOLUME_RATIO)
            } else {
                AudioFocusAction.KeepPlayingAction
            }
    }
}
