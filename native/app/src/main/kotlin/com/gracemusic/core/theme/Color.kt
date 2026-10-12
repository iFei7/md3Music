package com.gracemusic.core.theme

import androidx.compose.ui.graphics.Color

/**
 * 种子色链工具位。
 *
 * 对应 Flutter 端：
 * - `lib/core/theme/app_theme.dart`：8 个预设种子色（Material 3 Theme Builder key tone 40，
 *   色环顺序 蓝→紫→青→绿→黄→橙→红→粉）与 [Default] 默认种子；
 * - `lib/providers/theme_provider.dart` 的 `effectiveSeedColor` 优先级链：
 *   1. 封面动态取色（提取成功）→ 歌曲封面主色；
 *   2. 背景图莫奈取色（提取成功）→ 背景图主色；
 *   3. 系统主题色（开关开启且取到）→ 系统主色；
 *   4. 用户手动选择 → 手动色；
 *   5. 默认蓝色种子 [Default]。
 *
 * P0-C 仅落地静态种子面（预设清单 + 优先级链的文档挂点）；取色实现
 * （Palette 图片取色 / 系统 dynamic color）与 DataStore 持久化为 TODO，
 * 见 [Md3MusicTheme] 的 dynamicColor 形参与 TODO 注释。
 */
object SeedColors {

    /** 默认种子色（蓝色），未启用动态取色且未手动选择时的兜底。 */
    val Default: Color = Color(0xFF0061A4)

    /**
     * 8 个预设种子色，取自 Material 3 官方 Theme Builder 的 key tone 40。
     * 顺序：色环顺序（蓝→紫→青→绿→黄→橙→红→粉），索引 0 为默认色。
     */
    val Presets: List<Color> = listOf(
        Color(0xFF0061A4), // 蓝（默认）
        Color(0xFF6750A4), // 紫（M3 默认）
        Color(0xFF006A6A), // 青绿
        Color(0xFF386A20), // 绿
        Color(0xFF7E5700), // 黄
        Color(0xFF8C4A00), // 橙
        Color(0xFFB3261E), // 红
        Color(0xFF984061), // 粉
    )

    // TODO(P1): 接 DataStore 后落地 ThemeProvider 状态面：
    //   themeMode / useDynamicColor / useCoverSeedColor / manualSeedColor /
    //   useOledBlack / 背景图路径与模糊透明度（use_background_image 等键）。
    // TODO(P1): 封面取色 seed 链：Palette.from(coverBitmap).maximumColorCount(...) 取主色
    //   后走 tonalSpot 生成 ColorScheme（低版本动态取色降级路径，API 31 以下唯一动态源）。
    // TODO(P1): 背景图莫奈取色：同封面取色，seed 注入优先级见类注释第 2 级。
}
