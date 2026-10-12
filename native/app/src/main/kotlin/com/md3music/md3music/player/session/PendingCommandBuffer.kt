package com.md3music.md3music.player.session

/**
 * 「播放域尚未就绪」窗口期的待执行命令缓冲。
 *
 * 存在的唯一理由：进程冷启动唤醒播放。耳机媒体键可以从**已被杀死**的进程拉起
 * `MediaButtonReceiver` → 启动服务 → Hilt 构建单例 → 播放域从 Room/DataStore 恢复
 * 上次队列。在恢复完成之前到达的命令无处投递，必须暂存，等播放域就绪后按序重放。
 *
 * ### 为什么是 FIFO 而不是 lite 的「只留最新」
 *
 * lite 的 `LatestMediaCommandQueue` 采用「单飞 + 只留最新」语义，其前提是 Flutter
 * MethodChannel 这个**可能暂时未注册**的异步传输层——派发线程持续重试，期间到达的新命令
 * 覆盖旧的（`AudioPlaybackService.kt:985-1006`）。native 的派发是进程内同步调用，
 * 不存在「通道未注册」这一失败模式，因此那个队列的立身之本消失了。
 *
 * 而「只留最新」在本场景下是**错误**的：双击（play→next）在恢复期内到达时，若只保留
 * next，重放时队列已恢复但当前曲目未开始播放，`next` 会把用户从"什么都没响"跳到
 * 第二首——用户听到的第一声是第二首，而他的第一击是想要播放。FIFO 按序重放
 * （play→next）才符合用户意图。
 *
 * ### 有界与丢弃策略
 *
 * 容量上限 [DEFAULT_CAPACITY]，溢出时丢弃**最旧**的一条：缓冲期只有几百毫秒，
 * 能堆到溢出说明上游在异常刷命令；此时保留最近的意图比保留最早的更贴近用户当下所求。
 * 丢弃是静默的（不抛异常、不打日志噪音），但会累计到 [droppedCount] 供诊断。
 */
class PendingCommandBuffer(
    private val capacity: Int = DEFAULT_CAPACITY,
) {
    init {
        require(capacity >= 1) { "capacity 至少为 1，实际 $capacity" }
    }

    private val queue = ArrayDeque<PlayerCommand>()
    private var dropped = 0

    /** 累计因溢出被丢弃的命令条数（诊断用）。 */
    @get:Synchronized
    val droppedCount: Int get() = dropped

    /** 当前待执行命令条数。 */
    @get:Synchronized
    val size: Int get() = queue.size

    /** 是否为空。 */
    @get:Synchronized
    val isEmpty: Boolean get() = queue.isEmpty()

    /**
     * 入队。
     *
     * @return 若发生溢出丢弃返回 `true`（调用方据此可记录一次异常），否则 `false`。
     */
    @Synchronized
    fun offer(command: PlayerCommand): Boolean {
        var evicted = false
        while (queue.size >= capacity) {
            queue.removeFirst()
            dropped++
            evicted = true
        }
        queue.addLast(command)
        return evicted
    }

    /**
     * 按 FIFO 顺序投递到 [sink]，直到队列为空或 [sink] 返回 `false`。
     *
     * 返回 `false` 的那条命令（以及其后所有命令）会被**原序放回队首**，保证下次重放不丢序、
     * 不重排。这样调用方可以简单地"投递到拒收为止"，无需自己维护游标。
     *
     * @return 本次成功投递的条数。
     */
    @Synchronized
    fun drainTo(sink: (PlayerCommand) -> Boolean): Int {
        var delivered = 0
        while (true) {
            val next = queue.removeFirstOrNull() ?: break
            if (sink(next)) {
                delivered++
                continue
            }
            // 拒收：放回队首，保持原有顺序，等待下次重放
            queue.addFirst(next)
            break
        }
        return delivered
    }

    /** 只读快照（测试与诊断用，不改变队列状态）。 */
    @Synchronized
    fun snapshot(): List<PlayerCommand> = queue.toList()

    /** 清空队列与计数。 */
    @Synchronized
    fun clear() {
        queue.clear()
        dropped = 0
    }

    companion object {
        /**
         * 默认容量。
         *
         * 取值依据：冷启动恢复窗口（Hilt 构建 + Room 读取 + Rust 服务器就绪）实测在数百毫秒级；
         * 人工按键在该窗口内不可能超过 4 次。容量再大只会掩盖上游异常，不能换来任何真实收益。
         */
        const val DEFAULT_CAPACITY = 4
    }
}
