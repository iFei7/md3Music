package com.gracemusic.player.gate

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [shouldHandlePlaybackErrorEvent] 移植锁测试。
 *
 * 场景对标 test/providers/playback_error_event_gate_test.dart：
 * - 只接收当前请求已完成装载后的播放中错误；
 * - 忽略过期请求或装载阶段错误，由对应请求 Future 处理；
 * - 快速切歌产生的 just_audio 加载中断不标记为播放失败。
 */
class PlaybackErrorEventGateTest {

    @Test
    fun `只接收当前请求已完成装载后的播放中错误`() {
        assertTrue(
            shouldHandlePlaybackErrorEvent(
                errorCode = 0,
                isCurrentRequest = true,
                loadCompleted = true,
            ),
        )
    }

    @Test
    fun `忽略过期请求或装载阶段错误`() {
        assertFalse(
            shouldHandlePlaybackErrorEvent(
                errorCode = 0,
                isCurrentRequest = false,
                loadCompleted = true,
            ),
        )
        assertFalse(
            shouldHandlePlaybackErrorEvent(
                errorCode = 0,
                isCurrentRequest = true,
                loadCompleted = false,
            ),
        )
    }

    @Test
    fun `快速切歌产生的加载中断不标记为播放失败`() {
        assertFalse(
            shouldHandlePlaybackErrorEvent(
                errorCode = INTERRUPTED_PLAYER_LOAD_ERROR_CODE,
                isCurrentRequest = true,
                loadCompleted = true,
            ),
        )
        // 常量本身锁定为 10000000，防误改
        assert(INTERRUPTED_PLAYER_LOAD_ERROR_CODE == 10000000)
    }
}
