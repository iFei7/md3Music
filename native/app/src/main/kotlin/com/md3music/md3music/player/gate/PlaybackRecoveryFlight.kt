package com.md3music.md3music.player.gate

/**
 * 后台自动恢复任务的单飞与代次状态。
 *
 * 1:1 移植自 lib/providers/playback_recovery_flight.dart（31 行，全文移植）。
 *
 * 单独建模 token 生命周期，避免旧任务的 finally 释放后来启动的新任务。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - 初始 sequence = 0、inFlightToken = null；
 * - [tryStart] 在无占位时前置自增 sequence 并占用，返回 token；已有占位返回 null；
 * - [isCurrent] 判断 token 是否等于当前 sequence（注意：定时器代次比较用
 *   sequence，占位释放不改变 sequence）；
 * - [invalidate] 自增 sequence；releaseInFlight = true 时同时释放占位
 *   （立即接管场景）；
 * - [releaseIfOwned] 仅当占位仍属于该 token 时才释放，旧任务 finally
 *   不会误释新任务。
 */
class PlaybackRecoveryFlight {
    private var _sequence = 0

    /** 当前恢复代次。 */
    val sequence: Int get() = _sequence

    /** 当前占位中的恢复任务 token；无任务在飞时为 null。 */
    var inFlightToken: Int? = null
        private set

    /** 开始一个恢复任务；已有任务未释放时返回 null。 */
    fun tryStart(): Int? {
        if (inFlightToken != null) return null
        val token = ++_sequence
        inFlightToken = token
        return token
    }

    fun isCurrent(token: Int): Boolean = token == _sequence

    /** 使当前恢复任务和已排期定时器失效；需要立即接管时同时释放占位。 */
    fun invalidate(releaseInFlight: Boolean = false) {
        _sequence++
        if (releaseInFlight) inFlightToken = null
    }

    /** 只有占有当前占位的任务才能释放它。 */
    fun releaseIfOwned(token: Int) {
        if (inFlightToken == token) inFlightToken = null
    }
}
