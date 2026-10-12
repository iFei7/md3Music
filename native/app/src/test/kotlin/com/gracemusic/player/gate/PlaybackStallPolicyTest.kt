package com.gracemusic.player.gate

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.time.Duration
import kotlin.time.Duration.Companion.microseconds
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * [classifyCdnStallWindow] 移植锁测试。
 *
 * 场景对标 test/providers/playback_stall_policy_test.dart：
 * - 慢速窗口但剩余缓冲充足时等待，不重建音源；
 * - 缓冲余量低于刷新准备时间时换源；
 * - 播放位置停住且没有剩余缓冲时换源；
 * - 速率与缓冲阈值边界保持既定策略；
 * - 正常推进、向后 seek 和无效时间窗口都不触发换源。
 */
class PlaybackStallPolicyTest {

    private val minimumHeadroom = 10.seconds

    private fun classify(
        advanced: kotlin.time.Duration,
        elapsed: kotlin.time.Duration,
        bufferedHeadroom: kotlin.time.Duration,
    ) = classifyCdnStallWindow(
        advanced = advanced,
        elapsed = elapsed,
        bufferedHeadroom = bufferedHeadroom,
        minimumBufferedHeadroom = minimumHeadroom,
        minimumPlaybackRate = 0.5,
    )

    @Test
    fun `慢速窗口但剩余缓冲充足时等待，不重建音源`() {
        assertEquals(
            CdnStallWindowDecision.WAIT_FOR_BUFFERED_AUDIO,
            classify(
                advanced = 200.milliseconds,
                elapsed = 2.seconds,
                bufferedHeadroom = 56.seconds,
            ),
        )
    }

    @Test
    fun `缓冲余量低于刷新准备时间时换源`() {
        assertEquals(
            CdnStallWindowDecision.REFRESH_SOURCE,
            classify(
                advanced = 200.milliseconds,
                elapsed = 2.seconds,
                bufferedHeadroom = 8.seconds,
            ),
        )
    }

    @Test
    fun `播放位置停住且没有剩余缓冲时换源`() {
        assertEquals(
            CdnStallWindowDecision.REFRESH_SOURCE,
            classify(
                advanced = Duration.ZERO,
                elapsed = 2.seconds,
                bufferedHeadroom = Duration.ZERO,
            ),
        )
    }

    @Test
    fun `速率与缓冲阈值边界保持既定策略`() {
        // 速率恰达标（闭边界）：advanced == elapsed * 0.5 → 充分推进
        assertEquals(
            CdnStallWindowDecision.SUFFICIENT_PROGRESS,
            classify(
                advanced = 1.seconds,
                elapsed = 2.seconds,
                bufferedHeadroom = Duration.ZERO,
            ),
        )
        // 速率不达标 + 缓冲余量恰高阈值 1 微秒 → 等待
        assertEquals(
            CdnStallWindowDecision.WAIT_FOR_BUFFERED_AUDIO,
            classify(
                advanced = 999.milliseconds,
                elapsed = 2.seconds,
                bufferedHeadroom = 10.seconds + 1.microseconds,
            ),
        )
        // 速率不达标 + 缓冲余量恰等于阈值 → 换源（严格大于才等待）
        assertEquals(
            CdnStallWindowDecision.REFRESH_SOURCE,
            classify(
                advanced = 999.milliseconds,
                elapsed = 2.seconds,
                bufferedHeadroom = minimumHeadroom,
            ),
        )
    }

    @Test
    fun `正常推进、向后seek和无效时间窗口都不触发换源`() {
        assertEquals(
            CdnStallWindowDecision.SUFFICIENT_PROGRESS,
            classify(
                advanced = 1.seconds,
                elapsed = 2.seconds,
                bufferedHeadroom = Duration.ZERO,
            ),
        )
        assertEquals(
            CdnStallWindowDecision.SUFFICIENT_PROGRESS,
            classify(
                advanced = (-1).seconds,
                elapsed = 2.seconds,
                bufferedHeadroom = Duration.ZERO,
            ),
        )
        assertEquals(
            CdnStallWindowDecision.SUFFICIENT_PROGRESS,
            classify(
                advanced = Duration.ZERO,
                elapsed = Duration.ZERO,
                bufferedHeadroom = Duration.ZERO,
            ),
        )
    }
}
