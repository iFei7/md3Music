package com.gracemusic.player.gate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/**
 * [PlaybackRecoveryBudget] / [classifyPlaybackSourceHttpFailure] /
 * [shouldAutomaticallyRetryPlatformPlaybackError] /
 * [classifyPlaybackRecoveryFailure] 移植锁测试。
 *
 * 场景对标 test/providers/playback_recovery_budget_test.dart：
 * - 对单首歌最多发起三次自动恢复，并逐步退避；
 * - 换歌或显式重置会开启新的恢复预算；
 * - classifyPlaybackRecoveryFailure 五类非瞬时失败不重试、普通解析失败归瞬时；
 * - Media3 3003/4004/4005 阻断、其余（含未知码）保留重试；
 * - HTTP 401/403/408/425/429/5xx 可刷新链接，404/410 及客户端错误停止重试。
 */
class PlaybackRecoveryBudgetTest {

    @Test
    fun `对单首歌最多发起三次自动恢复，并逐步退避`() {
        val budget = PlaybackRecoveryBudget()

        assertEquals(30.seconds, budget.nextDelay)
        assertTrue(budget.tryConsume("song-a"))
        assertEquals(60.seconds, budget.nextDelay)
        assertTrue(budget.tryConsume("song-a"))
        assertEquals(120.seconds, budget.nextDelay)
        assertTrue(budget.tryConsume("song-a"))
        assertNull(budget.nextDelay)
        assertFalse(budget.tryConsume("song-a"))
    }

    @Test
    fun `换歌或显式重置会开启新的恢复预算`() {
        val budget = PlaybackRecoveryBudget()
        assertTrue(budget.tryConsume("song-a"))
        assertTrue(budget.tryConsume("song-b"))
        assertEquals(1, budget.attempts)
        budget.reset("song-b")
        assertEquals(0, budget.attempts)
        assertEquals(30.seconds, budget.nextDelay)
    }

    @Test
    fun `非瞬时恢复失败不进入自动重试`() {
        assertEquals(
            PlaybackRecoveryFailureKind.NO_FAILURE,
            classifyPlaybackRecoveryFailure(
                hasFailure = false,
                userCanceled = false,
                authenticationRequired = false,
                paidContent = false,
                networkAvailable = true,
            ),
        )
        assertEquals(
            PlaybackRecoveryFailureKind.USER_CANCELED,
            classifyPlaybackRecoveryFailure(
                hasFailure = true,
                userCanceled = true,
                authenticationRequired = false,
                paidContent = false,
                networkAvailable = true,
            ),
        )
        assertEquals(
            PlaybackRecoveryFailureKind.AUTHENTICATION_REQUIRED,
            classifyPlaybackRecoveryFailure(
                hasFailure = true,
                userCanceled = false,
                authenticationRequired = true,
                paidContent = false,
                networkAvailable = true,
            ),
        )
        assertEquals(
            PlaybackRecoveryFailureKind.PAID_CONTENT,
            classifyPlaybackRecoveryFailure(
                hasFailure = true,
                userCanceled = false,
                authenticationRequired = false,
                paidContent = true,
                networkAvailable = true,
            ),
        )
        assertEquals(
            PlaybackRecoveryFailureKind.NETWORK_UNAVAILABLE,
            classifyPlaybackRecoveryFailure(
                hasFailure = true,
                userCanceled = false,
                authenticationRequired = false,
                paidContent = false,
                networkAvailable = false,
            ),
        )
    }

    @Test
    fun `在线且可播放的普通解析失败归为瞬时错误`() {
        assertEquals(
            PlaybackRecoveryFailureKind.TRANSIENT_RESOLUTION,
            classifyPlaybackRecoveryFailure(
                hasFailure = true,
                userCanceled = false,
                authenticationRequired = false,
                paidContent = false,
                networkAvailable = true,
            ),
        )
    }

    @Test
    fun `Media3 确定性格式错误不自动重试`() {
        for (code in listOf(3003, 4004, 4005)) {
            assertFalse(
                "Media3 error code $code cannot be fixed by re-resolving URL",
                shouldAutomaticallyRetryPlatformPlaybackError(
                    isAndroid = true,
                    errorCode = code,
                ),
            )
        }
    }

    @Test
    fun `网络输出路由与未知失败保留自动重试`() {
        for (code in listOf(2001, 2002, 2005, 4001, 4003, 5001, 5002, 9999)) {
            assertTrue(
                "Media3 error code $code may recover after state changes",
                shouldAutomaticallyRetryPlatformPlaybackError(
                    isAndroid = true,
                    errorCode = code,
                ),
            )
        }
    }

    @Test
    fun `其他平台与无错误码时保留既有行为`() {
        assertTrue(
            shouldAutomaticallyRetryPlatformPlaybackError(
                isAndroid = false,
                errorCode = 4004,
            ),
        )
        assertTrue(
            shouldAutomaticallyRetryPlatformPlaybackError(
                isAndroid = true,
                errorCode = null,
            ),
        )
    }

    @Test
    fun `HTTP拒绝和限流可刷新链接，确定性缺失和客户端错误停止自动重试`() {
        for (status in listOf(401, 403, 408, 425, 429, 500, 503)) {
            assertTrue(
                "HTTP $status can recover after bounded URL refresh",
                shouldAutomaticallyRetryPlatformPlaybackError(
                    isAndroid = true,
                    errorCode = 2004,
                    httpStatusCode = status,
                ),
            )
        }
        for (status in listOf(400, 404, 410, 422)) {
            assertFalse(
                "HTTP $status should keep the manual retry path only",
                shouldAutomaticallyRetryPlatformPlaybackError(
                    isAndroid = true,
                    errorCode = 2004,
                    httpStatusCode = status,
                ),
            )
        }
    }

    @Test
    fun `HTTP失败分类表逐值一致`() {
        assertEquals(
            PlaybackSourceHttpFailureKind.SIGNED_URL_REJECTED,
            classifyPlaybackSourceHttpFailure(403),
        )
        assertEquals(
            PlaybackSourceHttpFailureKind.SIGNED_URL_REJECTED,
            classifyPlaybackSourceHttpFailure(401),
        )
        assertEquals(
            PlaybackSourceHttpFailureKind.RESOURCE_MISSING,
            classifyPlaybackSourceHttpFailure(404),
        )
        assertEquals(
            PlaybackSourceHttpFailureKind.RESOURCE_MISSING,
            classifyPlaybackSourceHttpFailure(410),
        )
        assertEquals(
            PlaybackSourceHttpFailureKind.TRANSIENT_HTTP_FAILURE,
            classifyPlaybackSourceHttpFailure(503),
        )
        assertEquals(
            PlaybackSourceHttpFailureKind.TRANSIENT_HTTP_FAILURE,
            classifyPlaybackSourceHttpFailure(500),
        )
        assertEquals(
            PlaybackSourceHttpFailureKind.PERMANENT_HTTP_FAILURE,
            classifyPlaybackSourceHttpFailure(422),
        )
        assertEquals(
            PlaybackSourceHttpFailureKind.PERMANENT_HTTP_FAILURE,
            classifyPlaybackSourceHttpFailure(400),
        )
        assertEquals(
            PlaybackSourceHttpFailureKind.NO_HTTP_STATUS,
            classifyPlaybackSourceHttpFailure(null),
        )
    }

    @Test
    fun `自定义预算参数按注入值生效`() {
        val budget = PlaybackRecoveryBudget(
            maxAttempts = 1,
            backoff = listOf(5.seconds),
        )
        assertEquals(5.seconds, budget.nextDelay)
        assertTrue(budget.tryConsume("song-a"))
        assertNull(budget.nextDelay)
        assertFalse(budget.tryConsume("song-a"))
    }
}
