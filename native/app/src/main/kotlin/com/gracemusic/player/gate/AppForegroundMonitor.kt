package com.gracemusic.player.gate

/**
 * 应用前后台变化监听器（系统事实）。
 *
 * @see AppForegroundMonitor
 */
fun interface AppForegroundListener {
    /**
     * @param backgrounded `true` = 应用整体进入后台（所有 Activity 都不可见）；
     *   `false` = 回到前台。
     */
    fun onForegroundChanged(backgrounded: Boolean)
}

/**
 * 应用前后台信号源端口（T-P1-08 B4）。
 *
 * ## 为什么需要「统一信号源」而不是各页面自采
 * Dart 侧 `PlayerProvider._isAppBackgrounded`（`player_provider.dart:352`）
 * 由 `WidgetsBindingObserver` 的 `AppLifecycleState` 驱动——**一处**采集、
 * 一处消费。native 若让每个页面各自注册 `ActivityLifecycleCallbacks`，
 * 会得到多个互相矛盾的「后台」判定（多 Activity / 分屏 / 画中画下
 * 「当前 Activity 是否可见」与「应用是否在后台」并不等价）。
 * 本端口强制收敛到**一个**生产者。
 *
 * ## 不得与 Service 生命周期或音频焦点混同（硬约束）
 * 应用回到前台 **不等于**：
 * - 播放前台服务被系统重建（Service 生命周期独立于 Activity 可见性）；
 * - 音频焦点被重新持有（焦点由 Media3 `AudioFocusManager` 唯一持有，
 *   见 [AudioFocusEventSource]）。
 * 因此本信号**只能**用于「应用可见性」相关决策，**不得**驱动播放/暂停/重试。
 * 具体地：`PlaybackStore` 收到 [com.gracemusic.player.state.PlaybackEvent.AppForegroundChanged]
 * 后**不再**触发 `RecoveryOrchestrator.onExternalRecoveryTrigger()`
 * （R-4 复核结论，见 `docs/native/phase-5-audio-focus.md` §R-4）。
 */
interface AppForegroundMonitor {

    /** 开始观测并回调；重复调用幂等（同一 [listener] 不重复注册）。 */
    fun start(listener: AppForegroundListener)

    /** 停止观测并释放观察者。 */
    fun stop()
}

/**
 * 空实现（不观测、不回调）。
 *
 * **用途仅限测试与降级**：语义等价于「本装配不接前后台信号」。
 * 生产 DI 必须绑定 `ProcessLifecycleAppForegroundMonitor`。
 */
object NoOpAppForegroundMonitor : AppForegroundMonitor {
    override fun start(listener: AppForegroundListener) = Unit
    override fun stop() = Unit
}
