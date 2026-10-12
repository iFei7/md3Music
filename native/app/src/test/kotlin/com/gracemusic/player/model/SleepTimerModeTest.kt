package com.gracemusic.player.model

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * [SleepTimerMode] 三态与迁移语义的移植锁测试。
 *
 * 场景对标 lib/providers/player_provider.dart：
 * - 56-68 行 enum 三值（off / countdown / endOfTrack）；
 * - 5266-5269 行 setSleepTimer 的 off / countdown 迁移；
 * - 5286-5296 行 ticker 到点的 endOfTrack / off 迁移；
 * - 5316-5320 行 setStopAfterCurrentTrack 撤销等待态。
 */
class SleepTimerModeTest {

    @Test
    fun `三态及顺序与 Dart 一致`() {
        assertEquals(
            listOf("OFF", "COUNTDOWN", "END_OF_TRACK"),
            SleepTimerMode.entries.map { it.name },
        )
    }

    @Test
    fun `设置定时进入倒计时_取消定时回到未启用`() {
        assertEquals(SleepTimerMode.COUNTDOWN, SleepTimerMode.forTimerStart(30.minutes))
        assertEquals(SleepTimerMode.COUNTDOWN, SleepTimerMode.forTimerStart(1.seconds))
        assertEquals(SleepTimerMode.OFF, SleepTimerMode.forTimerStart(null))
    }

    @Test
    fun `到点迁移_勾选播完当前歌曲则进入等待态`() {
        assertEquals(
            SleepTimerMode.END_OF_TRACK,
            SleepTimerMode.forTimerFired(stopAfterCurrentTrack = true),
        )
    }

    @Test
    fun `到点迁移_未勾选则回到未启用并由调用方暂停`() {
        assertEquals(
            SleepTimerMode.OFF,
            SleepTimerMode.forTimerFired(stopAfterCurrentTrack = false),
        )
    }

    @Test
    fun `取消播完当前歌曲偏好时撤销已到点的等待态`() {
        assertEquals(
            SleepTimerMode.OFF,
            SleepTimerMode.END_OF_TRACK.afterStopAfterCurrentTrackDisabled(),
        )
    }

    @Test
    fun `取消播完当前歌曲偏好不影响其他状态`() {
        assertEquals(
            SleepTimerMode.OFF,
            SleepTimerMode.OFF.afterStopAfterCurrentTrackDisabled(),
        )
        assertEquals(
            SleepTimerMode.COUNTDOWN,
            SleepTimerMode.COUNTDOWN.afterStopAfterCurrentTrackDisabled(),
        )
    }
}
