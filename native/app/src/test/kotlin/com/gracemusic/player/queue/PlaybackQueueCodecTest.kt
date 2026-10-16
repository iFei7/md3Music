package com.gracemusic.player.queue

import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.testutil.testSong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaybackQueueCodec] 的 round-trip 与容错测试（T-P1-11）。
 *
 * 纯 JVM（无 Android 依赖，无需 Robolectric）。
 *
 * 覆盖：结构 / 索引 / 循环 / 随机态 round-trip、`originalPlaylist` 保真、
 * URL 剥离、索引钳位、损坏数据容错、未知枚举兜底、`Song.equals` 语义保留。
 */
class PlaybackQueueCodecTest {

    private fun queue(
        playlist: List<com.gracemusic.data.model.Song>,
        originalPlaylist: List<com.gracemusic.data.model.Song> = playlist,
        currentIndex: Int = 0,
        shuffleEnabled: Boolean = false,
        loopMode: AppLoopMode = AppLoopMode.OFF,
    ) = PlaybackQueue(
        playlist = playlist,
        originalPlaylist = originalPlaylist,
        currentIndex = currentIndex,
        shuffleEnabled = shuffleEnabled,
        loopMode = loopMode,
    )

    @Test
    fun `round-trip_结构_索引_循环_随机全部一致`() {
        val before = queue(
            playlist = listOf(testSong("a"), testSong("b"), testSong("c")),
            currentIndex = 2,
            shuffleEnabled = true,
            loopMode = AppLoopMode.ALL,
        )

        val after = PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(before))!!

        assertEquals(listOf("a", "b", "c"), after.playlist.map { it.id })
        assertEquals(2, after.currentIndex)
        assertTrue(after.shuffleEnabled)
        assertEquals(AppLoopMode.ALL, after.loopMode)
    }

    @Test
    fun `round-trip_随机态的原始顺序保真`() {
        // 关键差异：Dart 恢复时把 _originalPlaylist 重置为当前 playlist，
        // 导致「关闭随机」无法还原原顺序；native 如实存两份。
        val before = queue(
            playlist = listOf(testSong("c"), testSong("a"), testSong("b")),
            originalPlaylist = listOf(testSong("a"), testSong("b"), testSong("c")),
            currentIndex = 0,
            shuffleEnabled = true,
            loopMode = AppLoopMode.OFF,
        )

        val after = PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(before))!!

        assertEquals(listOf("c", "a", "b"), after.playlist.map { it.id })
        assertEquals(listOf("a", "b", "c"), after.originalPlaylist.map { it.id })
    }

    @Test
    fun `原始顺序缺省时与播放列表对齐`() {
        val json = """{"playlist":[{"id":"a","title":"t","artist":"r","album":"b","durationMs":1000}],
            "originalPlaylist":[],"currentIndex":0,"shuffleEnabled":false,"loopMode":"OFF"}"""

        val after = PlaybackQueueCodec.decode(json)!!

        assertEquals(listOf("a"), after.originalPlaylist.map { it.id })
    }

    @Test
    fun `url 不被持久化`() {
        val song = testSong("a", url = "https://cdn.example/a?sign=secret&expire=123")
        val json = PlaybackQueueCodec.encode(queue(listOf(song)))

        // 断言磁盘上不残留任何签名 URL 片段（安全要求）。
        assertFalse(json.contains("cdn.example"))
        assertFalse(json.contains("sign="))
        assertFalse(json.contains("secret"))

        val after = PlaybackQueueCodec.decode(json)!!
        assertNull(after.playlist[0].url)
    }

    @Test
    fun `localPath 被持久化`() {
        val song = testSong("a", isOnline = false, localPath = "/music/a.flac")

        val after = PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(queue(listOf(song))))!!

        assertEquals("/music/a.flac", after.playlist[0].localPath)
    }

    @Test
    fun `全部字段逐项 round-trip`() {
        val song = testSong("a", isOnline = true, quality = "flac").copy(
            artworkUri = "https://img.example/a.jpg",
            albumId = "al1",
            artistId = "ar1",
            albumAudioId = "aa1",
            fileId = 42,
            isCloud = true,
            climaxStart = 12.5,
            climaxEnd = 45.5,
            bpm = 128,
            isLocallyFavorited = true,
            isLongAudio = true,
            loudnessLufs = -9.5,
            loudnessPeakDb = -1.2,
        )

        val after = PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(queue(listOf(song))))!!
            .playlist[0]

        assertEquals(song.id, after.id)
        assertEquals(song.title, after.title)
        assertEquals(song.artist, after.artist)
        assertEquals(song.album, after.album)
        assertEquals(song.duration, after.duration)
        assertEquals(song.localPath, after.localPath)
        assertEquals(song.artworkUri, after.artworkUri)
        assertEquals(song.isOnline, after.isOnline)
        assertEquals(song.albumId, after.albumId)
        assertEquals(song.artistId, after.artistId)
        assertEquals(song.quality, after.quality)
        assertEquals(song.albumAudioId, after.albumAudioId)
        assertEquals(song.fileId, after.fileId)
        assertEquals(song.isCloud, after.isCloud)
        assertEquals(song.climaxStart, after.climaxStart)
        assertEquals(song.climaxEnd, after.climaxEnd)
        assertEquals(song.bpm, after.bpm)
        assertEquals(song.isLocallyFavorited, after.isLocallyFavorited)
        assertEquals(song.isLongAudio, after.isLongAudio)
        assertEquals(song.loudnessLufs, after.loudnessLufs)
        assertEquals(song.loudnessPeakDb, after.loudnessPeakDb)
    }

    @Test
    fun `索引越界被钳位到末位`() {
        val before = queue(
            playlist = listOf(testSong("a"), testSong("b")),
            currentIndex = 0,
        )
        val json = PlaybackQueueCodec.encode(before).replace("\"currentIndex\":0", "\"currentIndex\":99")

        val after = PlaybackQueueCodec.decode(json)!!

        assertEquals(1, after.currentIndex)
    }

    @Test
    fun `负索引被钳位到首位`() {
        val before = queue(playlist = listOf(testSong("a"), testSong("b")), currentIndex = 0)
        val json = PlaybackQueueCodec.encode(before).replace("\"currentIndex\":0", "\"currentIndex\":-7")

        val after = PlaybackQueueCodec.decode(json)!!

        assertEquals(0, after.currentIndex)
    }

    @Test
    fun `空队列_索引为负一`() {
        val after = PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(PlaybackQueue()))!!

        assertTrue(after.playlist.isEmpty())
        assertEquals(-1, after.currentIndex)
    }

    @Test
    fun `损坏 JSON 返回 null 不抛异常`() {
        assertNull(PlaybackQueueCodec.decode("{not json"))
        assertNull(PlaybackQueueCodec.decode(""))
        assertNull(PlaybackQueueCodec.decode("[]"))
    }

    @Test
    fun `未知循环模式回落 OFF`() {
        val json = """{"playlist":[],"originalPlaylist":[],"currentIndex":-1,
            "shuffleEnabled":false,"loopMode":"FUTURE_MODE"}"""

        assertEquals(AppLoopMode.OFF, PlaybackQueueCodec.decode(json)!!.loopMode)
    }

    @Test
    fun `未知字段被容忍`() {
        val json = """{"playlist":[],"originalPlaylist":[],"currentIndex":-1,
            "shuffleEnabled":false,"loopMode":"OFF","futureField":123}"""

        assertEquals(0, PlaybackQueueCodec.decode(json)!!.playlist.size)
    }

    @Test
    fun `Song 相等性语义保留_同 id 视为同曲`() {
        val before = queue(listOf(testSong("a", title = "旧标题")), currentIndex = 0)
        val after = PlaybackQueueCodec.decode(PlaybackQueueCodec.encode(before))!!

        // Song.equals 仅比 id（对位 song.dart:215-221）——round-trip 后仍成立。
        assertEquals(before.playlist[0], after.playlist[0])
        // 但字段确实被还原（标题仍是旧的，未丢失）。
        assertEquals("旧标题", after.playlist[0].title)
        assertNotEquals(before.playlist[0].title, "新标题")
    }

    @Test
    fun `encode 恒成功且输出为 JSON 对象`() {
        val json = PlaybackQueueCodec.encode(PlaybackQueue())

        assertTrue(json.startsWith("{"))
        assertTrue(json.contains("\"playlist\""))
    }
}
