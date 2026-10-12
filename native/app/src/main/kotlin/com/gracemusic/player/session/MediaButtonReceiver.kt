package com.gracemusic.player.session

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import androidx.annotation.VisibleForTesting

/**
 * 线控耳机 / 蓝牙媒体键接收器（「唤醒播放」的入口）。
 *
 * 当系统内没有活跃的 `MediaSession` 时（App 进程被杀、从未播放过），媒体键会以
 * `android.intent.action.MEDIA_BUTTON` 广播形式下发，**该广播可以拉起已被杀死的进程**。
 * 有活跃会话时（正常播放中/后台暂停），媒体键由系统直接送给会话（media3 的
 * `MediaSessionLegacyStub` 注册的接收器优先级更高），不会走到这里——
 * 与 lite `MediaButtonReceiver.kt:20-22` 的行为一致。
 *
 * 1:1 移植 lite `MediaButtonReceiver.kt`。两处结构性调整：
 * 1. 手势判定抽到纯函数 [MediaButtonPolicy]；多击窗口状态抽到 [MediaButtonClickTracker]
 *    （lite 把它们混在接收器的静态字段里，无法单测，见该类注释）；
 * 2. 派发目标从 `AudioPlaybackService`（Flutter 引擎承载服务）换成
 *    [PlaybackKeepAliveService]。
 *
 * ### 派发路径为什么经由 Service 而不是直接投递注册点
 *
 * 1. **进程被杀的场景必须能唤醒**：只有 `startForegroundService` 能把组件拉起并拿到前台身份
 *    （Android 12+ 明确允许"收到媒体键广播的应用"启动前台服务）。进程内直接调注册点
 *    在不存在的进程里什么也做不了；
 * 2. **单一派发路径**：命令统一由 [PlaybackKeepAliveService.onStartCommand] 读 `Intent` extra
 *    后投给 [PlaybackSessionRegistry]，避免"接收器直投 + 服务再投"造成重复派发；
 * 3. 服务的 `onStartCommand` 在主线程执行，与播放域天然串行，不需要额外同步。
 */
class MediaButtonReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MEDIA_BUTTON) return
        val event = extractKeyEvent(intent) ?: return
        // 只处理按下事件：ACTION_UP 会在同一次物理按压里再触发一次，
        // 不滤除会让多击计数翻倍（单击变双击）。
        if (event.action != KeyEvent.ACTION_DOWN) return

        val appContext = context.applicationContext
        if (MediaButtonPolicy.usesMultiClick(event.keyCode)) {
            clickTracker.onMultiClickKey { dispatch(appContext, it) }
            return
        }
        MediaButtonPolicy.directCommand(event.keyCode)?.let { dispatch(appContext, it) }
    }

    private fun dispatch(context: Context, command: PlayerCommand) {
        Log.i(TAG, "媒体键派发命令：$command")
        PlaybackKeepAliveService.startWithCommand(context, command)
    }

    private fun extractKeyEvent(intent: Intent): KeyEvent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
        }

    companion object {
        private const val TAG = "MediaButtonReceiver"

        /**
         * 多击窗口状态。
         *
         * 放 companion（静态）而不是接收器实例字段：清单声明的接收器实例由 `LoadedApk` 缓存，
         * 但这一点在不同版本/ROM 上并不稳定，而多击判定**必须**跨广播共享计数与待执行回调
         * （两次 MEDIA_BUTTON 之间可能隔一次实例重建），否则偶发地把双击识别成两次单击。
         * lite 同样用静态字段，这是刻意选择而非随手。
         *
         * `@VisibleForTesting`：单测需要在用例间复位静态窗口（否则前一个用例残留的计数
         * 会把后一个用例的单击判成双击），故放宽到 internal 而不公开。
         */
        @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
        internal val clickTracker = MediaButtonClickTracker(Handler(Looper.getMainLooper()))
    }
}
