package com.md3music.md3music.player.session

import android.app.PendingIntent
import android.content.Intent
import android.os.IBinder
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.md3music.md3music.R
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * 媒体3 会话承载服务：把 App 的播放引擎挂进一个 `MediaSession`，
 * 由 media3 的 `MediaNotificationManager` + `DefaultMediaNotificationProvider`
 * 生成系统 now-playing 通知（通知栏可见、可控制播放、锁屏可见、蓝牙/车机可读）。
 *
 * 1:1 移植 lite `MD3MusicMediaSessionService.kt`，仅做两处结构性调整：
 * 1. 会话由**本服务**创建（而不是像 fork 那样在 `AudioPlayer.java` 里先建好再
 *    `addSession` 进来）。原因：fork 的写法是被 Flutter 插件层架构逼出来的——
 *    它的 `AudioPlayer` 生命周期独立于服务，且需要在多实例（主/辅播放器）之间
 *    转移活跃会话。native 的播放引擎是 Hilt 单例、生命周期长于服务，因此采用
 *    media3 官方推荐的"服务内建会话"写法：**播放器在服务之外，会话在服务之内**。
 *    服务被销毁重建时，播放器（因此播放状态）不受影响，`onGetSession` 返回新会话，
 *    SystemUI 会重连。
 * 2. 不再需要 fork 的 `setMediaSessionServiceHost` / `ensureActiveSessionHosted` /
 *    `syncSingleSessionToHost` 那一整套静态注册与活跃会话收敛逻辑——
 *    那套逻辑是为了在**多个** fork 播放器实例之间只暴露一个会话
 *    （`AudioPlayer.java:1252-1350`）。native 每个角色一个固定引擎、一个会话，
 *    由服务持有，天然不会出现"系统会话栈里残留旧歌会话"的问题。
 *
 * 保留的关键行为（都与系统集成的坑一一对应）：
 * - `setMediaNotificationProvider` 必须在 `onCreate` 内、`super.onCreate()` **之前**
 *   调用（lite 注释标明为 fork 源码 `MediaSessionService:594` 的约束；本工程同样在
 *   vendored 源码 `MediaSessionService.java:599` 处标注"should be called before
 *   onCreate() returns"）；
 * - 通知小图标统一为 `ic_launcher_monochrome`（装饰器见 [Md3NotificationProvider]）；
 * - `onBind` 把 vivo 原子随身听的私有 action 重映射到 legacy
 *   `android.media.browse.MediaBrowserService` 路径。
 *
 * 注意 `MediaSession` 的 sessionActivity 使用 App 的 launcher intent：
 * 点击通知卡片回到 App。`FLAG_IMMUTABLE` 是 Android 12+ 的硬性要求
 * （不带可变性标志的 PendingIntent 会直接抛异常）。
 */
@OptIn(UnstableApi::class)
@AndroidEntryPoint
class Md3MediaSessionService : MediaSessionService() {

    companion object {
        private const val TAG = "Md3MediaSessionService"

        /**
         * 会话 id。
         *
         * 必须是进程内唯一的非空字符串：fork 的注释指出空串 id 会被 media3 的
         * `SESSION_ID_TO_SESSION_MAP` 判为重复而 `checkArgument` 失败
         * （`AudioPlayer.java:1130-1131`）。
         */
        const val SESSION_ID = "md3music-native"

        /**
         * vivo / iQOO「原子随身听」绑定本服务时使用的私有 action。
         *
         * 与 lite 逐字一致（`MD3MusicMediaSessionService.kt:79`）。
         */
        const val VIVO_ATOMIC_SERVICE_ACTION = "com.vivo.musicwidgetmix.support.service"

        /**
         * 重映射目标：legacy MediaBrowserService 的接口 action。
         *
         * 取 `android.media.browse.MediaBrowserService`（框架常量，非 support 库版本）：
         * `MediaSessionService.onBind` 只认 `SERVICE_INTERFACE` 与
         * `MediaBrowserServiceCompat.SERVICE_INTERFACE` 两个 action
         * （vendored 源码 `MediaSessionService.java:378-405`），
         * 其余的落在 `default: return null`。原子随身听用 vivo 私有 action 绑定，
         * 若不走这条重映射就会拿到 null binder → 绑定失败 → 无歌词/无封面/无进度条。
         */
        const val LEGACY_BROWSER_SERVICE_ACTION = "android.media.browse.MediaBrowserService"
    }

    @Inject
    lateinit var callback: Md3MediaSessionCallback

    @Inject
    lateinit var player: Player

    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        // 必须在 super.onCreate() 之前设置：见类注释。
        setMediaNotificationProvider(
            Md3NotificationProvider(
                DefaultMediaNotificationProvider.Builder(applicationContext).build(),
                R.drawable.ic_launcher_monochrome,
            ),
        )
        super.onCreate()
        // Hilt 在此处（super.onCreate() 链）完成字段注入，因此上面不能提前使用 callback/engine。
        ensureSession()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        // 未初始化（引擎构建失败等）时返回 null 拒绝连接，而不是抛异常——
        // 系统侧会表现为"通知栏无播放控制"，比进程崩溃可诊断得多。
        return ensureSession()
    }

    override fun onBind(intent: Intent?): IBinder? {
        if (intent?.action == VIVO_ATOMIC_SERVICE_ACTION) {
            return super.onBind(Intent(LEGACY_BROWSER_SERVICE_ACTION))
        }
        return super.onBind(intent)
    }

    override fun onDestroy() {
        mediaSession?.let {
            mediaSession = null
            try {
                it.release()
            } catch (e: Exception) {
                Log.w(TAG, "释放会话失败：${e.javaClass.simpleName}: ${e.message}")
            }
        }
        super.onDestroy()
    }

    /**
     * 惰性创建并承载会话。
     *
     * 惰性而非在 `onCreate` 里直接建：`onGetSession` 会在**媒体键唤醒**等场景被调用，
     * 此时服务可能是刚被拉起、`onCreate` 与 `onBind`/`onStartCommand` 交错到达；
     * 统一收敛到本方法可以保证"会话最多建一次"。
     */
    private fun ensureSession(): MediaSession? {
        mediaSession?.let { return it }
        val session = try {
            val builder = MediaSession.Builder(this, player)
                .setId(SESSION_ID)
                .setCallback(callback)
            packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
                builder.setSessionActivity(
                    PendingIntent.getActivity(
                        this,
                        0,
                        launch,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
            builder.build()
        } catch (e: Exception) {
            Log.e(TAG, "构建媒体3会话失败：${e.javaClass.simpleName}: ${e.message}")
            return null
        }
        mediaSession = session
        Log.i(TAG, "媒体3会话已就绪 id=$SESSION_ID")
        return session
    }
}
