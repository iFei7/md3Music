package com.gracemusic.player.gate

import kotlin.time.Duration

/**
 * CDN 播放速率异常时，根据剩余缓冲决定是否立即重建音源。
 *
 * 1:1 移植自 lib/providers/playback_stall_policy.dart（26 行，全文移植）。
 */
enum class CdnStallWindowDecision {
    SUFFICIENT_PROGRESS,
    WAIT_FOR_BUFFERED_AUDIO,
    REFRESH_SOURCE,
}

/**
 * 慢速窗口仍有足够缓冲时继续播放，避免无谓重建解码器造成听感中断。
 *
 * 1:1 移植自 lib/providers/playback_stall_policy.dart:9-26。
 *
 * 语义契约（与 Dart 逐值一致，含边界）：
 * - elapsed <= 0 或 advanced < 0（无效窗口 / 向后 seek）→ SUFFICIENT_PROGRESS；
 * - advanced.inWholeMicroseconds >= elapsed.inWholeMicroseconds * minimumPlaybackRate
 *   （速率达标，>= 为闭边界）→ SUFFICIENT_PROGRESS；
 * - bufferedHeadroom > minimumBufferedHeadroom（严格大于）→ WAIT_FOR_BUFFERED_AUDIO；
 * - 其余 → REFRESH_SOURCE。
 */
fun classifyCdnStallWindow(
    advanced: Duration,
    elapsed: Duration,
    bufferedHeadroom: Duration,
    minimumBufferedHeadroom: Duration,
    minimumPlaybackRate: Double,
): CdnStallWindowDecision {
    if (elapsed <= Duration.ZERO || advanced < Duration.ZERO) {
        return CdnStallWindowDecision.SUFFICIENT_PROGRESS
    }
    if (advanced.inWholeMicroseconds >= elapsed.inWholeMicroseconds * minimumPlaybackRate) {
        return CdnStallWindowDecision.SUFFICIENT_PROGRESS
    }
    if (bufferedHeadroom > minimumBufferedHeadroom) {
        return CdnStallWindowDecision.WAIT_FOR_BUFFERED_AUDIO
    }
    return CdnStallWindowDecision.REFRESH_SOURCE
}
