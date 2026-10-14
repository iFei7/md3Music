package com.gracemusic.player.store

import android.content.Context
import com.gracemusic.player.session.PlaybackKeepAliveService
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject

/**
 * 播放保活控制器（台本 §3.6「保活」条的接口面）。
 *
 * 存在的唯一理由是把「什么时候该保活」的决策者（[PlaybackStore]，经
 * [com.gracemusic.player.store.PlaybackEffect.StartKeepAlive] /
 * [StopKeepAlive] 效果与事件对账两条路驱动）与「怎么保活」的实现
 * （[PlaybackKeepAliveService] 前台服务）解耦：
 * - Store 单测用假实现即可断言启停序列，不需要 Robolectric 拉真服务；
 * - 实现类只做转发，不自带任何策略（服务的 KDoc 明确「刻意不自作主张」）。
 *
 * 线程模型：实现方的方法会在**应用主线程**被调用（Store 的全部派发与
 * 效果执行在主线程串行完成）；服务侧的 start/stop 内部已吞掉系统拒绝异常。
 */
interface PlaybackKeepAlive {

    /** 请求进入保活前台（播放会话开始）。幂等。 */
    fun start()

    /** 请求撤下保活通知并结束服务（播放会话结束）。幂等。 */
    fun stop()
}

/**
 * [PlaybackKeepAlive] 的 Android 实现：转发 [PlaybackKeepAliveService] 的
 * 伴生入口（start(context) / stop(context)）。
 *
 * 刻意不含任何状态判断：服务生命周期由播放域决定，本类只是「控制器接口 →
 * 服务静态入口」的一跳转发。异常处理同样不在这里——服务的
 * `startCompat` / `stop` 已各自捕获并降级为日志（前台启动被 ROM 拒绝
 * 不能崩溃，见服务 KDoc）。
 */
class AndroidPlaybackKeepAlive @Inject constructor(
    @ApplicationContext private val context: Context,
) : PlaybackKeepAlive {

    override fun start() {
        PlaybackKeepAliveService.start(context)
    }

    override fun stop() {
        PlaybackKeepAliveService.stop(context)
    }
}
