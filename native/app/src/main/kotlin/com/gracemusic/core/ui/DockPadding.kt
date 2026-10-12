package com.gracemusic.core.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 玻璃 Dock 的默认高度 72dp。
 *
 * lite 的 Dock 是悬浮于内容之上的播放控制条（glass_dock_player.dart，
 *  morph 时长见 `Md3Motion.DockMorphDurationMillis`）；被其覆盖的内容
 * 需要底部避让。
 */
val DockHeight: Dp = 72.dp

/**
 * Dock 避让注入机制的对接口（P0-C 落地避让值本身，注入机制 P3 实现）。
 *
 * 对应 lite `BottomChromeScope`（responsive_layout.dart）的职责：底部
 * 导航栏可见时告知子树无需再为屏幕底部留白；Dock 悬浮 / 沉浸浏览时
 * body 最底部即屏幕最底部，需要防护。
 *
 * TODO(P3): 改为按「Dock 是否可见」条件注入（CompositionLocal 或
 *   ModifierLocal），仅在 Dock 悬浮时追加 72dp 底距；并叠加
 *   WindowInsets 系统栏避让（navigationBars）。
 */
fun Modifier.dockPadding(dockHeight: Dp = DockHeight): Modifier =
    this.padding(bottom = dockHeight)
