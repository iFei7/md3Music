package com.gracemusic.core.ui

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 玻璃 Dock 的默认高度 72dp。
 *
 * 对位 lite `lib/app.dart:623` 的 `_kDockReservedBottom = 72.0`：
 * Dock 内容高 52 + 底部留白 12 = 64，取 72 留 8dp 呼吸余量。被 Dock 覆盖的
 * 内容需要底部避让（台本 §1 红线 5：Dock 避让 72dp 条件注入）。
 */
val DockHeight: Dp = 72.dp

/**
 * Dock 底部避让量计算（纯函数，JVM 可测）。
 *
 * 注入值 = navigationBars 系统手势条 +（Dock 可见时）Dock 专属高度，
 * 与 lite `app.dart:1180-1189` 的 MediaQuery 底部 padding 注入语义一致：
 * 内容延伸到 Dock 后面（悬浮感），滚动末尾靠该 padding 让位。
 *
 * @param navigationBarsBottom 系统导航栏（手势条）insets 的底部高度
 * @param dockVisible Dock 是否可见（可见才叠加 [dockHeight]）
 * @param dockHeight Dock 高度（默认 [DockHeight] = 72dp）
 */
internal fun dockAvoidanceBottom(
    navigationBarsBottom: Dp,
    dockVisible: Boolean,
    dockHeight: Dp = DockHeight,
): Dp = if (dockVisible) navigationBarsBottom + dockHeight else navigationBarsBottom

/**
 * Dock 避让注入（P3-A 落地，替代 P0-C 的无条件 72dp 版本）。
 *
 * 对位 lite `BottomChromeScope`（responsive_layout.dart）+ `app.dart:1180-1189`：
 * 仅在 [visible] = true 时于系统 navigationBars insets 之上叠加 [dockHeight]；
 * false 时仅保留系统 insets（页面无 Dock 覆盖，如 FullPlayer 全屏态）。
 *
 * 用法：`Modifier.dockPadding(visible = true)`——由主壳（MainScaffold）对
 * Dock 可见的 tab 内容统一注入；滚动容器的底部 padding 消费该值。
 */
fun Modifier.dockPadding(
    visible: Boolean,
    dockHeight: Dp = DockHeight,
): Modifier = composed {
    val navigationBarsBottom: Dp = WindowInsets.navigationBars
        .asPaddingValues()
        .calculateBottomPadding()
    padding(bottom = dockAvoidanceBottom(navigationBarsBottom, visible, dockHeight))
}
