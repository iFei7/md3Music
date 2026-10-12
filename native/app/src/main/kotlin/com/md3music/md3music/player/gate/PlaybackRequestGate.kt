package com.md3music.md3music.player.gate

/**
 * 播放请求的 latest-wins 闸门。
 *
 * 1:1 移植自 lib/providers/playback_request_gate.dart（16 行，全文移植）。
 *
 * 背景：播放链接解析、setUrl 和等待 ready 都是异步操作。用户切歌或暂停后，
 * 旧请求即使稍后完成，也不能再把播放器重新拉起。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - 初始 generation = 0；
 * - [issue] 与 [invalidate] 均为前置自增（Dart `++_generation`）后返回新代次；
 * - [isCurrent] 仅当传入代次等于当前最新代次时为真。
 */
class PlaybackRequestGate {
    private var generation = 0

    /** 开始一个新的播放请求，并使之前的请求失效。 */
    fun issue(): Int = ++generation

    /** 取消当前请求，但不开始新的播放请求。 */
    fun invalidate(): Int = ++generation

    /** 判断请求是否仍是最新请求。 */
    fun isCurrent(generation: Int): Boolean = generation == this.generation
}
