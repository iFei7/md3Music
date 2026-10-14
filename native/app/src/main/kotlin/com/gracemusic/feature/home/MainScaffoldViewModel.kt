package com.gracemusic.feature.home

import androidx.lifecycle.ViewModel
import com.gracemusic.player.store.PlaybackStore
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject

/**
 * 主壳极薄 ViewModel（P3-A 的首个 `@HiltViewModel`）。
 *
 * 职责仅一件事：把进程级单例 [PlaybackStore] 暴露给主壳组合
 * （[MainScaffold] 经 `hiltViewModel()` 获取）。MVI 约束不变：UI 只读
 * `store.state` / `store.position` 并直接派发 [PlaybackIntent]，
 * 本类不持有可变状态、不经手播放引擎。
 *
 * TODO(P3-B): 随搜索数据链路扩展（搜索状态、点歌入队用例上移到 VM 层）。
 */
@HiltViewModel
class MainScaffoldViewModel @Inject constructor(
    val store: PlaybackStore,
) : ViewModel()
