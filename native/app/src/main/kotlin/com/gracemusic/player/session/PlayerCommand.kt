package com.gracemusic.player.session

/**
 * 播放域的外部命令词表。
 *
 * 这是「系统层 → 播放域」的**单向下行**词汇：媒体键、now-playing 通知按钮、
 * 桌面小组件、蓝牙设备、DLNA 控制端把用户意图表达为 [PlayerCommand]，
 * 由 T45 的 `PlaybackStore` 翻译成内部 `PlaybackIntent`。
 *
 * 为什么不让系统层直接持有 `PlaybackStore`：
 * 1. 系统层入口（`MediaSessionService` / `BroadcastReceiver`）可能在**播放域尚未初始化**
 *    时被拉起（进程被杀后的耳机唤醒），此时只能先缓存命令、等桥接就绪再投递；
 * 2. 命令需要跨进程存活（Intent extras / MediaSession `Bundle`），因此必须有稳定字符串编码
 *    （见 [PlayerCommandCodec]）——直接传对象无法满足。
 *
 * 与 lite 的对应关系（`AudioPlaybackService.kt:791-841` 的 `handleAction` / `sendFlutterCommand`
 * 映射表）：lite 用「ACTION_* 字符串 → MethodChannel 方法名」两跳，native 收敛为一跳——
 * [PlayerCommand] 既是语义类型，也是可编码的传输单元。
 */
sealed interface PlayerCommand {

    /** 开始/继续播放（耳机单击、通知播放键、唤醒播放）。 */
    data object Play : PlayerCommand

    /** 暂停（保留会话与队列，可恢复）。 */
    data object Pause : PlayerCommand

    /** 播放/暂停二态切换（通知主键、媒体键 PLAY_PAUSE）。 */
    data object TogglePlayPause : PlayerCommand

    /** 下一首（由播放域的队列逻辑决定"下一首"是谁，不由 media3 时间线决定）。 */
    data object Next : PlayerCommand

    /** 上一首。 */
    data object Previous : PlayerCommand

    /** 停止播放并释放前台服务（通知 STOP 按钮、退出播放）。 */
    data object Stop : PlayerCommand

    /** 切换当前曲目的收藏状态（now-playing 通知自定义按钮）。 */
    data object ToggleFavorite : PlayerCommand

    /** 绝对跳转（毫秒，播放域负责 clamp 到 `[0, duration]`）。 */
    data class SeekTo(val positionMs: Long) : PlayerCommand

    /** 相对跳转（毫秒，正为快进）。 */
    data class SeekBy(val deltaMs: Long) : PlayerCommand

    /**
     * 设置「准备即播」标志，用于播放域内部状态同步（例如系统恢复播放时对齐
     * `Player.playWhenReady`）。不改变当前媒体项。
     */
    data class SetPlayWhenReady(val playWhenReady: Boolean) : PlayerCommand
}

/**
 * [PlayerCommand] 的稳定字符串编码。
 *
 * 编码一旦发布即视为**协议**：Intent extras、`SessionCommand.customAction`、
 * 桌面小组件的 `RemoteViews` 点击意图都会写入它。新增命令只能**追加**，不得改写既有编码
 * （否则「升级安装后旧 PendingIntent 仍指向旧编码」会静默丢命令）。
 *
 * 为什么不用 `enum`：`PlayerCommand.SeekTo` 这类带参命令需要同时承载参数，
 * 而 `Intent` extra 的键名与编码值必须是常量，所以采用「编码值 + 结构化 extra」的组合。
 */
object PlayerCommandCodec {

    /** [Play] 的编码。 */
    const val CODE_PLAY = "play"

    /** [Pause] 的编码。 */
    const val CODE_PAUSE = "pause"

    /** [TogglePlayPause] 的编码。 */
    const val CODE_TOGGLE_PLAY_PAUSE = "togglePlayPause"

    /** [Next] 的编码。 */
    const val CODE_NEXT = "next"

    /** [Previous] 的编码。 */
    const val CODE_PREVIOUS = "previous"

    /** [Stop] 的编码。 */
    const val CODE_STOP = "stop"

    /** [ToggleFavorite] 的编码。 */
    const val CODE_TOGGLE_FAVORITE = "toggleFavorite"

    /** [SeekTo] 的编码。 */
    const val CODE_SEEK_TO = "seekTo"

    /** [SeekBy] 的编码。 */
    const val CODE_SEEK_BY = "seekBy"

    /** [SetPlayWhenReady] 的编码。 */
    const val CODE_SET_PLAY_WHEN_READY = "setPlayWhenReady"

    /** 参数：跳转位置（Long，毫秒）。 */
    const val EXTRA_POSITION_MS = "positionMs"

    /** 参数：相对跳转量（Long，毫秒）。 */
    const val EXTRA_DELTA_MS = "deltaMs"

    /** 参数：准备即播标志（Boolean）。 */
    const val EXTRA_PLAY_WHEN_READY = "playWhenReady"

    /**
     * 无参命令 → 编码。
     *
     * 带参命令（[PlayerCommand.SeekTo] / [PlayerCommand.SeekBy] / [PlayerCommand.SetPlayWhenReady]）
     * 也返回各自编码，参数由调用方另行写入 extra；这样媒体键/通知的"仅编码"路径与
     * 完整传递路径共用同一张表，不会分叉。
     */
    fun encode(command: PlayerCommand): String = when (command) {
        PlayerCommand.Play -> CODE_PLAY
        PlayerCommand.Pause -> CODE_PAUSE
        PlayerCommand.TogglePlayPause -> CODE_TOGGLE_PLAY_PAUSE
        PlayerCommand.Next -> CODE_NEXT
        PlayerCommand.Previous -> CODE_PREVIOUS
        PlayerCommand.Stop -> CODE_STOP
        PlayerCommand.ToggleFavorite -> CODE_TOGGLE_FAVORITE
        is PlayerCommand.SeekTo -> CODE_SEEK_TO
        is PlayerCommand.SeekBy -> CODE_SEEK_BY
        is PlayerCommand.SetPlayWhenReady -> CODE_SET_PLAY_WHEN_READY
    }

    /**
     * 编码 → 无参命令。
     *
     * 带参命令返回 `null`：调用方必须走 `SeekTo(it.getLongExtra(...))` 的重建路径，
     * 避免"以为拿到了命令却丢了参数"（例如把 `SeekTo(120_000)` 退化成从头播放）。
     */
    fun decode(code: String?): PlayerCommand? = when (code) {
        CODE_PLAY -> PlayerCommand.Play
        CODE_PAUSE -> PlayerCommand.Pause
        CODE_TOGGLE_PLAY_PAUSE -> PlayerCommand.TogglePlayPause
        CODE_NEXT -> PlayerCommand.Next
        CODE_PREVIOUS -> PlayerCommand.Previous
        CODE_STOP -> PlayerCommand.Stop
        CODE_TOGGLE_FAVORITE -> PlayerCommand.ToggleFavorite
        else -> null
    }

    /** [decode] 是否认识这个编码（含带参命令），供调用方区分"未知命令"与"缺参命令"。 */
    fun isKnown(code: String?): Boolean = when (code) {
        CODE_PLAY, CODE_PAUSE, CODE_TOGGLE_PLAY_PAUSE,
        CODE_NEXT, CODE_PREVIOUS, CODE_STOP, CODE_TOGGLE_FAVORITE,
        CODE_SEEK_TO, CODE_SEEK_BY, CODE_SET_PLAY_WHEN_READY,
        -> true

        else -> false
    }

    /**
     * 该命令是否为「带参命令」——即仅凭编码无法完整重建，必须携带 extra。
     * 用于在写入/读取 Intent 时做一致性校验（写入端与读取端共用同一判定，避免漏写 extra）。
     */
    fun requiresExtras(command: PlayerCommand): Boolean = when (command) {
        is PlayerCommand.SeekTo, is PlayerCommand.SeekBy, is PlayerCommand.SetPlayWhenReady -> true
        else -> false
    }
}
