package com.md3music.md3music.player.gate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaybackRecoveryFlight] 移植锁测试。
 *
 * 场景对标 test/providers/playback_recovery_flight_test.dart：
 * - 同时到达的恢复触发只允许一个任务进入；
 * - 旧任务 finally 不能释放手动接管后启动的新恢复任务；
 * - 失效的退避定时器不会匹配新恢复代次。
 */
class PlaybackRecoveryFlightTest {

    @Test
    fun `同时到达的恢复触发只允许一个任务进入`() {
        val flight = PlaybackRecoveryFlight()

        val first = flight.tryStart()

        assertNotNull(first)
        assertNull(flight.tryStart())
        assertNull(flight.tryStart())
        assertTrue(flight.isCurrent(first!!))
    }

    @Test
    fun `旧任务finally不能释放手动接管后启动的新恢复任务`() {
        val flight = PlaybackRecoveryFlight()
        val oldToken = flight.tryStart()!!

        flight.invalidate(releaseInFlight = true)
        val newToken = flight.tryStart()!!
        flight.releaseIfOwned(oldToken)

        assertFalse(flight.isCurrent(oldToken))
        assertTrue(flight.isCurrent(newToken))
        assertEquals(newToken, flight.inFlightToken)
        assertNull(flight.tryStart())
    }

    @Test
    fun `失效的退避定时器不会匹配新恢复代次`() {
        val flight = PlaybackRecoveryFlight()
        val scheduledSequence = flight.sequence

        flight.invalidate()

        assertFalse(flight.isCurrent(scheduledSequence))
        assertTrue(flight.isCurrent(flight.sequence))
    }

    @Test
    fun `不释放占位的失效仍阻塞后续启动`() {
        val flight = PlaybackRecoveryFlight()
        flight.tryStart()

        flight.invalidate()

        assertNull(flight.tryStart())
        assertEquals(1, flight.inFlightToken)
    }
}
