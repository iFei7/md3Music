package com.md3music.md3music.player.session

import android.os.Handler

/**
 * 媒体键多击判定窗口的状态机。
 *
 * 从 lite `MediaButtonReceiver` 的静态字段（`:36-40` 的 `clickCount` / `pendingAction`）
 * 提取为可注入的类，原因是那两个字段**只能靠真机连按复现**，无法单测：
 * 静态状态在用例间无法复位，判定时序也只能靠真实 350ms 等待。
 * 提取后 [MediaButtonClickTrackerTest] 可用 Robolectric 的虚拟时钟把
 * "单击/双击/三击/四击/两次独立单击"逐格断言。
 *
 * ### 只允许在主线程使用
 *
 * [handler] 必须是主线程的 Handler：多击窗口的语义是"同一物理按键在 350ms 内的连续动作"，
 * 而媒体键广播的 `onReceive` 本身就在主线程。不引入同步是刻意的——
 * 加锁只会掩盖"从子线程调用"这一真正的编程错误。
 *
 * ### 为什么第一击立即下发
 *
 * 见 [MediaButtonPolicy.immediateCommand]：单击场景必须在 Android 12+ 允许的窗口内
 * 启动前台服务，等 350ms 再决定就会错过窗口。因此双击的可观测行为是
 * "先播放当前曲，再切下一首"——这是 lite 已验证的产品行为。
 *
 * ### 为什么 sink 是逐次传入而不是构造期固定
 *
 * 回调在所有场景下都是"把命令派发到保活服务"，但命令的实际派发需要当次广播携带的
 * `Context`（实现里取 `applicationContext`，不会泄漏）；而补发发生在**另一条广播之后**，
 * 因此回调必须跟着"触发它的那次广播"走，而不是跟着状态机走
 * （否则补发会带着第一次广播的 Context 去派发）。
 */
internal class MediaButtonClickTracker(
    private val handler: Handler,
    private val timeoutMs: Long = MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS,
) {

    private var clickCount = 0
    private var pending: Runnable? = null

    /** 当前判定窗口内累计的点击数（诊断/测试用）。 */
    val pendingClickCount: Int get() = clickCount

    /** 是否有未完成的判定窗口。 */
    val hasPendingWindow: Boolean get() = pending != null

    /**
     * 收到一次多击按键。
     *
     * @param sink 命令出口。第一击会立即用它派发 [PlayerCommand.Play]；
     *   窗口超时后若判定为双击/三击，会用它派发 [PlayerCommand.Next] / [PlayerCommand.Previous]。
     */
    fun onMultiClickKey(sink: (PlayerCommand) -> Unit) {
        clickCount++
        pending?.let { handler.removeCallbacks(it) }
        MediaButtonPolicy.immediateCommand(clickCount)?.let(sink)

        val action = Runnable {
            val count = clickCount
            clickCount = 0
            pending = null
            MediaButtonPolicy.trailingCommand(count)?.let(sink)
        }
        pending = action
        handler.postDelayed(action, timeoutMs)
    }

    /** 丢弃未完成的判定窗口并清零点击数。 */
    fun reset() {
        pending?.let { handler.removeCallbacks(it) }
        pending = null
        clickCount = 0
    }
}
