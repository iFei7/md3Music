package com.gracemusic.player.store

import com.gracemusic.player.state.PlaybackState

/**
 * 一次归约的输出：**新状态快照 + 待执行效果列表**。
 *
 * 归约器（[PlaybackReducer]）对每个意图/事件返回本值；PlaybackStore 先发布
 * [state] 再按序执行 [effects]。把「状态迁移」与「副作用」绑成一个不可变值，
 * 使得：
 *
 * 1. **可单测**：纯函数输入输出，断言状态与效果各栏即可，不需要假引擎；
 * 2. **可重放**：同一 (state, intent/event) 序列必然得到同一输出（随机子路径
 *    除外，随机源经 [PlaybackReducer.reduce] 的 `random` 参数注入）；
 * 3. **效果不丢**：非法操作返回 [state] 不变 + 空效果（明确拒绝），而非抛异常
 *    或静默执行一半。
 *
 * 空效果列表统一用 [emptyList]（不用 null、不用可变 list），便捷工厂
 * [invoke] 免去手写 `emptyList()`。
 */
data class PlaybackTransition(
    val state: PlaybackState,
    val effects: List<PlaybackEffect>,
) {
    companion object {
        /** 仅有状态迁移、无副作用。 */
        operator fun invoke(state: PlaybackState): PlaybackTransition =
            PlaybackTransition(state, emptyList())

        /** 状态迁移 + 若干效果（零个时等价于上一个重载）。 */
        operator fun invoke(state: PlaybackState, vararg effects: PlaybackEffect): PlaybackTransition =
            PlaybackTransition(state, effects.toList())
    }
}
