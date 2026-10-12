package com.gracemusic.player.session

import javax.inject.Inject
import javax.inject.Singleton

/**
 * 播放域与系统层之间的**进程内注册点**。
 *
 * 职责极窄，只有一件事：把系统层投递的命令送到当前就绪的 [PlaybackSessionBridge]；
 * 播放域尚未就绪（冷启动恢复中）时经 [pending] 暂存，就绪后按序重放。
 *
 * 为什么是一个 @Singleton 注册点而不是让系统组件各自持有播放域：
 * 系统组件由 AMS 按需实例化（服务可能被销毁重建、广播接收器每次收到按键都会新建），
 * 它们的生命周期与播放域**无关**。注册点是二者之间唯一稳定的交点，
 * 且因为是进程内单例，服务重建不会丢桥。
 *
 * 线程模型：播放域在**主线程**完成注册（`attach` 在恢复队列后调用），
 * 命令入口 `MediaButtonReceiver.onReceive` / `Service.onStartCommand` 也都在主线程。
 * 缓冲内部另有同步保护，因此从其他线程调用 `dispatch` 也安全。
 */
@Singleton
class PlaybackSessionRegistry @Inject constructor() {

    /**
     * 待执行命令缓冲。
     *
     * 只在"播放域未就绪"窗口使用，因此容量极小（[PendingCommandBuffer.DEFAULT_CAPACITY]）。
     */
    private val pending = PendingCommandBuffer()

    /**
     * 当前就绪的桥。
     *
     * `@Volatile`：`attach` 可能发生在主线程，而 `dispatch` 可能来自 `RemoteViews`
     * 点击产生的服务启动（同样是主线程，但缓冲的 `drainTo` 会从持有锁的线程读它）。
     * 用 `@Volatile` 保证可见性，不引入额外的锁开销。
     */
    @Volatile
    private var bridge: PlaybackSessionBridge? = null

    /** 播放域是否已就绪。 */
    val isReady: Boolean get() = bridge != null

    /** 当前待执行命令条数（诊断/测试用）。 */
    val pendingCount: Int get() = pending.size

    /**
     * 播放域就绪后注册桥，并立即按序重放缓冲命令。
     *
     * 必须在**恢复完上次队列之后**调用——提前注册会让重放的 `Play` 落在一个空队列上，
     * 用户按下耳机键却听不到任何声音。
     *
     * @return 本次成功重放的命令条数。
     */
    fun attach(bridge: PlaybackSessionBridge): Int {
        this.bridge = bridge
        return replayPending()
    }

    /**
     * 注销桥（实例身份匹配）。播放域销毁时调用。
     *
     * 若缓冲中仍有命令，**刻意保留**：桥注销只意味着"暂时没有能给命令的人"，
     * 下一次 `attach` 会连同旧命令一起重放。这与 `clear()` 的语义区分开。
     */
    fun detach(bridge: PlaybackSessionBridge) {
        if (this.bridge === bridge) this.bridge = null
    }

    /**
     * 投递命令。已就绪则直投，未就绪则暂存。
     *
     * 注意 `bridge` 存在但返回 `false` 的情况（播放域收到命令时仍在恢复中）也走暂存路径——
     * 因此 `attach` 之后仍需调用一次 [replayPending] 才是完整闭环。
     */
    fun dispatch(command: PlayerCommand): DispatchOutcome {
        val target = bridge
        if (target != null && target.dispatch(command)) return DispatchOutcome.DISPATCHED
        pending.offer(command)
        return DispatchOutcome.BUFFERED
    }

    /**
     * 按 FIFO 顺序重放缓冲命令，遇到拒收即停止（剩余命令保持原序留待下次）。
     *
     * @return 本次成功投递的条数。
     */
    fun replayPending(): Int {
        val target = bridge ?: return 0
        return pending.drainTo { target.dispatch(it) }
    }

    /** 丢弃全部缓冲命令。仅用于"确定不再需要"的场景（例如用户显式退出播放）。 */
    fun clearPending() {
        pending.clear()
    }
}
