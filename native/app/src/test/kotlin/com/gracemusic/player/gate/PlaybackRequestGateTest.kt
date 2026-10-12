package com.gracemusic.player.gate

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaybackRequestGate] 移植锁测试。
 *
 * 场景对标 test/providers/playback_request_gate_test.dart：
 * - 新播放请求会使旧请求失效；
 * - 暂停或停止可以取消尚未完成的请求；
 * - 取消后可以正常开始新的请求。
 */
class PlaybackRequestGateTest {

    @Test
    fun `新播放请求会使旧请求失效`() {
        val gate = PlaybackRequestGate()
        val oldRequest = gate.issue()
        val newRequest = gate.issue()

        assertFalse(gate.isCurrent(oldRequest))
        assertTrue(gate.isCurrent(newRequest))
    }

    @Test
    fun `暂停或停止可以取消尚未完成的请求`() {
        val gate = PlaybackRequestGate()
        val request = gate.issue()

        gate.invalidate()

        assertFalse(gate.isCurrent(request))
    }

    @Test
    fun `取消后可以正常开始新的请求`() {
        val gate = PlaybackRequestGate()
        val oldRequest = gate.issue()
        gate.invalidate()
        val newRequest = gate.issue()

        assertFalse(gate.isCurrent(oldRequest))
        assertTrue(gate.isCurrent(newRequest))
    }
}
