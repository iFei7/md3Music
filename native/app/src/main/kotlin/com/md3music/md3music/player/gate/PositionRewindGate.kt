package com.md3music.md3music.player.gate

import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * 位置回退闸门：抑制「换源装载期间位置从 0 重新计数」造成的假回退。
 *
 * 1:1 移植自 lib/providers/position_rewind_gate.dart（63 行，全文移植）。
 *
 * 背景：`just_audio` 的 `setUrl`（换源）会让播放器位置从 0 重新开始，直到随后
 * 的 `seek` 落地。这段窗口（`_setUrlAndPlay` 等 `ready` 最长 10s，再 seek）里
 * 若把这个 0 当作真实进度发布给 UI，会出现两类问题：
 * - 进度条 / 时间文字闪回 0:00；
 * - 歌词视图把行号判成第一行 → 滚动目标跳到「歌词开头」，装载完成后从开头
 *   长距离滚回当前行（用户看到的就是「暂停后歌词从头滚到当前行」）。
 *
 * 闸门语义：装载前 [arm]（以即将 seek 到的目标为下限），装载期间小于下限的
 * 采样被 [shouldSuppress] 判为假回退而丢弃；`seek` 落地后由调用方 [disarm]
 * 放行。内置 [TIMEOUT] 兜底：装载卡死超过时限时自动放行，避免位置永久冻结。
 *
 * 详见 docs/2026-09-11-pause-lyric-scroll-from-top-analysis.md（方案 A）。
 *
 * 与 Dart 的差异：时间戳用 epoch 毫秒（[System.currentTimeMillis]）代替
 * DateTime，比较精度对 12s 超时判定无影响；`now` 参数默认取当前时间，
 * 测试可注入虚拟时间，无需 sleep。
 */
class PositionRewindGate {
    /** 闸门是否处于开启状态（诊断 / 测试用）。 */
    var armed: Boolean = false
        private set

    /** 当前下限：装载结束后预计到达的位置（诊断 / 测试用）。 */
    var floor: Duration = Duration.ZERO
        private set

    private var armedAt: Long? = null

    /**
     * 开启闸门。
     *
     * [floor] 为即将 seek 到的目标位置（= 装载后的真实进度）。
     * `floor <= 0` 表示没有明确目标（例如换源后确实要从 0 开始播），此时不开启。
     */
    fun arm(floor: Duration, now: Long = System.currentTimeMillis()) {
        if (floor <= Duration.ZERO) {
            disarm()
            return
        }
        armed = true
        this.floor = floor
        armedAt = now
    }

    /** 关闭闸门：`seek` 落地、装载结束（含失败/异常）时调用。 */
    fun disarm() {
        armed = false
        floor = Duration.ZERO
        armedAt = null
    }

    /**
     * 判断本次位置采样是否为「换源假回退」，需要丢弃。
     *
     * 仅在「开启中 + 采样小于下限 + 未超时」时返回 true；超时则自动关闭闸门并
     * 放行（装载卡死不能让对外位置永久冻结）。超时判定为严格大于
     * （Dart：`difference(at) > timeout`）。
     */
    fun shouldSuppress(value: Duration, now: Long = System.currentTimeMillis()): Boolean {
        if (!armed) return false
        val at = armedAt ?: now
        if ((now - at).milliseconds > TIMEOUT) {
            disarm()
            return false
        }
        return value < floor
    }

    companion object {
        /** 闸门最长保持时间：`_setUrlAndPlay` 等 `ready` 的上限约 10s，留出余量。 */
        val TIMEOUT: Duration = 12.seconds
    }
}
