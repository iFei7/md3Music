package com.gracemusic.player.session

/**
 * 播放域对系统层的唯一接缝。
 *
 * 「系统层」= `MediaSession.Callback`、`MediaButtonReceiver`、now-playing 通知按钮、
 * 桌面小组件、蓝牙/车机控制端、DLNA 控制端。它们一律只认 [PlayerCommand]，
 * 通过本接口把意图交给播放域，绝不直接触碰 `ExoPlayer` / `PlaybackStore`。
 *
 * 为什么必须是接口而不是直接依赖播放域：
 * 1. **冷启动顺序**：系统组件可能先于播放域被拉起（耳机唤醒被杀进程），此时无法构造播放域；
 * 2. **可测性**：`Md3MediaSessionCallback` 等系统组件的单测可以注入假实现，不需要真 ExoPlayer；
 * 3. **单一事实来源**：切歌/暂停的"谁说了算"必须只有播放域一个答案（lite 的教训是
 *    Dart 侧与 media3 时间线各有一套队列，导致媒体卡片"上一首"变成"从头重播当前曲"）。
 *
 * 刻意声明为普通 `interface` 而非 `fun interface`：实现方是播放域的单例对象，
 * `PlaybackSessionRegistry.detach` 依赖实例身份比较，允许随手传 lambda 会埋下
 * "detach 不掉"的隐患。
 */
interface PlaybackSessionBridge {

    /**
     * 投递一条外部命令。
     *
     * @return `true` = 播放域已受理（不保证必然产生状态变化，例如无曲目时的 `Next` 是合法空操作）；
     *         `false` = 播放域尚未就绪（正在恢复上次队列），调用方应交给
     *         [PlaybackSessionRegistry] 暂存并稍后重放。
     */
    fun dispatch(command: PlayerCommand): Boolean
}

/** [PlaybackSessionRegistry.dispatch] 的结果。 */
enum class DispatchOutcome {
    /** 播放域已就绪并受理，命令已生效。 */
    DISPATCHED,

    /** 播放域尚未就绪，命令已暂存，待其就绪后按序重放。 */
    BUFFERED,
}
