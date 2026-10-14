package com.gracemusic.ui.dock

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos

/**
 * 播放侧共享帧驱动（lite `lib/core/services/player_frame_driver.dart` 的
 * Compose 等价物，语义逐条对齐）。
 *
 * **为什么需要它**（lite :5-14 实测教训）：marquee、（未来）频谱/歌词等
 * 60fps 驱动若各自独立起帧，启动时刻随机、相位错开，帧提交交错会让整页
 * 帧率翻倍；把所有 60fps 需求挂到同一节拍上，更新率不变、无视觉降级。
 *
 * **订阅计数语义**（lite :16-55）：首个订阅者到来时启动节拍，最后一个
 * 订阅者离开时停掉（不留空转）；回调内可能增删订阅，分发时对订阅者列表
 * 取快照迭代并跳过已移除项（lite `_onTick` :46-54 的防御）。
 *
 * **为什么用 `withFrameNanos` 而非 `delay(16)`**：`delay` 与 vsync 不同步，
 * 累积漂移且错帧；`withFrameNanos` 由 Choreographer 帧回调驱动，每帧步进
 * 用真实帧间隔计算，无漂移（红线：禁 delay(16) 模拟帧驱动）。
 */
class PlayerFrameDriver internal constructor() {

    /** 订阅者回调：参数为本帧与上一帧的真实间隔（毫秒，恒为正）。 */
    private val listeners = ArrayList<(dtMillis: Float) -> Unit>()

    /**
     * 是否已有订阅者（诊断 / 驱动启停状态）。读取于 composition——
     * [rememberPlayerFrameDriver] 据此在首个订阅时装配 `withFrameNanos` 循环、
     * 末个取消时让循环随组合离开而终止。
     */
    var isRunning: Boolean by mutableStateOf(false)
        private set

    /**
     * 订阅共享节拍；同一回调重复订阅是 no-op（lite :31-35 防御）。
     * @return 订阅句柄，[Subscription.dispose] 取消；末个取消即停节拍。
     */
    fun subscribe(listener: (dtMillis: Float) -> Unit): Subscription {
        if (listeners.contains(listener)) return Subscription { }
        listeners.add(listener)
        isRunning = true
        return Subscription {
            listeners.remove(listener)
            isRunning = listeners.isNotEmpty()
        }
    }

    /** 分发一帧：快照迭代，跳过分发途中已取消的订阅（lite :46-54 防御）。 */
    internal fun dispatch(dtMillis: Float) {
        val snapshot = ArrayList(listeners)
        for (listener in snapshot) {
            if (listeners.contains(listener)) listener(dtMillis)
        }
    }
}

/** 一次共享节拍的订阅句柄。 */
fun interface Subscription {
    /** 取消订阅；最后一个订阅者离开时帧循环随之停止。 */
    fun dispose()
}

/**
 * 取组合内共享的 [PlayerFrameDriver]。
 *
 * 驱动的帧循环仅在「存在订阅者」时装配（`isRunning` 状态读取于本组合）：
 * 首个订阅把 `isRunning` 置 true → 本函数重组 → `LaunchedEffect` 进入组合，
 * `withFrameNanos` 无限循环开始；末个取消把 `isRunning` 置 false → effect
 * 离开组合，协程取消、循环终止。单节拍多订阅共享，无空转。
 */
@Composable
public fun rememberPlayerFrameDriver(): PlayerFrameDriver {
    val driver: PlayerFrameDriver = remember { PlayerFrameDriver() }
    if (driver.isRunning) {
        LaunchedEffect(driver) {
            var lastFrameTimeNanos = 0L
            while (true) {
                withFrameNanos { frameTimeNanos ->
                    if (lastFrameTimeNanos != 0L) {
                        driver.dispatch((frameTimeNanos - lastFrameTimeNanos) / 1_000_000f)
                    }
                    lastFrameTimeNanos = frameTimeNanos
                }
            }
        }
    }
    return driver
}
