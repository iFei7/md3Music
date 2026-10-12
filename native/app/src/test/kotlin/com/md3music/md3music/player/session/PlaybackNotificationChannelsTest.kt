package com.md3music.md3music.player.session

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * 保活通知渠道测试。
 *
 * 渠道配置是"建错就改不回来"的典型：Android 8+ 渠道一旦创建，**重要度不可修改**。
 * 若首次创建时误用 IMPORTANCE_LOW/DEFAULT，保活通知会变成会响、会震、会占据
 * 通知顶部的打扰项，只能靠卸载重装或换渠道 id 才能纠正。
 * 因此这里把重要度、静音、无角标逐项断言。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class PlaybackNotificationChannelsTest {

    private val context get() = RuntimeEnvironment.getApplication()

    private val manager: NotificationManager
        get() = context.getSystemService(NotificationManager::class.java)

    private fun channelOf(id: String): NotificationChannel? = manager.getNotificationChannel(id)

    @Test
    fun `通知 id 与渠道 id 被钉死为协议值`() {
        assertEquals("md3music_keepalive_v2", PlaybackNotificationChannels.KEEPALIVE_CHANNEL_ID)
        // 1001 是 media3 的 now-playing 通知 id；相同 id 会互相覆盖，
        // 保活通知会顶掉播放控制，必须错开。
        assertEquals(1002, PlaybackNotificationChannels.KEEPALIVE_NOTIFICATION_ID)
    }

    @Test
    fun `首次创建得到最低重要度且完全静音的渠道`() {
        PlaybackNotificationChannels.ensureCreated(context)

        val channel = channelOf(PlaybackNotificationChannels.KEEPALIVE_CHANNEL_ID)
        assertNotNull("渠道必须被创建", channel)
        assertEquals(
            "重要度必须是 MIN：否则保活通知会变成打扰项，且创建后无法修改",
            NotificationManager.IMPORTANCE_MIN,
            channel!!.importance,
        )
        assertNull("渠道必须静音，否则部分 ROM 会「叮咚」", channel.sound)
        assertFalse("不得显示角标", channel.canShowBadge())
        assertEquals("播放保活", channel.name.toString())
    }

    @Test
    fun `重复调用不重建渠道`() {
        PlaybackNotificationChannels.ensureCreated(context)
        val first = channelOf(PlaybackNotificationChannels.KEEPALIVE_CHANNEL_ID)

        PlaybackNotificationChannels.ensureCreated(context)
        val second = channelOf(PlaybackNotificationChannels.KEEPALIVE_CHANNEL_ID)

        assertEquals(
            "配置已正确时不得删除重建——重建会重置用户在系统设置里对通知做的调整",
            first,
            second,
        )
        assertEquals(1, manager.notificationChannels.size)
    }

    @Test
    fun `既有渠道重要度不符时先删后建`() {
        // 模拟升级路径：旧版本曾以可发声重要度建过同 id 渠道。
        manager.createNotificationChannel(
            NotificationChannel(
                PlaybackNotificationChannels.KEEPALIVE_CHANNEL_ID,
                "旧渠道",
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )

        PlaybackNotificationChannels.ensureCreated(context)

        val channel = channelOf(PlaybackNotificationChannels.KEEPALIVE_CHANNEL_ID)
        assertEquals(
            "重要度不符时必须先删后建（渠道重要度不可原地修改）",
            NotificationManager.IMPORTANCE_MIN,
            channel!!.importance,
        )
        assertEquals("重建后名称应为当前资源文案", "播放保活", channel.name.toString())
    }

    @Test
    fun `通知文案取自字符串资源且非空`() {
        assertEquals("播放保活", context.getString(com.md3music.md3music.R.string.keepalive_channel_name))
        assertFalse(
            context.getString(com.md3music.md3music.R.string.keepalive_notification_text).isBlank(),
        )
    }
}
