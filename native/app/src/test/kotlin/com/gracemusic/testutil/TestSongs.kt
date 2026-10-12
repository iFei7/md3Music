package com.gracemusic.testutil

import com.gracemusic.data.model.Song
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 测试用歌曲构造器。
 *
 * 播放域（队列 / 状态 / store）的单测大量需要「同一批 id 的歌」来断言顺序与
 * 索引，逐处手写 [Song] 的 22 个字段既啰嗦又容易在字段缺省值上产生口径分歧。
 * 这里收敛成一个内部工具，只暴露测试真正关心的字段。
 *
 * **默认值的选择**：默认按「在线曲目」构造（[Song.isOnline] = true），因为
 * 队列的绝大多数分支（URL 解析、音质降级、云盘分流）都发生在线曲上；需要
 * 验本地分支时显式传 `isOnline = false` + [localPath]。
 */
internal fun testSong(
    id: String,
    title: String = "曲目$id",
    artist: String = "歌手$id",
    album: String = "专辑$id",
    duration: Duration = 200.seconds,
    url: String? = null,
    localPath: String? = null,
    isOnline: Boolean = true,
    quality: String? = null,
    isCloud: Boolean = false,
    isLongAudio: Boolean = false,
): Song = Song(
    id = id,
    title = title,
    artist = artist,
    album = album,
    duration = duration,
    url = url,
    localPath = localPath,
    isOnline = isOnline,
    quality = quality,
    isCloud = isCloud,
    isLongAudio = isLongAudio,
)

/** 按 id 批量构造在线曲目。 */
internal fun testSongs(vararg ids: String): List<Song> = ids.map { testSong(it) }

/** 取歌曲列表的 id 序列，便于断言顺序。 */
internal fun idsOf(songs: List<Song>): List<String> = songs.map { it.id }
