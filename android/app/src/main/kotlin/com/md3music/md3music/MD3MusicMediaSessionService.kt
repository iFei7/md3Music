package com.md3music.md3music

import android.annotation.SuppressLint
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaNotification
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.CommandButton
import com.google.common.collect.ImmutableList
import com.ryanheise.just_audio.AudioPlayer

/**
 * 媒体3 会话承载服务（方案 B 阶段1：媒体3 通知栏上线）。
 *
 * 职责：把 just_audio fork 自建的 androidx.media3.session.MediaSession 归入本服务，
 * 由 media3 的 MediaNotificationManager + DefaultMediaNotificationProvider 生成系统
 * now playing 通知（通知栏可见、可控制播放）。仅作会话承载，不承担播放/焦点逻辑。
 */
@OptIn(UnstableApi::class)
@SuppressLint("UnsafeOptInUsageError")
class MD3MusicMediaSessionService : MediaSessionService() {

    companion object {
        /// 批次14：进程内单例引用（本服务的唯一实例）。AudioPlaybackService 经此
        /// 直查 media3 是否真正处于前台（fork startedInForeground 直读），替代
        /// 不可靠的系统 API 探测（v1 四条件轮询已证伪）。
        @Volatile
        var instance: MD3MusicMediaSessionService? = null

        private const val TAG = "MD3MusicMediaSessionService"
    }

    override fun onCreate() {
        // 必须在 onCreate() 返回前设置（fork 源码 MediaSessionService:594 的约束）。
        // 包一层 provider 才能拿到 Media3 真正生成的那条媒体通知（含 id 与 Notification
        // 对象），并统一指定通知小图标。
        setMediaNotificationProvider(
            Md3NotificationProvider(
                DefaultMediaNotificationProvider.Builder(applicationContext).build()
            )
        )
        super.onCreate()
        // 批次14：注册进程内单例（与 setMediaSessionServiceHost 相互独立）
        instance = this
        // 注册为 fork 的会话 host：fork 创建/已有活跃会话后 addSession 到本服务渲染通知
        AudioPlayer.setMediaSessionServiceHost(this)
    }

    override fun onGetSession(info: MediaSession.ControllerInfo): MediaSession? {
        // 返回 fork 当前活跃的媒体3会话；未初始化时拒绝连接
        return AudioPlayer.getActiveMediaSession()
    }

    /**
     * 委托给 media3 默认 provider，并统一指定通知小图标。
     */
    private class Md3NotificationProvider(
        private val delegate: DefaultMediaNotificationProvider
    ) : MediaNotification.Provider {

        override fun createNotification(
            mediaSession: MediaSession,
            customLayout: ImmutableList<CommandButton>,
            actionFactory: MediaNotification.ActionFactory,
            onNotificationChangedCallback: MediaNotification.Provider.Callback
        ): MediaNotification {
            delegate.setSmallIcon(R.drawable.ic_launcher_monochrome)
            return delegate.createNotification(
                mediaSession, customLayout, actionFactory, onNotificationChangedCallback
            )
        }

        override fun handleCustomCommand(
            session: MediaSession,
            action: String,
            extras: Bundle
        ): Boolean = delegate.handleCustomCommand(session, action, extras)
    }

    override fun onDestroy() {
        AudioPlayer.setMediaSessionServiceHost(null)
        // 批次14：注销单例引用（先于 super.onDestroy，避免销毁后仍被查询到）
        instance = null
        super.onDestroy()
    }

    /// 批次14：media3 是否真正处于前台（fork MediaNotificationManager 的
    /// startedInForeground 直读）。查询异常/服务未就绪一律返回 false——
    /// 宁可让 AudioPlaybackService 多挂隐形保活，不可出现零 FGS 进程被系统杀。
    fun isMedia3Foreground(): Boolean = try {
        super.isNotificationStartedInForeground()
    } catch (_: Throwable) {
        false
    }

    /**
     * 批次17（P0）：任务被移除（最近任务卡片划掉）→ 停播并结束本服务。
     *
     * 用户明确要求「划掉即停、进程退出」。批次15/16 的「播放中不 stopSelf、
     * 补挂通知保活」语义整体反转删除。
     *
     * 有意**不调用 super**：fork 默认实现为
     * `if (!isPlaybackOngoing()) stopSelf()`，而 isPlaybackOngoing() 取自
     * startedInForeground（是否已 startForeground）。Android 12 后台掉前台后该值
     * 恒为 false，划卡会被误判为「未播放」进而 stopSelf 并删除通知（即使服务因
     * 绑定仍在，也会掉 FGS）。fork 的 MediaSessionService#onTaskRemoved 未标注
     * @CallSuper，允许子类完全接管；本实现显式停播，不依赖 super 的默认语义。
     *
     * 停播保留播放进度：playWhenReady=false + pause()（不用 stop()，避免
     * 清掉进度），用户下次打开 App 可从原进度续播。
     * fork 的 pauseAllPlayersAndStopSelf() 只置 playWhenReady=false，这里
     * 显式补 pause()，确保播放器立即进入暂停态。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "onTaskRemoved: stop playback and exit")
        try {
            getSessions().forEach { session ->
                session.player.let { p ->
                    p.playWhenReady = false
                    p.pause()
                }
            }
        } catch (e: Throwable) {
            // 会话查询/操作失败不阻断退出：停播是尽力而为，stopSelf 必须执行
            Log.w(
                TAG,
                "onTaskRemoved: pause sessions failed: " +
                    "${e.javaClass.simpleName}: ${e.message}"
            )
        }
        stopSelf()
    }
}
