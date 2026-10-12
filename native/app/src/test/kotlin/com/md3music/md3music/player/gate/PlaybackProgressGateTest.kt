package com.md3music.md3music.player.gate

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * [PlaybackProgressGate] 移植锁测试。
 *
 * 场景对标 test/providers/playback_progress_gate_test.dart 的
 * PlaybackProgressGate 组（provider 级接线测试依赖 Flutter 平台，不在
 * JVM 纯逻辑层覆盖）：
 * - 恢复时重复上报当前位置不算真实推进；
 * - 只在平台位置超过请求基线后报告一次推进；
 * - 过期请求不推进当前请求，新请求会重设基线。
 */
class PlaybackProgressGateTest {

    @Test
    fun `恢复时重复上报当前位置不算真实推进`() {
        val gate = PlaybackProgressGate()
        gate.begin(7, baseline = 2.minutes)

        assertFalse(gate.observe(7, 2.minutes))
        assertFalse(gate.observe(7, 1.minutes + 59.seconds))
    }

    @Test
    fun `只在平台位置超过请求基线后报告一次推进`() {
        val gate = PlaybackProgressGate()
        gate.begin(7, baseline = 2.minutes)

        assertTrue(gate.observe(7, 2.minutes + 200.milliseconds))
        assertFalse(gate.observe(7, 2.minutes + 400.milliseconds))
    }

    @Test
    fun `过期请求不推进当前请求，新请求会重设基线`() {
        val gate = PlaybackProgressGate()
        gate.begin(7, baseline = 2.minutes)
        gate.begin(8, baseline = 0.seconds)

        assertFalse(gate.observe(7, 3.minutes))
        assertTrue(gate.observe(8, 200.milliseconds))
    }

    @Test
    fun `isPending 与 reset 状态切换`() {
        val gate = PlaybackProgressGate()
        gate.begin(7, baseline = 2.minutes)
        assertTrue(gate.isPending(7))

        assertTrue(gate.observe(7, 2.minutes + 200.milliseconds))
        assertFalse(gate.isPending(7))

        gate.reset()
        assertFalse(gate.isPending(7))
        assertFalse(gate.observe(7, 2.minutes + 200.milliseconds))
    }
}
