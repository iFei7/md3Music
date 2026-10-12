package com.gracemusic.player.session

import android.app.Application
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 命令 ↔ Intent extras 编解码测试。
 *
 * 这是"跨组件命令传递"的协议层：`MediaButtonReceiver` → `Service.onStartCommand`、
 * 桌面小组件的 `PendingIntent`…都靠它。最容易出的缺陷是**带参命令忘了落 extra**，
 * 此时若读取端"容错重建"，`SeekTo`/`SeekBy` 就会退化成从头播放这类错误动作。
 * 因此本测试同时锁住"能往返"与"缺参时宁可为 null"。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class PlayerCommandIntentTest {

    private fun roundTrip(command: PlayerCommand): PlayerCommand? =
        PlayerCommandIntent.read(PlayerCommandIntent.put(Intent(), command))

    @Test
    fun `无参命令全部可往返`() {
        val commands = listOf(
            PlayerCommand.Play,
            PlayerCommand.Pause,
            PlayerCommand.TogglePlayPause,
            PlayerCommand.Next,
            PlayerCommand.Previous,
            PlayerCommand.Stop,
            PlayerCommand.ToggleFavorite,
        )
        for (command in commands) {
            assertEquals("命令 $command 的 Intent 往返必须闭合", command, roundTrip(command))
        }
    }

    @Test
    fun `带参命令可往返且参数不丢失`() {
        assertEquals(PlayerCommand.SeekTo(123_456L), roundTrip(PlayerCommand.SeekTo(123_456L)))
        assertEquals(PlayerCommand.SeekTo(-1L), roundTrip(PlayerCommand.SeekTo(-1L)))
        assertEquals(PlayerCommand.SeekBy(-5_000L), roundTrip(PlayerCommand.SeekBy(-5_000L)))
        assertEquals(
            PlayerCommand.SetPlayWhenReady(true),
            roundTrip(PlayerCommand.SetPlayWhenReady(true)),
        )
        assertEquals(
            PlayerCommand.SetPlayWhenReady(false),
            roundTrip(PlayerCommand.SetPlayWhenReady(false)),
        )
    }

    @Test
    fun `零值与 false 参数也必须真实写入`() {
        // SeekTo(0) 与 SetPlayWhenReady(false) 都是合法命令，若读取端用
        // getLongExtra(..., 默认0) / getBooleanExtra(..., false) 而忘记 hasExtra 校验，
        // "缺参"与"参数恰为零值"就无法区分——这里锁住零值能被正确往返。
        assertEquals(PlayerCommand.SeekTo(0L), roundTrip(PlayerCommand.SeekTo(0L)))
        assertEquals(PlayerCommand.SeekBy(0L), roundTrip(PlayerCommand.SeekBy(0L)))
        assertEquals(
            PlayerCommand.SetPlayWhenReady(false),
            roundTrip(PlayerCommand.SetPlayWhenReady(false)),
        )
    }

    @Test
    fun `带参命令缺 extra 时返回 null 而不是退化成默认值`() {
        val intent = Intent().putExtra(
            PlayerCommandIntent.EXTRA_COMMAND,
            PlayerCommandCodec.CODE_SEEK_TO,
        )
        assertNull("缺 positionMs 不得退化成 SeekTo(0)", PlayerCommandIntent.read(intent))

        val seekBy = Intent().putExtra(
            PlayerCommandIntent.EXTRA_COMMAND,
            PlayerCommandCodec.CODE_SEEK_BY,
        )
        assertNull("缺 deltaMs 不得退化成 SeekBy(0)", PlayerCommandIntent.read(seekBy))

        val playWhenReady = Intent().putExtra(
            PlayerCommandIntent.EXTRA_COMMAND,
            PlayerCommandCodec.CODE_SET_PLAY_WHEN_READY,
        )
        assertNull(
            "缺 playWhenReady 不得退化成 false（那会变成一次静默暂停）",
            PlayerCommandIntent.read(playWhenReady),
        )
    }

    @Test
    fun `空 Intent 与未知编码返回 null`() {
        assertNull(PlayerCommandIntent.read(null))
        assertNull(PlayerCommandIntent.read(Intent()))
        assertNull(
            PlayerCommandIntent.read(
                Intent().putExtra(PlayerCommandIntent.EXTRA_COMMAND, "bogus"),
            ),
        )
    }
}
