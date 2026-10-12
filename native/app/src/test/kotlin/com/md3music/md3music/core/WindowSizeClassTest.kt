package com.md3music.md3music.core

import com.md3music.md3music.core.responsive.WindowSizeBreakpoints
import com.md3music.md3music.core.responsive.WindowSizeClass
import com.md3music.md3music.core.responsive.gridColumnsForWidth
import com.md3music.md3music.core.responsive.isPadLayout
import com.md3music.md3music.core.responsive.shouldUseTwoPaneLayout
import com.md3music.md3music.core.responsive.windowSizeClassForWidth
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * WindowSizeClass 断点计算纯函数测试。
 *
 * 锁定 lite `lib/core/layout/responsive_layout.dart` 的断点语义：
 * `width < 600 → Compact；width < 900 → Medium；否则 Expanded`。
 */
class WindowSizeClassTest {

    @Test
    fun `宽度低于 600dp 为 Compact`() {
        assertEquals(WindowSizeClass.Compact, windowSizeClassForWidth(0f))
        assertEquals(WindowSizeClass.Compact, windowSizeClassForWidth(320f))
        assertEquals(WindowSizeClass.Compact, windowSizeClassForWidth(599.9f))
    }

    @Test
    fun `600dp 起进入 Medium`() {
        assertEquals(WindowSizeClass.Medium, windowSizeClassForWidth(600f))
        assertEquals(WindowSizeClass.Medium, windowSizeClassForWidth(840f))
        assertEquals(WindowSizeClass.Medium, windowSizeClassForWidth(899.9f))
    }

    @Test
    fun `900dp 起进入 Expanded`() {
        assertEquals(WindowSizeClass.Expanded, windowSizeClassForWidth(900f))
        assertEquals(WindowSizeClass.Expanded, windowSizeClassForWidth(1200f))
        assertEquals(WindowSizeClass.Expanded, windowSizeClassForWidth(2560f))
    }

    @Test
    fun `断点常量为 600 与 900`() {
        assertEquals(600f, WindowSizeBreakpoints.Compact, 0f)
        assertEquals(900f, WindowSizeBreakpoints.Medium, 0f)
    }

    @Test
    fun `Pad 布局按最短边判定 600dp 边界`() {
        assertEquals(false, isPadLayout(599.9f))
        assertEquals(true, isPadLayout(600f))
        assertEquals(true, isPadLayout(800f))
    }

    @Test
    fun `双栏仅 Expanded 启用`() {
        assertEquals(false, shouldUseTwoPaneLayout(WindowSizeClass.Compact))
        assertEquals(false, shouldUseTwoPaneLayout(WindowSizeClass.Medium))
        assertEquals(true, shouldUseTwoPaneLayout(WindowSizeClass.Expanded))
    }

    @Test
    fun `网格列数按目标宽度均分并夹紧`() {
        // 宽度或目标非法时回落 min
        assertEquals(2, gridColumnsForWidth(0f))
        assertEquals(2, gridColumnsForWidth(400f, targetExtent = 0f))
        // 200dp 目标宽度：400dp → 2 列；600dp → 3 列；1200dp → 6 列
        assertEquals(2, gridColumnsForWidth(400f))
        assertEquals(3, gridColumnsForWidth(600f))
        assertEquals(6, gridColumnsForWidth(1200f))
        // 超过 max 夹到 6；自定义 min/max 生效
        assertEquals(6, gridColumnsForWidth(1600f))
        assertEquals(4, gridColumnsForWidth(400f, min = 4))
        assertEquals(2, gridColumnsForWidth(400f, targetExtent = 300f))
    }
}
