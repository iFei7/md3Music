package com.gracemusic.ui.dock

import com.gracemusic.ui.dock.DockLogic.DockVisibility
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * Dock 纯逻辑单测（JVM，无 Android 依赖）。
 *
 * 钉死 `DockLogic` 与 lite 源码的逐常量对位关系：
 * - 项宽公式：glass_dock_player.dart:277-279；
 * - 单展开状态机：glass_dock_player.dart:44-53,166-186；
 * - 进度钳位：glass_dock_player.dart:385-389,548-554；
 * - 歌名区宽度防御：glass_dock_player.dart:520-528；
 * - marquee 回卷：glass_dock_player.dart:827-833；暂停归零：`:846-852`；
 * - FullPlayer 门控：glass_dock_player.dart:199-207；
 * - 坍缩圆 tab 回退：glass_dock_player.dart:307-314。
 */
class DockLogicTest {

    // ─────────────────────────── 导航项宽 ───────────────────────────

    @Test
    fun `项宽表 - 少于等于4项时足额44dp`() {
        assertEquals(44f, DockLogic.navItemWidthDp(1), 0f)
        assertEquals(44f, DockLogic.navItemWidthDp(3), 0f)
        assertEquals(44f, DockLogic.navItemWidthDp(4), 0f)
    }

    @Test
    fun `项宽表 - 5项42 6项34 对齐lite注释`() {
        // glass_dock_player.dart:271-272：5 项 42（footprint 44）、6 项 34（footprint 36）
        assertEquals(42f, DockLogic.navItemWidthDp(5), 0f)
        assertEquals(34f, DockLogic.navItemWidthDp(6), 0f)
    }

    @Test
    fun `项宽表 - floor公式夹位下限28`() {
        // 7 项：(220/7)-2 = 29.43 → floor 29（未触底）
        assertEquals(29f, DockLogic.navItemWidthDp(7), 0f)
        // 8 项：(220/8)-2 = 25.5 → floor 25 → 夹到 28
        assertEquals(28f, DockLogic.navItemWidthDp(8), 0f)
        // 9 项（全 tab 序）：(220/9)-2 = 22.44 → floor 22 → 夹到 28
        assertEquals(28f, DockLogic.navItemWidthDp(9), 0f)
    }

    @Test
    fun `项宽表 - 空与非法计数防御`() {
        // count <= 4 分支覆盖 0 与负数（lite 的三元条件 count <= 4 同样命中 44）
        assertEquals(44f, DockLogic.navItemWidthDp(0), 0f)
        assertEquals(44f, DockLogic.navItemWidthDp(-3), 0f)
    }

    // ─────────────────────────── 单展开状态机 ───────────────────────────

    @Test
    fun `状态机 - 初始为导航展开`() {
        val state = DockLogic.DockExpansion.initial()
        assertEquals(true, state.navExpanded)
        assertEquals(false, state.controlsExpanded)
    }

    @Test
    fun `状态机 - 任意点击序列后恰好一个展开`() {
        var state = DockLogic.DockExpansion.initial()
        val random = Random(20261014)
        repeat(200) {
            state = when (random.nextInt(3)) {
                0 -> DockLogic.onNavCircleClicked(state)   // 点坍缩导航圆 → 导航展开
                1 -> DockLogic.onTabSelected(state)        // 切 tab → 导航展开
                else -> DockLogic.onPlayerButtonToggled(state) // 点播放器钮 → 翻转让位
            }
            // 单展开不变量：导航与播放器恰好一个展开（双 true / 双 false 均非法）
            assertTrue(
                "第 $it 步后破坏单展开不变量: $state",
                state.navExpanded != state.controlsExpanded,
            )
        }
    }

    @Test
    fun `状态机 - 播放器钮点击双向闭环`() {
        // 形态 A（导航胶囊 + 播放器球）→ 点播放器球 → 形态 B（导航球 + 播放器胶囊）
        var state = DockLogic.onPlayerButtonToggled(DockLogic.DockExpansion.initial())
        assertEquals(false, state.navExpanded)
        assertEquals(true, state.controlsExpanded)
        // 形态 B → 再点播放器胶囊背景 → 收起回形态 A
        state = DockLogic.onPlayerButtonToggled(state)
        assertEquals(true, state.navExpanded)
        assertEquals(false, state.controlsExpanded)
    }

    @Test
    fun `状态机 - 导航侧点击恒展开导航`() {
        // 形态 B 下点导航坍缩圆 / 切 tab → 播放器强制收起（反向闭环）
        var state = DockLogic.DockExpansion(navExpanded = false)
        state = DockLogic.onNavCircleClicked(state)
        assertEquals(true, state.navExpanded)
        assertEquals(false, state.controlsExpanded)
        state = DockLogic.DockExpansion(navExpanded = false)
        state = DockLogic.onTabSelected(state)
        assertEquals(true, state.navExpanded)
        assertEquals(false, state.controlsExpanded)
    }

    // ─────────────────────────── 进度钳位 ───────────────────────────

    @Test
    fun `进度比例 - duration为null或0时进度为0`() {
        // glass_dock_player.dart:385-389：duration null / zero → progress 0（只画轨道）
        assertEquals(0f, DockLogic.progressRatio(100L, null), 0f)
        assertEquals(0f, DockLogic.progressRatio(100L, 0L), 0f)
    }

    @Test
    fun `进度比例 - 正常值与钳位`() {
        assertEquals(0.5f, DockLogic.progressRatio(500L, 1000L), 1e-6f)
        // 负位置钳到 0
        assertEquals(0f, DockLogic.progressRatio(-5L, 1000L), 0f)
        // 超长钳到 1
        assertEquals(1f, DockLogic.progressRatio(1500L, 1000L), 0f)
    }

    // ─────────────────────────── 歌名区宽度防御 ───────────────────────────

    @Test
    fun `歌名区宽度 - 上限120下限0`() {
        // glass_dock_player.dart:522-528：fixedWidth = 120 + 36 + 3 + 8 + 10 = 177
        assertEquals(177f, DockLogic.CAPSULE_FIXED_WIDTH_DP, 0f)
        // 可用恰等于固定区 → 歌名 0
        assertEquals(0f, DockLogic.capsuleMarqueeWidthDp(177f), 0f)
        // 宽裕 → 上限 120
        assertEquals(120f, DockLogic.capsuleMarqueeWidthDp(297f), 0f)
        assertEquals(120f, DockLogic.capsuleMarqueeWidthDp(1000f), 0f)
        // 中间值透传
        assertEquals(23f, DockLogic.capsuleMarqueeWidthDp(200f), 0f)
        // 极限压缩 → 0（不超宽）
        assertEquals(0f, DockLogic.capsuleMarqueeWidthDp(100f), 0f)
    }

    // ─────────────────────────── marquee 回卷 ───────────────────────────

    @Test
    fun `marquee回卷 - 步进与无缝循环`() {
        // glass_dock_player.dart:827-833：offset = (offset + dt*speed) % (textWidth + gap)
        assertEquals(10f, DockLogic.marqueeLoopOffset(0f, 10f, 100f), 0f)
        // 超过 total = 100 + 32 = 132 → 回卷
        assertEquals(8f, DockLogic.marqueeLoopOffset(100f, 40f, 100f), 0f)
    }

    @Test
    fun `marquee回卷 - 零宽与负值防御`() {
        // glass_dock_player.dart:827-833：total = textWidth + gap；文本未测量
        //（textWidth = 0）时 total = 32 仍有效、按 gap 环宽回卷（lite 同样行为）
        assertEquals(15f, DockLogic.marqueeLoopOffset(5f, 10f, 0f), 0f)
        // 负 delta（防御，帧 dt 恒正）：floorMod 语义保持非负
        assertEquals(120f, DockLogic.marqueeLoopOffset(10f, -22f, 100f), 0f)
    }

    // ─────────────────────────── FullPlayer 门控 ───────────────────────────

    @Test
    fun `FullPlayer门控 - 三段阈值`() {
        // glass_dock_player.dart:199-207：>0.5 移除；>0.2 IgnorePointer+淡出；其余正常
        assertEquals(DockVisibility.REMOVED, DockLogic.dockVisibility(0.51f))
        assertEquals(DockVisibility.REMOVED, DockLogic.dockVisibility(1.0f))
        assertEquals(DockVisibility.FADED, DockLogic.dockVisibility(0.5f))
        assertEquals(DockVisibility.FADED, DockLogic.dockVisibility(0.21f))
        assertEquals(DockVisibility.VISIBLE, DockLogic.dockVisibility(0.2f))
        assertEquals(DockVisibility.VISIBLE, DockLogic.dockVisibility(0f))
    }

    @Test
    fun `FullPlayer门控 - 淡出alpha为1减fraction并钳位`() {
        assertEquals(0.8f, DockLogic.dockAlpha(0.2f), 1e-6f)
        assertEquals(0.2f, DockLogic.dockAlpha(0.8f), 1e-6f)
        // 越界防御
        assertEquals(1f, DockLogic.dockAlpha(-0.1f), 1e-6f)
        assertEquals(0f, DockLogic.dockAlpha(1.2f), 1e-6f)
    }

    // ─────────────────────────── 坍缩圆 tab 回退 ───────────────────────────

    @Test
    fun `坍缩圆 - 选中可见用选中 不可见回退第一个可见`() {
        // glass_dock_player.dart:307-314
        assertEquals("user", DockLogic.collapsedNavTabId("user", listOf("discover", "user")))
        assertEquals("discover", DockLogic.collapsedNavTabId("fm", listOf("discover", "user")))
        assertNull("空可见集回退 null（上层保持坍缩圆不画图标）", DockLogic.collapsedNavTabId("fm", emptyList()))
    }

    // ─────────────────────────── 进度环几何常量 ───────────────────────────

    @Test
    fun `进度环半径 - 坍缩球贴外缘 胶囊贴封面外缘`() {
        // 坍缩球：glass_dock_player.dart:395-399，26 − 0.75 − 0.5 = 24.75
        assertEquals(24.75f, DockLogic.collapsedRingRadiusDp(), 0f)
        // 展开胶囊：glass_dock_player.dart:562-565，18 + 0.75 = 18.75
        assertEquals(18.75f, DockLogic.capsuleRingRadiusDp(), 0f)
    }
}
