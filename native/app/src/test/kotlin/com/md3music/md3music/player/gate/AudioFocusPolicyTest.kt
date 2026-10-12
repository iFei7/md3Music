package com.md3music.md3music.player.gate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [decideInterruptionAction] 音频焦点三模式决策移植锁测试。
 *
 * 场景对标 test/services/audio_focus_policy_test.dart：
 * - duck 事件组 9 例；
 * - pause / unknown 事件组各 6 例（共 12 例）。
 */
class AudioFocusPolicyTest {

    private fun decide(
        mode: AudioFocusInterruptionMode,
        begin: Boolean,
        type: AudioInterruptionType,
        isPlaying: Boolean = true,
        currentVolume: Double = 0.8,
        volumeBeforeDuck: Double? = null,
    ) = decideInterruptionAction(
        mode = mode,
        begin = begin,
        type = type,
        isPlaying = isPlaying,
        currentVolume = currentVolume,
        volumeBeforeDuck = volumeBeforeDuck,
    )

    // ---- duck 事件 ----

    @Test
    fun `duckAndRestore 开始降音为当前音量的一半`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE,
            begin = true,
            type = AudioInterruptionType.DUCK,
            isPlaying = true,
            currentVolume = 0.8,
        )
        assertTrue(action is AudioFocusAction.DuckVolumeAction)
        assertEquals(0.4, (action as AudioFocusAction.DuckVolumeAction).targetVolume, 1e-9)
    }

    @Test
    fun `duckAndRestore 按相对比例降音不放大`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE,
            begin = true,
            type = AudioInterruptionType.DUCK,
            isPlaying = true,
            currentVolume = 0.3,
        )
        assertEquals(0.15, (action as AudioFocusAction.DuckVolumeAction).targetVolume, 1e-9)
    }

    @Test
    fun `duckAndRestore 中断结束恢复原音量`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE,
            begin = false,
            type = AudioInterruptionType.DUCK,
            isPlaying = true,
            currentVolume = 0.4,
            volumeBeforeDuck = 0.8,
        )
        assertTrue(action is AudioFocusAction.RestoreVolumeAction)
        assertEquals(0.8, (action as AudioFocusAction.RestoreVolumeAction).targetVolume, 1e-9)
    }

    @Test
    fun `duckAndRestore 无原音量记录时回退当前音量`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE,
            begin = false,
            type = AudioInterruptionType.DUCK,
            isPlaying = true,
            currentVolume = 0.4,
        )
        assertEquals(0.4, (action as AudioFocusAction.RestoreVolumeAction).targetVolume, 1e-9)
    }

    @Test
    fun `pauseAndResume 对 duck 型中断同样暂停`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME,
            begin = true,
            type = AudioInterruptionType.DUCK,
            isPlaying = true,
        )
        assertEquals(AudioFocusAction.PausePlaybackAction, action)
    }

    @Test
    fun `pauseAndResume duck 开始时未播放则保持`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME,
            begin = true,
            type = AudioInterruptionType.DUCK,
            isPlaying = false,
        )
        assertEquals(AudioFocusAction.KeepPlayingAction, action)
    }

    @Test
    fun `pauseAndResume duck 结束时恢复播放`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME,
            begin = false,
            type = AudioInterruptionType.DUCK,
            isPlaying = false,
        )
        assertEquals(AudioFocusAction.ResumePlaybackAction, action)
    }

    @Test
    fun `keepPlaying 对 duck 中断不做任何响应`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.KEEP_PLAYING,
            begin = true,
            type = AudioInterruptionType.DUCK,
            isPlaying = true,
        )
        assertEquals(AudioFocusAction.KeepPlayingAction, action)
    }

    @Test
    fun `duckAndRestore duck 开始时未播放则保持`() {
        val action = decide(
            mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE,
            begin = true,
            type = AudioInterruptionType.DUCK,
            isPlaying = false,
        )
        assertEquals(AudioFocusAction.KeepPlayingAction, action)
    }

    // ---- pause / unknown 事件 ----

    @Test
    fun `pause 与 unknown 事件三模式决策`() {
        for (type in listOf(AudioInterruptionType.PAUSE, AudioInterruptionType.UNKNOWN)) {
            assertEquals(
                "$type: pauseAndResume + begin + playing → PausePlaybackAction",
                AudioFocusAction.PausePlaybackAction,
                decide(
                    mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME,
                    begin = true,
                    type = type,
                    isPlaying = true,
                ),
            )
            assertEquals(
                "$type: pauseAndResume + begin + 未播放 → KeepPlayingAction",
                AudioFocusAction.KeepPlayingAction,
                decide(
                    mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME,
                    begin = true,
                    type = type,
                    isPlaying = false,
                ),
            )
            assertEquals(
                "$type: pauseAndResume + end → ResumePlaybackAction",
                AudioFocusAction.ResumePlaybackAction,
                decide(
                    mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME,
                    begin = false,
                    type = type,
                    isPlaying = false,
                ),
            )
            assertEquals(
                "$type: keepPlaying + begin → KeepPlayingAction",
                AudioFocusAction.KeepPlayingAction,
                decide(
                    mode = AudioFocusInterruptionMode.KEEP_PLAYING,
                    begin = true,
                    type = type,
                    isPlaying = true,
                ),
            )
            val duckAction = decide(
                mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE,
                begin = true,
                type = type,
                isPlaying = true,
                currentVolume = 0.8,
            )
            assertTrue(
                "$type: duckAndRestore + begin + playing → DuckVolumeAction",
                duckAction is AudioFocusAction.DuckVolumeAction,
            )
            assertEquals(
                0.4,
                (duckAction as AudioFocusAction.DuckVolumeAction).targetVolume,
                1e-9,
            )
            val restoreAction = decide(
                mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE,
                begin = false,
                type = type,
                isPlaying = true,
                currentVolume = 0.4,
                volumeBeforeDuck = 0.8,
            )
            assertTrue(
                "$type: duckAndRestore + end → RestoreVolumeAction",
                restoreAction is AudioFocusAction.RestoreVolumeAction,
            )
            assertEquals(
                0.8,
                (restoreAction as AudioFocusAction.RestoreVolumeAction).targetVolume,
                1e-9,
            )
        }
    }

    @Test
    fun `duck 音量比例锁定为 0_5`() {
        assertEquals(0.5, DUCK_VOLUME_RATIO, 0.0)
    }
}
