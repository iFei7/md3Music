package com.md3music.md3music.player.session

import android.app.Application
import android.content.ContextWrapper
import android.content.Intent
import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * 媒体键接收器测试。
 *
 * 验证的是"按键 → 派发到保活服务"这条链的**决策**：哪个键产生哪条命令、
 * ACTION_UP 与非媒体广播必须被忽略、多击按键的第一击必须立即派发。
 *
 * 多击窗口的时序细节由 [MediaButtonClickTrackerTest] 覆盖（那里能用虚拟时钟精确推进），
 * 本类只锁"第一击立即播放"这一条，避免与前者重复。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class MediaButtonReceiverTest {

    private val application: Application get() = RuntimeEnvironment.getApplication()

    private val receiver = MediaButtonReceiver()

    @Before
    fun setUp() {
        // 多击窗口是静态状态，会跨用例残留；不复位会把后一用例的单击判成双击。
        MediaButtonReceiver.clickTracker.reset()
        shadowOf(application as ContextWrapper).clearStartedServices()
    }

    /**
     * 被记录的「已启动服务」Intent 列表。
     *
     * 必须把 [Application] 显式上转为 [ContextWrapper] 才能拿到
     * `ShadowContextWrapper`：`Shadows.shadowOf(Application)` 返回的是 `ShadowApplication`，
     * 而启动服务的记录自 Robolectric 4.x 起已搬到 `ShadowContextWrapper`
     * （`ShadowApplication` 不再有 `getNextStartedService`）。
     */
    private fun startedIntents(): List<Intent> =
        shadowOf(application as ContextWrapper).allStartedServices

    private fun mediaButtonIntent(keyCode: Int, action: Int = KeyEvent.ACTION_DOWN): Intent =
        Intent(Intent.ACTION_MEDIA_BUTTON).putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(action, keyCode))

    private fun dispatchedCommand(): PlayerCommand? {
        val intent = startedIntents().lastOrNull() ?: return null
        assertEquals(
            "必须派发到保活服务（进程被杀时只有它能被拉起）",
            PlaybackKeepAliveService::class.java.name,
            intent.component?.className,
        )
        assertEquals(
            "必须带 DISPATCH_COMMAND action 才会走派发分支",
            PlaybackKeepAliveService.ACTION_DISPATCH_COMMAND,
            intent.action,
        )
        return PlayerCommandIntent.read(intent)
    }

    @Test
    fun `耳机钩键单击立即派发播放`() {
        receiver.onReceive(application, mediaButtonIntent(KeyEvent.KEYCODE_HEADSETHOOK))
        assertEquals(PlayerCommand.Play, dispatchedCommand())
    }

    @Test
    fun `播放暂停键单击立即派发播放`() {
        receiver.onReceive(application, mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
        assertEquals(PlayerCommand.Play, dispatchedCommand())
    }

    @Test
    fun `独立下一首键派发下一首且不走多击路径`() {
        receiver.onReceive(application, mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_NEXT))
        assertEquals(PlayerCommand.Next, dispatchedCommand())
    }

    @Test
    fun `独立上一首键派发上一首`() {
        receiver.onReceive(application, mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(PlayerCommand.Previous, dispatchedCommand())
    }

    @Test
    fun `独立播放与暂停键分别派发`() {
        receiver.onReceive(application, mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_PLAY))
        assertEquals(PlayerCommand.Play, dispatchedCommand())

        receiver.onReceive(application, mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_PAUSE))
        assertEquals(PlayerCommand.Pause, dispatchedCommand())
    }

    @Test
    fun `停止键降级为暂停不清空队列`() {
        receiver.onReceive(application, mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_STOP))
        assertEquals(PlayerCommand.Pause, dispatchedCommand())
    }

    @Test
    fun `ACTION_UP 被忽略_避免多击计数翻倍`() {
        receiver.onReceive(
            application,
            mediaButtonIntent(KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.ACTION_UP),
        )
        assertEquals(0, startedIntents().size)
        assertNull(dispatchedCommand())
    }

    @Test
    fun `非媒体键被忽略`() {
        receiver.onReceive(application, mediaButtonIntent(KeyEvent.KEYCODE_VOLUME_UP))
        assertEquals(0, startedIntents().size)
    }

    @Test
    fun `非 MEDIA_BUTTON 广播被忽略`() {
        val intent = Intent(Intent.ACTION_SCREEN_ON).putExtra(
            Intent.EXTRA_KEY_EVENT,
            KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_HEADSETHOOK),
        )
        receiver.onReceive(application, intent)
        assertEquals(0, startedIntents().size)
    }

    @Test
    fun `缺少按键事件 extra 被忽略`() {
        receiver.onReceive(application, Intent(Intent.ACTION_MEDIA_BUTTON))
        assertEquals(0, startedIntents().size)
    }

    @Test
    fun `派发使用应用上下文而非接收器入参上下文`() {
        // 接收器可能收到 Activity/Service 上下文；用 applicationContext 才能避免
        // 把短生命周期上下文塞进延后 350ms 执行的回调里（双击补发路径会长期持有它）。
        val holder = ContextWrapper(application)
        receiver.onReceive(holder, mediaButtonIntent(KeyEvent.KEYCODE_MEDIA_NEXT))
        assertNotNull(dispatchedCommand())
        assertEquals(1, startedIntents().size)
    }
}
