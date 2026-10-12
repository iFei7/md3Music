package com.md3music.md3music.player.gate

import kotlin.time.Duration

/**
 * 只把本次请求基线之后的平台位置增长认作真实播放进度。
 *
 * 1:1 移植自 lib/providers/playback_progress_gate.dart（32 行，全文移植）。
 *
 * 播放/恢复命令已发出只表示用户意图，不代表解码器已经推进位置。此闸门
 * 忽略恢复时重发的当前位置、旧请求的位置事件，以及同一请求的后续采样。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - [begin] 重设 request / baseline，并清零 reported 一次性标志；
 * - [observe] 仅在「request 匹配 + 未上报过 + platformPosition > baseline」
 *   （严格大于，等于基线不算推进）时返回 true，且同一请求只上报一次；
 * - [isPending] 表示请求已登记且尚未观察到真实推进；
 * - [reset] 回到初始态（request = null）。
 */
class PlaybackProgressGate {
    private var request: Int? = null
    private var baseline: Duration = Duration.ZERO
    private var reported = false

    fun begin(request: Int, baseline: Duration) {
        this.request = request
        this.baseline = baseline
        reported = false
    }

    /** 首次观察到当前请求的位置超过基线时返回 true。 */
    fun observe(request: Int, platformPosition: Duration): Boolean {
        if (request != this.request || reported || platformPosition <= baseline) {
            return false
        }
        reported = true
        return true
    }

    fun isPending(request: Int): Boolean = this.request == request && !reported

    fun reset() {
        this.request = null
        baseline = Duration.ZERO
        reported = false
    }
}
