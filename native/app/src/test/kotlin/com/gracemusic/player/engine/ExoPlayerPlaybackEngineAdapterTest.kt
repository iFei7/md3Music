package com.gracemusic.player.engine

import android.app.Application
import android.content.Context
import android.os.Looper
import androidx.media3.common.FlagSet
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import com.gracemusic.data.model.Song
import com.gracemusic.player.model.PlaybackErrorInfo
import com.gracemusic.player.model.PlaybackErrorOrigin
import com.gracemusic.player.store.EngineListener
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * ExoPlayer 播放引擎适配器测试（Robolectric + 真 ExoPlayer）。
 *
 * 参照 [AudioEngineFactoryTest] 的构建模式构造**真** [AudioEngine]，断言全部落在
 * 可观测状态上（mediaItemCount / mediaId / uri / playWhenReady / currentPosition /
 * volume / speed / 监听事件序列 / positionFlow）。
 *
 * **测试设计约束（诚实边界）**：Robolectric 下音频不真正解码（无 MediaCodec），
 * 因此本测试**不断言播放推进**（currentPosition 自动增长、STATE_READY、真实 duration
 * 均不出现）；装载不存在文件后的 BUFFERING→error 时序属真实时间竞态，亦不断言。
 * 位置流的采样与节流以「手动驱动 onIsPlayingChanged + seekTo 后的 currentPosition」
 * 验证：seek 后的 currentPosition 是引擎真实状态，采样管道把它搬进 positionFlow，
 * 不是伪造推进。duration 非 null 的转发路径依赖真实解码，不在本测试覆盖范围
 * （由 Store 层假引擎测试覆盖 onDurationChanged 的消费）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class ExoPlayerPlaybackEngineAdapterTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    private fun newEngine(): AudioEngine =
        AudioEngineFactory(context).create(AudioEngineConfig(role = EngineRole.MAIN))

    /** 记录全部引擎事件的假监听者（顺序即事实）。 */
    private class RecordingListener : EngineListener {
        val events = CopyOnWriteArrayList<String>()

        override fun onPlaybackStateChanged(playbackState: Int) {
            events.add("state:$playbackState")
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            events.add("isPlaying:$isPlaying")
        }

        override fun onDurationChanged(durationMs: Long?) {
            events.add("duration:$durationMs")
        }

        override fun onCurrentSongChanged(songId: String?) {
            events.add("song:$songId")
        }

        override fun onPlaybackCompleted() {
            events.add("completed")
        }

        override fun onError(info: PlaybackErrorInfo) {
            events.add("error:${info.message}")
        }
    }

    /** 捕获完整 [PlaybackErrorInfo] 的监听者（断言 B1 原始错误码/HTTP 码透传）。 */
    private class ErrorCaptureListener : EngineListener {
        val infos = CopyOnWriteArrayList<PlaybackErrorInfo>()

        override fun onError(info: PlaybackErrorInfo) {
            infos.add(info)
        }
    }

    /**
     * 模拟 media3 `HttpDataSource.InvalidResponseCodeException`：公开的
     * `val responseCode` 生成公开无参 `getResponseCode()`，供
     * `extractHttpStatusCode` 的反射路径命中。
     *
     * 刻意**不加** `private`：反射访问检查要求声明类可访问（真实
     * `InvalidResponseCodeException` 即公开类），私有嵌套类会让 `invoke`
     * 抛 `IllegalAccessException` 而误判为「取不到」。
     */
    class FakeHttpStatusException(val responseCode: Int) : java.io.IOException()

    private fun song(
        id: String = "song-1",
        isOnline: Boolean = false,
        url: String? = null,
        localPath: String? = null,
    ): Song = Song(
        id = id,
        title = "测试曲目",
        artist = "测试歌手",
        album = "测试专辑",
        duration = 240.seconds,
        url = url,
        localPath = localPath,
        isOnline = isOnline,
    )

    /** 推进 Robolectric 主 looper 虚拟时钟（毫秒）。 */
    private fun advance(ms: Long) =
        shadowOf(Looper.getMainLooper()).idleFor(ms, TimeUnit.MILLISECONDS)

    // ------------------------------------------------------------------
    // 时间线投射
    // ------------------------------------------------------------------

    @Test
    fun `prepare_本地裸路径投射为单曲时间线_mediaId与fileURI正确`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), 3000, true)

            val player = engine.player
            assertEquals("单曲时间线：只允许 1 个媒体项", 1, player.mediaItemCount)
            assertEquals("mediaId 必须等于 song.id", "song-1", player.currentMediaItem?.mediaId)
            assertEquals(
                "裸绝对路径必须转 file:// URI（lite _resolvePlaybackUrlImpl:5665-5669 语义）",
                "file:///storage/emulated/0/Music/a.mp3",
                player.currentMediaItem?.localConfiguration?.uri.toString(),
            )
            assertTrue("playWhenReady=true 必须真实下发", player.playWhenReady)
            assertEquals("起始位置必须真实 seek", 3000L, player.currentPosition)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare_带scheme的本地路径原样透射`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            // content://：media3 DataSource 原生支持（lite 侧的解析是 just_audio 限制）。
            adapter.prepare(song(id = "c-1", localPath = "content://media/external/audio/media/42"), null, false)
            assertEquals(
                "content://media/external/audio/media/42",
                engine.player.currentMediaItem?.localConfiguration?.uri.toString(),
            )

            // file:// 已编码路径原样透射（不得二次编码）。
            adapter.prepare(song(id = "f-1", localPath = "file:///storage/emulated/0/a%20b.mp3"), null, false)
            assertEquals(
                "file:///storage/emulated/0/a%20b.mp3",
                engine.player.currentMediaItem?.localConfiguration?.uri.toString(),
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare_在线曲目_url非空时原样投射`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(
                song(id = "o-1", isOnline = true, url = "https://cdn.example.com/audio/abc.mp3"),
                0,
                false,
            )
            val player = engine.player
            assertEquals(1, player.mediaItemCount)
            assertEquals("o-1", player.currentMediaItem?.mediaId)
            assertEquals(
                "https://cdn.example.com/audio/abc.mp3",
                player.currentMediaItem?.localConfiguration?.uri.toString(),
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare_在线曲目_url为null_拒绝执行且不触碰引擎`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)
        try {
            // 不得崩、不得伪造成功：直接返回，引擎状态保持原样。
            adapter.prepare(song(id = "o-null", isOnline = true, url = null), null, true)

            val player = engine.player
            assertEquals("无音源不得投射时间线", 0, player.mediaItemCount)
            assertFalse("不得替用户置起播意图", player.playWhenReady)
            assertTrue("拒绝执行不得产生任何引擎事件", listener.events.isEmpty())
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare_本地曲目无localPath也无url_拒绝执行`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(id = "empty", isOnline = false), null, true)
            assertEquals(0, engine.player.mediaItemCount)
            assertFalse(engine.player.playWhenReady)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare_本地曲目无localPath但有url_走url兜底`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            // 非在线曲目的 url（NAS 按需下载回写等场景）仍可作为音源。
            adapter.prepare(
                song(id = "nas-1", isOnline = false, localPath = null, url = "https://nas.example/a.flac"),
                null,
                false,
            )
            assertEquals(1, engine.player.mediaItemCount)
            assertEquals(
                "https://nas.example/a.flac",
                engine.player.currentMediaItem?.localConfiguration?.uri.toString(),
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare_startPositionMs为null_不seek保持零位`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, false)
            assertEquals(0L, engine.player.currentPosition)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare_触发BUFFERING与曲目切换事件并转发`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)
        try {
            // 同步阶段断言（不推进虚拟时钟，规避真实加载的时序竞态）。
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, true)

            assertTrue(
                "prepare 后必须收到 BUFFERING 状态事件",
                listener.events.contains("state:${Player.STATE_BUFFERING}"),
            )
            assertTrue(
                "prepare 后必须收到曲目切换确认（mediaId 身份）",
                listener.events.contains("song:song-1"),
            )
        } finally {
            adapter.release()
        }
    }

    // ------------------------------------------------------------------
    // 播放控制（真实调用可观察）
    // ------------------------------------------------------------------

    @Test
    fun `play与pause_真实驱动playWhenReady`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, false)
            assertFalse(engine.player.playWhenReady)

            adapter.play()
            assertTrue("play() 必须真实置 playWhenReady", engine.player.playWhenReady)

            adapter.pause()
            assertFalse("pause() 必须真实清 playWhenReady", engine.player.playWhenReady)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `stop_保留媒体项并回到IDLE`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, true)
            adapter.stop()

            val player = engine.player
            assertEquals(Player.STATE_IDLE, player.playbackState)
            assertEquals("非 reset 版 stop：媒体项保留", 1, player.mediaItemCount)
            assertEquals("song-1", player.currentMediaItem?.mediaId)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `seekTo_真实生效`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, false)
            adapter.seekTo(7000)
            assertEquals(7000L, engine.player.currentPosition)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `seekBy_按currentPosition加增量且负向兜底到零`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), 5000, false)
            assertEquals(5000L, engine.player.currentPosition)

            adapter.seekBy(2500)
            assertEquals("currentPosition + delta", 7500L, engine.player.currentPosition)

            adapter.seekBy(-99999)
            assertEquals("负向越界必须兜底到 0", 0L, engine.player.currentPosition)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `setVolume与setSpeed_真实生效`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, false)

            adapter.setVolume(0.5f)
            assertEquals(0.5f, engine.player.volume, 0f)

            adapter.setSpeed(1.5f)
            assertEquals(1.5f, engine.player.playbackParameters.speed, 0f)
        } finally {
            adapter.release()
        }
    }

    // ------------------------------------------------------------------
    // 监听桥接与去重
    // ------------------------------------------------------------------

    @Test
    fun `播放状态与playing_按值去重转发`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)
        try {
            adapter.onPlaybackStateChanged(Player.STATE_READY)
            adapter.onPlaybackStateChanged(Player.STATE_READY)
            adapter.onIsPlayingChanged(true)
            adapter.onIsPlayingChanged(true)

            assertEquals(
                "同一事实不得重复转发",
                listOf("state:${Player.STATE_READY}", "isPlaying:true"),
                listener.events.toList(),
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `STATE_ENDED_发onPlaybackCompleted且仅一次`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)
        try {
            adapter.onPlaybackStateChanged(Player.STATE_ENDED)
            assertEquals(
                listOf("state:${Player.STATE_ENDED}", "completed"),
                listener.events.toList(),
            )

            // 重复进入 ENDED（同值）不得再发 completed。
            adapter.onPlaybackStateChanged(Player.STATE_ENDED)
            assertEquals(
                "completed 只允许一次",
                1,
                listener.events.count { it == "completed" },
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `onMediaItemTransition_按mediaId身份对账`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)
        try {
            val item1 = MediaItem.Builder().setMediaId("song-1").setUri("file:///a.mp3").build()
            val item2 = MediaItem.Builder().setMediaId("song-2").setUri("file:///b.mp3").build()

            adapter.onMediaItemTransition(item1, Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED)
            adapter.onMediaItemTransition(item1, Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT)
            adapter.onMediaItemTransition(item2, Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED)
            adapter.onMediaItemTransition(null, Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED)

            assertEquals(
                "同身份不重复；null 身份也必须传达（时间线已空）",
                listOf("song:song-1", "song:song-2", "song:null"),
                listener.events.toList(),
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `onPlayerError_文案经safePlaybackErrorMessage收敛`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)
        try {
            // 未知错误折叠为兜底文案，原始细节（URL/异常）不得外泄。
            adapter.onPlayerError(
                PlaybackException(
                    "https://cdn.example.com/x.mp3 404 java.io.IOException",
                    null,
                    PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
                ),
            )
            // 已知错误走显式映射。
            adapter.onPlayerError(
                PlaybackException(
                    "无法获取播放链接",
                    null,
                    PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
                ),
            )

            assertEquals(
                listOf("error:播放失败，请重试", "error:无法获取播放链接，请重试"),
                listener.events.toList(),
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `onPlayerError_透传原始错误码与码名`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val capture = ErrorCaptureListener()
        adapter.addListener(capture)
        try {
            adapter.onPlayerError(
                PlaybackException(
                    "bad status",
                    null,
                    PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
                ),
            )

            val info = capture.infos.single()
            assertEquals(
                "media3 原始 errorCode 必须逐值透传",
                PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
                info.errorCode,
            )
            assertEquals(
                "码名必须透传（media3 getErrorCodeName 实证值）",
                "ERROR_CODE_IO_BAD_HTTP_STATUS",
                info.errorCodeName,
            )
            assertNull("无 cause 时不得臆造 HTTP 状态码", info.httpStatusCode)
            assertEquals(
                "引擎路径来源必须为 ENGINE（解析路径才带 songId/RESOLUTION）",
                PlaybackErrorOrigin.ENGINE,
                info.origin,
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `onPlayerError_从cause链提取HTTP状态码`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val capture = ErrorCaptureListener()
        adapter.addListener(capture)
        try {
            // 直接 cause 携带 responseCode。
            adapter.onPlayerError(
                PlaybackException(
                    "invalid response code",
                    FakeHttpStatusException(404),
                    PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
                ),
            )
            assertEquals(404, capture.infos.single().httpStatusCode)

            // 嵌套 cause 链（外层无 responseCode）也必须能取到。
            adapter.onPlayerError(
                PlaybackException(
                    "wrapped",
                    IllegalStateException("outer", FakeHttpStatusException(503)),
                    PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
                ),
            )
            assertEquals(
                "必须沿 cause 链向下提取",
                503,
                capture.infos.last().httpStatusCode,
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `onEvents_未知时长不重复通知`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)
        try {
            val events = Player.Events(FlagSet.Builder().add(Player.EVENT_TIMELINE_CHANGED).build())
            // 无媒体装载 → duration 恒 TIME_UNSET → 映射 null；null == null 去重。
            adapter.onEvents(engine.player, events)
            adapter.onEvents(engine.player, events)
            adapter.onEvents(engine.player, events)

            assertTrue(
                "未知时长（null）不得重复通知",
                listener.events.none { it.startsWith("duration:") },
            )
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `prepare_重复装载同一首歌_曲目身份事件不重复`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)
        try {
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, false)
            adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, false)

            assertEquals(
                "重复 prepare 同一 mediaId 不得重复广播曲目切换",
                1,
                listener.events.count { it == "song:song-1" },
            )
        } finally {
            adapter.release()
        }
    }

    // ------------------------------------------------------------------
    // release 安全
    // ------------------------------------------------------------------

    @Test
    fun `release_迟到回调被丢弃且公开方法安全幂等`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val listener = RecordingListener()
        adapter.addListener(listener)

        adapter.release()

        // 测试模拟的迟到回调路径（真实回调已被 removeListener 阻断）：
        // 全部必须被 released 标志丢弃，不抛、不转发。
        adapter.onPlaybackStateChanged(Player.STATE_READY)
        adapter.onIsPlayingChanged(true)
        adapter.onMediaItemTransition(
            MediaItem.Builder().setMediaId("late").setUri("file:///late.mp3").build(),
            Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED,
        )
        adapter.onPlayerError(
            PlaybackException("boom", null, PlaybackException.ERROR_CODE_IO_UNSPECIFIED),
        )
        adapter.onEvents(
            engine.player,
            Player.Events(FlagSet.Builder().add(Player.EVENT_TIMELINE_CHANGED).build()),
        )
        assertTrue("release 后回调必须全部丢弃", listener.events.isEmpty())

        // release 后公开方法：早退、不抛、不触碰已释放的 player。
        adapter.play()
        adapter.pause()
        adapter.stop()
        adapter.seekTo(1000)
        adapter.seekBy(1000)
        adapter.setVolume(0.5f)
        adapter.setSpeed(1.5f)
        adapter.prepare(song(localPath = "/storage/emulated/0/Music/a.mp3"), null, true)
        adapter.addListener(listener)
        adapter.removeListener(listener)

        // release 幂等。
        adapter.release()
        assertTrue("release 后仍不得有任何事件", listener.events.isEmpty())
    }

    @Test
    fun `release_停止位置采样`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.onIsPlayingChanged(true)
            adapter.seekTo(5000)
            advance(250)
            assertEquals("采样必须真实工作", 5.seconds, adapter.positionFlow.value)

            adapter.release()
            advance(600)
            assertEquals("release 后采样必须停止", 5.seconds, adapter.positionFlow.value)
        } finally {
            engine.close()
        }
    }

    // ------------------------------------------------------------------
    // 位置流采样
    // ------------------------------------------------------------------

    @Test
    fun `位置流_播放态按约200ms节流采样`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            // 手动驱动 isPlaying 事件（media3 真实会派发的桥接入点）启动采样；
            // seek 后的 currentPosition 是引擎真实状态，采样管道负责搬运。
            adapter.onIsPlayingChanged(true)
            adapter.seekTo(5000)

            advance(199)
            assertEquals("未满 200ms 节流窗口不得写值", Duration.ZERO, adapter.positionFlow.value)

            advance(2)
            assertEquals("节流窗口到期必须写值", 5.seconds, adapter.positionFlow.value)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `位置流_暂停态停止采样`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            adapter.onIsPlayingChanged(true)
            adapter.seekTo(5000)
            advance(250)
            assertEquals(5.seconds, adapter.positionFlow.value)

            adapter.onIsPlayingChanged(false)
            adapter.seekTo(9000)
            advance(600)
            assertEquals("暂停后不得继续采样（停止空转）", 5.seconds, adapter.positionFlow.value)
        } finally {
            adapter.release()
        }
    }

    @Test
    fun `位置流_空闲态不采样`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            // 未播放、未缓冲：采样 job 不得启动。
            adapter.seekTo(4000)
            advance(600)
            assertEquals(Duration.ZERO, adapter.positionFlow.value)
        } finally {
            adapter.release()
        }
    }

    // ------------------------------------------------------------------
    // 主线程约束
    // ------------------------------------------------------------------

    @Test
    fun `非主线程调用公开方法抛IllegalStateException`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        val failures = CopyOnWriteArrayList<Throwable>()
        fun runOffMain(block: () -> Unit) {
            val thread = Thread {
                try {
                    block()
                } catch (e: Throwable) {
                    failures.add(e)
                }
            }
            thread.start()
            thread.join()
        }
        try {
            runOffMain { adapter.play() }
            runOffMain { adapter.pause() }
            runOffMain { adapter.stop() }
            runOffMain { adapter.seekTo(1) }
            runOffMain { adapter.seekBy(1) }
            runOffMain { adapter.setVolume(0.5f) }
            runOffMain { adapter.setSpeed(1f) }
            runOffMain { adapter.prepare(song(localPath = "/a.mp3"), null, false) }
            runOffMain { adapter.addListener(RecordingListener()) }
            runOffMain { adapter.removeListener(RecordingListener()) }
            runOffMain { adapter.release() }

            assertEquals("每个公开方法都必须拒绝", 11, failures.size)
            assertTrue(
                "必须抛 IllegalStateException 而非静默出错：$failures",
                failures.all { it is IllegalStateException },
            )
        } finally {
            // release() 在后台线程被拒（released 未置位），此处兜底释放引擎。
            engine.close()
        }
    }

    @Test
    fun `初始状态查询_IDLE且时长未知且位置为零`() {
        val engine = newEngine()
        val adapter = ExoPlayerPlaybackEngineAdapter(engine)
        try {
            assertNull("未装载曲目时 duration 未知", adapter.durationMs)
            assertEquals(Player.STATE_IDLE, adapter.playbackState)
            assertFalse(adapter.isPlaying)
            assertEquals(Duration.ZERO, adapter.positionFlow.value)
        } finally {
            adapter.release()
        }
    }
}
