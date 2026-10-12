package com.gracemusic.player.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 命令编码表测试。
 *
 * 锁住的是「协议兼容性」而不是实现细节：编码值一旦被写进 PendingIntent / 桌面小组件的
 * RemoteViews 点击意图，就会随用户设备上的旧构件存活数月。因此每个编码值都必须被显式断言，
 * 任何"顺手改个名字"的改动都会在这里立刻失败。
 */
class PlayerCommandCodecTest {

    @Test
    fun `每个无参命令的编码值被钉死`() {
        assertEquals("play", PlayerCommandCodec.encode(PlayerCommand.Play))
        assertEquals("pause", PlayerCommandCodec.encode(PlayerCommand.Pause))
        assertEquals("togglePlayPause", PlayerCommandCodec.encode(PlayerCommand.TogglePlayPause))
        assertEquals("next", PlayerCommandCodec.encode(PlayerCommand.Next))
        assertEquals("previous", PlayerCommandCodec.encode(PlayerCommand.Previous))
        assertEquals("stop", PlayerCommandCodec.encode(PlayerCommand.Stop))
        assertEquals("toggleFavorite", PlayerCommandCodec.encode(PlayerCommand.ToggleFavorite))
    }

    @Test
    fun `编码与解码互为逆运算`() {
        val roundTrippable = listOf(
            PlayerCommand.Play,
            PlayerCommand.Pause,
            PlayerCommand.TogglePlayPause,
            PlayerCommand.Next,
            PlayerCommand.Previous,
            PlayerCommand.Stop,
            PlayerCommand.ToggleFavorite,
        )
        for (command in roundTrippable) {
            assertEquals(
                "命令 $command 的编解码必须闭合",
                command,
                PlayerCommandCodec.decode(PlayerCommandCodec.encode(command)),
            )
        }
    }

    @Test
    fun `带参命令可以被编码但拒绝仅凭编码重建`() {
        val withExtras = listOf(
            PlayerCommand.SeekTo(120_000L),
            PlayerCommand.SeekBy(-5_000L),
            PlayerCommand.SetPlayWhenReady(true),
        )
        for (command in withExtras) {
            val code = PlayerCommandCodec.encode(command)
            assertTrue("带参命令的编码必须被 isKnown 认识：$code", PlayerCommandCodec.isKnown(code))
            assertNull(
                "带参命令不得仅凭编码重建，否则参数会被静默丢弃（$command）",
                PlayerCommandCodec.decode(code),
            )
            assertTrue("带参命令必须要求 extra：$command", PlayerCommandCodec.requiresExtras(command))
        }
    }

    @Test
    fun `无参命令不要求 extra`() {
        assertFalse(PlayerCommandCodec.requiresExtras(PlayerCommand.Play))
        assertFalse(PlayerCommandCodec.requiresExtras(PlayerCommand.Stop))
    }

    @Test
    fun `未知编码与空编码被识别为未知且不重建`() {
        assertFalse(PlayerCommandCodec.isKnown(null))
        assertFalse(PlayerCommandCodec.isKnown(""))
        assertFalse(PlayerCommandCodec.isKnown("bogus"))
        assertNull(PlayerCommandCodec.decode(null))
        assertNull(PlayerCommandCodec.decode(""))
        assertNull(PlayerCommandCodec.decode("bogus"))
    }

    @Test
    fun `参数键名是协议的一部分`() {
        assertEquals("positionMs", PlayerCommandCodec.EXTRA_POSITION_MS)
        assertEquals("deltaMs", PlayerCommandCodec.EXTRA_DELTA_MS)
        assertEquals("playWhenReady", PlayerCommandCodec.EXTRA_PLAY_WHEN_READY)
    }
}
