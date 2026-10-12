package com.gracemusic.player.model

/**
 * 应用层循环模式（播放器底部模式按钮的三态之一）。
 *
 * 1:1 移植自 lib/providers/player_provider.dart:54 的 enum AppLoopMode。
 *
 * **与播放引擎的关系（关键语义，player_provider.dart:1397-1402）**：
 * Dart 侧 just_audio 的 LoopMode 恒设为 off——项目通过 setUrl 加载单一
 * AudioSource，LoopMode.one/all 在单 source 下会自动循环且不触发 completed
 * 事件，导致应用层 _handlePlaybackCompleted 无法接管切歌。循环逻辑完全由
 * 应用层本枚举 + _handlePlaybackCompleted 控制。native 侧（Media3/ExoPlayer）
 * 移植时应保持同一约定：引擎循环恒关，重复播放由播放器状态层实现。
 */
enum class AppLoopMode {
    /** 不循环：播完当前按 _handlePlaybackCompleted 的队列边界规则停止或结束。 */
    OFF,

    /** 单曲循环：当前歌曲播完后重播当前歌曲。 */
    ONE,

    /** 列表循环：播完最后一首回到第一首。 */
    ALL,
    ;

    companion object {
        /**
         * 从持久化名称恢复模式（大小写敏感精确匹配），无法识别时回落 [OFF]。
         *
         * 1:1 移植自 player_provider.dart:1374-1377（恢复播放状态时）：
         * ```dart
         * _loopMode = AppLoopMode.values.firstWhere(
         *   (m) => m.name == state.loopMode, orElse: () => AppLoopMode.off);
         * ```
         */
        fun fromStoredName(name: String?): AppLoopMode =
            entries.firstOrNull { it.name == name } ?: OFF
    }
}

/**
 * 模式按钮的切换循环：不循环 → 列表循环 → 单曲循环 → 不循环。
 *
 * 1:1 移植自 player_provider.dart:5143-5153（toggleLoopMode 的 switch）：
 * ```dart
 * case AppLoopMode.off:  await _applyLoopMode(AppLoopMode.all);
 * case AppLoopMode.all:  await _applyLoopMode(AppLoopMode.one);
 * case AppLoopMode.one:  await _applyLoopMode(AppLoopMode.off);
 * ```
 */
fun AppLoopMode.toggled(): AppLoopMode =
    when (this) {
        AppLoopMode.OFF -> AppLoopMode.ALL
        AppLoopMode.ALL -> AppLoopMode.ONE
        AppLoopMode.ONE -> AppLoopMode.OFF
    }
