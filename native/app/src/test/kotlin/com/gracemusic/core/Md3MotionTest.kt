package com.gracemusic.core

import com.gracemusic.core.theme.Md3Motion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 动效常量移植锁测试。
 *
 * 锁定 `Md3Motion` 与 Flutter 源码逐值一致（motion_constants.dart /
 * m3e_core M3EMotion / 各核心 Widget 时长），防止后续误改。
 */
class Md3MotionTest {

    @Test
    fun `核心时长与 Flutter 一致`() {
        assertEquals(400, Md3Motion.DefaultDurationMillis)
        assertEquals(600, Md3Motion.EmphasisDurationMillis)
    }

    @Test
    fun `默认弹簧参数为 dampingRatio 0_825 与 stiffness 180`() {
        assertEquals(0.825f, Md3Motion.DefaultSpringDampingRatio, 0f)
        assertEquals(180f, Md3Motion.DefaultSpringStiffness, 0f)
        assertEquals(1.0f, Md3Motion.DefaultSpringMass, 0f)
        val spec = Md3Motion.defaultSpring<Float>()
        assertEquals(0.825f, spec.dampingRatio, 0f)
        assertEquals(180f, spec.stiffness, 0f)
    }

    @Test
    fun `两条缓动曲线端点正确且单调`() {
        for (easing in listOf(Md3Motion.ExpressiveEasing, Md3Motion.EmphasizedEasing)) {
            assertEquals(0f, easing.transform(0f), 1e-4f)
            assertEquals(1f, easing.transform(1f), 1e-4f)
            var previous = easing.transform(0f)
            for (i in 1..20) {
                val t = i / 20f
                val current = easing.transform(t)
                assertTrue("曲线应单调不减", current >= previous - 1e-4f)
                previous = current
            }
        }
    }

    @Test
    fun `M3E 弹簧预设与 m3e_core 逐值一致`() {
        assertEquals(1400f, Md3Motion.StandardSpatialFast.stiffness, 0f)
        assertEquals(0.9f, Md3Motion.StandardSpatialFast.dampingRatio, 0f)
        assertEquals(700f, Md3Motion.StandardSpatialDefault.stiffness, 0f)
        assertEquals(0.9f, Md3Motion.StandardSpatialDefault.dampingRatio, 0f)
        assertEquals(300f, Md3Motion.StandardSpatialSlow.stiffness, 0f)
        assertEquals(0.9f, Md3Motion.StandardSpatialSlow.dampingRatio, 0f)
        assertEquals(800f, Md3Motion.ExpressiveSpatialFast.stiffness, 0f)
        assertEquals(0.6f, Md3Motion.ExpressiveSpatialFast.dampingRatio, 0f)
        assertEquals(380f, Md3Motion.ExpressiveSpatialDefault.stiffness, 0f)
        assertEquals(0.8f, Md3Motion.ExpressiveSpatialDefault.dampingRatio, 0f)
        assertEquals(200f, Md3Motion.ExpressiveSpatialSlow.stiffness, 0f)
        assertEquals(0.8f, Md3Motion.ExpressiveSpatialSlow.dampingRatio, 0f)
        assertEquals(3800f, Md3Motion.StandardEffectsFast.stiffness, 0f)
        assertEquals(1.0f, Md3Motion.StandardEffectsFast.dampingRatio, 0f)
        assertEquals(1600f, Md3Motion.StandardEffectsDefault.stiffness, 0f)
        assertEquals(1.0f, Md3Motion.StandardEffectsDefault.dampingRatio, 0f)
        assertEquals(800f, Md3Motion.StandardEffectsSlow.stiffness, 0f)
        assertEquals(1.0f, Md3Motion.StandardEffectsSlow.dampingRatio, 0f)
        assertEquals(3800f, Md3Motion.ExpressiveEffectsFast.stiffness, 0f)
        assertEquals(1.0f, Md3Motion.ExpressiveEffectsFast.dampingRatio, 0f)
        assertEquals(1600f, Md3Motion.ExpressiveEffectsDefault.stiffness, 0f)
        assertEquals(1.0f, Md3Motion.ExpressiveEffectsDefault.dampingRatio, 0f)
        assertEquals(800f, Md3Motion.ExpressiveEffectsSlow.stiffness, 0f)
        assertEquals(1.0f, Md3Motion.ExpressiveEffectsSlow.dampingRatio, 0f)
        assertEquals(1600f, Md3Motion.StandardOverflow.stiffness, 0f)
        assertEquals(0.85f, Md3Motion.StandardOverflow.dampingRatio, 0f)
        assertEquals(1000f, Md3Motion.StandardPopup.stiffness, 0f)
        assertEquals(0.6f, Md3Motion.StandardPopup.dampingRatio, 0f)
    }

    @Test
    fun `M3E 预设可产出对应参数的 SpringSpec`() {
        val spec = Md3Motion.StandardPopup.spec<Float>()
        assertEquals(1000f, spec.stiffness, 0f)
        assertEquals(0.6f, spec.dampingRatio, 0f)
    }

    @Test
    fun `组件级固定时长与 lite 一致`() {
        assertEquals(80, Md3Motion.CapsuleStretchDurationMillis)
        assertEquals(500, Md3Motion.PullToRefreshMinDisplayMillis)
        assertEquals(350, Md3Motion.TransportTransitionDurationMillis)
        assertEquals(120, Md3Motion.TransportPressDurationMillis)
        assertEquals(260, Md3Motion.DockMorphDurationMillis)
        assertEquals(220, Md3Motion.SheetResizeDurationMillis)
        assertEquals(200, Md3Motion.SortFadeDurationMillis)
    }
}
