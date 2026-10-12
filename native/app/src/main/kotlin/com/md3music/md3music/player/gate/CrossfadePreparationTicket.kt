package com.md3music.md3music.player.gate

/**
 * 交叉淡化备用源的提交凭据，确保异步准备仍属于当前曲间过渡。
 *
 * 1:1 移植自 lib/providers/crossfade_preparation_ticket.dart（41 行，全文移植）。
 *
 * 语义契约（与 Dart 逐值一致）：
 * - generation / queueRevision / currentIndex / currentSongId 必须与当前
 *   过渡身份逐一相等；
 * - targetIndex 必须在 [0, playlist.size) 内（越界不提交）；
 * - playlist[targetIndex] 的 id / albumId / albumAudioId 必须与
 *   [targetSong] 相等（同 ID 不同专辑版本视为不同曲目）。
 */
data class CrossfadePreparationTicket(
    val generation: Int,
    val queueRevision: Int,
    val currentIndex: Int,
    val currentSongId: String?,
    val targetIndex: Int,
    val targetSong: Song,
) {
    fun canCommit(
        currentGeneration: Int,
        currentQueueRevision: Int,
        currentIndex: Int,
        currentSongId: String?,
        playlist: List<Song>,
    ): Boolean {
        if (generation != currentGeneration ||
            queueRevision != currentQueueRevision ||
            this.currentIndex != currentIndex ||
            this.currentSongId != currentSongId ||
            targetIndex < 0 ||
            targetIndex >= playlist.size
        ) {
            return false
        }
        val target = playlist[targetIndex]
        return target.id == targetSong.id &&
            target.albumId == targetSong.albumId &&
            target.albumAudioId == targetSong.albumAudioId
    }
}
