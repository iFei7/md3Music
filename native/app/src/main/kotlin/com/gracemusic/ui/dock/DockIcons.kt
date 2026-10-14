package com.gracemusic.ui.dock

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/**
 * Dock 内置自绘图标集（Material Symbols 公开 path 数据，Apache-2.0）。
 *
 * **偏离登记（图标来源）**：lite 直接使用 Flutter Material Icons 字体图标；
 * native 工程当前**没有 material-icons 依赖**且 P3-A2 受「无新增依赖」
 * 约束，故控制键图标与 Preview 用的 tab 样例图标以 Material Symbols 官方
 * path 数据自绘 [ImageVector]（24dp 视口逐值一致）。P3-D 设置页接线若引入
 * material-icons 依赖，可直接替换，消费方签名（[DockTab] 用 `ImageVector`）
 * 无需变化。
 *
 * tab 图标为 Preview / 骨架期样例：正式接线时由主壳传入真实图标
 * （选中/未选中两态），此处 selected 与 unselected 暂共用同一 path、
 * 仅以 tint 区分（与 lite 坍缩圆回退分支的 outlined 用法一致）。
 */
internal object DockIcons {

    /** 由 Material Symbols 的 24dp path 数据构建填充图标。 */
    private fun materialPath(name: String, pathData: String): ImageVector =
        ImageVector.Builder(
            name = name,
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply {
            addPath(
                pathData = addPathNodes(pathData),
                fill = SolidColor(Color.Black),
                fillAlpha = 1f,
                stroke = null,
                strokeAlpha = 1f,
                strokeLineWidth = 1f,
                strokeLineCap = StrokeCap.Butt,
                strokeLineJoin = StrokeJoin.Miter,
                strokeLineMiter = 4f,
                pathFillType = androidx.compose.ui.graphics.PathFillType.NonZero,
            )
        }.build()

    /** 播放（Material `play_arrow`）。 */
    internal val PlayArrow: ImageVector = materialPath(
        "PlayArrow",
        "M8 5v14l11-7z",
    )

    /** 暂停（Material `pause`）。 */
    internal val Pause: ImageVector = materialPath(
        "Pause",
        "M6 19h4V5H6v14zm8-14v14h4V5h-4z",
    )

    /** 下一曲（Material `skip_next`）。 */
    internal val SkipNext: ImageVector = materialPath(
        "SkipNext",
        "M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z",
    )

    /** 上一曲（Material `skip_previous`）。 */
    internal val SkipPrevious: ImageVector = materialPath(
        "SkipPrevious",
        "M6 6h2v12H6zm3.5 6l8.5 6V6z",
    )

    /** 音符占位（Material `music_note`；无歌 / 封面缺失时使用，lite :409-414）。 */
    internal val MusicNote: ImageVector = materialPath(
        "MusicNote",
        "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z",
    )

    /** 主页（Material `home`；tab `discover`）。 */
    internal val Home: ImageVector = materialPath(
        "Home",
        "M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z",
    )

    /** 收藏（Material `favorite`；tab `favorites`）。 */
    internal val Favorite: ImageVector = materialPath(
        "Favorite",
        "M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z",
    )

    /** 本地音乐（Material `library_music`；tab `library`）。 */
    internal val LibraryMusic: ImageVector = materialPath(
        "LibraryMusic",
        "M20 2H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-2 5h-3v5.5c0 1.38-1.12 2.5-2.5 2.5S10 13.88 10 12.5s1.12-2.5 2.5-2.5c.57 0 1.08.19 1.5.51V5h4v2zM4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6z",
    )

    /** 私人 FM（Material `radio`；tab `fm`）。 */
    internal val Radio: ImageVector = materialPath(
        "Radio",
        "M3.24 6.15C2.51 6.43 2 7.17 2 8v12c0 1.1.89 2 2 2h16c1.11 0 2-.9 2-2V8c0-1.11-.89-2-2-2H8.3l8.26-3.34L15.88 1 3.24 6.15zM7 20c-1.66 0-3-1.34-3-3s1.34-3 3-3 3 1.34 3 3-1.34 3-3 3zm13-1h-7v-2h7v2zm0-4h-7v-2h7v2zm0-4h-7V9h7v2z",
    )

    /** 搜索（Material `search`；tab `search`）。 */
    internal val Search: ImageVector = materialPath(
        "Search",
        "M15.5 14h-.79l-.28-.27C15.41 12.59 16 11.11 16 9.5 16 5.91 13.09 3 9.5 3S3 5.91 3 9.5 5.91 16 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z",
    )

    /** 听歌识曲（Material `mic`；tab `recognition`）。 */
    internal val Mic: ImageVector = materialPath(
        "Mic",
        "M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.3-3c0 3-2.54 5.1-5.3 5.1S6.7 14 6.7 11H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c3.28-.48 6-3.3 6-6.72h-1.7z",
    )

    /** 听书（Material `auto_stories`；tab `audiobook`）。 */
    internal val AutoStories: ImageVector = materialPath(
        "AutoStories",
        "M21 5c-1.11-.35-2.33-.5-3.5-.5-1.95 0-4.05.4-5.5 1.5-1.45-1.1-3.55-1.5-5.5-1.5S2.45 4.9 1 6v14.65c0 .25.25.5.5.5.1 0 .15-.05.25-.05C3.1 20.45 5.05 20 6.5 20c1.95 0 4.05.4 5.5 1.5 1.35-.85 3.8-1.5 5.5-1.5 1.65 0 3.35.3 4.75 1.05.1.05.15.05.25.05.25 0 .5-.25.5-.5V6c-.6-.45-1.25-.75-2-1zm0 13.5c-1.1-.35-2.3-.5-3.5-.5-1.7 0-4.15.65-5.5 1.5V8c1.35-.85 3.8-1.5 5.5-1.5 1.2 0 2.4.15 3.5.5v11.5z",
    )

    /** 设置（Material `settings`；tab `settings`）。 */
    internal val Settings: ImageVector = materialPath(
        "Settings",
        "M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z",
    )

    /** 我的（Material `person`；tab `user`）。 */
    internal val Person: ImageVector = materialPath(
        "Person",
        "M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z",
    )
}
