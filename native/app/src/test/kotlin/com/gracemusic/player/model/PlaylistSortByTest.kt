package com.gracemusic.player.model

import com.gracemusic.testutil.testSong
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaylistSortBy] 与比较器的移植锁测试。
 *
 * 对标 lib/providers/player_provider.dart：
 * - 94 行 enum 三值（queue / title / duration）；
 * - 5070 行 `if (by == PlaylistSortBy.queue || _playlist.length < 2) return;`
 * - 5078-5096 行 sort 闭包（标题按 displayName 折叠大小写、时长按 Duration、
 *   queue 恒等、降序取反）。
 */
class PlaylistSortByTest {

    @Test
    fun `三值与 Dart 一致`() {
        assertEquals(listOf("QUEUE", "TITLE", "DURATION"), PlaylistSortBy.entries.map { it.name })
    }

    @Test
    fun `跳过守卫_播放顺序维度恒跳过`() {
        assertTrue(PlaylistSortBy.QUEUE.isNoOpFor(10))
        assertTrue(PlaylistSortBy.QUEUE.isNoOpFor(1))
    }

    @Test
    fun `跳过守卫_不足两首时一律跳过`() {
        assertTrue(PlaylistSortBy.TITLE.isNoOpFor(0))
        assertTrue(PlaylistSortBy.TITLE.isNoOpFor(1))
        assertTrue(PlaylistSortBy.DURATION.isNoOpFor(1))
        assertFalse(PlaylistSortBy.TITLE.isNoOpFor(2))
        assertFalse(PlaylistSortBy.DURATION.isNoOpFor(2))
    }

    @Test
    fun `播放顺序维度比较器恒等`() {
        val cmp = PlaylistSortBy.QUEUE.comparator()
        assertEquals(0, cmp.compare(testSong("b", title = "zzz"), testSong("a", title = "aaa")))
    }

    @Test
    fun `标题比较剥离扩展名并忽略大小写`() {
        val cmp = PlaylistSortBy.TITLE.comparator()
        // displayName：Beta.mp3 → Beta；alpha.flac → alpha
        assertTrue(cmp.compare(testSong("1", title = "Beta.mp3"), testSong("2", title = "alpha.flac")) > 0)
        assertTrue(cmp.compare(testSong("1", title = "alpha.flac"), testSong("2", title = "Beta.mp3")) < 0)
        // 仅扩展名不同 → displayName 相同 → 相等
        assertEquals(0, cmp.compare(testSong("1", title = "same.mp3"), testSong("2", title = "same.flac")))
    }

    @Test
    fun `时长比较按毫秒序`() {
        val cmp = PlaylistSortBy.DURATION.comparator()
        assertTrue(cmp.compare(testSong("1", duration = 4.minutes), testSong("2", duration = 3.seconds)) > 0)
        assertEquals(0, cmp.compare(testSong("1", duration = 10.seconds), testSong("2", duration = 10.seconds)))
    }

    @Test
    fun `降序为结果取反`() {
        val a = testSong("1", title = "a")
        val b = testSong("2", title = "b")
        val asc = PlaylistSortBy.TITLE.comparator(ascending = true)
        val desc = PlaylistSortBy.TITLE.comparator(ascending = false)

        assertTrue(asc.compare(a, b) < 0)
        assertTrue(desc.compare(a, b) > 0)
        // 相等键取反仍是 0
        assertEquals(0, desc.compare(a, testSong("3", title = "a")))
    }

    @Test
    fun `排序行为与比较器一致`() {
        val songs = listOf(
            testSong("1", title = "b.mp3", duration = 30.seconds),
            testSong("2", title = "A.flac", duration = 10.seconds),
            testSong("3", title = "c", duration = 20.seconds),
        )
        assertEquals(
            listOf("2", "1", "3"),
            songs.sortedWith(PlaylistSortBy.TITLE.comparator()).map { it.id },
        )
        assertEquals(
            listOf("2", "3", "1"),
            songs.sortedWith(PlaylistSortBy.DURATION.comparator()).map { it.id },
        )
    }
}
