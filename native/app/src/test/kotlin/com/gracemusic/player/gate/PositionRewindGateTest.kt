package com.gracemusic.player.gate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * [PositionRewindGate] 移植锁测试（方案 A：换源装载期间不发布"位置从 0
 * 重新计数"的假回退）。
 *
 * 场景对标 test/providers/position_rewind_gate_test.dart：
 * - 未开启时不抑制任何采样；
 * - 目标 <= 0 不开启（换源后确实要从 0 开始播）；
 * - 开启后丢弃小于目标的回退采样，到达/超过目标放行；
 * - 超时后自动放行并关闭闸门（装载卡死兜底）；
 * - disarm 后回退采样放行（装载结束后的合法 seek 回退）；
 * - 重复 arm 以最后一次目标为准。
 */
class PositionRewindGateTest {

    @Test
    fun `未开启时不抑制任何采样`() {
        val gate = PositionRewindGate()
        assertFalse(gate.armed)
        assertFalse(gate.shouldSuppress(0.seconds))
        assertFalse(gate.shouldSuppress(30.seconds))
    }

    @Test
    fun `目标小于等于0不开启`() {
        val gate = PositionRewindGate()
        gate.arm(0.seconds)
        assertFalse(gate.armed)
        assertEquals(0.seconds, gate.floor)
        assertFalse(gate.shouldSuppress(0.seconds))
    }

    @Test
    fun `开启后丢弃小于目标的回退采样，到达或超过目标放行`() {
        val gate = PositionRewindGate()
        val now = 1_756_000_000_000L // 虚拟时间，不依赖真实时钟
        gate.arm(60.seconds, now = now)
        assertTrue(gate.armed)
        assertEquals(60.seconds, gate.floor)

        // 换源副作用：位置从 0 重新计数 / 中间的旧采样
        assertTrue(gate.shouldSuppress(0.seconds, now = now))
        assertTrue(gate.shouldSuppress(5.seconds, now = now))
        assertTrue(gate.shouldSuppress(59_999.milliseconds, now = now))

        // 到达/超过目标 = 真实进度，放行
        assertFalse(gate.shouldSuppress(60.seconds, now = now))
        assertFalse(gate.shouldSuppress(61.seconds, now = now))
        // 放行不自动关闭闸门（仍需装载结束时显式 disarm，避免窗口后段再被污染）
        assertTrue(gate.armed)
    }

    @Test
    fun `超时后自动放行并关闭闸门`() {
        val gate = PositionRewindGate()
        val now = 1_756_000_000_000L
        gate.arm(60.seconds, now = now)
        val later = now + PositionRewindGate.TIMEOUT.inWholeMilliseconds + 1_000L
        assertFalse(
            gate.shouldSuppress(0.seconds, now = later),
        )
        assertFalse(gate.armed)
    }

    @Test
    fun `恰好等于超时阈值仍保持抑制（严格大于才放行）`() {
        val gate = PositionRewindGate()
        val now = 1_756_000_000_000L
        gate.arm(60.seconds, now = now)
        val atTimeout = now + PositionRewindGate.TIMEOUT.inWholeMilliseconds
        assertTrue(gate.shouldSuppress(0.seconds, now = atTimeout))
        assertTrue(gate.armed)
    }

    @Test
    fun `disarm 后回退采样放行`() {
        val gate = PositionRewindGate()
        gate.arm(60.seconds)
        assertTrue(gate.shouldSuppress(10.seconds))

        gate.disarm()
        assertFalse(gate.armed)
        assertFalse(gate.shouldSuppress(10.seconds))
    }

    @Test
    fun `重复 arm 以最后一次目标为准`() {
        val gate = PositionRewindGate()
        gate.arm(60.seconds)
        gate.arm(120.seconds)
        assertEquals(120.seconds, gate.floor)
        assertTrue(gate.shouldSuppress(90.seconds))
        assertFalse(gate.shouldSuppress(120.seconds))
    }
}
