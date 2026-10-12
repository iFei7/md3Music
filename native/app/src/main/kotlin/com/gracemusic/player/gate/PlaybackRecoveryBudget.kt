package com.gracemusic.player.gate

import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 当前恢复失败的决策类别。
 *
 * 1:1 移植自 lib/providers/playback_recovery_budget.dart:2-9。
 */
enum class PlaybackRecoveryFailureKind {
    NO_FAILURE,
    USER_CANCELED,
    AUTHENTICATION_REQUIRED,
    PAID_CONTENT,
    NETWORK_UNAVAILABLE,
    TRANSIENT_RESOLUTION,
}

/**
 * 播放媒体源返回 HTTP 状态后的恢复策略分类。
 *
 * 1:1 移植自 lib/providers/playback_recovery_budget.dart:12-18。
 */
enum class PlaybackSourceHttpFailureKind {
    NO_HTTP_STATUS,
    SIGNED_URL_REJECTED,
    RESOURCE_MISSING,
    TRANSIENT_HTTP_FAILURE,
    PERMANENT_HTTP_FAILURE,
}

/**
 * HTTP 失败分类（1:1 移植自 lib/providers/playback_recovery_budget.dart:20-37）。
 *
 * 分类表（逐值一致）：
 * - null → NO_HTTP_STATUS；
 * - 401 / 403 → SIGNED_URL_REJECTED（签名拒绝）；
 * - 404 / 410 → RESOURCE_MISSING（资源缺失）；
 * - 408 / 425 / 429 / >= 500 → TRANSIENT_HTTP_FAILURE（瞬时，无上界）；
 * - 其余 → PERMANENT_HTTP_FAILURE（永久）。
 */
fun classifyPlaybackSourceHttpFailure(
    statusCode: Int?,
): PlaybackSourceHttpFailureKind {
    if (statusCode == null) return PlaybackSourceHttpFailureKind.NO_HTTP_STATUS
    if (statusCode == 401 || statusCode == 403) {
        return PlaybackSourceHttpFailureKind.SIGNED_URL_REJECTED
    }
    if (statusCode == 404 || statusCode == 410) {
        return PlaybackSourceHttpFailureKind.RESOURCE_MISSING
    }
    if (statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500
    ) {
        return PlaybackSourceHttpFailureKind.TRANSIENT_HTTP_FAILURE
    }
    return PlaybackSourceHttpFailureKind.PERMANENT_HTTP_FAILURE
}

/**
 * Android Media3 的错误码可区分媒体格式错误与可通过重新解析恢复的失败。
 * 未知错误默认保留原有有限重试行为，避免错误码升级时误阻断恢复。
 *
 * 1:1 移植自 lib/providers/playback_recovery_budget.dart:41-56。
 *
 * 判定顺序（与 Dart 一致）：先按 HTTP 状态分类，RESOURCE_MISSING /
 * PERMANENT_HTTP_FAILURE 直接不重试；否则非 Android 或无错误码时重试；
 * 最后 Media3 3003（容器不受支持）/ 4004 / 4005（解码器不支持格式或能力
 * 不足）为确定性兼容问题，不重试。
 */
fun shouldAutomaticallyRetryPlatformPlaybackError(
    isAndroid: Boolean,
    errorCode: Int?,
    httpStatusCode: Int? = null,
): Boolean {
    val httpFailure = classifyPlaybackSourceHttpFailure(httpStatusCode)
    if (httpFailure == PlaybackSourceHttpFailureKind.RESOURCE_MISSING ||
        httpFailure == PlaybackSourceHttpFailureKind.PERMANENT_HTTP_FAILURE
    ) {
        return false
    }
    if (!isAndroid || errorCode == null) return true

    // Media3 3003：容器不受支持；4004/4005：解码器不支持格式或能力不足。
    // 重新请求同一媒体 URL 无法修复这些确定性兼容问题。
    return errorCode != 3003 && errorCode != 4004 && errorCode != 4005
}

/**
 * 把已知不可恢复状态与可重试解析失败分开，避免定时器盲目重试。
 *
 * 1:1 移植自 lib/providers/playback_recovery_budget.dart:59-74。
 *
 * 优先级（短路顺序与 Dart 一致）：
 * hasFailure → userCanceled → authenticationRequired → paidContent →
 * networkAvailable → transientResolution。
 */
fun classifyPlaybackRecoveryFailure(
    hasFailure: Boolean,
    userCanceled: Boolean,
    authenticationRequired: Boolean,
    paidContent: Boolean,
    networkAvailable: Boolean,
): PlaybackRecoveryFailureKind {
    if (!hasFailure) return PlaybackRecoveryFailureKind.NO_FAILURE
    if (userCanceled) return PlaybackRecoveryFailureKind.USER_CANCELED
    if (authenticationRequired) {
        return PlaybackRecoveryFailureKind.AUTHENTICATION_REQUIRED
    }
    if (paidContent) return PlaybackRecoveryFailureKind.PAID_CONTENT
    if (!networkAvailable) return PlaybackRecoveryFailureKind.NETWORK_UNAVAILABLE
    return PlaybackRecoveryFailureKind.TRANSIENT_RESOLUTION
}

/**
 * 单首歌曲的有限自动恢复预算，避免后台网络故障形成永久重试循环。
 *
 * 1:1 移植自 lib/providers/playback_recovery_budget.dart:77-113。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - 默认 maxAttempts = 3、backoff = [30s, 60s, 120s]；
 * - [tryConsume] 遇到不同 songId 先按新歌重置预算；attempts 达到
 *   maxAttempts 后返回 false；
 * - [nextDelay] 在 attempts >= maxAttempts 或 backoff 为空时返回 null，
 *   否则取 backoff[attempts.clamp(0, backoff.length - 1)]；
 * - [reset] 显式重置（可同时切换到指定 songId）。
 */
class PlaybackRecoveryBudget(
    val maxAttempts: Int = 3,
    val backoff: List<Duration> = listOf(30.seconds, 60.seconds, 120.seconds),
) {
    private var songId: String? = null
    private var _attempts = 0

    val attempts: Int get() = _attempts

    /** 开始一次恢复尝试；返回 false 时本歌曲自动预算已耗尽。 */
    fun tryConsume(songId: String): Boolean {
        if (this.songId != songId) reset(songId)
        if (_attempts >= maxAttempts) return false
        _attempts++
        return true
    }

    /** 失败后下次后台重试等待时间；耗尽后返回 null。 */
    val nextDelay: Duration?
        get() {
            if (_attempts >= maxAttempts || backoff.isEmpty()) return null
            val index = _attempts.coerceIn(0, backoff.size - 1)
            return backoff[index]
        }

    fun reset(songId: String? = null) {
        this.songId = songId
        _attempts = 0
    }
}
