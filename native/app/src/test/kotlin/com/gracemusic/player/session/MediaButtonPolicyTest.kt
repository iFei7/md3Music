package com.gracemusic.player.session

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 线控媒体键手势策略测试。
 *
 * 这是 T44 里唯一"时序即行为"的一段逻辑：单击必须立刻播放（否则 Android 12+ 会拒绝
 * 后台启动前台服务），双击/三击必须在 350ms 窗口后补发切歌。真机上要复现"精确到毫秒的
 * 连按序列"几乎不可能稳定，因此这里把窗口内的每一击逐一断言。
 */
class MediaButtonPolicyTest {

    @Test
    fun `判定窗口与 lite 逐字节一致`() {
        assertEquals(350L, MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS)
    }

    @Test
    fun `耳机钩键与播放暂停键走多击路径`() {
        assertTrue(MediaButtonPolicy.usesMultiClick(KeyEvent.KEYCODE_HEADSETHOOK))
        assertTrue(MediaButtonPolicy.usesMultiClick(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
    }

    @Test
    fun `明确语义键不走多击路径`() {
        assertFalse(MediaButtonPolicy.usesMultiClick(KeyEvent.KEYCODE_MEDIA_PLAY))
        assertFalse(MediaButtonPolicy.usesMultiClick(KeyEvent.KEYCODE_MEDIA_PAUSE))
        assertFalse(MediaButtonPolicy.usesMultiClick(KeyEvent.KEYCODE_MEDIA_NEXT))
        assertFalse(MediaButtonPolicy.usesMultiClick(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertFalse(MediaButtonPolicy.usesMultiClick(KeyEvent.KEYCODE_MEDIA_STOP))
        assertFalse(MediaButtonPolicy.usesMultiClick(KeyEvent.KEYCODE_VOLUME_UP))
    }

    @Test
    fun `第一击立即下发播放_后续击不立即下发`() {
        assertEquals(PlayerCommand.Play, MediaButtonPolicy.immediateCommand(1))
        assertNull("第二击不得立即下发，否则双击会变成播放+重复播放", MediaButtonPolicy.immediateCommand(2))
        assertNull(MediaButtonPolicy.immediateCommand(3))
        assertNull(MediaButtonPolicy.immediateCommand(4))
        assertNull(MediaButtonPolicy.immediateCommand(0))
    }

    @Test
    fun `超时后按累计击数补发切歌_单击与四击以上不补发`() {
        assertNull("单击已由 immediateCommand 下发过播放，不得重复", MediaButtonPolicy.trailingCommand(1))
        assertEquals(PlayerCommand.Next, MediaButtonPolicy.trailingCommand(2))
        assertEquals(PlayerCommand.Previous, MediaButtonPolicy.trailingCommand(3))
        assertNull("四击及以上不下发（与 lite when(count){2,3} 一致）", MediaButtonPolicy.trailingCommand(4))
        assertNull(MediaButtonPolicy.trailingCommand(0))
    }

    @Test
    fun `完整手势序列_双击的端到端命令序列是先播放再下一首`() {
        // 模拟 350ms 内连按两下的真实时序：用策略函数推演，避免依赖 Handler 定时器。
        val dispatched = mutableListOf<PlayerCommand>()
        var clickCount = 0
        repeat(2) {
            clickCount++
            MediaButtonPolicy.immediateCommand(clickCount)?.let(dispatched::add)
        }
        MediaButtonPolicy.trailingCommand(clickCount)?.let(dispatched::add)
        assertEquals(listOf(PlayerCommand.Play, PlayerCommand.Next), dispatched)
    }

    @Test
    fun `完整手势序列_三击的端到端命令序列是先播放再上一首`() {
        val dispatched = mutableListOf<PlayerCommand>()
        var clickCount = 0
        repeat(3) {
            clickCount++
            MediaButtonPolicy.immediateCommand(clickCount)?.let(dispatched::add)
        }
        MediaButtonPolicy.trailingCommand(clickCount)?.let(dispatched::add)
        assertEquals(listOf(PlayerCommand.Play, PlayerCommand.Previous), dispatched)
    }

    @Test
    fun `明确语义键映射到对应命令`() {
        assertEquals(PlayerCommand.Play, MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_MEDIA_PLAY))
        assertEquals(PlayerCommand.Pause, MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_MEDIA_PAUSE))
        assertEquals(PlayerCommand.Next, MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_MEDIA_NEXT))
        assertEquals(PlayerCommand.Previous, MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(
            "线控停止按键按用户预期降级为暂停，而非清空队列",
            PlayerCommand.Pause,
            MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_MEDIA_STOP),
        )
    }

    @Test
    fun `非媒体键不被本策略认领`() {
        assertNull(MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_VOLUME_UP))
        assertNull(MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_HEADSETHOOK))
        assertNull(MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertNull(MediaButtonPolicy.directCommand(KeyEvent.KEYCODE_UNKNOWN))
    }
}
