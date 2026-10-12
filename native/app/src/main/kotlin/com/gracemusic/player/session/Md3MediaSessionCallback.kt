package com.gracemusic.player.session

import android.os.Bundle
import androidx.annotation.DrawableRes
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 项目自有的 media3 会话命令与按钮构造。
 *
 * 结构对应 lite `AudioPlayer.java:1604-1670`（阶段4「自研交互迁往媒体3」）。fork 把这部分写在
 * Flutter 插件层的 `AudioPlayer.java` 里，原生化后无处可继承，因此按 Kotlin 重实现；
 * 图标语义沿用 lite 的取舍，但**命令标识已改为 GraceMusic 自己的命名空间**（见
 * [CUSTOM_ACTION_TOGGLE_FAVORITE] 的说明），不再与 lite 逐字对齐。
 */
object Md3SessionCommands {

    /**
     * 收藏按钮的自定义命令标识。
     *
     * **协议值，定稿后不得随意修改**：该字符串进入 SystemUI 的按钮点击 → 会话命令
     * 回传链路，改它必须保证「声明可用命令」（[availableSessionCommands]）与
     * 「按钮绑定」（[buildFavoriteButton]）两侧同步，否则点击会被 media3 过滤或无法识别。
     *
     * 值取 `com.gracemusic.toggle_favorite`：沿用 lite 时代 `com.md3music.toggle_favorite`
     * 的协议形态，但把命名空间换成本应用包根 `com.gracemusic`。GraceMusic 是全新
     * applicationId（`com.gracemusic.app`）的独立应用，不存在与 lite 之间的历史会话兼容
     * 负担，命令标识理应带上自己的品牌前缀，而不必再迁就 lite 的字面值。
     */
    const val CUSTOM_ACTION_TOGGLE_FAVORITE = "com.gracemusic.toggle_favorite"

    /**
     * 注意：用 `Bundle()` 而不是 `Bundle.EMPTY`。
     * `Bundle.EMPTY` 要求 API 26+，而本项目 minSdk 为 24 —— 与 lite
     * `AudioPlayer.java:1619` 的取舍一致。
     */
    private val CMD_TOGGLE_FAVORITE = SessionCommand(CUSTOM_ACTION_TOGGLE_FAVORITE, Bundle())

    /** 会话可供 controller 使用的自定义命令集合。 */
    fun availableSessionCommands(): androidx.media3.session.SessionCommands =
        androidx.media3.session.SessionCommands.Builder()
            .add(CMD_TOGGLE_FAVORITE)
            .build()

    /** [CMD_TOGGLE_FAVORITE] 供本类内比较使用。 */
    internal fun toggleFavoriteCommand(): SessionCommand = CMD_TOGGLE_FAVORITE

    /** 判断到达的自定义命令是否为收藏切换。 */
    fun isToggleFavorite(command: SessionCommand?): Boolean =
        command != null && CUSTOM_ACTION_TOGGLE_FAVORITE == command.customAction

    /**
     * 构造通知栏的收藏按钮（图标随收藏态切换）。
     *
     * 由播放域在收藏态变化时调用并配合 `MediaSession.setCustomLayout` 生效。
     * 图标以参数注入而不是在此处引用 `R`：让本函数保持纯逻辑、可被 JVM 单测覆盖。
     */
    fun buildFavoriteButton(
        isFavorited: Boolean,
        @DrawableRes favoriteOnIconRes: Int,
        @DrawableRes favoriteOffIconRes: Int,
    ): CommandButton = CommandButton.Builder()
        .setSessionCommand(CMD_TOGGLE_FAVORITE)
        .setDisplayName("收藏")
        .setIconResId(if (isFavorited) favoriteOnIconRes else favoriteOffIconRes)
        .setEnabled(true)
        .build()
}

/**
 * 项目自有的 `MediaSession.Callback`。
 *
 * 1:1 移植 lite `AudioPlayer.java:1134-1204` 的匿名 `MediaSession.Callback`，
 * 唯一的结构性差异是用 [PlaybackSessionRegistry] 取代 fork 的静态
 * `CustomActionListener`（见下）。
 *
 * ### 三处分支的取舍
 *
 * 1. `onConnect`：必须显式声明可用自定义命令。**不声明的话，media3 会把自定义按钮
 *    从内部通知 controller 的 `customLayout` 里过滤成禁用/移除**，通知栏的收藏按钮根本不渲染
 *    （fork 阶段4 踩过的坑，注释写在 `AudioPlayer.java:1138-1140`）。
 *
 * 2. `onPlayerCommandRequest` 拦截 `SEEK_TO_NEXT/PREVIOUS` 并返回 [SessionResult.RESULT_INFO_SKIPPED]：
 *    App 的播放队列**自维护**，不依赖 media3 时间线。若放行原生 seek，
 *    media3 会驱动 ExoPlayer 在其时间线上移动，与 App 队列脱节——用户看到的现象是
 *    "点上一首却从头重播当前曲"（fork 阶段6 的实测缺陷）。
 *    返回 `RESULT_INFO_SKIPPED` 而不是 ERROR：它是 info 级结果，
 *    SystemUI 不会弹错误提示，只是静默跳过原生默认行为。
 *
 * 3. `COMMAND_PLAY_PAUSE` **不投递命令、直接返回 RESULT_SUCCESS**：
 *    - 若同时投递 `TogglePlayPause`，会与 media3 紧随其后执行的默认切换**叠加成两次切换**，
 *      净效果是"点了没反应"；
 *    - 向播放域投递 `Pause`（绝对语义）虽然幂等，但 fork 之所以这么做是为了取消 Dart 侧
 *      换源的 in-flight Future（`AudioPlayer.java:1168-1174`）——native 没有这条侧信道；
 *    - 因此播放/暂停的权威写入方就是 media3 自己，播放域通过观察 player 的
 *      `playWhenReady` 同步（这是 media3 的既定分工，不是"双写"）。
 *
 * ### 与 T45 的接口约定（重要）
 *
 * 本回调只负责"把系统意图转成 [PlayerCommand]"。通知栏的上一首/下一首按钮**是否可用**
 * 取决于 media3 时间线里 `hasNextMediaItem()/hasPreviousMediaItem()`——而把 App 队列
 * 投射到时间线是 T45（PlaybackStore 构建队列时设置 MediaItem 列表）的职责。
 * 在时间线为空时，本回调的拦截逻辑依然正确，只是系统不会渲染切歌按钮。
 */
@OptIn(UnstableApi::class)
@Singleton
class Md3MediaSessionCallback @Inject constructor(
    private val registry: PlaybackSessionRegistry,
) : MediaSession.Callback {

    override fun onConnect(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
    ): MediaSession.ConnectionResult {
        // 必须用 AcceptedResultBuilder 在默认结果上追加自定义命令，
        // 而不是 new ConnectionResult(...)：后者会丢掉 media3 默认放行的
        // 播放器命令集，导致通知/蓝牙连不上播放控制。
        val result = MediaSession.ConnectionResult.AcceptedResultBuilder(session)
            .setAvailableSessionCommands(Md3SessionCommands.availableSessionCommands())
            .build()
        return result
    }

    override fun onPlayerCommandRequest(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
        @Player.Command playerCommand: Int,
    ): Int = when (playerCommand) {
        Player.COMMAND_SEEK_TO_NEXT,
        Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
        -> {
            // App 队列自维护：拦截原生 seek，改由播放域决定"下一首是谁"
            registry.dispatch(PlayerCommand.Next)
            SessionResult.RESULT_INFO_SKIPPED
        }

        Player.COMMAND_SEEK_TO_PREVIOUS,
        Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
        -> {
            registry.dispatch(PlayerCommand.Previous)
            SessionResult.RESULT_INFO_SKIPPED
        }

        // 其余命令（含 PLAY_PAUSE）交回 media3 默认实现（等价于返回 RESULT_SUCCESS）。
        // 详见类注释第 3 条：此处刻意不投递命令，避免双重切换。
        else -> SessionResult.RESULT_SUCCESS
    }

    override fun onCustomCommand(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
        customCommand: SessionCommand,
        args: Bundle,
    ): ListenableFuture<SessionResult> {
        if (Md3SessionCommands.isToggleFavorite(customCommand)) {
            registry.dispatch(PlayerCommand.ToggleFavorite)
        }
        // 无论是否识别，都返回成功：返回 NOT_SUPPORTED 会让 SystemUI 在按钮上
        // 显示错误反馈，而"命令不认识"是版本前向兼容的正常情形（例如旧通知
        // PendingIntent 指向已下线的命令）。
        return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
    }
}
