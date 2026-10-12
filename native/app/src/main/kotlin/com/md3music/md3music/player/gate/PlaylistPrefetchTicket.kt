package com.md3music.md3music.player.gate

/**
 * 后台预取结果的提交凭据，避免过期 URL 写入后来被挪到相同索引的歌曲。
 *
 * 1:1 移植自 lib/providers/playlist_prefetch_ticket.dart（37 行，全文移植）。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - queueRevision / quality / userId 三项必须与当前值逐一相等（userId 可空，
 *   按相等性比较，不区分「未登录」与「空串」之外的语义）；
 * - 当前播放列表中必须存在一个条目同时满足：isOnline、id / albumId /
 *   albumAudioId 与票务歌曲相等、url 仍为 null（尚未写入 URL）；
 * - 满足任一即提交（`any`），相同条目的重复队列项可复用同一预取 URL。
 */
data class PlaylistPrefetchTicket(
    val queueRevision: Int,
    val quality: String,
    val userId: String?,
    val song: Song,
) {
    fun canCommit(
        currentQueueRevision: Int,
        currentQuality: String,
        currentUserId: String?,
        currentPlaylist: List<Song>,
    ): Boolean {
        if (queueRevision != currentQueueRevision ||
            quality != currentQuality ||
            userId != currentUserId
        ) {
            return false
        }
        return currentPlaylist.any { candidate ->
            candidate.isOnline &&
                candidate.id == song.id &&
                candidate.albumId == song.albumId &&
                candidate.albumAudioId == song.albumAudioId &&
                candidate.url == null
        }
    }
}
