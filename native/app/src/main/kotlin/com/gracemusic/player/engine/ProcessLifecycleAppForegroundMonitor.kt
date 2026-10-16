package com.gracemusic.player.engine

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.gracemusic.player.gate.AppForegroundListener
import com.gracemusic.player.gate.AppForegroundMonitor
import javax.inject.Inject
import javax.inject.Singleton

/**
 * [AppForegroundMonitor] 的生产实现：`ProcessLifecycleOwner` 应用级生命周期。
 *
 * ## 为什么是 ProcessLifecycleOwner（而不是 ActivityLifecycleCallbacks）
 * `ProcessLifecycleOwner` 是 AndroidX 官方给出的**应用级**前后台信号：
 * 它把所有 Activity 的生命周期聚合成一个「进程可见性」状态，
 * 且**刻意**对 `onStop` 加了约 700ms 延迟
 * （`ProcessLifecycleOwner` 源码 `TIMEOUT_MS`），用于吸收旋转/多窗口等
 * 配置变化造成的瞬时 stop-start 抖动——这正是「不得在每个页面各自维护
 * 一份前后台状态」所要求的统一信号源。
 *
 * 直接用 `ActivityLifecycleCallbacks` 统计活跃 Activity 计数会：
 * 1. 在配置变化时误报一次「进入后台」（触发无意义的播放策略重算）；
 * 2. 无法正确处理多 Activity / 分屏（计数为 0 的判定时机与进程可见性不同步）。
 *
 * ## 映射（1:1）
 * | 生命周期 | [AppForegroundListener.onForegroundChanged] |
 * |---|---|
 * | `onStart` | `backgrounded = false`（回到前台） |
 * | `onStop` | `backgrounded = true`（进入后台） |
 *
 * 与 Dart `WidgetsBindingObserver.didChangeAppLifecycleState` 的
 * `resumed` / `paused` 映射同构（`player_provider.dart:352` 的
 * `_isAppBackgrounded`）。
 *
 * ## 硬约束（见 [AppForegroundMonitor] KDoc）
 * 本信号**不得**驱动播放/暂停/重试。`PlaybackStore` 只把它写进
 * `PlaybackState.isAppBackgrounded`（事实），**不**再触发恢复链
 * （R-4 复核结论：移除 `onExternalRecoveryTrigger` 连线）。
 *
 * ## 线程
 * `ProcessLifecycleOwner.get()` 必须在主线程首次访问（内部注册
 * `ContentProvider` 的初始化在 `Application.onCreate` 完成）；
 * 生命周期回调同样在主线程。`PlaybackStore` 是 `@MainThread` 单例，
 * 故 [start] / [stop] 恒在主线程调用。
 *
 * ## 生命周期
 * [start] 幂等（同一 listener 重复调用不重复注册）；[stop] 摘除观察者并清引用。
 * 进程级单例，不随 UI 重建。
 */
@Singleton
class ProcessLifecycleAppForegroundMonitor @Inject constructor() : AppForegroundMonitor {

    /** 当前订阅者（null = 未订阅）。 */
    private var listener: AppForegroundListener? = null

    private val observer = object : DefaultLifecycleObserver {
        override fun onStart(owner: LifecycleOwner) {
            listener?.onForegroundChanged(backgrounded = false)
        }

        override fun onStop(owner: LifecycleOwner) {
            listener?.onForegroundChanged(backgrounded = true)
        }
    }

    override fun start(listener: AppForegroundListener) {
        if (this.listener === listener) return
        if (this.listener != null) stop()
        this.listener = listener
        ProcessLifecycleOwner.get().lifecycle.addObserver(observer)
    }

    override fun stop() {
        ProcessLifecycleOwner.get().lifecycle.removeObserver(observer)
        listener = null
    }
}
