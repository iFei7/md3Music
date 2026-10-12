package com.gracemusic.player.session

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import com.gracemusic.R

/**
 * 保活通知渠道的常量与创建逻辑。
 *
 * 1:1 移植 lite `AudioPlaybackService.kt:1311-1371`（`createNotificationChannel`）的
 * 保活部分，保留其全部关键决策（IMPORTANCE_MIN、静音、`setShowBadge(false)`、
 * 隐私锁屏可见性、"重要度不符则先删后建"的迁移策略）。
 *
 * ### 为什么单列一个渠道
 *
 * media3 的 now-playing 通知走自己的默认渠道（`default_channel_id`，名称取自
 * `R.string.default_notification_channel_name`，已带 zh 本地化「正在播放」）。
 * 保活通知是**另一条**用户可独立关闭的通知，必须有自己的渠道——用户长按它进入系统设置
 * 关闭时，不会误伤 now-playing 通知。
 *
 * ### 为什么重要度必须是 IMPORTANCE_MIN
 *
 * Android 8+ 渠道一旦创建，**重要度不可修改**。所以要展示在"折叠的其他通知"区、
 * 且不发出任何提示音/震动，只能从一开始就建成 IMPORTANCE_MIN。
 * lite 踩过两次坑：一是遗产渠道以 IMPORTANCE_NONE 建（系统直接隐藏，达不到保活可见的目的），
 * 二是从可发声渠道改建时系统不保证删除重建生效。因此本实现：
 *   1. 检测已有渠道的重要度/静音配置，不符则先删后建；
 *   2. 同时 `setSound(null, null)` + `enableVibration(false)`，兜住"渠道静默但部分 ROM
 *      仍「叮咚」"的机型差异（lite 注释里荣耀/vivo 实测）。
 */
internal object PlaybackNotificationChannels {

    /**
     * 保活渠道 id。
     *
     * GraceMusic 是全新 applicationId（`com.gracemusic.app`）下的独立应用，首次安装时
     * 系统里不存在任何历史渠道，**没有旧渠道兼容负担**：渠道 id 只需在本应用内稳定即可，
     * 不必再沿用 lite 时代的 `md3music_keepalive_v2`（两者 applicationId 不同、渠道本就
     * 互不可见，同名反而会在日志/故障排查时造成与 lite 的混淆）。`_v2` 后缀保留——
     * 它标记的是"已修正为 IMPORTANCE_MIN 静默渠道"这一代实现，对未来的自升级仍有意义。
     */
    const val KEEPALIVE_CHANNEL_ID = "gracemusic_keepalive_v2"

    /**
     * 保活通知 id。
     *
     * 取 1002 而不是复用 media3 的 1001（[androidx.media3.session.DefaultMediaNotificationProvider.DEFAULT_NOTIFICATION_ID]）：
     * 两个渠道是两条独立通知，若 id 相同会互相覆盖——保活通知会顶掉 now-playing，
     * 用户就看不到播放控制了。与 lite `NOTIFICATION_ID = 1002` 同理。
     */
    const val KEEPALIVE_NOTIFICATION_ID = 1002

    /** 创建（或在配置不符时重建）保活渠道。幂等，可在每次服务启动时调用。 */
    fun ensureCreated(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val appContext = context.applicationContext

        if (needsRecreate(manager)) {
            // 渠道重要度不可变更，只能删除后重建；用户对该渠道的"关闭"状态也会一并重置，
            // 这是升级路径上可接受的取舍（lite 同样如此）。
            manager.deleteNotificationChannel(KEEPALIVE_CHANNEL_ID)
        }
        if (manager.getNotificationChannel(KEEPALIVE_CHANNEL_ID) == null) {
            manager.createNotificationChannel(buildChannel(appContext))
        }
    }

    /** 现有渠道的重要度/静音配置是否符合 IMPORTANCE_MIN 静默要求。 */
    private fun needsRecreate(manager: NotificationManager): Boolean {
        val existing = manager.getNotificationChannel(KEEPALIVE_CHANNEL_ID) ?: return false
        return existing.importance != NotificationManager.IMPORTANCE_MIN || existing.sound != null
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildChannel(context: Context): NotificationChannel =
        NotificationChannel(
            KEEPALIVE_CHANNEL_ID,
            context.getString(R.string.keepalive_channel_name),
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = context.getString(R.string.keepalive_channel_description)
            setShowBadge(false)
            lockscreenVisibility = NotificationCompat.VISIBILITY_PRIVATE
            // 关键修复：禁用声音与震动（部分 ROM 会忽略 IMPORTANCE_MIN 仍发声）
            setSound(null, null)
            enableVibration(false)
        }
}
