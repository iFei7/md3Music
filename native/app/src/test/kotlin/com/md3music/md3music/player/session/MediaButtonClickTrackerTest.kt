package com.md3music.md3music.player.session

import android.os.Handler
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.TimeUnit

/**
 * 多击判定窗口测试（虚拟时钟）。
 *
 * 「单击立即播放 / 双击补下一首 / 三击补上一首」是 T44 里**唯一**必须精确到毫秒的时序逻辑：
 * 真机上要复现"350ms 内连按三下"几乎不可能稳定，这里用 Robolectric 的虚拟时钟
 * （`ShadowLooper.idleFor`）把每一格时序逐一推进。
 *
 * 断言方式：每次断言前先取走并清空已派发列表，这样"某一步必须*不*派发"也能被显式表达
 * （例如第二击不得立即下发、未超时前不得补发）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = android.app.Application::class)
class MediaButtonClickTrackerTest {

    private val handler = Handler(Looper.getMainLooper())

    /** 已派发的命令（断言前用 [takeDispatched] 取走）。 */
    private val dispatched = mutableListOf<PlayerCommand>()

    private val sink: (PlayerCommand) -> Unit = { dispatched.add(it) }

    private fun tracker() = MediaButtonClickTracker(handler)

    /**
     * 推进虚拟时钟。
     *
     * 前一个用例遗留的待执行回调即使被触发，也只会写入**那些用例自己的**列表，
     * 不会污染当前用例的断言，因此无需在用例间清理消息队列。
     */
    private fun advance(ms: Long) =
        shadowOf(Looper.getMainLooper()).idleFor(ms, TimeUnit.MILLISECONDS)

    private fun takeDispatched(): List<PlayerCommand> {
        val snapshot = dispatched.toList()
        dispatched.clear()
        return snapshot
    }

    @Test
    fun `单击立即下发播放_超时后不补发`() {
        val tracker = tracker()
        tracker.onMultiClickKey(sink)

        assertEquals(
            "第一击必须立即播放（不能错过前台服务启动窗口）",
            listOf(PlayerCommand.Play),
            takeDispatched(),
        )
        advance(MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS - 1)
        assertTrue("未超时前不得补发", takeDispatched().isEmpty())

        advance(2)
        assertTrue("单击不得在超时后补发任何命令", takeDispatched().isEmpty())
        assertFalse(tracker.hasPendingWindow)
        assertEquals(0, tracker.pendingClickCount)
    }

    @Test
    fun `双击得到先播放再下一首`() {
        val tracker = tracker()
        tracker.onMultiClickKey(sink)
        assertEquals(listOf(PlayerCommand.Play), takeDispatched())

        advance(120)
        tracker.onMultiClickKey(sink)
        assertTrue("第二击不得立即下发", takeDispatched().isEmpty())

        advance(MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS)
        assertEquals(listOf(PlayerCommand.Next), takeDispatched())
    }

    @Test
    fun `三击得到先播放再上一首_且不会同时补发下一首`() {
        val tracker = tracker()
        tracker.onMultiClickKey(sink)
        assertEquals(listOf(PlayerCommand.Play), takeDispatched())

        advance(100)
        tracker.onMultiClickKey(sink)
        advance(100)
        tracker.onMultiClickKey(sink)
        assertTrue(takeDispatched().isEmpty())

        advance(MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS)
        assertEquals(
            "窗口重排失败会同时补发上一首与下一首（旧回调未被取消），故必须是单元素",
            listOf(PlayerCommand.Previous),
            takeDispatched(),
        )
    }

    @Test
    fun `四击在超时后不下发任何命令`() {
        val tracker = tracker()
        repeat(4) {
            tracker.onMultiClickKey(sink)
            advance(50)
        }
        assertEquals("只有第一击立即下发", listOf(PlayerCommand.Play), takeDispatched())

        advance(MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS)
        assertTrue("四击及以上不补发（与 lite when(count){2,3} 一致）", takeDispatched().isEmpty())
    }

    @Test
    fun `两次相隔超过窗口的单击各自立即播放`() {
        val tracker = tracker()
        tracker.onMultiClickKey(sink)
        assertEquals(listOf(PlayerCommand.Play), takeDispatched())

        advance(MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS + 1)
        assertTrue("第一次单击的窗口已结束，不得补发", takeDispatched().isEmpty())

        tracker.onMultiClickKey(sink)
        assertEquals(
            "第二次单击必须被视为新窗口的第一击，而不是双击",
            listOf(PlayerCommand.Play),
            takeDispatched(),
        )
        advance(MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS + 1)
        assertTrue("两次独立单击都不得补发切歌", takeDispatched().isEmpty())
    }

    @Test
    fun `补发使用当次传入的回调_不会串到上一次广播的 Context`() {
        val tracker = tracker()
        val firstSink = mutableListOf<PlayerCommand>()
        val secondSink = mutableListOf<PlayerCommand>()

        tracker.onMultiClickKey { firstSink.add(it) }
        advance(100)
        tracker.onMultiClickKey { secondSink.add(it) }
        advance(MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS)

        // 第一击已立即用第一个 sink 派发；补发必须用第二次广播的 sink
        assertEquals(listOf(PlayerCommand.Play), firstSink)
        assertEquals(listOf(PlayerCommand.Next), secondSink)
    }

    @Test
    fun `reset 取消未完成的窗口并清零计数`() {
        val tracker = tracker()
        tracker.onMultiClickKey(sink)
        assertEquals(listOf(PlayerCommand.Play), takeDispatched())

        advance(100)
        tracker.onMultiClickKey(sink)
        assertEquals(2, tracker.pendingClickCount)

        tracker.reset()
        advance(MediaButtonPolicy.MULTI_CLICK_TIMEOUT_MS)

        assertEquals(0, tracker.pendingClickCount)
        assertFalse(tracker.hasPendingWindow)
        assertTrue("reset 后待补发的下一首必须被取消", takeDispatched().isEmpty())
    }
}
