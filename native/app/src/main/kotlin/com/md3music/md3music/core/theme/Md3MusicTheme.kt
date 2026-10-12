package com.md3music.md3music.core.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/**
 * md3Music 原生版应用主题。
 *
 * 对应 Flutter 端 `lib/core/theme/app_theme.dart` 的
 * `AppTheme.lightThemeFromSeed` / `AppTheme.darkThemeFromSeed` 与
 * `lib/providers/theme_provider.dart` 的状态面：
 *
 * - **静态默认配色**：seed 色 0xFF0061A4（[SeedColors.Default]）经
 *   material_color_utilities `SchemeTonalSpot` 生成的完整 M3 配色，
 *   与 Flutter `ColorScheme.fromSeed(seedColor: 0xFF0061A4)` 逐通道一致
 *   （由 Dart 脚本按 m3e 同版算法生成，非手填近似值）；
 * - **动态取色**：API 31+ 用 `dynamicLightColorScheme` / `dynamicDarkColorScheme`
 *   取系统壁纸色，低版本回落静态 scheme；
 * - **OLED 纯黑**：dark scheme 的 surface 系列覆写为纯黑（surfaceContainerHigh/Highest
 *   保留极深灰维持卡片层级感），仅深色模式生效；
 * - **Typography**：P0-C 用 Material3 默认 Typography（仓库无字体资产，
 *   不引入自定义字体）。
 *
 * P0-C 降级项（TODO）：
 * - 主题开关（dynamicColor / oledBlack / themeMode）尚未接 DataStore，
 *   由调用方传参，默认关闭；
 * - 低版本动态取色 seed 链（封面 / 背景图 Palette 取色）未实现；
 * - Flutter 端自定义 TextTheme（emphasized 字重等）、CardTheme/AppBarTheme 等
 *   细项未移植，P3 按页面需要逐步补齐。
 */
@Composable
fun Md3MusicTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    oledBlack: Boolean = false,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme = when {
        // API 31+ 动态取色（系统壁纸色）；lite 的开关默认关闭，行为一致
        dynamicColor && supportsDynamicColor() ->
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)

        darkTheme -> Md3DarkColorScheme
        else -> Md3LightColorScheme
    }.let { scheme ->
        // OLED 纯黑仅深色模式生效（lite: darkThemeFromSeed(useOledBlack:)）
        if (darkTheme && oledBlack) scheme.withOledBlack() else scheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        // TODO(P3): 移植 Flutter 自定义 TextTheme（M3E emphasized 字重、
        //   各级字号/行高/字距）；当前用 M3 默认排版。
        typography = Typography(),
        content = content,
    )
}

/** 当前设备是否支持系统动态取色（API 31 / Android 12+）。 */
internal fun supportsDynamicColor(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

/**
 * OLED 纯黑覆写：dark scheme 的 surface 系列覆盖为 [Color.Black] / 极深灰，
 * 保留 onSurface 等前景色不变（保证对比度）。
 *
 * 移植自 Flutter `darkThemeFromSeed(useOledBlack: true)` 的 copyWith 覆写：
 * surfaceContainerLowest/Low/Container 纯黑；High/Highest 用极深灰保留
 * 卡片/底栏层级感；inverseSurface 保持不变确保 Snackbar 反色正常。
 */
internal fun ColorScheme.withOledBlack(): ColorScheme = copy(
    surface = Color.Black,
    surfaceContainerLowest = Color.Black,
    surfaceContainerLow = Color.Black,
    surfaceContainer = Color.Black,
    // High/Highest 保留极深灰，让卡片/底栏仍有微妙层级感
    surfaceContainerHigh = Color(0xFF111111),
    surfaceContainerHighest = Color(0xFF1A1A1A),
)

/**
 * 浅色静态配色：seed 0xFF0061A4 + SchemeTonalSpot。
 *
 * 由 material_color_utilities 0.13.0 按 Flutter `ColorScheme.fromSeed` 同算法
 * （`SchemeTonalSpot` + `MaterialDynamicColors`，contrastLevel 0）生成，
 * 与 lite 浅色主题逐通道一致。
 */
internal val Md3LightColorScheme: ColorScheme = lightColorScheme(
    primary = Color(0xFF36618E),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFD1E4FF),
    onPrimaryContainer = Color(0xFF1A4975),
    secondary = Color(0xFF535F70),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFD7E3F8),
    onSecondaryContainer = Color(0xFF3B4858),
    tertiary = Color(0xFF6B5778),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFF3DAFF),
    onTertiaryContainer = Color(0xFF523F5F),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF93000A),
    outline = Color(0xFF73777F),
    outlineVariant = Color(0xFFC3C6CF),
    surface = Color(0xFFF8F9FF),
    onSurface = Color(0xFF191C20),
    surfaceVariant = Color(0xFFDFE2EB),
    onSurfaceVariant = Color(0xFF43474E),
    inverseSurface = Color(0xFF2E3135),
    inverseOnSurface = Color(0xFFEFF0F7),
    inversePrimary = Color(0xFFA0CAFD),
    surfaceTint = Color(0xFF36618E),
    background = Color(0xFFF8F9FF),
    onBackground = Color(0xFF191C20),
    surfaceBright = Color(0xFFF8F9FF),
    surfaceDim = Color(0xFFD8DAE0),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF2F3FA),
    surfaceContainer = Color(0xFFECEEF4),
    surfaceContainerHigh = Color(0xFFE6E8EE),
    surfaceContainerHighest = Color(0xFFE1E2E8),
    scrim = Color(0xFF000000),
)

/**
 * 深色静态配色：seed 0xFF0061A4 + SchemeTonalSpot。
 *
 * 生成方式同 [Md3LightColorScheme]（contrastLevel 0，isDark = true），
 * 与 lite 深色主题逐通道一致。
 */
internal val Md3DarkColorScheme: ColorScheme = darkColorScheme(
    primary = Color(0xFFA0CAFD),
    onPrimary = Color(0xFF003258),
    primaryContainer = Color(0xFF1A4975),
    onPrimaryContainer = Color(0xFFD1E4FF),
    secondary = Color(0xFFBBC7DB),
    onSecondary = Color(0xFF253140),
    secondaryContainer = Color(0xFF3B4858),
    onSecondaryContainer = Color(0xFFD7E3F8),
    tertiary = Color(0xFFD7BEE4),
    onTertiary = Color(0xFF3B2948),
    tertiaryContainer = Color(0xFF523F5F),
    onTertiaryContainer = Color(0xFFF3DAFF),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    outline = Color(0xFF8D9199),
    outlineVariant = Color(0xFF43474E),
    surface = Color(0xFF111418),
    onSurface = Color(0xFFE1E2E8),
    surfaceVariant = Color(0xFF43474E),
    onSurfaceVariant = Color(0xFFC3C6CF),
    inverseSurface = Color(0xFFE1E2E8),
    inverseOnSurface = Color(0xFF2E3135),
    inversePrimary = Color(0xFF36618E),
    surfaceTint = Color(0xFFA0CAFD),
    background = Color(0xFF111418),
    onBackground = Color(0xFFE1E2E8),
    surfaceBright = Color(0xFF36393E),
    surfaceDim = Color(0xFF111418),
    surfaceContainerLowest = Color(0xFF0B0E13),
    surfaceContainerLow = Color(0xFF191C20),
    surfaceContainer = Color(0xFF1D2024),
    surfaceContainerHigh = Color(0xFF272A2F),
    surfaceContainerHighest = Color(0xFF32353A),
    scrim = Color(0xFF000000),
)
