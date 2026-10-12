package com.gracemusic.player.session

import android.app.Application
import android.os.Bundle
import androidx.media3.common.Player
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.gracemusic.player.engine.AudioEngine
import com.gracemusic.player.engine.AudioEngineConfig
import com.gracemusic.player.engine.AudioEngineFactory
import com.gracemusic.player.engine.EngineRole
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * `MediaSession.Callback` 行为测试。
 *
 * 用**真实的** `MediaSession`（挂在真实的 ExoPlayer 上）而不是 mock：
 * 本类要锁住的三条行为全部与 media3 的协议细节耦合（`RESULT_INFO_SKIPPED` 的取值、
 * `onConnect` 必须用 `AcceptedResultBuilder`、自定义命令要靠 `SessionCommand` 匹配），
 * mock 掉之后这些协议约束就测不出来了。
 *
 * 最关键的回归项是 [播放暂停命令不得投递_避免与媒体3 默认切换叠加]：一旦有人"顺手补齐"
 * 给 PLAY_PAUSE 也投递一条 `TogglePlayPause`，用户点通知暂停键会变成"没反应"（两次切换抵消）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class Md3MediaSessionCallbackTest {

    private lateinit var engine: AudioEngine
    private lateinit var session: MediaSession
    private lateinit var registry: PlaybackSessionRegistry
    private lateinit var callback: Md3MediaSessionCallback

    /** 记录派发内容的探针桥。 */
    private val dispatched = mutableListOf<PlayerCommand>()

    private val controllerInfo: MediaSession.ControllerInfo
        get() = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
            "com.gracemusic.test",
            /* pid= */ 1,
            /* uid= */ 1,
            /* libraryVersion= */ 0,
            /* interfaceVersion= */ 0,
            /* trusted= */ true,
            Bundle(),
        )

    @Before
    fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        engine = AudioEngineFactory(context).create(
            AudioEngineConfig(role = EngineRole.MAIN, enableFlacExtension = false),
        )
        registry = PlaybackSessionRegistry()
        callback = Md3MediaSessionCallback(registry)
        registry.attach(object : PlaybackSessionBridge {
            override fun dispatch(command: PlayerCommand): Boolean {
                dispatched.add(command)
                return true
            }
        })
        session = MediaSession.Builder(context, engine.player)
            .setId("gracemusic-test")
            .setCallback(callback)
            .build()
    }

    @After
    fun tearDown() {
        session.release()
        engine.close()
    }

    @Test
    fun `下一首命令被拦截并转发播放域`() {
        assertEquals(
            SessionResult.RESULT_INFO_SKIPPED,
            callback.onPlayerCommandRequest(session, controllerInfo, Player.COMMAND_SEEK_TO_NEXT),
        )
        assertEquals(listOf(PlayerCommand.Next), dispatched)
    }

    @Test
    fun `按媒体项下一首同样被拦截`() {
        assertEquals(
            SessionResult.RESULT_INFO_SKIPPED,
            callback.onPlayerCommandRequest(
                session,
                controllerInfo,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            ),
        )
        assertEquals(listOf(PlayerCommand.Next), dispatched)
    }

    @Test
    fun `上一首命令被拦截并转发播放域`() {
        assertEquals(
            SessionResult.RESULT_INFO_SKIPPED,
            callback.onPlayerCommandRequest(session, controllerInfo, Player.COMMAND_SEEK_TO_PREVIOUS),
        )
        assertEquals(listOf(PlayerCommand.Previous), dispatched)
    }

    @Test
    fun `按媒体项上一首同样被拦截`() {
        assertEquals(
            SessionResult.RESULT_INFO_SKIPPED,
            callback.onPlayerCommandRequest(
                session,
                controllerInfo,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            ),
        )
        assertEquals(listOf(PlayerCommand.Previous), dispatched)
    }

    @Test
    fun `播放暂停命令不得投递_避免与媒体3 默认切换叠加`() {
        assertEquals(
            "必须放行 media3 默认实现（返回 SUCCESS），否则双重切换会互相抵消",
            SessionResult.RESULT_SUCCESS,
            callback.onPlayerCommandRequest(session, controllerInfo, Player.COMMAND_PLAY_PAUSE),
        )
        assertTrue("PLAY_PAUSE 不得投递任何命令", dispatched.isEmpty())
    }

    @Test
    fun `未拦截的命令放行且不投递`() {
        assertEquals(
            SessionResult.RESULT_SUCCESS,
            callback.onPlayerCommandRequest(session, controllerInfo, Player.COMMAND_SET_SPEED_AND_PITCH),
        )
        assertTrue(dispatched.isEmpty())
    }

    @Test
    fun `收藏自定义命令被转发且返回成功`() {
        val result = callback.onCustomCommand(
            session,
            controllerInfo,
            Md3SessionCommands.toggleFavoriteCommand(),
            Bundle(),
        )

        assertEquals(listOf(PlayerCommand.ToggleFavorite), dispatched)
        assertEquals(SessionResult.RESULT_SUCCESS, result.get().resultCode)
    }

    @Test
    fun `未知自定义命令不转发但仍返回成功_兼容旧通知残留`() {
        val result = callback.onCustomCommand(
            session,
            controllerInfo,
            SessionCommand("com.gracemusic.legacy_command", Bundle()),
            Bundle(),
        )

        assertTrue("未知命令不得被误认为收藏", dispatched.isEmpty())
        assertEquals(
            "未知命令必须返回成功：返回 NOT_SUPPORTED 会让 SystemUI 弹错误反馈",
            SessionResult.RESULT_SUCCESS,
            result.get().resultCode,
        )
    }

    @Test
    fun `onConnect 放行自定义命令供通知按钮渲染`() {
        val result = callback.onConnect(session, controllerInfo)

        assertTrue("必须是已接受结果，否则播放控制整体不可用", result.isAccepted)
        assertTrue(
            "未在 onConnect 声明收藏命令，通知栏收藏按钮会被过滤掉",
            result.availableSessionCommands.contains(Md3SessionCommands.toggleFavoriteCommand()),
        )
    }
}
