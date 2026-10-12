package com.gracemusic.player.gate

/**
 * just_audio 用此代码表示一次加载被后续 setUrl 中断，属于快速切歌的正常信号。
 *
 * 1:1 移植自 lib/providers/playback_error_event_gate.dart:2。
 */
const val INTERRUPTED_PLAYER_LOAD_ERROR_CODE = 10000000

/**
 * 只有当前请求已经装载成功后的错误才转成可见播放失败。
 *
 * 1:1 移植自 lib/providers/playback_error_event_gate.dart:8-15。
 *
 * 装载阶段错误由对应 setUrl Future 返回给调用方处理；过期请求的错误事件
 * 不能覆盖新曲目状态。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - errorCode == [INTERRUPTED_PLAYER_LOAD_ERROR_CODE]（切歌中断）直接忽略；
 * - 其余要求 isCurrentRequest && loadCompleted 同时为真。
 */
fun shouldHandlePlaybackErrorEvent(
    errorCode: Int,
    isCurrentRequest: Boolean,
    loadCompleted: Boolean,
): Boolean {
    if (errorCode == INTERRUPTED_PLAYER_LOAD_ERROR_CODE) return false
    return isCurrentRequest && loadCompleted
}
