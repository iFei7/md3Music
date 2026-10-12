package com.gracemusic.player.gate

import com.gracemusic.data.model.Song
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/**
 * [PlaylistPrefetchTicket] 移植锁测试。
 *
 * 场景对标 test/providers/playlist_prefetch_ticket_test.dart：
 * - 相同队列、账号、音质与条目时允许提交；
 * - 队列清空、替换或重排后的旧请求均不可提交；
 * - 切换账号或音质后旧结果不可提交；
 * - 不会给同 ID 的不同专辑条目或已有 URL 的条目提交；
 * - 相同条目的重复队列项仍可复用同一预取 URL。
 */
class PlaylistPrefetchTicketTest {

    private fun song(
        id: String = "track",
        albumId: String? = "album",
        url: String? = null,
        isOnline: Boolean = true,
    ) = Song(
        id = id,
        title = "title-$id",
        artist = "artist",
        album = "album",
        duration = 0.seconds,
        albumId = albumId,
        albumAudioId = albumId?.let { "audio-$it" },
        url = url,
        isOnline = isOnline,
    )

    private val target = song()

    private val ticket = PlaylistPrefetchTicket(
        queueRevision = 4,
        quality = "lossless",
        userId = "user-1",
        song = target,
    )

    private fun canCommit(
        revision: Int = 4,
        quality: String = "lossless",
        userId: String? = "user-1",
        playlist: List<Song>? = null,
    ) = ticket.canCommit(
        currentQueueRevision = revision,
        currentQuality = quality,
        currentUserId = userId,
        currentPlaylist = playlist ?: listOf(target),
    )

    @Test
    fun `相同队列、账号、音质与条目时允许提交`() {
        assertTrue(canCommit())
    }

    @Test
    fun `队列替换后的旧请求不可提交`() {
        assertFalse(canCommit(revision = 5))
        assertFalse(canCommit(revision = 5, playlist = listOf(song(id = "other"))))
    }

    @Test
    fun `切换账号或音质后旧结果不可提交`() {
        assertFalse(canCommit(userId = "user-2"))
        assertFalse(canCommit(quality = "high"))
    }

    @Test
    fun `不会给同ID的不同专辑条目或已有URL的条目提交`() {
        assertFalse(canCommit(playlist = listOf(song(albumId = "different-album"))))
        assertFalse(canCommit(playlist = listOf(song(url = "https://cdn.invalid/audio"))))
    }

    @Test
    fun `相同条目的重复队列项仍可复用同一预取URL`() {
        assertTrue(canCommit(playlist = listOf(target, song())))
    }

    @Test
    fun `本地歌曲或userId不匹配时不可提交`() {
        assertFalse(canCommit(playlist = listOf(song(isOnline = false))))
        assertFalse(canCommit(userId = null))
    }
}
