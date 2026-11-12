package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 批次44：暂停后空闲释放策略的 JVM 单测（不依赖 Android/Robolectric）。
 */
class IdleStopPolicyTest {

    private val policy = IdleStopPolicy()

    // ===== normalizeMinutes =====

    @Test
    fun normalizeMinutes_nullFallsBackToDefault() {
        assertEquals(IdleStopPolicy.DEFAULT_MINUTES, policy.normalizeMinutes(null))
    }

    @Test
    fun normalizeMinutes_negativeBecomesDisabled() {
        assertEquals(0, policy.normalizeMinutes(-1))
    }

    @Test
    fun normalizeMinutes_zeroStaysDisabled() {
        assertEquals(0, policy.normalizeMinutes(0))
    }

    @Test
    fun normalizeMinutes_overMaxIsClamped() {
        assertEquals(IdleStopPolicy.MAX_MINUTES, policy.normalizeMinutes(61))
    }

    @Test
    fun normalizeMinutes_normalValuePassesThrough() {
        assertEquals(10, policy.normalizeMinutes(10))
    }

    // ===== delayMs =====

    @Test
    fun delayMs_disabledIsZero() {
        assertEquals(0L, policy.delayMs(0))
    }

    @Test
    fun delayMs_tenMinutesIsSixHundredThousandMillis() {
        assertEquals(600_000L, policy.delayMs(10))
    }

    // ===== shouldStop =====

    @Test
    fun shouldStop_playingNeverStops() {
        assertFalse(policy.shouldStop(playing = true, minutes = 10))
    }

    @Test
    fun shouldStop_pausedButDisabledNeverStops() {
        assertFalse(policy.shouldStop(playing = false, minutes = 0))
    }

    @Test
    fun shouldStop_pausedAndEnabledStops() {
        assertTrue(policy.shouldStop(playing = false, minutes = 10))
    }

    // ===== resolveMinutes（SharedPreferences 值类型归一化）=====

    @Test
    fun resolveMinutes_longZeroResolvesDisabled() {
        // 用户关闭开关：Flutter setInt(0) 实际写 Long 0，原生必须读到 0
        assertEquals(0, IdleStopPolicy.resolveMinutes(0L))
        assertFalse(policy.shouldStop(playing = false, minutes = policy.normalizeMinutes(0)))
    }

    @Test
    fun resolveMinutes_longTenResolvesTen() {
        // 默认开启 10 分钟：Flutter setInt(10) 实际写 Long 10
        assertEquals(10, IdleStopPolicy.resolveMinutes(10L))
        assertTrue(policy.shouldStop(playing = false, minutes = policy.normalizeMinutes(10)))
    }

    @Test
    fun resolveMinutes_intPassesThrough() {
        assertEquals(5, IdleStopPolicy.resolveMinutes(5))
    }

    @Test
    fun resolveMinutes_doublePassesThrough() {
        // 防 Double 类型的脏值也能归一化
        assertEquals(10, IdleStopPolicy.resolveMinutes(10.0))
    }

    @Test
    fun resolveMinutes_invalidTypeFallsBackToDefault() {
        assertEquals(IdleStopPolicy.DEFAULT_MINUTES, IdleStopPolicy.resolveMinutes("abc"))
        assertEquals(IdleStopPolicy.DEFAULT_MINUTES, IdleStopPolicy.resolveMinutes(true))
    }

    @Test
    fun resolveMinutes_nullFallsBackToDefault() {
        // 从未写入过该 key：prefs.all 取不到 → null → 默认 10
        assertEquals(IdleStopPolicy.DEFAULT_MINUTES, IdleStopPolicy.resolveMinutes(null))
    }
}
