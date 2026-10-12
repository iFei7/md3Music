package com.gracemusic.core.responsive

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalConfiguration

/**
 * 窗口尺寸分级（WindowSizeClass）。
 *
 * 移植自 `lib/core/layout/responsive_layout.dart` 的 `ScreenType` 与
 * `getScreenType` 断点定义：
 * - **Compact**：宽度 < 600dp，手机竖屏；
 * - **Medium**：600dp <= 宽度 < 900dp，小平板 / 折叠屏展开 / 手机横屏；
 * - **Expanded**：宽度 >= 900dp，大屏平板 / 桌面窗口。
 *
 * 断点语义与 lite 逐值一致：[windowSizeClassForWidth] 量的是**可用宽度**
 * （横屏手机也会越过 600dp），[isPadLayout] 量的是**最短边**
 * （只有真正的大屏设备才越过）。
 */
enum class WindowSizeClass {
    Compact,
    Medium,
    Expanded,
}

/** 断点值 600dp / 900dp（对应 lite 的 `_compactBreakpoint` / `_mediumBreakpoint`）。 */
object WindowSizeBreakpoints {
    const val Compact = 600f
    const val Medium = 900f
}

/**
 * 按可用宽度（dp）推导尺寸分级的纯函数。
 *
 * 对应 lite `getScreenType(width)`：
 * `width < 600 → Compact；width < 900 → Medium；否则 Expanded`。
 */
fun windowSizeClassForWidth(widthDp: Float): WindowSizeClass = when {
    widthDp < WindowSizeBreakpoints.Compact -> WindowSizeClass.Compact
    widthDp < WindowSizeBreakpoints.Medium -> WindowSizeClass.Medium
    else -> WindowSizeClass.Expanded
}

/**
 * 当前 WindowSizeClass 的 CompositionLocal 提供位。
 *
 * 由应用根层（`ui.Md3MusicApp`）经 [rememberWindowSizeClass] 计算后注入，
 * 页面侧 `LocalWindowSizeClass.current` 读取。默认值 Compact（未提供时
 * 按最窄布局兜底，与「先保证手机布局正确」的策略一致）。
 */
val LocalWindowSizeClass: ProvidableCompositionLocal<WindowSizeClass> =
    staticCompositionLocalOf { WindowSizeClass.Compact }

/**
 * 记住当前窗口的尺寸分级：随配置变化（旋转 / 分屏 / 折叠展开 / 多窗 resize）重算。
 *
 * 对应 lite `getScreenTypeFromContext(context)`（`MediaQuery.sizeOf(context).width`）；
 * native 侧用 `LocalConfiguration.screenWidthDp`（当前应用窗口的可用宽度，
 * 多窗模式下即窗口宽度，语义与 MediaQuery 一致）。
 */
@Composable
fun rememberWindowSizeClass(): WindowSizeClass {
    val configuration = LocalConfiguration.current
    return remember(configuration.screenWidthDp) {
        windowSizeClassForWidth(configuration.screenWidthDp.toFloat())
    }
}

/**
 * 当前是否使用 Pad（大屏）布局：分栏播放器、网格列数偏好、居中大弹窗等。
 *
 * 移植自 lite `isPadLayout` 的 [DeviceType.auto] 分支：按**有效视口最短边**判定，
 * 而不是设备物理 dp——「显示大小」调大后可用逻辑区随之变小，两边一致才不会
 * 出现「Pad 分栏挤在手机大小的视口里」。
 *
 * TODO(P1): 接设置里的手动覆盖（lite `DeviceType.phone` / `DeviceType.pad`
 *   直接服从用户选择，auto 才走本函数）。
 */
fun isPadLayout(shortestSideDp: Float): Boolean =
    shortestSideDp >= WindowSizeBreakpoints.Compact

/**
 * 双栏 Master-Detail 判定（P0-C 只做判定，完整双栏留 P3）。
 *
 * 对应 `lib/core/layout/adaptive_navigator.dart` 的 `DesktopTwoPane` 使用条件：
 * 大屏布局的 B 类 Tab（收藏 / 本地乐库等列表-详情页）才进入双栏。
 *
 * TODO(P3): 实现双栏容器（主列表 + 可拖拽分隔条 + 右侧详情面板嵌套 Navigator），
 *   以及 `DetailPaneScope` / 前进历史栈（ForwardHistory）的 Compose 对应物。
 */
fun shouldUseTwoPaneLayout(sizeClass: WindowSizeClass): Boolean =
    sizeClass == WindowSizeClass.Expanded

/**
 * 按容器**局部宽度**推导网格列数。
 *
 * 移植自 lite `gridColumnsForWidth`：分栏 / 双栏会改变可用宽度，列数必须按
 * 面板内局部宽度测量，而非全局屏幕宽度——否则窄详情/主列面板会塞进过多列。
 * 按每列目标宽度 [targetExtent]（默认 200dp，对应 `AppLayout.gridTargetExtent`）
 * 均分，结果夹在 [min]（默认 2）与 [max]（默认 6）之间。
 */
fun gridColumnsForWidth(
    widthDp: Float,
    targetExtent: Float = 200f,
    min: Int = 2,
    max: Int = 6,
): Int {
    if (widthDp <= 0f || targetExtent <= 0f) return min
    val columns = (widthDp / targetExtent).toInt()
    return columns.coerceIn(min, max)
}
