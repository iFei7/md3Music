package com.gracemusic.player.model

/**
 * 将播放域内部错误收敛为可展示文案，避免原始异常、URL 或平台细节进入 UI。
 *
 * 1:1 移植自 lib/providers/player_provider.dart:120-133 的
 * `safePlaybackErrorMessage`。Dart 原文：
 *
 * ```dart
 * String? safePlaybackErrorMessage(String? error) {
 *   if (error == null || error.isEmpty) return null;
 *   return switch (error) {
 *     '该章节为 听书VIP单独付费内容' => '该听书章节需要单独购买',
 *     '无法获取播放链接' => '无法获取播放链接，请重试',
 *     '播放失败，请检查网络' => '播放失败，请检查网络后重试',
 *     '播放恢复失败，请稍后重试' => '播放恢复失败，请重试',
 *     '无法获取云盘播放链接' => '无法获取云盘播放链接，请重试',
 *     '音频引擎尚未就绪' => '播放器尚未就绪，请重试',
 *     _ => '播放失败，请重试',
 *   };
 * }
 * ```
 *
 * **注意第三行左侧的「听书VIP」中间有一个空格**（`听书VIP单独付费内容`）：
 * 这是 Dart 侧的字面量原样，发送方（`_resolveAndPlayCurrentSongImpl`）
 * 写出的也是同一串。迁移时不要去「顺手修正」它，否则映射失效、文案退化成
 * 兜底的「播放失败，请重试」，用户看不到「需单独购买」的准确提示。
 *
 * **未知错误一律折叠**为「播放失败，请重试」——原始串可能含 URL/异常堆栈，
 * 直接上屏属于信息泄漏。
 */
fun safePlaybackErrorMessage(error: String?): String? {
    if (error.isNullOrEmpty()) return null
    return when (error) {
        "该章节为 听书VIP单独付费内容" -> "该听书章节需要单独购买"
        "无法获取播放链接" -> "无法获取播放链接，请重试"
        "播放失败，请检查网络" -> "播放失败，请检查网络后重试"
        "播放恢复失败，请稍后重试" -> "播放恢复失败，请重试"
        "无法获取云盘播放链接" -> "无法获取云盘播放链接，请重试"
        "音频引擎尚未就绪" -> "播放器尚未就绪，请重试"
        else -> "播放失败，请重试"
    }
}
