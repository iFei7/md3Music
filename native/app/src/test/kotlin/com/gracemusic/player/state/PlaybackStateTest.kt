package com.gracemusic.player.state

import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.model.AudioQuality
import com.gracemusic.player.model.SleepTimerMode
import com.gracemusic.player.queue.PlaybackQueue
import com.gracemusic.testutil.testSong
import com.gracemusic.testutil.testSongs
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaybackState] 的字段默认值与派生属性锁测试。
 *
 * 对标 lib/providers/player_provider.dart 的字段初值与只读 getter：
 * - 初值：`_volume = 1.0`(344) / `_speed = 1.0`(345) / `_audioQuality = standard`(355)
 *   / `_closeLocalMusicComments = true`(361) / `_isWifiNetwork = true`(365)
 *   / `_sleepTimerMode = off`(389) / `_crossfadeDuration = 4s`(472-474)
 * - 派生：[isSleepTimerActive](753-755) / [resolveErrorForDisplay](701)
 *   / [currentQualityLabel](761-782)
 */
class PlaybackStateTest {

    @Test
    fun `默认值_与 Dart 字段初值逐项对齐`() {
        val s = PlaybackState()
        assertTrue(s.queue.isEmpty)
        assertNull(s.currentSong)
        assertFalse(s.isPlaying)
        assertFalse(s.awaitingPlaybackProgress)
        assertFalse(s.playbackNotReady)
        assertEquals(0.seconds, s.position)
        assertEquals(0.seconds, s.platformPosition)
        assertNull(s.duration)
        assertEquals(1.0, s.volume, 0.0)
        assertEquals(1.0, s.speed, 0.0)
        assertFalse(s.isResolvingUrl)
        assertNull(s.resolveError)
        assertFalse(s.manualRetryInFlight)
        assertEquals(AudioQuality.STANDARD, s.audioQuality)
        assertNull(s.actualPlayingQuality)
        assertEquals(SleepTimerMode.OFF, s.sleepTimerMode)
        assertNull(s.sleepTimerRemaining)
        assertFalse(s.stopAfterTimerEnds)
        assertFalse(s.crossfadeEnabled)
        assertEquals(4.seconds, s.crossfadeDuration)
        assertTrue(s.isWifiNetwork)
        assertFalse(s.showQualityDowngradeToast)
        assertTrue(s.closeLocalMusicComments)
        assertEquals(0, s.queueRevision)
    }

    @Test
    fun `交叉淡化默认时长为四秒`() {
        assertEquals(4.seconds, PlaybackState.DEFAULT_CROSSFADE_DURATION)
    }

    @Test
    fun `队列派生属性直接代理到 queue`() {
        val queue = PlaybackQueue(
            playlist = testSongs("a", "b", "c"),
            originalPlaylist = testSongs("a", "b", "c"),
            currentIndex = 2,
            shuffleEnabled = true,
            loopMode = AppLoopMode.ALL,
        )
        val s = PlaybackState(queue = queue)

        assertEquals("c", s.currentSong?.id)
        assertEquals(listOf("a", "b", "c"), s.playlist.map { it.id })
        assertEquals(2, s.currentIndex)
        assertEquals(AppLoopMode.ALL, s.loopMode)
        assertTrue(s.shuffleEnabled)
    }

    @Test
    fun `错误文案_原始串收敛后才可上屏`() {
        val raw = PlaybackState(resolveError = "该章节为 听书VIP单独付费内容")
        assertEquals("该听书章节需要单独购买", raw.resolveErrorForDisplay)
        assertEquals("该章节为 听书VIP单独付费内容", raw.resolveError) // 原始值保留

        val leaked = PlaybackState(resolveError = "http://cdn/x.mp3 500")
        assertEquals("播放失败，请重试", leaked.resolveErrorForDisplay)

        assertNull(PlaybackState().resolveErrorForDisplay)
    }

    @Test
    fun `音质标签_档位展示名`() {
        assertEquals("标准音质", PlaybackState().audioQualityLabel)
        assertEquals("无损音质", PlaybackState(audioQuality = AudioQuality.FLAC).audioQualityLabel)
    }

    @Test
    fun `睡眠定时是否启用_以模式为单一真相源`() {
        assertFalse(PlaybackState().isSleepTimerActive)
        assertTrue(PlaybackState(sleepTimerMode = SleepTimerMode.COUNTDOWN).isSleepTimerActive)
        // endOfTrack 到点等待态没有剩余时间，但仍是「已启用」
        val waiting = PlaybackState(sleepTimerMode = SleepTimerMode.END_OF_TRACK, sleepTimerRemaining = null)
        assertTrue(waiting.isSleepTimerActive)
        assertNull(waiting.sleepTimerRemaining)
    }

    @Test
    fun `实际音质标签_本地曲优先用歌曲自带的音质码`() {
        val local = PlaybackState(
            queue = PlaybackQueue(
                playlist = listOf(testSong("l", isOnline = false, quality = "320")),
                currentIndex = 0,
            ),
            audioQuality = AudioQuality.VIPER,
        )
        assertEquals("高音质", local.currentQualityLabel())
    }

    @Test
    fun `实际音质标签_本地曲的未知音质码原样展示`() {
        val local = PlaybackState(
            queue = PlaybackQueue(
                playlist = listOf(testSong("l", isOnline = false, quality = "weird")),
                currentIndex = 0,
            ),
        )
        assertEquals("weird", local.currentQualityLabel())
    }

    @Test
    fun `实际音质标签_在线曲优先显示实际播放音质_降级后与设置不同`() {
        val online = PlaybackState(
            queue = PlaybackQueue(
                playlist = listOf(testSong("o", isOnline = true)),
                currentIndex = 0,
            ),
            audioQuality = AudioQuality.VIPER,
            actualPlayingQuality = "320",
        )
        assertEquals("高音质", online.currentQualityLabel())
    }

    @Test
    fun `实际音质标签_在线曲尚无实际音质时回退到用户设置`() {
        val online = PlaybackState(
            queue = PlaybackQueue(
                playlist = listOf(testSong("o", isOnline = true)),
                currentIndex = 0,
            ),
            audioQuality = AudioQuality.HIRES,
            actualPlayingQuality = null,
        )
        assertEquals("Hi-Res", online.currentQualityLabel())
    }

    @Test
    fun `实际音质标签_无当前曲时回退到用户设置`() {
        assertEquals("标准音质", PlaybackState().currentQualityLabel())
        assertEquals("蝰蛇母带", PlaybackState(audioQuality = AudioQuality.VIPER).currentQualityLabel())
    }

    @Test
    fun `实际音质标签_支持注入在线音质码映射_供 P2 接入 KugouQuality`() {
        val online = PlaybackState(
            queue = PlaybackQueue(playlist = listOf(testSong("o")), currentIndex = 0),
            actualPlayingQuality = "hires_x",
        )
        assertEquals("hires_x", online.currentQualityLabel()) // 默认：未知名原样
        assertEquals("后置注入", online.currentQualityLabel { "后置注入" })
    }

    @Test
    fun `顶层映射函数_覆盖五档且未知名原样`() {
        assertEquals("标准音质", defaultOnlineQualityLabel("128"))
        assertEquals("高音质", defaultOnlineQualityLabel("320"))
        assertEquals("无损音质", defaultOnlineQualityLabel("flac"))
        assertEquals("Hi-Res", defaultOnlineQualityLabel("high"))
        assertEquals("蝰蛇母带", defaultOnlineQualityLabel("viper_tape"))
        assertEquals("unknown_code", defaultOnlineQualityLabel("unknown_code"))
    }

    @Test
    fun `状态可拷贝且不共享队列引用`() {
        val a = PlaybackState(queue = PlaybackQueue(playlist = testSongs("a"), currentIndex = 0))
        val b = a.copy(isPlaying = true)

        assertFalse(a.isPlaying)
        assertTrue(b.isPlaying)
        assertEquals(a.queue, b.queue)
        assertFalse(b == a.copy(volume = 0.5, isPlaying = true))
    }

    @Test
    fun `位置与平台位置是两个独立字段`() {
        // Dart 侧 position 会被 seek 乐观写入、platformPosition 只由位置流更新，
        // 二者可能短暂不一致，不能合并成一个字段。
        val s = PlaybackState(position = 90.seconds, platformPosition = 0.seconds)
        assertEquals(90.seconds, s.position)
        assertEquals(0.seconds, s.platformPosition)
        assertFalse(s.position == s.platformPosition)
        assertEquals(3.minutes, s.copy(position = 3.minutes).position)
    }
}
