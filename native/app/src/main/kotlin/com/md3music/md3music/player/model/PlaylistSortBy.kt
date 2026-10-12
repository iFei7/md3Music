package com.md3music.md3music.player.model

import com.md3music.md3music.data.model.Song

/**
 * 队列排序维度（播放列表面板的排序菜单）。
 *
 * 1:1 移植自 lib/providers/player_provider.dart:94 的 enum PlaylistSortBy。
 */
enum class PlaylistSortBy {
    /** 保持当前播放顺序，即不排序（`sortPlaylist` 见此值直接返回）。 */
    QUEUE,

    /** 按标题（[Song.displayName]，大小写无关）排序。 */
    TITLE,

    /** 按时长排序。 */
    DURATION,
}

/**
 * 排序比较器，1:1 移植自 player_provider.dart:5078-5096（`sortPlaylist` 的 sort 闭包）：
 *
 * ```dart
 * final int cmp;
 * switch (by) {
 *   case PlaylistSortBy.title:
 *     cmp = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
 *     break;
 *   case PlaylistSortBy.duration:
 *     cmp = a.duration.compareTo(b.duration);
 *     break;
 *   case PlaylistSortBy.queue:
 *     cmp = 0;
 *     break;
 * }
 * return ascending ? cmp : -cmp;
 * ```
 *
 * **三处刻意保留的细节**：
 * 1. 标题比较用 [Song.displayName]（已剥离 `.mp3` 等扩展名）而非 [Song.title]——
 *    与歌单页排序口径一致；
 * 2. [PlaylistSortBy.QUEUE] 的比较结果为 0（恒等），即「不重排」；
 * 3. 降序是**取反结果**（`-cmp`）而不是交换参数，与 Dart 逐字对应。
 *
 * **与 Dart 的两点已知差异（均为无害改进，此处显式记录）**：
 * - 大小写折叠：Dart 用 `String.toLowerCase()`，Kotlin 用 [String.lowercase]。
 *   两者都是 locale 无关的 Unicode 默认折叠，仅在极少数特殊码位上有差别。
 * - 稳定性：Dart `List.sort` 文档明示「不保证稳定」，Kotlin [List.sortedWith]
 *   底层是 TimSort（稳定）。相等键的相对顺序在 native 侧比 lite 更可预测，
 *   排序结果不会因此错乱。
 */
fun PlaylistSortBy.comparator(ascending: Boolean = true): Comparator<Song> {
    val base: Comparator<Song> = when (this) {
        PlaylistSortBy.QUEUE -> Comparator { _, _ -> 0 }
        PlaylistSortBy.TITLE -> Comparator { a, b ->
            a.displayName.lowercase().compareTo(b.displayName.lowercase())
        }
        PlaylistSortBy.DURATION -> Comparator { a, b -> a.duration.compareTo(b.duration) }
    }
    return if (ascending) base else base.reversed()
}

/**
 * 队列是否可排序：`PlaylistSortBy.queue`（顺序即播放顺序，无需重排）或
 * 队列元素少于 2 个时直接跳过。
 *
 * 1:1 移植自 player_provider.dart:5070（`sortPlaylist` 的首行守卫）：
 * ```dart
 * if (by == PlaylistSortBy.queue || _playlist.length < 2) return;
 * ```
 */
fun PlaylistSortBy.isNoOpFor(playlistSize: Int): Boolean =
    this == PlaylistSortBy.QUEUE || playlistSize < 2
