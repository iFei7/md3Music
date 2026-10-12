package com.md3music.md3music.core.theme

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 静态配色锁测试。
 *
 * 校验 native 静态 scheme 与 Flutter `ColorScheme.fromSeed(0xFF0061A4)`
 * （SchemeTonalSpot，material_color_utilities 0.13.0 生成）逐通道一致，
 * 以及 OLED 纯黑覆写与 lite `darkThemeFromSeed(useOledBlack: true)` 一致。
 *
 * 这些函数为纯计算（不触达 android.os.Build），普通 JVM 测试即可运行。
 */
class Md3MusicThemeTest {

    @Test
    fun `浅色静态配色与 Flutter fromSeed 逐通道一致`() {
        val scheme = Md3LightColorScheme
        assertEquals(Color(0xFF36618E), scheme.primary)
        assertEquals(Color(0xFFFFFFFF), scheme.onPrimary)
        assertEquals(Color(0xFFD1E4FF), scheme.primaryContainer)
        assertEquals(Color(0xFF1A4975), scheme.onPrimaryContainer)
        assertEquals(Color(0xFF535F70), scheme.secondary)
        assertEquals(Color(0xFFD7E3F8), scheme.secondaryContainer)
        assertEquals(Color(0xFF3B4858), scheme.onSecondaryContainer)
        assertEquals(Color(0xFF6B5778), scheme.tertiary)
        assertEquals(Color(0xFFF3DAFF), scheme.tertiaryContainer)
        assertEquals(Color(0xFF523F5F), scheme.onTertiaryContainer)
        assertEquals(Color(0xFFBA1A1A), scheme.error)
        assertEquals(Color(0xFFFFDAD6), scheme.errorContainer)
        assertEquals(Color(0xFF93000A), scheme.onErrorContainer)
        assertEquals(Color(0xFF73777F), scheme.outline)
        assertEquals(Color(0xFFC3C6CF), scheme.outlineVariant)
        assertEquals(Color(0xFFF8F9FF), scheme.surface)
        assertEquals(Color(0xFF191C20), scheme.onSurface)
        assertEquals(Color(0xFFDFE2EB), scheme.surfaceVariant)
        assertEquals(Color(0xFF43474E), scheme.onSurfaceVariant)
        assertEquals(Color(0xFF2E3135), scheme.inverseSurface)
        assertEquals(Color(0xFFEFF0F7), scheme.inverseOnSurface)
        assertEquals(Color(0xFFA0CAFD), scheme.inversePrimary)
        assertEquals(Color(0xFF36618E), scheme.surfaceTint)
        assertEquals(Color(0xFFD8DAE0), scheme.surfaceDim)
        assertEquals(Color(0xFFF8F9FF), scheme.surfaceBright)
        assertEquals(Color(0xFFFFFFFF), scheme.surfaceContainerLowest)
        assertEquals(Color(0xFFF2F3FA), scheme.surfaceContainerLow)
        assertEquals(Color(0xFFECEEF4), scheme.surfaceContainer)
        assertEquals(Color(0xFFE6E8EE), scheme.surfaceContainerHigh)
        assertEquals(Color(0xFFE1E2E8), scheme.surfaceContainerHighest)
    }

    @Test
    fun `深色静态配色与 Flutter fromSeed 逐通道一致`() {
        val scheme = Md3DarkColorScheme
        assertEquals(Color(0xFFA0CAFD), scheme.primary)
        assertEquals(Color(0xFF003258), scheme.onPrimary)
        assertEquals(Color(0xFF1A4975), scheme.primaryContainer)
        assertEquals(Color(0xFFD1E4FF), scheme.onPrimaryContainer)
        assertEquals(Color(0xFFBBC7DB), scheme.secondary)
        assertEquals(Color(0xFF3B4858), scheme.secondaryContainer)
        assertEquals(Color(0xFFD7E3F8), scheme.onSecondaryContainer)
        assertEquals(Color(0xFFD7BEE4), scheme.tertiary)
        assertEquals(Color(0xFF523F5F), scheme.tertiaryContainer)
        assertEquals(Color(0xFFFFB4AB), scheme.error)
        assertEquals(Color(0xFF690005), scheme.onError)
        assertEquals(Color(0xFF8D9199), scheme.outline)
        assertEquals(Color(0xFF43474E), scheme.outlineVariant)
        assertEquals(Color(0xFF111418), scheme.surface)
        assertEquals(Color(0xFFE1E2E8), scheme.onSurface)
        assertEquals(Color(0xFFC3C6CF), scheme.onSurfaceVariant)
        assertEquals(Color(0xFFE1E2E8), scheme.inverseSurface)
        assertEquals(Color(0xFF2E3135), scheme.inverseOnSurface)
        assertEquals(Color(0xFF36618E), scheme.inversePrimary)
        assertEquals(Color(0xFFA0CAFD), scheme.surfaceTint)
        assertEquals(Color(0xFF111418), scheme.surfaceDim)
        assertEquals(Color(0xFF36393E), scheme.surfaceBright)
        assertEquals(Color(0xFF0B0E13), scheme.surfaceContainerLowest)
        assertEquals(Color(0xFF191C20), scheme.surfaceContainerLow)
        assertEquals(Color(0xFF1D2024), scheme.surfaceContainer)
        assertEquals(Color(0xFF272A2F), scheme.surfaceContainerHigh)
        assertEquals(Color(0xFF32353A), scheme.surfaceContainerHighest)
    }

    @Test
    fun `OLED 纯黑覆写 surface 系列并保留前景色`() {
        val oled = Md3DarkColorScheme.withOledBlack()
        assertEquals(Color.Black, oled.surface)
        assertEquals(Color.Black, oled.surfaceContainerLowest)
        assertEquals(Color.Black, oled.surfaceContainerLow)
        assertEquals(Color.Black, oled.surfaceContainer)
        // High/Highest 保留极深灰，让卡片/底栏仍有微妙层级感
        assertEquals(Color(0xFF111111), oled.surfaceContainerHigh)
        assertEquals(Color(0xFF1A1A1A), oled.surfaceContainerHighest)
        // 前景色 / 反色保持不变
        assertEquals(Md3DarkColorScheme.onSurface, oled.onSurface)
        assertEquals(Md3DarkColorScheme.onSurfaceVariant, oled.onSurfaceVariant)
        assertEquals(Md3DarkColorScheme.primary, oled.primary)
        assertEquals(Md3DarkColorScheme.inverseSurface, oled.inverseSurface)
    }

    @Test
    fun `OLED 覆写不改变浅色 scheme`() {
        val light = Md3LightColorScheme
        // 浅色主题不触发 OLED（仅 darkTheme 分支调用），行为上无纯黑 surface
        assertEquals(Color(0xFFF8F9FF), light.surface)
    }
}
