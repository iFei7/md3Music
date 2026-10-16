package com.gracemusic.player.offline

/**
 * 离线「前进」候选过滤的**纯策略**（S-B §4.1）——零 I/O、零协程、零 Android 依赖。
 *
 * ## 职责边界（只做「选谁」，不做「怎么查」）
 * 输入 = 既有候选枚举 [com.gracemusic.player.queue.PlaybackQueue.nextCandidateIndices]
 * 产出的候选下标序列（该序列**已封装**循环 / 随机 / 队尾截断语义）+ 一个「某下标是否
 * 已缓存」的**同步谓词**；输出 = [Decision.Play]（首个已缓存候选）或 [Decision.Stop]
 * （无任何可播缓存）。
 *
 * 本类**不**推导队列索引算术（交接文档铁律 §4-7：索引算术必须逐行模拟 Dart，
 * 由 `PlaybackQueue` 独家承担）。「怎么查缓存」是挂起的 I/O，属
 * [PlaybackCacheResolver]，由 `PlaybackStore` 的受控执行器按候选**惰性**查询后，
 * 用本策略做最终决策。
 *
 * ## 边界（必须明确，见 S-B §4.1）
 * - **空候选列表**（空队列 / 单曲 / 无效索引）→ [Decision.Stop]；
 * - **候选全未缓存** → [Decision.Stop]；
 * - **负下标一律不进入谓词**（防御性契约：真实来源不会产出负值，但绝不把无效下标
 *   当成命中）；
 * - 首个命中即返回（[cachedOf] 不会被调用到命中之后的下标——短路语义，见单测）。
 *
 * ## 为什么 `cachedOf` 是同步谓词（而非 suspend）
 * 契约建议保持「纯函数、无 I/O、无协程」。真实缓存查询
 * （[PlaybackCacheResolver.resolveCachedSource]）是挂起 I/O，故由调用方
 * （`PlaybackStore`）逐候选挂起查询、把命中结果填进一个表，再以该表为谓词调用
 * [choose]——**惰性短路由调用方保证**（首个命中即停止查询），本策略保持纯粹、
 * 可纯单测、可重放。
 */
object OfflineAdvancePolicy {

    /** 离线前进的决策结果。 */
    sealed interface Decision {

        /** 切到 [index] 并继续播放（首个已缓存候选）。 */
        data class Play(val index: Int) : Decision

        /** 无可播缓存：停止播放（保留队列 + 错误态，见 `PlaybackIntent.OfflineNoPlayableCache`）。 */
        data object Stop : Decision
    }

    /**
     * 在 [candidates]（按既定顺序）中选出**首个** [cachedOf] 为真的下标。
     *
     * @param candidates 候选下标序列（来自 `PlaybackQueue.nextCandidateIndices()`，
     *   或单曲循环语义下的「当前曲」单元素序列）。
     * @param cachedOf 「该下标是否已缓存」的同步谓词（纯、无副作用）。
     * @return 首个命中 → [Decision.Play]；[candidates] 为空或全未命中 → [Decision.Stop]。
     */
    fun choose(candidates: List<Int>, cachedOf: (Int) -> Boolean): Decision {
        for (index in candidates) {
            // 负下标一律不进入谓词（防御性契约，见 `OfflineAdvancePolicyTest`）：
            // 真实来源 `PlaybackQueue.nextCandidateIndices()` 在 `n <= 1` 或
            // `currentIndex < 0` 时即返回空表，正常不会产出负值；此处显式拦住，
            // 是为了让「无效下标」绝不可能被当成命中——它既对应不了任何队列项，
            // `PlayAt(-1)` 也只会走归约器的越界分支，属无意义结果。
            if (index < 0) continue
            if (cachedOf(index)) return Decision.Play(index)
        }
        return Decision.Stop
    }
}
