package com.md3music.md3music.player.session

import android.os.Bundle
import androidx.annotation.DrawableRes
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList

/**
 * now-playing 通知的 `MediaNotification.Provider` 装饰器。
 *
 * 1:1 移植 lite `MD3MusicMediaSessionService.kt:50-71`（`Md3NotificationProvider`）：
 * 唯一职责是把通知小图标统一钉成项目的 monochrome 图标，其余全部委托 media3 默认实现。
 *
 * ### 为什么需要这一层
 *
 * media3 的 `DefaultMediaNotificationProvider` 默认小图标取自 `R.drawable.media3_notification_small_icon`，
 * 与本项目图标不一致；而 `setSmallIcon` 只能通过 provider 的公有 API 设置，
 * 没有静态配置入口。装饰器是最小侵入的做法——**不重写通知构建逻辑**，
 * 因此 media3 后续版本对通知布局/按钮槽位的调整会自动跟随（lite 踩过"手写通知布局
 * 与系统按钮槽位不匹配"的坑，故这里坚决不自己拼 Notification）。
 *
 * ### 委托而非继承
 *
 * 用组合（持有 [delegate]）而不是继承 `DefaultMediaNotificationProvider`：
 * 该类的构造函数与 `AbstractMediaNotificationProvider` 的内部状态不保证稳定，
 * 继承会把内部实现细节变成 API 契约。
 */
@OptIn(UnstableApi::class)
internal class Md3NotificationProvider(
    private val delegate: DefaultMediaNotificationProvider,
    @DrawableRes smallIconResId: Int,
) : MediaNotification.Provider {

    init {
        // 幂等的字段赋值；放在 init 而不是 createNotification 里，
        // 避免蓝牙歌词高频刷新时每帧都做一次无意义的 setter 调用。
        delegate.setSmallIcon(smallIconResId)
    }

    override fun createNotification(
        mediaSession: MediaSession,
        customLayout: ImmutableList<CommandButton>,
        actionFactory: MediaNotification.ActionFactory,
        onNotificationChangedCallback: MediaNotification.Provider.Callback,
    ): MediaNotification = delegate.createNotification(
        mediaSession,
        customLayout,
        actionFactory,
        onNotificationChangedCallback,
    )

    override fun handleCustomCommand(
        session: MediaSession,
        action: String,
        extras: Bundle,
    ): Boolean = delegate.handleCustomCommand(session, action, extras)
}
