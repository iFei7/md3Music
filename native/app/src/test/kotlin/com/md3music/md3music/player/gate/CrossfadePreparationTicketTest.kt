package com.md3music.md3music.player.gate

import com.md3music.md3music.data.model.Song
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/**
 * [CrossfadePreparationTicket] 移植锁测试。
 *
 * 场景对标 test/providers/crossfade_preparation_ticket_test.dart：
 * - 只有原曲间身份仍有效时才允许提交；
 * - 目标被移除、重排或同 ID 替换为不同专辑版本时丢弃。
 */
class CrossfadePreparationTicketTest {

    private fun song(
        id: String,
        albumId: String? = null,
        albumAudioId: String? = null,
    ) = Song(
        id = id,
        title = "title-$id",
        artist = "artist",
        album = "album",
        duration = 0.seconds,
        url = "https://media.example/$id.mp3",
        isOnline = true,
        albumId = albumId,
        albumAudioId = albumAudioId,
    )

    private val current = song("current")

    private val target = song("next", albumId = "album-1", albumAudioId = "audio-1")

    private val ticket = CrossfadePreparationTicket(
        generation = 3,
        queueRevision = 8,
        currentIndex = 0,
        currentSongId = current.id,
        targetIndex = 1,
        targetSong = target,
    )

    private fun canCommit(
        generation: Int = 3,
        queueRevision: Int = 8,
        currentIndex: Int = 0,
        currentSongId: String? = "current",
        playlist: List<Song>? = null,
    ) = ticket.canCommit(
        currentGeneration = generation,
        currentQueueRevision = queueRevision,
        currentIndex = currentIndex,
        currentSongId = currentSongId,
        playlist = playlist ?: listOf(current, target),
    )

    @Test
    fun `只有原曲间身份仍有效时才允许提交`() {
        assertTrue(canCommit())
        assertFalse(canCommit(generation = 4))
        assertFalse(canCommit(queueRevision = 9))
        assertFalse(canCommit(currentIndex = 1))
        assertFalse(canCommit(currentSongId = "replaced"))
    }

    @Test
    fun `目标被移除、重排或同ID替换为不同专辑版本时丢弃`() {
        assertFalse(canCommit(playlist = listOf(current)))
        assertFalse(canCommit(playlist = listOf(target, current)))
        assertFalse(
            canCommit(
                playlist = listOf(
                    current,
                    song("next", albumId = "album-2"),
                ),
            ),
        )
    }
}
