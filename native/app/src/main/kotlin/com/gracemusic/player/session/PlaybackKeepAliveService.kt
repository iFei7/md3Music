package com.gracemusic.player.session

import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.media3.session.MediaSessionService
import com.gracemusic.R
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * 播放保活前台服务（IMPORTANCE_MIN 静默通知，防 ROM 折叠 now-playing 后回收进程）。
 *
 * 对应 lite `AudioPlaybackService.kt` 的保活职责（`ensureForeground` /
 * `refreshKeepaliveForeground` / `startForegroundDetached`，见 `:843-923`），
 * 但剥掉了全部 Flutter 专有部分（后台 FlutterEngine、MethodChannel、
 * `sendFlutterCommand` 广播）。
 *
 * ### 为什么是**独立**的第二个前台服务，而不是并入 `Md3MediaSessionService`
 *
 * 一个 `Service` 在同一时刻只能持有一条前台通知（`startForeground` 的 id 会相互替换）。
 * 而本服务的全部价值恰恰在于"**第二条**通知"：now-playing 通知被 ROM 折叠/限流后，
 * 仍有一条 IMPORTANCE_MIN 的常驻通知把服务钉在前台状态，进程才不会降级为普通后台。
 * 若并入 media3 的会话服务，就得和 media3 的 `MediaNotificationManager` 抢同一个
 * `startForeground` 槽位，等于把 media3 的通知渲染逻辑改坏。lite 也是两个服务，
 * 这不是历史包袱而是结构必然。
 *
 * ### 生命周期由谁驱动（重要契约）
 *
 * 本服务**刻意不自作主张**：它不监听播放器状态、不猜测"该不该保活"。
 * - 媒体键唤醒路径：`MediaButtonReceiver` → [startWithCommand]（进程被拉起后立即进入前台，
 *   满足 Android 12+「`startForegroundService` 后 5 秒内必须 `startForeground`」的硬约束）；
 * - 应用内播放：由播放域（T45 `PlaybackStore`）在开始播放时调 [start]、在停止播放时调 [stop]。
 *
 * 这样"什么时候该保活"只有一个决策者，与 lite 把 WakeLock 与通知的开关散布在
 * 多处 `ACTION_*` 分支里的做法相比更不容易出现状态漂移。
 *
 * ### 为什么不再手写 WakeLock / WifiLock
 *
 * lite 用 `PowerManager.PARTIAL_WAKE_LOCK` + `WifiManager.WIFI_MODE_FULL_HIGH_PERF`
 * 手工持锁（`AudioPlaybackService.kt:418-455`），那是因为 fork 从未调用
 * `ExoPlayer.Builder.setWakeMode` —— media3 的 `wakeMode` **默认为 `C.WAKE_MODE_NONE`**，
 * 内部 `WakeLockManager` / `WifiLockManager` 都是关闭的（`ExoPlayer.java:700`、
 * `ExoPlayerImpl.java:433-436`）。native 改为直接
 * `setWakeMode(C.WAKE_MODE_NETWORK)`（见 `AudioEngineFactory`），media3 自带的实现使用的
 * 正是完全相同的两把锁（`WakeLockManager.java:64` 的 `PARTIAL_WAKE_LOCK`、
 * `WifiLockManager.java:63` 的 `WIFI_MODE_FULL_HIGH_PERF`），且随播放器状态自动持放——
 * 比手写更少泄漏路径。故此处**不再**手工持锁。
 */
@AndroidEntryPoint
class PlaybackKeepAliveService : Service() {

    companion object {
        private const val TAG = "PlaybackKeepAlive"

        /** 启动/复用本服务并派发一条播放命令。 */
        const val ACTION_DISPATCH_COMMAND = "com.gracemusic.app.action.DISPATCH_COMMAND"

        /** 进入保活前台（播放域开始播放时调用）。 */
        const val ACTION_START = "com.gracemusic.app.action.START"

        /** 撤下保活通知并结束本服务（停止播放时调用）。 */
        const val ACTION_STOP = "com.gracemusic.app.action.STOP"

        /**
         * 启动服务并派发命令（媒体键唤醒入口）。
         *
         * 走 `startForegroundService`：Android 12+ 明确允许「收到媒体键广播的应用」
         * 启动前台服务，这是唤醒播放能拿到前台身份的唯一合法窗口。
         */
        fun startWithCommand(context: Context, command: PlayerCommand) {
            val intent = Intent(context, PlaybackKeepAliveService::class.java)
                .setAction(ACTION_DISPATCH_COMMAND)
            PlayerCommandIntent.put(intent, command)
            startCompat(context, intent)
        }

        /** 请求进入保活前台。已在前台时是幂等的。 */
        fun start(context: Context) {
            startCompat(
                context,
                Intent(context, PlaybackKeepAliveService::class.java).setAction(ACTION_START),
            )
        }

        /** 请求撤下保活通知并结束服务。 */
        fun stop(context: Context) {
            val intent = Intent(context, PlaybackKeepAliveService::class.java).setAction(ACTION_STOP)
            try {
                // 停止路径不需要前台身份，用 startService 即可；失败（例如被 ROM 拦截）不影响
                // 用户可感知行为——真正的播放停止由播放域完成，这里只是回收通知。
                context.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "stop 请求失败：${e.javaClass.simpleName}: ${e.message}")
            }
        }

        private fun startCompat(context: Context, intent: Intent) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "启动失败: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    @Inject
    lateinit var registry: PlaybackSessionRegistry

    /** 是否已成功进入前台（决定异常路径是"自杀"还是"留着"）。 */
    private var promoted = false

    private var cachedLaunchIntent: PendingIntent? = null

    /** 缓存的保活通知对象（内容恒定，无需重建）。 */
    private var cachedNotification: android.app.Notification? = null

    /**
     * 会话承载服务的绑定连接。
     *
     * 1:1 对应 lite `AudioPlaybackService.kt:626-633`：用带
     * `MediaSessionService.SERVICE_INTERFACE` action 的 Intent 绑定，确保
     * `MediaSessionService.onBind` 走 `case SERVICE_INTERFACE` 分支返回非空 binder
     * （否则绑定会被判定为失败）。绑定成功即意味着会话服务已 `onCreate` →
     * 播放引擎与 MediaSession 均已就绪，随后 media3 才能在播放开始后渲染 now-playing 通知。
     */
    private val sessionServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            Log.i(TAG, "会话承载服务已连接")
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            Log.w(TAG, "会话承载服务连接断开")
        }
    }

    private var sessionServiceBound = false

    override fun onCreate() {
        super.onCreate()
        PlaybackNotificationChannels.ensureCreated(this)
        bindSessionService()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISPATCH_COMMAND -> {
                // 必须先进入前台：本服务可能是被 startForegroundService 拉起的，
                // 5 秒内不调用 startForeground 会触发
                // ForegroundServiceDidNotStartInTimeException 直接崩溃。
                promoteToForeground()
                PlayerCommandIntent.read(intent)?.let { registry.dispatch(it) }
            }

            ACTION_START -> promoteToForeground()

            ACTION_STOP -> {
                demoteFromForeground()
                stopSelf()
            }

            else -> {
                // 系统重启服务（intent == null）或未知 action：进程此刻没有可保活的播放状态，
                // 留着只会产生一条无意义的常驻通知。
                // 与 lite 的 START_STICKY 不同：lite 需要服务活着以维持后台 FlutterEngine，
                // native 的播放状态全在本进程内，进程若已被回收则没有任何东西可保。
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        unbindSessionService()
        demoteFromForeground()
        super.onDestroy()
    }

    private fun bindSessionService() {
        try {
            val intent = Intent(this, Md3MediaSessionService::class.java)
                .setAction(MediaSessionService.SERVICE_INTERFACE)
            sessionServiceBound = bindService(intent, sessionServiceConnection, Context.BIND_AUTO_CREATE)
        } catch (e: Exception) {
            Log.w(TAG, "绑定会话承载服务失败：${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun unbindSessionService() {
        if (!sessionServiceBound) return
        sessionServiceBound = false
        try {
            unbindService(sessionServiceConnection)
        } catch (e: Exception) {
            Log.w(TAG, "解绑会话承载服务失败：${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * 进入前台。
     *
     * **每次调用都会真实执行 `startForeground`**，而不是"已在前台就跳过"：
     * `ActiveServices.startServiceLocked` 在 `fgRequired` 从 false 变为 true 时会重新挂上
     * 5 秒的 `serviceForegroundTimeout`。若第二次 `startForegroundService` 之后我们因为
     * `promoted == true` 而提前 return，超时就会触发
     * `ForegroundServiceDidNotStartInTimeException` —— 表现为"连按两次耳机键闪退"。
     * 重复调用 `startForeground` 本身是幂等的（仅替换通知），代价可忽略。
     *
     * 异常处理与 lite `startForegroundDetached`（`:854-879`）一致：前台启动被系统拒绝
     * （`ForegroundServiceStartNotAllowedException`，例如导航类 App 夺走焦点后本 App 转后台）
     * 必须被吞掉，否则会以两种方式崩溃——本次 `startForeground` 直接抛异常，
     * 或 `startForegroundService` 已拉起服务但未成功进入前台，5 秒后触发
     * `RemoteServiceException("did not call startForeground")`。
     * 但**仅当尚未成功进入过前台时才自停**：若服务本就正常在前台跑（本次只是通知刷新被拒），
     * 自停会把一个合法的前台服务杀掉，反而丢掉保活。native 的播放由会话服务承载，
     * 因此自停不影响播放。
     */
    private fun promoteToForeground() {
        try {
            ServiceCompat.startForeground(
                this,
                PlaybackNotificationChannels.KEEPALIVE_NOTIFICATION_ID,
                buildKeepAliveNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
            promoted = true
        } catch (e: Throwable) {
            Log.w(TAG, "进入前台被拒绝：${e.javaClass.simpleName}: ${e.message}")
            if (!promoted) {
                try {
                    stopSelf()
                } catch (_: Throwable) {
                    // 自停失败也不能让异常逃逸到 AMS
                }
            }
        }
    }

    /**
     * 构建（并缓存）保活通知。
     *
     * 缓存理由：媒体键/唤醒路径会在短时间内多次触发 `promoteToForeground`，
     * 而通知内容恒定，重建纯属浪费。
     */
    private fun buildKeepAliveNotification(): android.app.Notification {
        cachedNotification?.let { return it }
        val notification = NotificationCompat.Builder(this, PlaybackNotificationChannels.KEEPALIVE_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle("")
            .setContentText(getString(R.string.keepalive_notification_text))
            .setContentIntent(launchPendingIntent())
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setSilent(true)
            .build()
        cachedNotification = notification
        return notification
    }

    private fun demoteFromForeground() {
        if (!promoted) return
        promoted = false
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.w(TAG, "撤下保活通知失败：${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * 点击保活通知回到 App 的 PendingIntent。
     *
     * 缓存复用（lite `:586-598` 同一取舍）：蓝牙歌词/元数据高频刷新时，每帧重建
     * PendingIntent 会带来可观的 Binder 开销，而本服务可能在播放全程反复刷新通知。
     */
    private fun launchPendingIntent(): PendingIntent? {
        cachedLaunchIntent?.let { return it }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        ).also { cachedLaunchIntent = it }
    }
}
