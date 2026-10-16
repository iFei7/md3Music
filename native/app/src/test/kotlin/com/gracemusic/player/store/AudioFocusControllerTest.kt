package com.gracemusic.player.store

import android.media.AudioManager
import com.gracemusic.player.gate.AudioFocusEventListener
import com.gracemusic.player.gate.AudioFocusEventSource
import com.gracemusic.player.gate.AudioFocusInterruptionMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * [AudioFocusController] 的三模式运行时测试（T-P1-08）。
 *
 * 覆盖：attach/detach 生命周期、三模式 × 中断类型决策表、`pausedByInterruption`
 * 标志语义、fork 标志下发、忽略模式、用户传输意图清标志、迟到事件丢弃。
 *
 * 用 [FakeAudioFocusEventSource] + [FakeAudioFocusHost]，不触碰真实 `AudioManager`
 * 焦点（真机行为不在本测试范围，见文档「真机验证限制」）。
 */
@RunWith(RobolectricTestRunner::class)
class AudioFocusControllerTest {

    private val GAIN = AudioManager.AUDIOFOCUS_GAIN
    private val LOSS = AudioManager.AUDIOFOCUS_LOSS
    private val LOSS_TRANSIENT = AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
    private val CAN_DUCK = AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK

    private fun fixture(
        mode: AudioFocusInterruptionMode = AudioFocusInterruptionMode.KEEP_PLAYING,
        ignore: Boolean = false,
        playing: Boolean = true,
    ): Triple<AudioFocusController, FakeAudioFocusEventSource, FakeAudioFocusHost> {
        val source = FakeAudioFocusEventSource()
        val host = FakeAudioFocusHost(playing)
        val controller = AudioFocusController(source, host)
        controller.attach()
        controller.onPreferenceChanged(ignore, mode)
        return Triple(controller, source, host)
    }

    // ─────────────────────────── 生命周期 ───────────────────────────

    @Test
    fun `attach 注册监听并下发初始标志`() {
        val (_, source, _) = fixture()

        assertEquals(1, source.listeners.size)
        assertEquals(false, source.ignoreAudioFocus)
        assertEquals(true, source.forceKeepPlaying) // 默认 KEEP_PLAYING + 非忽略
        assertEquals(true, source.lastForcedWillPauseWhenDucked)
    }

    @Test
    fun `attach 幂等_重复调用不重复注册`() {
        val (controller, source, _) = fixture()
        controller.attach()
        controller.attach()

        assertEquals(1, source.listeners.size)
    }

    @Test
    fun `detach 注销监听且迟到事件不产生动作`() {
        val (controller, source, host) = fixture(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        controller.detach()

        assertEquals(0, source.listeners.size)
        // 即使 fork 侧因竞态仍投递（此处直接调已注销的监听器引用），也不得产生动作。
        source.emit(LOSS_TRANSIENT)
        assertEquals(0, host.pauseCount)
    }

    @Test
    fun `未attach时事件不产生动作`() {
        val source = FakeAudioFocusEventSource()
        val host = FakeAudioFocusHost(playing = true)
        val controller = AudioFocusController(source, host)
        controller.onPreferenceChanged(ignore = false, mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)
        // 未 attach → 未注册监听 → emit 无对象可调。
        source.emit(LOSS_TRANSIENT)

        assertEquals(0, host.pauseCount)
        assertTrue(source.listeners.isEmpty())
    }

    // ─────────────────────── KEEP_PLAYING 模式 ───────────────────────

    @Test
    fun `KEEP_PLAYING 短暂中断不暂停`() {
        val (_, source, host) = fixture(mode = AudioFocusInterruptionMode.KEEP_PLAYING)

        source.emit(LOSS_TRANSIENT)
        source.emit(CAN_DUCK)

        assertEquals(0, host.pauseCount)
    }

    @Test
    fun `KEEP_PLAYING 独占LOSS且正在播放时暂停`() {
        val (_, source, host) = fixture(mode = AudioFocusInterruptionMode.KEEP_PLAYING)

        source.emit(LOSS)

        assertEquals(1, host.pauseCount)
        assertEquals(0, host.resumeCount)
    }

    @Test
    fun `KEEP_PLAYING 独占LOSS但未播放时不动作`() {
        val (_, source, host) = fixture(
            mode = AudioFocusInterruptionMode.KEEP_PLAYING,
            playing = false,
        )

        source.emit(LOSS)

        assertEquals(0, host.pauseCount)
    }

    @Test
    fun `KEEP_PLAYING 独占LOSS暂停后GAIN不自动恢复`() {
        // 对位 Dart：keepPlaying 的 LOSS 分支不记 _pausedByInterruption，故 GAIN 不恢复。
        val (_, source, host) = fixture(mode = AudioFocusInterruptionMode.KEEP_PLAYING)

        source.emit(LOSS)
        host.playing = false
        source.emit(GAIN)

        assertEquals(1, host.pauseCount)
        assertEquals(0, host.resumeCount)
    }

    // ────────────────────── PAUSE_AND_RESUME 模式 ──────────────────────

    @Test
    fun `PAUSE_AND_RESUME 短暂中断暂停并记标志`() {
        val (controller, source, host) = fixture(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)

        source.emit(LOSS_TRANSIENT)

        assertEquals(1, host.pauseCount)
        assertTrue(controller.isPausedByInterruption())
    }

    @Test
    fun `PAUSE_AND_RESUME GAIN恢复此前中断暂停`() {
        val (controller, source, host) = fixture(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)

        source.emit(LOSS_TRANSIENT)
        host.playing = false
        source.emit(GAIN)

        assertEquals(1, host.resumeCount)
        assertFalse(controller.isPausedByInterruption())
    }

    @Test
    fun `PAUSE_AND_RESUME 未播放时中断不暂停也不记标志`() {
        val (controller, source, host) = fixture(
            mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME,
            playing = false,
        )

        source.emit(LOSS_TRANSIENT)
        source.emit(GAIN)

        assertEquals(0, host.pauseCount)
        assertEquals(0, host.resumeCount)
        assertFalse(controller.isPausedByInterruption())
    }

    @Test
    fun `PAUSE_AND_RESUME 未曾中断时GAIN不恢复`() {
        val (_, source, host) = fixture(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)

        source.emit(GAIN)

        assertEquals(0, host.resumeCount)
    }

    @Test
    fun `PAUSE_AND_RESUME 独占LOSS同样暂停并可在GAIN恢复`() {
        val (controller, source, host) = fixture(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)

        source.emit(LOSS)
        assertEquals(1, host.pauseCount)
        assertTrue(controller.isPausedByInterruption())

        host.playing = false
        source.emit(GAIN)
        assertEquals(1, host.resumeCount)
    }

    @Test
    fun `用户传输意图清除中断暂停标志_GAIN不再恢复`() {
        // 验收项：用户主动暂停后，焦点恢复不得自动播放。
        val (controller, source, host) = fixture(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)

        source.emit(LOSS_TRANSIENT) // 中断暂停
        host.playing = false
        controller.onUserTransportIntent() // 用户按下暂停（或切歌/seek）

        source.emit(GAIN)

        assertEquals(0, host.resumeCount)
        assertFalse(controller.isPausedByInterruption())
    }

    // ────────────────────── DUCK_AND_RESTORE 模式 ──────────────────────

    @Test
    fun `DUCK_AND_RESTORE 任何中断都不干预`() {
        val (controller, source, host) = fixture(mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE)

        source.emit(LOSS_TRANSIENT)
        source.emit(CAN_DUCK)
        source.emit(LOSS)
        source.emit(GAIN)

        assertEquals(0, host.pauseCount)
        assertEquals(0, host.resumeCount)
        assertFalse(controller.isPausedByInterruption())
    }

    // ─────────────────────────── 忽略模式 ───────────────────────────

    @Test
    fun `忽略模式 所有中断都不响应`() {
        val (_, source, host) = fixture(
            mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME,
            ignore = true,
        )

        source.emit(LOSS)
        source.emit(LOSS_TRANSIENT)
        source.emit(CAN_DUCK)
        source.emit(GAIN)

        assertEquals(0, host.pauseCount)
        assertEquals(0, host.resumeCount)
    }

    // ─────────────────────── fork 标志下发 ───────────────────────

    @Test
    fun `标志下发_KEEP_PLAYING非忽略`() {
        val (_, source, _) = fixture(mode = AudioFocusInterruptionMode.KEEP_PLAYING)

        assertEquals(false, source.ignoreAudioFocus)
        assertEquals(true, source.forceKeepPlaying)
        assertEquals(true, source.lastForcedWillPauseWhenDucked)
    }

    @Test
    fun `标志下发_PAUSE_AND_RESUME`() {
        val (_, source, _) = fixture(mode = AudioFocusInterruptionMode.PAUSE_AND_RESUME)

        assertEquals(false, source.ignoreAudioFocus)
        assertEquals(false, source.forceKeepPlaying)
        assertEquals(true, source.lastForcedWillPauseWhenDucked)
    }

    @Test
    fun `标志下发_DUCK_AND_RESTORE保留系统自动duck`() {
        val (_, source, _) = fixture(mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE)

        assertEquals(false, source.ignoreAudioFocus)
        assertEquals(false, source.forceKeepPlaying)
        assertEquals(false, source.lastForcedWillPauseWhenDucked)
    }

    @Test
    fun `标志下发_忽略模式强制不自动duck且不保持播放`() {
        val (_, source, _) = fixture(ignore = true, mode = AudioFocusInterruptionMode.KEEP_PLAYING)

        assertEquals(true, source.ignoreAudioFocus)
        assertEquals(false, source.forceKeepPlaying)
        assertEquals(true, source.lastForcedWillPauseWhenDucked)
    }

    @Test
    fun `偏好变更后重下发标志`() {
        val (controller, source, _) = fixture(mode = AudioFocusInterruptionMode.KEEP_PLAYING)
        assertEquals(true, source.forceKeepPlaying)

        controller.onPreferenceChanged(ignore = false, mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE)

        assertEquals(false, source.forceKeepPlaying)
        assertEquals(false, source.lastForcedWillPauseWhenDucked)
    }

    @Test
    fun `detach 后偏好变更不下发标志`() {
        val (controller, source, _) = fixture()
        controller.detach()
        source.resetFlagRecords()

        controller.onPreferenceChanged(ignore = true, mode = AudioFocusInterruptionMode.DUCK_AND_RESTORE)

        assertNull(source.ignoreAudioFocus)
    }

    // ─────────────────────────── fakes ───────────────────────────

    private class FakeAudioFocusEventSource : AudioFocusEventSource {
        val listeners = mutableListOf<AudioFocusEventListener>()
        var ignoreAudioFocus: Boolean? = null
        var forceKeepPlaying: Boolean? = null
        var lastForcedWillPauseWhenDucked: Boolean? = null

        override fun addListener(listener: AudioFocusEventListener) {
            if (!listeners.contains(listener)) listeners.add(listener)
        }

        override fun removeListener(listener: AudioFocusEventListener) {
            listeners.remove(listener)
        }

        override fun setIgnoreAudioFocus(ignore: Boolean) {
            ignoreAudioFocus = ignore
        }

        override fun setForceKeepPlaying(keepPlaying: Boolean) {
            forceKeepPlaying = keepPlaying
        }

        override fun setForcedWillPauseWhenDucked(force: Boolean?) {
            lastForcedWillPauseWhenDucked = force
        }

        /** 模拟 fork 派发一次原始焦点事件（副本遍历，避免回调内改列表）。 */
        fun emit(focusChange: Int) {
            listeners.toList().forEach { it.onAudioFocusChanged(focusChange) }
        }

        /** 只清标志记录（保留监听），用于断言「detach 后不再下发」。 */
        fun resetFlagRecords() {
            ignoreAudioFocus = null
            forceKeepPlaying = null
            lastForcedWillPauseWhenDucked = null
        }
    }

    private class FakeAudioFocusHost(var playing: Boolean) : AudioFocusHost {
        var pauseCount = 0
        var resumeCount = 0

        override fun isPlaying(): Boolean = playing

        override fun pauseByInterruption() {
            pauseCount++
        }

        override fun resumeAfterInterruption() {
            resumeCount++
        }
    }
}
