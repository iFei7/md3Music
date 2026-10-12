package com.gracemusic.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * [Song] 移植锁测试。
 *
 * 场景对标 Dart 侧：
 * - test/data/unknown_artist_test.dart（isUnknownArtist 与占位常量）；
 * - lib/data/models/song.dart 内 displayDuration / displayName / == 的语义。
 */
class SongTest {

    private fun song(
        id: String = "s1",
        title: String = "夜曲",
        artist: String = "周杰伦",
        album: String = "十一月的萧邦",
        duration: kotlin.time.Duration = 239.seconds,
        url: String? = null,
        isOnline: Boolean = true,
        albumId: String? = "album-1",
        albumAudioId: String? = "audio-1",
    ) = Song(
        id = id,
        title = title,
        artist = artist,
        album = album,
        duration = duration,
        url = url,
        isOnline = isOnline,
        albumId = albumId,
        albumAudioId = albumAudioId,
    )

    @Test
    fun `必填字段按值构造且可空字段与布尔默认值正确`() {
        val minimal = Song(
            id = "s1",
            title = "夜曲",
            artist = "周杰伦",
            album = "十一月的萧邦",
            duration = 239.seconds,
        )
        assertEquals("s1", minimal.id)
        assertEquals(239.seconds, minimal.duration)
        assertFalse(minimal.isOnline)
        assertFalse(minimal.isCloud)
        assertFalse(minimal.isLocallyFavorited)
        assertFalse(minimal.isLongAudio)
        assertEquals(null, minimal.url)
        assertEquals(null, minimal.localPath)
        assertEquals(null, minimal.artworkUri)
        assertEquals(null, minimal.albumId)
        assertEquals(null, minimal.artistId)
        assertEquals(null, minimal.quality)
        assertEquals(null, minimal.albumAudioId)
        assertEquals(null, minimal.fileId)
        assertEquals(null, minimal.climaxStart)
        assertEquals(null, minimal.climaxEnd)
        assertEquals(null, minimal.bpm)
        assertEquals(null, minimal.loudnessLufs)
        assertEquals(null, minimal.loudnessPeakDb)
    }

    @Test
    fun `全部可选字段可显式赋值`() {
        val full = song().copy(
            localPath = "/music/s1.mp3",
            artworkUri = "https://img.invalid/s1.jpg",
            artistId = "artist-1",
            quality = "flac",
            fileId = 42,
            isCloud = true,
            climaxStart = 12.5,
            climaxEnd = 45.0,
            bpm = 96,
            isLocallyFavorited = true,
            isLongAudio = true,
            loudnessLufs = -9.5,
            loudnessPeakDb = -1.0,
        )
        assertEquals("/music/s1.mp3", full.localPath)
        assertEquals("https://img.invalid/s1.jpg", full.artworkUri)
        assertEquals("artist-1", full.artistId)
        assertEquals("flac", full.quality)
        assertEquals(42, full.fileId)
        assertTrue(full.isCloud)
        assertEquals(12.5, full.climaxStart!!, 1e-9)
        assertEquals(45.0, full.climaxEnd!!, 1e-9)
        assertEquals(96, full.bpm)
        assertTrue(full.isLocallyFavorited)
        assertTrue(full.isLongAudio)
        assertEquals(-9.5, full.loudnessLufs!!, 1e-9)
        assertEquals(-1.0, full.loudnessPeakDb!!, 1e-9)
    }

    @Test
    fun `displayDuration 按分秒两位展示`() {
        assertEquals("00:00", song(duration = 0.seconds).displayDuration)
        assertEquals("01:05", song(duration = 65.seconds).displayDuration)
        assertEquals("09:59", song(duration = 599.seconds).displayDuration)
        assertEquals("02:05", song(duration = 125.seconds).displayDuration)
    }

    @Test
    fun `displayDuration 分钟按 60 回绕（Dart inMinutes remainder 60 语义）`() {
        // 1 小时整：分钟 60 % 60 = 0 → "00:00"（小时位丢失是 Dart 既有行为）
        assertEquals("00:00", song(duration = 1.hours).displayDuration)
        // 61 分钟：分钟 61 % 60 = 1 → "01:00"
        assertEquals("01:00", song(duration = 61.minutes).displayDuration)
    }

    @Test
    fun `displayName 剥离音频扩展名且不改写原始 title`() {
        assertEquals("夜曲", song(title = "夜曲.mp3").displayName)
        assertEquals("夜曲", song(title = "夜曲.FLAC").displayName)
        assertEquals("夜曲", song(title = "夜曲.opus").displayName)
        // replaceFirst 只替换第一个匹配；结尾锚定下唯一匹配在末尾
        assertEquals("夜曲.mp3", song(title = "夜曲.mp3.mp3").displayName)
        // 不在白名单的扩展名保持原样
        assertEquals("夜曲.xyz", song(title = "夜曲.xyz").displayName)
        // 无扩展名时原样返回
        assertEquals("夜曲", song(title = "夜曲").displayName)
        // 原始 title 字段保持不变（搜索/收藏 key 依赖）
        assertEquals("夜曲.mp3", song(title = "夜曲.mp3").title)
    }

    @Test
    fun `相等性仅比较 id（Dart operator 语义）`() {
        val a = song(id = "s1", title = "夜曲", url = null)
        val sameId = song(id = "s1", title = "改名后的标题", url = "https://cdn.invalid/x")
        val otherId = song(id = "s2")
        assertEquals(a, sameId)
        assertEquals(a.hashCode(), sameId.hashCode())
        assertNotEquals(a, otherId)
        assertTrue(a == a)
        assertFalse(a.equals("not-a-song"))
    }

    @Test
    fun `同 id 歌曲在集合中去重（ Dart hashCode 语义的下游用法）`() {
        val set = HashSet<Song>()
        set.add(song(id = "s1", title = "夜曲"))
        set.add(song(id = "s1", title = "夜曲（改名）"))
        set.add(song(id = "s2"))
        assertEquals(2, set.size)
    }

    @Test
    fun `copy 保留未指定字段并可显式置空 url（Dart copyWith clearUrl 场景）`() {
        val original = song(url = "https://cdn.invalid/expired")
        val updated = original.copy(title = "新标题")
        assertEquals("s1", updated.id)
        assertEquals("新标题", updated.title)
        assertEquals(original.url, updated.url)
        assertEquals(original.duration, updated.duration)
        assertEquals(original.albumId, updated.albumId)
        val cleared = original.copy(url = null)
        assertEquals(null, cleared.url)
        assertEquals("s1", cleared.id)
    }

    @Test
    fun `isUnknownArtist 覆盖两侧占位值与空串`() {
        assertTrue(isUnknownArtist(UNKNOWN_ARTIST_PLACEHOLDER))
        assertTrue(isUnknownArtist(UNKNOWN_ARTIST_PLACEHOLDER_LOCAL))
        assertTrue(isUnknownArtist(null))
        assertTrue(isUnknownArtist(""))
        assertTrue(isUnknownArtist("   "))
    }

    @Test
    fun `isUnknownArtist 不误判真实歌手名`() {
        assertFalse(isUnknownArtist("G.E.M.邓紫棋"))
        assertFalse(isUnknownArtist("周杰伦"))
        assertFalse(isUnknownArtist("hanser"))
        // 含「未知」但不是占位值的真名（防止过宽判定）
        assertFalse(isUnknownArtist("未知森林"))
        assertFalse(isUnknownArtist("未知艺术家乐队"))
    }

    @Test
    fun `占位常量值与原字面量一致`() {
        assertEquals("未知歌曲", UNKNOWN_SONG_TITLE)
        assertEquals("未知歌手", UNKNOWN_ARTIST_PLACEHOLDER)
        assertEquals("未知艺术家", UNKNOWN_ARTIST_PLACEHOLDER_LOCAL)
        // 两侧占位值互不相等（旧守卫只比其一必然漏判）
        assertNotEquals(UNKNOWN_ARTIST_PLACEHOLDER, UNKNOWN_ARTIST_PLACEHOLDER_LOCAL)
    }
}
