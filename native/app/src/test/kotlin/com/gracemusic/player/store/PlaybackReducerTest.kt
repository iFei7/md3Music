package com.gracemusic.player.store

import com.gracemusic.player.gate.AudioFocusInterruptionMode
import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.model.AudioQuality
import com.gracemusic.player.model.PlaylistSortBy
import com.gracemusic.player.model.SleepTimerMode
import com.gracemusic.player.queue.PlaybackQueue
import com.gracemusic.player.state.PlaybackEvent
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.player.state.PlaybackState
import com.gracemusic.player.store.PlaybackEffect.Pause
import com.gracemusic.player.store.PlaybackEffect.PersistFavoriteToggle
import com.gracemusic.player.store.PlaybackEffect.PersistPlaybackCursor
import com.gracemusic.player.store.PlaybackEffect.PersistPreference
import com.gracemusic.player.store.PlaybackEffect.Play
import com.gracemusic.player.store.PlaybackEffect.Prepare
import com.gracemusic.player.store.PlaybackEffect.RefreshSystemNotification
import com.gracemusic.player.store.PlaybackEffect.ResolveSongUrl
import com.gracemusic.player.store.PlaybackEffect.SeekBy
import com.gracemusic.player.store.PlaybackEffect.SeekTo
import com.gracemusic.player.store.PlaybackEffect.SetSpeed
import com.gracemusic.player.store.PlaybackEffect.SetVolume
import com.gracemusic.player.store.PlaybackEffect.ShowMessage
import com.gracemusic.player.store.PlaybackEffect.StartKeepAlive
import com.gracemusic.player.store.PlaybackEffect.Stop
import com.gracemusic.player.store.PlaybackEffect.StopKeepAlive
import com.gracemusic.testutil.idsOf
import com.gracemusic.testutil.testSong
import com.gracemusic.testutil.testSongs
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaybackReducer] 全量归约锁测试（纯 JUnit4，无 Android 依赖）。
 *
 * 覆盖台本 §3.5 契约与 §4 测试计划表首行：42 个意图 × 正反例、12 个事件、
 * 7 类竞态，以及空队列/边界/seek 合法性/循环随机/错误恢复/重复事件/过期事件。
 *
 * ## 覆盖矩阵（意图/事件/竞态 → 测试名，一一对应）
 *
 * **装载与起播**：
 * - `PlaySingleSong` → `PlaySingleSong_本地曲直接备播并换成单曲队列`（正例）/
 *   `PlaySingleSong_在线曲无地址走解析且标记解析中`（边界）
 * - `PlayOnlineSingleSong` → `PlayOnlineSingleSong_已带地址也强制重新解析`（正例+边界）
 * - `PlayPlaylistFrom` → `PlayPlaylistFrom_非随机保持原序并从起始索引起播`（正例）/
 *   `PlayPlaylistFrom_空列表拒绝` / `PlayPlaylistFrom_随机模式起始曲置首且同源可复现` /
 *   `PlayPlaylistFrom_起始索引越界收敛到合法区间`（边界）
 * - `PlayOnlinePlaylistFrom` → `PlayOnlinePlaylistFrom_装载并强制解析当前曲`（正例+空列表边界）
 * - `PlayCloudPlaylistFrom` → `PlayCloudPlaylistFrom_装载云盘队列并解析`（正例+空列表边界）
 * - `PlayAt` → `PlayAt_播放列表面板指定下标`（正例）/ `PlayAt_越界索引拒绝`（边界）
 *
 * **传输控制**：
 * - `Resume` → `Resume_就绪态直接起播`（正例）/ `Resume_空队列拒绝` /
 *   `Resume_未就绪时带当前位置重备`（边界）
 * - `Pause` → `Pause_清等待标志且不抢写播放态`（正例+边界）
 * - `PauseForSeek` → `PauseForSeek_只前置暂停不停保活不落盘`（正例+边界）
 * - `SeekTo` → `SeekTo_乐观写位置并下发绝对定位`（正例）/ `SeekTo_未知时长拒绝` /
 *   `SeekTo_目标越界钳位到时长` / `SeekTo_播完停机后拒绝`（边界）
 * - `SeekBy` → `SeekBy_正向相对定位`（正例）/ `SeekBy_负向钳位到零`（边界）
 * - `Next` → `Next_非队尾前进一位并重备`（正例）/ `Next_空队列拒绝` /
 *   `Next_OFF停在末曲提示并暂停` / `Next_单曲循环且仅一首时重播当前曲` /
 *   `Next_列表循环队尾绕回队首` / `Next_单曲加列表循环绕回起点为无操作` /
 *   `Next_预载模式不出声不等待推进`（边界）
 * - `Previous` → `Previous_队首绕到队尾`（正例）/ `Previous_空队列拒绝` /
 *   `Previous_单曲加列表循环绕回起点仅落盘` / `Previous_单曲非列表循环绕回时定位回零`（边界）
 * - `RetryCurrent` → `RetryCurrent_在线曲丢弃旧地址并重解析` /
 *   `RetryCurrent_本地曲带当前位置重备`（正例）/ `RetryCurrent_重试在途时拒绝` /
 *   `RetryCurrent_解析在途时拒绝`（边界）
 * - `Stop` → `Stop_清播放基准但保留队列`（正例+边界）
 * - `SeekGestureStarted` → `SeekGestureStarted_播放中前置暂停`（正例）/
 *   `SeekGestureStarted_未播放时无操作`（边界）
 * - `SeekGestureCompleted` → `SeekGestureCompleted_落目标位置并下发定位`（正例）/
 *   `SeekGestureCompleted_未知时长拒绝`（边界）
 *
 * **队列编辑**：
 * - `AppendToQueue` → `AppendToQueue_按id去重并涨修订号`（正例）/ `AppendToQueue_全部重复时无操作`（边界）
 * - `InsertAfterCurrent` → `InsertAfterCurrent_插到当前曲之后`（正例）/
 *   `InsertAfterCurrent_空队列退化为追加` / `InsertAfterCurrent_仅传入当前曲时无操作`（边界）
 * - `RemoveAt` → `RemoveAt_删非当前曲仅索引前移`（正例）/ `RemoveAt_越界拒绝` /
 *   `RemoveAt_删当前曲播放中重备新当前曲` / `RemoveAt_删当前曲暂停时不复活播放` /
 *   `RemoveAt_删至空队列停机`（边界）
 * - `RemoveMany` → `RemoveMany_批量删非当前曲`（正例）/ `RemoveMany_含当前曲时重定位重备` /
 *   `RemoveMany_删至空队列停机` / `RemoveMany_空集合无操作`（边界）
 * - `ReorderQueue` → `ReorderQueue_重排并保持当前曲索引正确`（正例）/
 *   `ReorderQueue_越界无操作` / `ReorderQueue_原地移动无操作`（边界）
 * - `SortQueue` → `SortQueue_按标题重排且当前曲跟随`（正例）/ `SortQueue_QUEUE维度无操作` /
 *   `SortQueue_不足两首无操作`（边界）
 * - `UpdateSong` → `UpdateSong_纯写写不重备` / `UpdateSong_解析回写收尾后重备当前曲`（正例）/
 *   `UpdateSong_未命中同id曲目无操作`（边界）
 * - `ClearQueue` → `ClearQueue_停机并清空队列`（正例）/ `ClearQueue_空队列上也产生停机效果`（边界）
 *
 * **播放偏好**：
 * - `ToggleLoopMode` → `ToggleLoopMode_三态切换且不涨修订号`（正例+边界）
 * - `CyclePlayMode` → `CyclePlayMode_不循环进列表循环不涨修订号` /
 *   `CyclePlayMode_单曲循环进随机且涨修订号` / `CyclePlayMode_随机退出恢复原始顺序并关循环`（正例+边界）
 * - `SetVolume` → `SetVolume_钳位并下发引擎音量`（正例+边界）
 * - `SetSpeed` → `SetSpeed_钳位到区间`（正例+边界）
 * - `SetAudioQuality` → `SetAudioQuality_变更后清实际音质并对在线当前曲重解析`（正例）/
 *   `SetAudioQuality_同值无操作` / `SetAudioQuality_本地当前曲不触发解析` /
 *   `SetAudioQuality_移动网络写移动键`（边界）
 * - `SetSleepTimer` → `SetSleepTimer_设置倒计时记录剩余`（正例）/ `SetSleepTimer_取消时清等待态与勾选`（边界）
 * - `SetStopAfterCurrentTrack` → `SetStopAfterCurrentTrack_启用仅记偏好`（正例）/
 *   `SetStopAfterCurrentTrack_取消时撤销到点等待态`（边界）
 * - `SetIgnoreAudioFocus` → `SetIgnoreAudioFocus_只落盘不写状态`（正例+边界）
 * - `SetAudioFocusInterruptionMode` → `SetAudioFocusInterruptionMode_只落盘不写状态`（正例+边界）
 * - `SetShowQualityDowngradeToast` → `SetShowQualityDowngradeToast_写内存并落盘`（正例+边界）
 * - `SetRestoreMemoryEnabled` → `SetRestoreMemoryEnabled_只落盘不写状态`（正例+边界）
 * - `SetCloseLocalMusicComments` → `SetCloseLocalMusicComments_变更才落盘`（正例）/
 *   `SetCloseLocalMusicComments_同值无操作`（边界）
 *
 * **派生刷新与落盘**：`RefreshQualityForNetwork` → `RefreshQualityForNetwork_归约层无状态变化`；
 * `RefreshCrossfadeSettings` → `RefreshCrossfadeSettings_归约层无操作`；
 * `RefreshNotification` → `RefreshNotification_只发通知刷新效果`；
 * `FlushPersistence` → `FlushPersistence_只发落盘效果`（各含正例+边界断言）。
 *
 * **收藏**：`ToggleFavorite` → `ToggleFavorite_有当前曲时发收藏切换效果`（正例）/
 * `ToggleFavorite_无当前曲无操作`（边界）。
 *
 * **事件（12）**：
 * - `EnginePlaybackStateChanged` → `EnginePlaybackStateChanged_READY清未就绪标志` /
 *   `..._BUFFERING置未就绪但不抢写播放态` / `..._IDLE收敛播放态` / `..._ENDED只置未就绪不抢写isPlaying`
 * - `EngineIsPlayingChanged` → `EngineIsPlayingChanged_唯一播放态写入口`
 * - `EnginePositionChanged` → `EnginePositionChanged_同步平台位置并带动展示位置` /
 *   `..._落后于乐观目标的采样被抑制`
 * - `EngineDurationChanged` → `EngineDurationChanged_写入与清空`
 * - `EngineMediaItemTransition` → `..._与当前曲相符时确认且不改状态` / `..._迟到旧曲transition被忽略`
 * - `EnginePlaybackCompleted` → `..._单曲循环重播当前曲` / `..._单曲循环在线曲异常结束走断点重解析` /
 *   `..._列表循环推进到下一首` / `..._列表循环队尾绕回队首` / `..._OFF队尾提示并停机` /
 *   `..._已结束态重复投递为无操作` / `..._空队列无操作` / `..._定时到点等待态播完即停` /
 *   `..._等待态异常结束不算播完继续循环语义`
 * - `EngineError` → `EngineError_原始错误入状态且待推进标志清理` / `EngineError_空消息回落兜底文案`
 * - `NetworkChanged` → `NetworkChanged_切换网络只写标志` / `..._同值无操作`
 * - `AppForegroundChanged` → `AppForegroundChanged_归约层无状态可写`
 * - `VolumeChanged` → `VolumeChanged_引擎侧瞬态音量不改写用户设置`
 * - `LoopModeChanged` → `LoopModeChanged_外部循环模式对齐队列` / `..._同值无操作`
 * - `PlaybackProgressConfirmed` → `PlaybackProgressConfirmed_清理等待推进标志`
 *
 * **7 类竞态**：`竞态1_快速连续切歌_末态为第二目标且过期transition被丢弃` /
 * `竞态2_旧曲目回调迟到被身份对账丢弃` / `竞态3_暂停早于准备完成_状态不自相矛盾` /
 * `竞态4_播放结束与手动切歌交错_两种顺序均有确定末态` / `竞态5_seek手势与进度回调交错_乐观值保留` /
 * `竞态6_释放后旧事件_空队列下全部惰性` / `竞态7_队列变化与自动下一首交错_索引一致且空队列停机`。
 */
class PlaybackReducerTest {

    // ───────────────────────── 测试基建 ─────────────────────────

    private fun localSongs(vararg ids: String): List<com.gracemusic.data.model.Song> =
        ids.map { testSong(it, isOnline = false, localPath = "/music/$it.flac") }

    private fun onlineSongs(vararg ids: String): List<com.gracemusic.data.model.Song> =
        ids.map { testSong(it) }

    private fun stateOf(
        songs: List<com.gracemusic.data.model.Song>,
        currentIndex: Int = 0,
        loopMode: AppLoopMode = AppLoopMode.OFF,
        shuffleEnabled: Boolean = false,
        revision: Int = 0,
    ): PlaybackState = PlaybackState(
        queue = PlaybackQueue(
            playlist = songs,
            originalPlaylist = songs,
            currentIndex = currentIndex,
            shuffleEnabled = shuffleEnabled,
            loopMode = loopMode,
        ),
        queueRevision = revision,
    )

    /** 播放中快照：isPlaying = true，位置/平台位置一致，时长默认 200s。 */
    private fun playing(
        songs: List<com.gracemusic.data.model.Song>,
        currentIndex: Int = 0,
        loopMode: AppLoopMode = AppLoopMode.OFF,
        duration: Duration? = 200.seconds,
        position: Duration = 30.seconds,
        awaiting: Boolean = false,
        revision: Int = 0,
    ): PlaybackState = stateOf(songs, currentIndex, loopMode, revision = revision).copy(
        isPlaying = true,
        duration = duration,
        position = position,
        platformPosition = position,
        awaitingPlaybackProgress = awaiting,
    )

    /** 非法操作的明确拒绝：状态原样 + 空效果。 */
    private fun assertRejected(before: PlaybackState, transition: PlaybackTransition) {
        assertEquals(before, transition.state)
        assertTrue(transition.effects.isEmpty())
    }

    private fun reduceIntent(
        state: PlaybackState,
        intent: PlaybackIntent,
        random: Random = Random(1),
    ): PlaybackTransition = PlaybackReducer.reduce(state, intent, random)

    // ═══════════════════════ 装载与起播 ═══════════════════════

    @Test
    fun `PlaySingleSong_本地曲直接备播并换成单曲队列`() {
        val song = testSong("s1", isOnline = false, localPath = "/music/s1.flac")
        val t = reduceIntent(PlaybackState(), PlaybackIntent.PlaySingleSong(song))

        assertEquals(listOf("s1"), idsOf(t.state.playlist))
        assertEquals(0, t.state.currentIndex)
        assertEquals("s1", t.state.currentSong?.id)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertFalse(t.state.isResolvingUrl)
        assertNull(t.state.resolveError)
        assertEquals(Duration.ZERO, t.state.position)
        assertEquals(Duration.ZERO, t.state.platformPosition)
        assertNull(t.state.duration)
        assertEquals(1, t.state.queueRevision)
        assertEquals(
            listOf(Prepare(song, startPositionMs = null, playWhenReady = true), StartKeepAlive, PersistPlaybackCursor),
            t.effects,
        )
    }

    @Test
    fun `PlaySingleSong_在线曲无地址走解析且标记解析中`() {
        val song = testSong("o1")
        val t = reduceIntent(PlaybackState(), PlaybackIntent.PlaySingleSong(song))

        assertTrue(t.state.isResolvingUrl)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(
            listOf(ResolveSongUrl(song), StartKeepAlive, PersistPlaybackCursor),
            t.effects,
        )
    }

    @Test
    fun `PlaySingleSong_保留队列既有随机与循环偏好`() {
        // Dart playSong 直接赋值三个队列字段，不触碰 _shuffleEnabled / _loopMode。
        val before = stateOf(onlineSongs("a", "b"), shuffleEnabled = true, loopMode = AppLoopMode.ALL)
        val t = reduceIntent(before, PlaybackIntent.PlaySingleSong(testSong("x", isOnline = false, localPath = "/x.flac")))

        assertTrue(t.state.shuffleEnabled)
        assertEquals(AppLoopMode.ALL, t.state.loopMode)
    }

    @Test
    fun `PlayOnlineSingleSong_已带地址也强制重新解析`() {
        // Dart playOnlineSong：无论是否已带 url 都重新解析（缓存路径默认关闭）。
        val song = testSong("o1", url = "http://stale/o1.mp3")
        val t = reduceIntent(PlaybackState(), PlaybackIntent.PlayOnlineSingleSong(song))

        assertTrue(t.state.isResolvingUrl)
        assertEquals(listOf("o1"), idsOf(t.state.playlist))
        assertEquals(
            listOf(ResolveSongUrl(song), StartKeepAlive, PersistPlaybackCursor),
            t.effects,
        )
    }

    @Test
    fun `PlayPlaylistFrom_非随机保持原序并从起始索引起播`() {
        val songs = localSongs("a", "b", "c")
        val t = reduceIntent(PlaybackState(), PlaybackIntent.PlayPlaylistFrom(songs, startIndex = 2))

        assertEquals(listOf("a", "b", "c"), idsOf(t.state.playlist))
        assertEquals(listOf("a", "b", "c"), idsOf(t.state.queue.originalPlaylist))
        assertEquals(2, t.state.currentIndex)
        assertEquals("c", t.state.currentSong?.id)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(1, t.state.queueRevision)
        assertEquals(
            listOf(
                Prepare(songs[2], startPositionMs = null, playWhenReady = true),
                StartKeepAlive,
                PersistPlaybackCursor,
            ),
            t.effects,
        )
    }

    @Test
    fun `PlayPlaylistFrom_空列表拒绝`() {
        val before = playing(onlineSongs("a"))
        val t = reduceIntent(before, PlaybackIntent.PlayPlaylistFrom(emptyList(), startIndex = 0))
        assertRejected(before, t)
    }

    @Test
    fun `PlayPlaylistFrom_随机模式起始曲置首且同源可复现`() {
        val songs = onlineSongs("a", "b", "c", "d")
        val base = PlaybackState(queue = PlaybackQueue(shuffleEnabled = true))

        val t1 = reduceIntent(base, PlaybackIntent.PlayPlaylistFrom(songs, startIndex = 2), random = Random(7))
        val t2 = reduceIntent(base, PlaybackIntent.PlayPlaylistFrom(songs, startIndex = 2), random = Random(7))

        assertEquals("c", t1.state.playlist.first().id)
        assertEquals(0, t1.state.currentIndex)
        assertEquals(setOf("a", "b", "c", "d"), t1.state.playlist.mapTo(HashSet()) { it.id })
        // 同随机源 → 同输出（纯函数可重放）
        assertEquals(idsOf(t1.state.playlist), idsOf(t2.state.playlist))
        assertEquals(t1, t2)
    }

    @Test
    fun `PlayPlaylistFrom_起始索引越界收敛到合法区间`() {
        val t = reduceIntent(
            PlaybackState(),
            PlaybackIntent.PlayPlaylistFrom(localSongs("a", "b"), startIndex = 99),
        )
        assertEquals(1, t.state.currentIndex)
    }

    @Test
    fun `PlayOnlinePlaylistFrom_装载并强制解析当前曲`() {
        val songs = onlineSongs("a", "b")
        val t = reduceIntent(PlaybackState(), PlaybackIntent.PlayOnlinePlaylistFrom(songs, startIndex = 1))

        assertEquals(listOf("a", "b"), idsOf(t.state.playlist))
        assertEquals(1, t.state.currentIndex)
        assertTrue(t.state.isResolvingUrl)
        assertEquals(
            listOf(ResolveSongUrl(songs[1]), StartKeepAlive, PersistPlaybackCursor),
            t.effects,
        )

        val before = playing(onlineSongs("a"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.PlayOnlinePlaylistFrom(emptyList(), 0)))
    }

    @Test
    fun `PlayCloudPlaylistFrom_装载云盘队列并解析`() {
        val cloud = listOf(testSong("c1", isOnline = true, isCloud = true))
        val t = reduceIntent(PlaybackState(), PlaybackIntent.PlayCloudPlaylistFrom(cloud, startIndex = 0))

        assertEquals(listOf("c1"), idsOf(t.state.playlist))
        assertTrue(t.state.isResolvingUrl)
        assertEquals(
            listOf(ResolveSongUrl(cloud[0]), StartKeepAlive, PersistPlaybackCursor),
            t.effects,
        )

        val before = playing(onlineSongs("a"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.PlayCloudPlaylistFrom(emptyList(), 0)))
    }

    @Test
    fun `PlayAt_播放列表面板指定下标`() {
        val before = stateOf(localSongs("a", "b", "c"), currentIndex = 0, revision = 3)
        val t = reduceIntent(before, PlaybackIntent.PlayAt(index = 2))

        assertEquals(2, t.state.currentIndex)
        assertEquals("c", t.state.currentSong?.id)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(4, t.state.queueRevision)
        assertEquals(
            listOf(
                Prepare(testSong("c", isOnline = false, localPath = "/music/c.flac"), null, true),
                StartKeepAlive,
                PersistPlaybackCursor,
            ),
            t.effects,
        )
    }

    @Test
    fun `PlayAt_越界索引拒绝`() {
        val before = stateOf(onlineSongs("a", "b"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.PlayAt(index = 5)))
        assertRejected(before, reduceIntent(before, PlaybackIntent.PlayAt(index = -1)))
        val empty = PlaybackState()
        assertRejected(empty, reduceIntent(empty, PlaybackIntent.PlayAt(index = 0)))
    }

    // ═══════════════════════ 传输控制 ═══════════════════════

    @Test
    fun `Resume_就绪态直接起播`() {
        val before = playing(localSongs("a"))
        val t = reduceIntent(before, PlaybackIntent.Resume)

        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(Play, StartKeepAlive, PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `Resume_空队列拒绝`() {
        val before = PlaybackState()
        assertRejected(before, reduceIntent(before, PlaybackIntent.Resume))
    }

    @Test
    fun `Resume_未就绪时带当前位置重备`() {
        val before = playing(localSongs("a"), position = 90.seconds).copy(playbackNotReady = true)
        val t = reduceIntent(before, PlaybackIntent.Resume)

        assertTrue(t.state.awaitingPlaybackProgress)
        assertFalse(t.state.isResolvingUrl)
        assertEquals(
            listOf(
                Prepare(testSong("a", isOnline = false, localPath = "/music/a.flac"), 90_000, true),
                StartKeepAlive,
                PersistPlaybackCursor,
            ),
            t.effects,
        )
    }

    @Test
    fun `Resume_解析在途时重新发起解析`() {
        val song = testSong("o1")
        val before = stateOf(listOf(song)).copy(isResolvingUrl = true)
        val t = reduceIntent(before, PlaybackIntent.Resume)

        assertTrue(t.state.isResolvingUrl)
        assertEquals(listOf(ResolveSongUrl(song), StartKeepAlive, PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `Pause_清等待标志且不抢写播放态`() {
        // isPlaying 只由引擎事件写入（台本 §3.5 规则 1）：Pause 意图保持原值，
        // 由 EngineIsPlayingChanged(false) 收敛。
        val before = playing(onlineSongs("a")).copy(awaitingPlaybackProgress = true)
        val t = reduceIntent(before, PlaybackIntent.Pause)

        assertFalse(t.state.awaitingPlaybackProgress)
        assertTrue(t.state.isPlaying)
        assertEquals(listOf(Pause, StopKeepAlive, PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `PauseForSeek_只前置暂停不停保活不落盘`() {
        val before = playing(onlineSongs("a")).copy(awaitingPlaybackProgress = true, isResolvingUrl = true)
        val t = reduceIntent(before, PlaybackIntent.PauseForSeek)

        assertFalse(t.state.awaitingPlaybackProgress)
        assertFalse(t.state.isResolvingUrl) // Dart _invalidatePlaybackRequest 对齐
        assertEquals(listOf(Pause), t.effects)
    }

    @Test
    fun `SeekTo_乐观写位置并下发绝对定位`() {
        val before = playing(localSongs("a"), position = 30.seconds)
        val t = reduceIntent(before, PlaybackIntent.SeekTo(90.seconds))

        assertEquals(90.seconds, t.state.position)
        assertEquals(30.seconds, t.state.platformPosition) // 平台位置等引擎确认
        assertEquals(listOf(SeekTo(90_000), PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `SeekTo_未知时长拒绝`() {
        val before = playing(localSongs("a"), duration = null)
        assertRejected(before, reduceIntent(before, PlaybackIntent.SeekTo(90.seconds)))
    }

    @Test
    fun `SeekTo_无当前曲拒绝`() {
        val before = PlaybackState(duration = 200.seconds)
        assertRejected(before, reduceIntent(before, PlaybackIntent.SeekTo(10.seconds)))
    }

    @Test
    fun `SeekTo_目标越界钳位到时长`() {
        // Dart：just_audio 内部 clamp（player_provider.dart:4222 直接下传）。
        val t = reduceIntent(playing(localSongs("a"), duration = 200.seconds), PlaybackIntent.SeekTo(999.seconds))
        assertEquals(200.seconds, t.state.position)
        assertEquals(listOf(SeekTo(200_000), PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `SeekTo_播完停机后拒绝`() {
        // 台本 §3.5：ENDED 后 seek 拒绝。终态由 Completed 停机分支 + ENDED 状态事件收敛。
        val ended = playing(localSongs("a"))
            .let { PlaybackReducer.reduce(it, PlaybackEvent.EnginePlaybackCompleted).state }
        assertRejected(ended, reduceIntent(ended, PlaybackIntent.SeekTo(10.seconds)))
    }

    @Test
    fun `SeekTo_装载缓冲期不误伤`() {
        // BUFFERING 期间 isPlaying 仍为 true → 不命中终态判据，seek 放行。
        val buffering = playing(localSongs("a"))
            .let { PlaybackReducer.reduce(it, PlaybackEvent.EnginePlaybackStateChanged(2)).state }
        val t = reduceIntent(buffering, PlaybackIntent.SeekTo(60.seconds))
        assertEquals(60.seconds, t.state.position)
    }

    @Test
    fun `SeekBy_正向相对定位`() {
        val t = reduceIntent(playing(localSongs("a"), position = 30.seconds), PlaybackIntent.SeekBy(15.seconds))
        assertEquals(45.seconds, t.state.position)
        assertEquals(listOf(SeekBy(15_000), PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `SeekBy_负向钳位到零`() {
        val t = reduceIntent(playing(localSongs("a"), position = 5.seconds), PlaybackIntent.SeekBy((-10).seconds))
        assertEquals(Duration.ZERO, t.state.position)
        assertEquals(listOf(SeekBy(-10_000), PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `Next_非队尾前进一位并重备`() {
        val before = playing(onlineSongs("a", "b", "c"))
        val t = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))

        assertEquals(1, t.state.currentIndex)
        assertEquals("b", t.state.currentSong?.id)
        assertEquals(Duration.ZERO, t.state.position)
        assertNull(t.state.duration)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(before.queueRevision, t.state.queueRevision) // next 不涨修订号
        assertEquals(
            listOf(ResolveSongUrl(testSong("b")), StartKeepAlive, PersistPlaybackCursor),
            t.effects,
        )
    }

    @Test
    fun `Next_空队列拒绝`() {
        val before = PlaybackState()
        assertRejected(before, reduceIntent(before, PlaybackIntent.Next(autoPlay = true)))
    }

    @Test
    fun `Next_OFF停在末曲提示并暂停`() {
        val before = playing(onlineSongs("a", "b"), currentIndex = 1)
        val t = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))

        assertEquals(1, t.state.currentIndex) // 索引不动
        assertFalse(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(ShowMessage("已经是最后一首了"), Pause, StopKeepAlive), t.effects)
    }

    @Test
    fun `Next_单曲循环且仅一首时重播当前曲`() {
        val before = playing(localSongs("a"), loopMode = AppLoopMode.ONE, position = 200.seconds)
        val t = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))

        assertEquals(0, t.state.currentIndex)
        assertEquals(Duration.ZERO, t.state.position)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(SeekTo(0L), Play, StartKeepAlive, PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `Next_列表循环队尾绕回队首`() {
        val before = playing(onlineSongs("a", "b"), currentIndex = 1, loopMode = AppLoopMode.ALL)
        val t = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))

        assertEquals(0, t.state.currentIndex)
        assertEquals("a", t.state.currentSong?.id)
    }

    @Test
    fun `Next_单曲加列表循环绕回起点为无操作`() {
        // Dart：nextIndex == startIndex → break，循环后仅通知、不落盘（_saveState
        // 在循环体内，未到达），故效果为空。
        val before = playing(onlineSongs("a"), loopMode = AppLoopMode.ALL)
        val t = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))

        assertEquals(before.queue, t.state.queue)
        assertEquals(before.currentIndex, t.state.currentIndex)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `Next_预载模式不出声不等待推进`() {
        val t = reduceIntent(playing(onlineSongs("a", "b")), PlaybackIntent.Next(autoPlay = false))

        assertEquals(1, t.state.currentIndex)
        assertFalse(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(ResolveSongUrl(testSong("b")), PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `Previous_队首绕到队尾`() {
        val before = playing(onlineSongs("a", "b", "c"), currentIndex = 0)
        val t = reduceIntent(before, PlaybackIntent.Previous(autoPlay = true))

        assertEquals(2, t.state.currentIndex)
        assertEquals("c", t.state.currentSong?.id)
        assertEquals(Duration.ZERO, t.state.position)
    }

    @Test
    fun `Previous_空队列拒绝`() {
        val before = PlaybackState()
        assertRejected(before, reduceIntent(before, PlaybackIntent.Previous(autoPlay = true)))
    }

    @Test
    fun `Previous_单曲加列表循环绕回起点仅落盘`() {
        // Dart previousWrapAction：ALL → break（仅落盘 + 通知，不改播放）。
        val before = playing(localSongs("a"), loopMode = AppLoopMode.ALL, position = 30.seconds)
        val t = reduceIntent(before, PlaybackIntent.Previous(autoPlay = true))

        assertEquals(0, t.state.currentIndex)
        assertEquals(30.seconds, t.state.position) // 不定位回零
        assertEquals(listOf(PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `Previous_单曲非列表循环绕回时定位回零`() {
        // 与 next 的 RestartSingle 不对称：只 seek(0)，不补 play（Dart 既有设计）。
        val before = playing(localSongs("a"), position = 30.seconds)
        val t = reduceIntent(before, PlaybackIntent.Previous(autoPlay = true))

        assertEquals(Duration.ZERO, t.state.position)
        assertEquals(listOf(SeekTo(0L), PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `RetryCurrent_在线曲丢弃旧地址并重解析`() {
        val song = testSong("o1", url = "http://stale/o1.mp3")
        val before = stateOf(listOf(song)).copy(resolveError = "播放失败，请重试")
        val t = reduceIntent(before, PlaybackIntent.RetryCurrent)

        assertTrue(t.state.manualRetryInFlight)
        assertTrue(t.state.isResolvingUrl)
        assertNull(t.state.currentSong?.url) // 旧地址已丢弃
        assertNull(t.state.resolveError)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(
            listOf(ResolveSongUrl(testSong("o1")), StartKeepAlive, PersistPlaybackCursor),
            t.effects,
        )
    }

    @Test
    fun `RetryCurrent_本地曲带当前位置重备`() {
        val before = playing(localSongs("a"), position = 42.seconds).copy(resolveError = "播放失败，请重试")
        val t = reduceIntent(before, PlaybackIntent.RetryCurrent)

        assertTrue(t.state.manualRetryInFlight)
        assertNull(t.state.resolveError)
        assertEquals(
            listOf(
                Prepare(testSong("a", isOnline = false, localPath = "/music/a.flac"), 42_000, true),
                StartKeepAlive,
                PersistPlaybackCursor,
            ),
            t.effects,
        )
    }

    @Test
    fun `RetryCurrent_重试在途时拒绝`() {
        val before = stateOf(localSongs("a")).copy(manualRetryInFlight = true)
        assertRejected(before, reduceIntent(before, PlaybackIntent.RetryCurrent))
    }

    @Test
    fun `RetryCurrent_解析在途时拒绝`() {
        val before = stateOf(localSongs("a")).copy(isResolvingUrl = true)
        assertRejected(before, reduceIntent(before, PlaybackIntent.RetryCurrent))
    }

    @Test
    fun `RetryCurrent_无当前曲拒绝`() {
        val before = PlaybackState()
        assertRejected(before, reduceIntent(before, PlaybackIntent.RetryCurrent))
    }

    @Test
    fun `Stop_清播放基准但保留队列`() {
        val before = playing(onlineSongs("a", "b"), position = 30.seconds).copy(resolveError = "boom")
        val t = reduceIntent(before, PlaybackIntent.Stop)

        assertEquals(listOf("a", "b"), idsOf(t.state.playlist)) // 队列保留
        assertEquals(Duration.ZERO, t.state.position)
        assertEquals(Duration.ZERO, t.state.platformPosition)
        assertNull(t.state.duration)
        assertNull(t.state.resolveError)
        assertFalse(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(Stop, StopKeepAlive, PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `SeekGestureStarted_播放中前置暂停`() {
        val before = playing(localSongs("a")).copy(awaitingPlaybackProgress = true)
        val t = reduceIntent(before, PlaybackIntent.SeekGestureStarted(wasPlaying = true))

        assertFalse(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(Pause), t.effects)
    }

    @Test
    fun `SeekGestureStarted_未播放时无操作`() {
        val before = playing(localSongs("a")).copy(isPlaying = false)
        assertRejected(before, reduceIntent(before, PlaybackIntent.SeekGestureStarted(wasPlaying = false)))
    }

    @Test
    fun `SeekGestureCompleted_落目标位置并下发定位`() {
        val t = reduceIntent(
            playing(localSongs("a")),
            PlaybackIntent.SeekGestureCompleted(sessionId = 7, position = 120.seconds),
        )
        assertEquals(120.seconds, t.state.position)
        assertEquals(listOf(SeekTo(120_000), PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `SeekGestureCompleted_未知时长拒绝`() {
        val before = playing(localSongs("a"), duration = null)
        assertRejected(before, reduceIntent(before, PlaybackIntent.SeekGestureCompleted(sessionId = 7, position = 10.seconds)))
    }

    // ═══════════════════════ 队列编辑 ═══════════════════════

    @Test
    fun `AppendToQueue_按id去重并涨修订号`() {
        val before = stateOf(onlineSongs("a", "b"))
        val t = reduceIntent(before, PlaybackIntent.AppendToQueue(listOf(testSong("b"), testSong("c"))))

        assertEquals(listOf("a", "b", "c"), idsOf(t.state.playlist))
        assertEquals(1, t.state.queueRevision)
        assertEquals(listOf(PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `AppendToQueue_全部重复时无操作`() {
        val before = stateOf(onlineSongs("a"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.AppendToQueue(listOf(testSong("a")))))
    }

    @Test
    fun `InsertAfterCurrent_插到当前曲之后`() {
        val before = stateOf(onlineSongs("a", "b", "c"), currentIndex = 0)
        val t = reduceIntent(before, PlaybackIntent.InsertAfterCurrent(listOf(testSong("x"))))

        assertEquals(listOf("a", "x", "b", "c"), idsOf(t.state.playlist))
        assertEquals(0, t.state.currentIndex)
        assertEquals(1, t.state.queueRevision)
    }

    @Test
    fun `InsertAfterCurrent_空队列退化为追加`() {
        val t = reduceIntent(PlaybackState(), PlaybackIntent.InsertAfterCurrent(listOf(testSong("x"))))
        assertEquals(listOf("x"), idsOf(t.state.playlist))
    }

    @Test
    fun `InsertAfterCurrent_仅传入当前曲时无操作`() {
        val before = stateOf(onlineSongs("a", "b"), currentIndex = 0)
        assertRejected(before, reduceIntent(before, PlaybackIntent.InsertAfterCurrent(listOf(testSong("a")))))
    }

    @Test
    fun `RemoveAt_删非当前曲仅索引前移`() {
        val before = stateOf(onlineSongs("a", "b", "c"), currentIndex = 2)
        val t = reduceIntent(before, PlaybackIntent.RemoveAt(index = 0))

        assertEquals(listOf("b", "c"), idsOf(t.state.playlist))
        assertEquals(1, t.state.currentIndex)
        assertEquals(1, t.state.queueRevision)
        assertEquals(listOf(PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `RemoveAt_越界拒绝`() {
        val before = stateOf(onlineSongs("a"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.RemoveAt(index = 5)))
        assertRejected(before, reduceIntent(before, PlaybackIntent.RemoveAt(index = -1)))
    }

    @Test
    fun `RemoveAt_删当前曲播放中重备新当前曲`() {
        val before = playing(localSongs("a", "b"), currentIndex = 0)
        val t = reduceIntent(before, PlaybackIntent.RemoveAt(index = 0))

        assertEquals(listOf("b"), idsOf(t.state.playlist))
        assertEquals(0, t.state.currentIndex)
        assertEquals("b", t.state.currentSong?.id)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(Duration.ZERO, t.state.position)
        assertEquals(
            listOf(
                Prepare(testSong("b", isOnline = false, localPath = "/music/b.flac"), 0L, true),
                StartKeepAlive,
                PersistPlaybackCursor,
            ),
            t.effects,
        )
    }

    @Test
    fun `RemoveAt_删当前曲暂停时不复活播放`() {
        // 差异项 3：Dart 无条件 playCommand；native 按 isPlaying 决定 playWhenReady。
        val before = playing(localSongs("a", "b"), currentIndex = 0).copy(isPlaying = false)
        val t = reduceIntent(before, PlaybackIntent.RemoveAt(index = 0))

        assertFalse(t.state.awaitingPlaybackProgress)
        assertEquals(
            listOf(
                Prepare(testSong("b", isOnline = false, localPath = "/music/b.flac"), 0L, false),
                PersistPlaybackCursor,
            ),
            t.effects,
        )
    }

    @Test
    fun `RemoveAt_删至空队列停机`() {
        val before = playing(localSongs("a"))
        val t = reduceIntent(before, PlaybackIntent.RemoveAt(index = 0))

        assertTrue(t.state.queue.isEmpty)
        assertEquals(-1, t.state.currentIndex)
        assertNull(t.state.currentSong)
        assertEquals(Duration.ZERO, t.state.position)
        assertNull(t.state.duration)
        assertEquals(listOf(Stop, StopKeepAlive, PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `RemoveMany_批量删非当前曲`() {
        val before = stateOf(onlineSongs("a", "b", "c"), currentIndex = 2)
        val t = reduceIntent(before, PlaybackIntent.RemoveMany(setOf("a", "b")))

        assertEquals(listOf("c"), idsOf(t.state.playlist))
        assertEquals(0, t.state.currentIndex)
        assertEquals(1, t.state.queueRevision)
    }

    @Test
    fun `RemoveMany_含当前曲时重定位重备`() {
        val before = playing(localSongs("a", "b", "c"), currentIndex = 1)
        val t = reduceIntent(before, PlaybackIntent.RemoveMany(setOf("b", "c")))

        assertEquals(listOf("a"), idsOf(t.state.playlist))
        assertEquals(0, t.state.currentIndex)
        assertEquals("a", t.state.currentSong?.id)
        assertTrue(t.state.awaitingPlaybackProgress)
    }

    @Test
    fun `RemoveMany_删至空队列停机`() {
        val before = playing(localSongs("a"))
        val t = reduceIntent(before, PlaybackIntent.RemoveMany(setOf("a")))

        assertTrue(t.state.queue.isEmpty)
        assertEquals(listOf(Stop, StopKeepAlive, PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `RemoveMany_空集合无操作`() {
        val before = stateOf(onlineSongs("a"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.RemoveMany(emptySet())))
    }

    @Test
    fun `ReorderQueue_重排并保持当前曲索引正确`() {
        // ReorderableListView 约定：oldIndex < newIndex 时 newIndex 需 -1，
        // 因此 reorder(0, 2) 的实际插入位是 1 → [b, a, c]，当前曲跟随到 1。
        val before = stateOf(onlineSongs("a", "b", "c"), currentIndex = 0)
        val t = reduceIntent(before, PlaybackIntent.ReorderQueue(oldIndex = 0, newIndex = 2))

        assertEquals(listOf("b", "a", "c"), idsOf(t.state.playlist))
        assertEquals(1, t.state.currentIndex) // 当前曲跟随
        assertEquals("a", t.state.currentSong?.id)
        assertEquals(1, t.state.queueRevision)
    }

    @Test
    fun `ReorderQueue_越界无操作`() {
        val before = stateOf(onlineSongs("a", "b"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.ReorderQueue(oldIndex = 0, newIndex = 9)))
    }

    @Test
    fun `ReorderQueue_原地移动无操作`() {
        val before = stateOf(onlineSongs("a", "b"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.ReorderQueue(oldIndex = 1, newIndex = 1)))
    }

    @Test
    fun `SortQueue_按标题重排且当前曲跟随`() {
        val songs = listOf(
            testSong("c", title = "c.mp3"),
            testSong("a", title = "a.mp3"),
            testSong("b", title = "b.mp3"),
        )
        val before = stateOf(songs, currentIndex = 0)
        val t = reduceIntent(before, PlaybackIntent.SortQueue(by = PlaylistSortBy.TITLE, ascending = true))

        assertEquals(listOf("a", "b", "c"), idsOf(t.state.playlist))
        assertEquals(listOf("a", "b", "c"), idsOf(t.state.queue.originalPlaylist))
        assertEquals(2, t.state.currentIndex)
        assertEquals(1, t.state.queueRevision)
    }

    @Test
    fun `SortQueue_QUEUE维度无操作`() {
        val before = stateOf(onlineSongs("b", "a"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.SortQueue(by = PlaylistSortBy.QUEUE)))
    }

    @Test
    fun `SortQueue_不足两首无操作`() {
        val before = stateOf(onlineSongs("a"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.SortQueue(by = PlaylistSortBy.TITLE)))
    }

    @Test
    fun `UpdateSong_纯写写不重备`() {
        // NAS 下载回写 localPath：只换队列项，不打断播放（Dart 同样）。
        val before = playing(localSongs("a", "b"), currentIndex = 0)
        val t = reduceIntent(before, PlaybackIntent.UpdateSong(testSong("b", isOnline = false, localPath = "/new/b.flac")))

        assertEquals("/new/b.flac", t.state.playlist[1].localPath)
        assertEquals("a", t.state.currentSong?.id)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `UpdateSong_解析回写收尾后重备当前曲`() {
        // ResolveSongUrl 执行器解析成功后的回写：清解析标志并按起播意愿重备。
        val song = testSong("o1")
        val before = stateOf(listOf(song)).copy(
            isResolvingUrl = true,
            awaitingPlaybackProgress = true,
            position = 45.seconds,
        )
        val resolved = testSong("o1", url = "http://cdn/o1.mp3")
        val t = reduceIntent(before, PlaybackIntent.UpdateSong(resolved))

        assertFalse(t.state.isResolvingUrl)
        assertEquals("http://cdn/o1.mp3", t.state.currentSong?.url)
        assertEquals(listOf(Prepare(resolved, 45_000, true)), t.effects)
    }

    @Test
    fun `UpdateSong_未命中同id曲目无操作`() {
        val before = stateOf(onlineSongs("a"))
        assertRejected(before, reduceIntent(before, PlaybackIntent.UpdateSong(testSong("zzz"))))
    }

    @Test
    fun `ClearQueue_停机并清空队列`() {
        val before = playing(onlineSongs("a", "b"))
        val t = reduceIntent(before, PlaybackIntent.ClearQueue)

        assertTrue(t.state.queue.isEmpty)
        assertEquals(-1, t.state.currentIndex)
        assertEquals(Duration.ZERO, t.state.position)
        assertNull(t.state.duration)
        assertNull(t.state.resolveError)
        assertEquals(1, t.state.queueRevision)
        assertEquals(listOf(Stop, StopKeepAlive, PersistPlaybackCursor), t.effects)
    }

    @Test
    fun `ClearQueue_空队列上也产生停机效果`() {
        val before = PlaybackState()
        val t = reduceIntent(before, PlaybackIntent.ClearQueue)
        assertTrue(t.state.queue.isEmpty)
        assertEquals(1, t.state.queueRevision)
        assertEquals(listOf(Stop, StopKeepAlive, PersistPlaybackCursor), t.effects)
    }

    // ═══════════════════════ 播放偏好 ═══════════════════════

    @Test
    fun `ToggleLoopMode_三态切换且不涨修订号`() {
        // Dart _applyLoopMode 没有 _queueRevision++（只作废预加载）。
        val off = stateOf(onlineSongs("a"), loopMode = AppLoopMode.OFF)
        val all = reduceIntent(off, PlaybackIntent.ToggleLoopMode)
        assertEquals(AppLoopMode.ALL, all.state.loopMode)
        assertEquals(0, all.state.queueRevision)
        assertEquals(listOf(PersistPlaybackCursor), all.effects)

        val one = reduceIntent(all.state, PlaybackIntent.ToggleLoopMode)
        assertEquals(AppLoopMode.ONE, one.state.loopMode)

        val back = reduceIntent(one.state, PlaybackIntent.ToggleLoopMode)
        assertEquals(AppLoopMode.OFF, back.state.loopMode)
    }

    @Test
    fun `CyclePlayMode_不循环进列表循环不涨修订号`() {
        val t = reduceIntent(stateOf(onlineSongs("a", "b"), loopMode = AppLoopMode.OFF), PlaybackIntent.CyclePlayMode)
        assertEquals(AppLoopMode.ALL, t.state.loopMode)
        assertFalse(t.state.shuffleEnabled)
        assertEquals(0, t.state.queueRevision)
    }

    @Test
    fun `CyclePlayMode_单曲循环进随机且涨修订号`() {
        val t = reduceIntent(
            stateOf(onlineSongs("a", "b", "c"), loopMode = AppLoopMode.ONE),
            PlaybackIntent.CyclePlayMode,
            random = Random(3),
        )
        assertTrue(t.state.shuffleEnabled)
        assertEquals(AppLoopMode.ALL, t.state.loopMode) // 进入随机先置列表循环
        assertEquals(0, t.state.currentIndex) // 当前曲置首
        assertEquals(1, t.state.queueRevision)
    }

    @Test
    fun `CyclePlayMode_随机退出恢复原始顺序并关循环`() {
        val queue = PlaybackQueue(
            playlist = onlineSongs("c", "a", "b"),
            originalPlaylist = onlineSongs("a", "b", "c"),
            currentIndex = 0,
            shuffleEnabled = true,
            loopMode = AppLoopMode.ALL,
        )
        val t = reduceIntent(PlaybackState(queue = queue), PlaybackIntent.CyclePlayMode, random = Random(9))

        assertFalse(t.state.shuffleEnabled)
        assertEquals(AppLoopMode.OFF, t.state.loopMode)
        assertEquals(listOf("a", "b", "c"), idsOf(t.state.playlist))
        assertEquals(2, t.state.currentIndex) // 当前曲 c 还原到原位
        assertEquals("c", t.state.currentSong?.id)
        assertEquals(1, t.state.queueRevision)
    }

    @Test
    fun `SetVolume_钳位并下发引擎音量`() {
        val mid = reduceIntent(PlaybackState(), PlaybackIntent.SetVolume(0.5))
        assertEquals(0.5, mid.state.volume, 0.0)
        assertEquals(listOf(SetVolume(0.5f), PersistPreference("player_volume")), mid.effects)

        val high = reduceIntent(PlaybackState(), PlaybackIntent.SetVolume(1.7))
        assertEquals(1.0, high.state.volume, 0.0)
        val low = reduceIntent(PlaybackState(), PlaybackIntent.SetVolume(-0.5))
        assertEquals(0.0, low.state.volume, 0.0)
    }

    @Test
    fun `SetSpeed_钳位到区间`() {
        val fast = reduceIntent(PlaybackState(), PlaybackIntent.SetSpeed(9.0))
        assertEquals(4.0, fast.state.speed, 0.0)
        assertEquals(listOf(SetSpeed(4.0f)), fast.effects)

        val slow = reduceIntent(PlaybackState(), PlaybackIntent.SetSpeed(0.1))
        assertEquals(0.25, slow.state.speed, 0.0)

        val normal = reduceIntent(PlaybackState(), PlaybackIntent.SetSpeed(1.5))
        assertEquals(1.5, normal.state.speed, 0.0)
    }

    @Test
    fun `SetAudioQuality_变更后清实际音质并对在线当前曲重解析`() {
        val before = stateOf(onlineSongs("o1")).copy(actualPlayingQuality = "320", isWifiNetwork = true)
        val t = reduceIntent(before, PlaybackIntent.SetAudioQuality(AudioQuality.FLAC))

        assertEquals(AudioQuality.FLAC, t.state.audioQuality)
        assertNull(t.state.actualPlayingQuality)
        assertTrue(t.state.isResolvingUrl)
        assertEquals(
            listOf(PersistPreference("settings_default_quality_wifi"), ResolveSongUrl(testSong("o1"))),
            t.effects,
        )
    }

    @Test
    fun `SetAudioQuality_同值无操作`() {
        val before = PlaybackState(audioQuality = AudioQuality.STANDARD)
        assertRejected(before, reduceIntent(before, PlaybackIntent.SetAudioQuality(AudioQuality.STANDARD)))
    }

    @Test
    fun `SetAudioQuality_本地当前曲不触发解析`() {
        val before = stateOf(localSongs("l1"))
        val t = reduceIntent(before, PlaybackIntent.SetAudioQuality(AudioQuality.HIRES))

        assertFalse(t.state.isResolvingUrl)
        assertEquals(listOf(PersistPreference("settings_default_quality_wifi")), t.effects)
    }

    @Test
    fun `SetAudioQuality_移动网络写移动键`() {
        val before = PlaybackState(isWifiNetwork = false)
        val t = reduceIntent(before, PlaybackIntent.SetAudioQuality(AudioQuality.HIGH))
        assertEquals(listOf(PersistPreference("settings_default_quality_mobile")), t.effects)
    }

    @Test
    fun `SetSleepTimer_设置倒计时记录剩余`() {
        val t = reduceIntent(PlaybackState(), PlaybackIntent.SetSleepTimer(30.minutes))
        assertEquals(SleepTimerMode.COUNTDOWN, t.state.sleepTimerMode)
        assertEquals(30.minutes, t.state.sleepTimerRemaining)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `SetSleepTimer_取消时清等待态与勾选`() {
        val before = PlaybackState(sleepTimerMode = SleepTimerMode.END_OF_TRACK, stopAfterTimerEnds = true)
        val t = reduceIntent(before, PlaybackIntent.SetSleepTimer(duration = null))

        assertEquals(SleepTimerMode.OFF, t.state.sleepTimerMode)
        assertNull(t.state.sleepTimerRemaining)
        assertFalse(t.state.stopAfterTimerEnds)
    }

    @Test
    fun `SetStopAfterCurrentTrack_启用仅记偏好`() {
        val before = PlaybackState(sleepTimerMode = SleepTimerMode.COUNTDOWN)
        val t = reduceIntent(before, PlaybackIntent.SetStopAfterCurrentTrack(enabled = true))

        assertTrue(t.state.stopAfterTimerEnds)
        assertEquals(SleepTimerMode.COUNTDOWN, t.state.sleepTimerMode) // 等待态由到点设置
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `SetStopAfterCurrentTrack_取消时撤销到点等待态`() {
        val before = PlaybackState(sleepTimerMode = SleepTimerMode.END_OF_TRACK, stopAfterTimerEnds = true)
        val t = reduceIntent(before, PlaybackIntent.SetStopAfterCurrentTrack(enabled = false))

        assertFalse(t.state.stopAfterTimerEnds)
        assertEquals(SleepTimerMode.OFF, t.state.sleepTimerMode)
    }

    @Test
    fun `SetIgnoreAudioFocus_只落盘不写状态`() {
        val before = PlaybackState()
        val t = reduceIntent(before, PlaybackIntent.SetIgnoreAudioFocus(enabled = true))
        assertEquals(before, t.state)
        assertEquals(listOf(PersistPreference("settings_ignore_audio_focus")), t.effects)
    }

    @Test
    fun `SetAudioFocusInterruptionMode_只落盘不写状态`() {
        val before = PlaybackState()
        val t = reduceIntent(before, PlaybackIntent.SetAudioFocusInterruptionMode(AudioFocusInterruptionMode.PAUSE_AND_RESUME))
        assertEquals(before, t.state)
        assertEquals(listOf(PersistPreference("settings_audio_focus_interruption_mode")), t.effects)
    }

    @Test
    fun `SetShowQualityDowngradeToast_写内存并落盘`() {
        val t = reduceIntent(PlaybackState(), PlaybackIntent.SetShowQualityDowngradeToast(enabled = true))
        assertTrue(t.state.showQualityDowngradeToast)
        assertEquals(listOf(PersistPreference("settings_show_quality_downgrade_toast")), t.effects)
    }

    @Test
    fun `SetRestoreMemoryEnabled_只落盘不写状态`() {
        val before = PlaybackState()
        val t = reduceIntent(before, PlaybackIntent.SetRestoreMemoryEnabled(enabled = false))
        assertEquals(before, t.state)
        assertEquals(listOf(PersistPreference("settings_restore_memory")), t.effects)
    }

    @Test
    fun `SetCloseLocalMusicComments_变更才落盘`() {
        val before = PlaybackState(closeLocalMusicComments = true)
        val t = reduceIntent(before, PlaybackIntent.SetCloseLocalMusicComments(enabled = false))
        assertFalse(t.state.closeLocalMusicComments)
        assertEquals(listOf(PersistPreference("settings_close_local_music_comments")), t.effects)
    }

    @Test
    fun `SetCloseLocalMusicComments_同值无操作`() {
        val before = PlaybackState(closeLocalMusicComments = true)
        assertRejected(before, reduceIntent(before, PlaybackIntent.SetCloseLocalMusicComments(enabled = true)))
    }

    // ═══════════════════════ 派生刷新与落盘 ═══════════════════════

    @Test
    fun `RefreshQualityForNetwork_归约层无状态变化`() {
        // 设置读取归 Store；读到新值后经 SetAudioQuality 回灌（唯一归约路径）。
        val before = playing(onlineSongs("a"))
        val t = reduceIntent(before, PlaybackIntent.RefreshQualityForNetwork)
        assertEquals(before, t.state)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `RefreshCrossfadeSettings_归约层无操作`() {
        // 交叉淡化未接线（T-P1-07）且词汇表无对应意图，暂为触发器 no-op。
        val before = playing(onlineSongs("a"))
        val t = reduceIntent(before, PlaybackIntent.RefreshCrossfadeSettings)
        assertEquals(before, t.state)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `RefreshNotification_只发通知刷新效果`() {
        val t = reduceIntent(PlaybackState(), PlaybackIntent.RefreshNotification)
        assertEquals(listOf(RefreshSystemNotification), t.effects)
    }

    @Test
    fun `FlushPersistence_只发落盘效果`() {
        val t = reduceIntent(PlaybackState(), PlaybackIntent.FlushPersistence)
        assertEquals(listOf(PersistPlaybackCursor), t.effects)
    }

    // ═══════════════════════ 收藏 ═══════════════════════

    @Test
    fun `ToggleFavorite_有当前曲时发收藏切换效果`() {
        val before = stateOf(onlineSongs("a"))
        val t = reduceIntent(before, PlaybackIntent.ToggleFavorite)
        assertEquals(before, t.state) // 收藏态属数据层，状态无字段
        assertEquals(listOf(PersistFavoriteToggle("a")), t.effects)
    }

    @Test
    fun `ToggleFavorite_无当前曲无操作`() {
        val before = PlaybackState()
        assertRejected(before, reduceIntent(before, PlaybackIntent.ToggleFavorite))
    }

    // ═══════════════════════ 事件 ═══════════════════════

    @Test
    fun `EnginePlaybackStateChanged_READY清未就绪标志`() {
        val before = playing(localSongs("a")).copy(playbackNotReady = true)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackStateChanged(3))

        assertFalse(t.state.playbackNotReady)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `EnginePlaybackStateChanged_BUFFERING置未就绪但不抢写播放态`() {
        val t = PlaybackReducer.reduce(playing(localSongs("a")), PlaybackEvent.EnginePlaybackStateChanged(2))
        assertTrue(t.state.playbackNotReady)
        assertTrue(t.state.isPlaying) // 缓冲期平台仍在播
    }

    @Test
    fun `EnginePlaybackStateChanged_IDLE收敛播放态`() {
        val before = playing(localSongs("a")).copy(awaitingPlaybackProgress = true)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackStateChanged(1))

        assertTrue(t.state.playbackNotReady)
        assertFalse(t.state.isPlaying)
        assertFalse(t.state.awaitingPlaybackProgress)
    }

    @Test
    fun `EnginePlaybackStateChanged_ENDED只置未就绪不抢写isPlaying`() {
        // ENDED 先于 Completed 到达（ExoPlayerImpl.java:2158-2162 的顺序 + 适配器
        // 在 ENDED 回调内同步触发 Completed）：此处不抢写 isPlaying，否则首次播完
        // 会被 Completed 的重复投递守卫误判。
        val before = playing(localSongs("a")).copy(awaitingPlaybackProgress = true)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackStateChanged(4))

        assertTrue(t.state.playbackNotReady)
        assertTrue(t.state.isPlaying)
        assertFalse(t.state.awaitingPlaybackProgress)
    }

    @Test
    fun `EngineIsPlayingChanged_唯一播放态写入口`() {
        val paused = playing(localSongs("a")).copy(awaitingPlaybackProgress = true, manualRetryInFlight = true)
        val t = PlaybackReducer.reduce(paused, PlaybackEvent.EngineIsPlayingChanged(false))

        assertFalse(t.state.isPlaying)
        assertFalse(t.state.awaitingPlaybackProgress)
        assertTrue(t.state.manualRetryInFlight) // 暂停不清重试在途标志

        val started = PlaybackReducer.reduce(
            playing(localSongs("a")).copy(manualRetryInFlight = true),
            PlaybackEvent.EngineIsPlayingChanged(true),
        )
        assertTrue(started.state.isPlaying)
        assertFalse(started.state.manualRetryInFlight) // 真正起播 → 重试 concluded
    }

    @Test
    fun `EnginePositionChanged_同步平台位置并带动展示位置`() {
        val t = PlaybackReducer.reduce(
            playing(localSongs("a"), position = 30.seconds),
            PlaybackEvent.EnginePositionChanged(30.5.seconds),
        )
        assertEquals(30.5.seconds, t.state.platformPosition)
        assertEquals(30.5.seconds, t.state.position)
    }

    @Test
    fun `EnginePositionChanged_落后于乐观目标的采样被抑制`() {
        // seek 手势/乐观窗内：平台位置持续更新，展示位置保留乐观目标。
        val t = PlaybackReducer.reduce(
            playing(localSongs("a"), position = 150.seconds),
            PlaybackEvent.EnginePositionChanged(120.seconds),
        )
        assertEquals(120.seconds, t.state.platformPosition)
        assertEquals(150.seconds, t.state.position)
    }

    @Test
    fun `EngineDurationChanged_写入与清空`() {
        val set = PlaybackReducer.reduce(PlaybackState(), PlaybackEvent.EngineDurationChanged(200.seconds))
        assertEquals(200.seconds, set.state.duration)

        val cleared = PlaybackReducer.reduce(set.state, PlaybackEvent.EngineDurationChanged(null))
        assertNull(cleared.state.duration)
    }

    @Test
    fun `EngineMediaItemTransition_与当前曲相符时确认且不改状态`() {
        val before = playing(onlineSongs("a", "b"), currentIndex = 1)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EngineMediaItemTransition(1))

        assertEquals(before, t.state)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `EngineMediaItemTransition_迟到旧曲transition被忽略`() {
        // 快速切歌后旧曲的 transition 迟到：身份对账丢弃，不回采旧索引。
        val before = playing(onlineSongs("a", "b", "c"), currentIndex = 2)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EngineMediaItemTransition(0))

        assertEquals(before, t.state)
        assertEquals(2, t.state.currentIndex)
    }

    @Test
    fun `EnginePlaybackCompleted_单曲循环重播当前曲`() {
        val before = playing(localSongs("a"), loopMode = AppLoopMode.ONE, position = 200.seconds)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)

        assertEquals(0, t.state.currentIndex)
        assertEquals(Duration.ZERO, t.state.position)
        assertEquals(Duration.ZERO, t.state.platformPosition)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(SeekTo(0L), Play, StartKeepAlive), t.effects)
    }

    @Test
    fun `EnginePlaybackCompleted_单曲循环在线曲异常结束走断点重解析`() {
        // URL 过期形态：位置远未到时长 → 丢弃旧地址从断点重解析（重试预算归 Store）。
        val before = stateOf(listOf(testSong("o1", url = "http://stale/o1.mp3")), loopMode = AppLoopMode.ONE).copy(
            isPlaying = true,
            position = 60.seconds,
            duration = 200.seconds,
            platformPosition = 60.seconds,
        )
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)

        assertTrue(t.state.isResolvingUrl)
        assertNull(t.state.currentSong?.url)
        assertEquals(60.seconds, t.state.position) // 断点续播
        assertEquals(listOf(ResolveSongUrl(testSong("o1")), StartKeepAlive), t.effects)
    }

    @Test
    fun `EnginePlaybackCompleted_列表循环推进到下一首`() {
        val before = playing(localSongs("a", "b"), currentIndex = 0, loopMode = AppLoopMode.ALL, position = 200.seconds)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)

        assertEquals(1, t.state.currentIndex)
        assertEquals(Duration.ZERO, t.state.position)
        assertTrue(t.state.awaitingPlaybackProgress)
        assertEquals(
            listOf(
                Prepare(testSong("b", isOnline = false, localPath = "/music/b.flac"), null, true),
                StartKeepAlive,
                PersistPlaybackCursor,
            ),
            t.effects,
        )
    }

    @Test
    fun `EnginePlaybackCompleted_列表循环队尾绕回队首`() {
        val before = playing(localSongs("a", "b"), currentIndex = 1, loopMode = AppLoopMode.ALL)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)
        assertEquals(0, t.state.currentIndex)
    }

    @Test
    fun `EnginePlaybackCompleted_OFF队尾提示并停机`() {
        val before = playing(localSongs("a"), position = 200.seconds)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)

        assertEquals(0, t.state.currentIndex)
        assertFalse(t.state.isPlaying)
        assertTrue(t.state.playbackNotReady)
        assertFalse(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(ShowMessage("已经是最后一首了"), Pause, StopKeepAlive), t.effects)
    }

    @Test
    fun `EnginePlaybackCompleted_已结束态重复投递为无操作`() {
        val ended = PlaybackReducer.reduce(playing(localSongs("a")), PlaybackEvent.EnginePlaybackCompleted).state
        val t = PlaybackReducer.reduce(ended, PlaybackEvent.EnginePlaybackCompleted)

        assertEquals(ended, t.state)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `EnginePlaybackCompleted_空队列无操作`() {
        val before = PlaybackState()
        assertRejected(before, PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted))
    }

    @Test
    fun `EnginePlaybackCompleted_定时到点等待态播完即停`() {
        // endOfTrack：当前曲自然播完 → 复位模式 + 暂停，不看队列位置。
        val before = playing(localSongs("a", "b"), position = 200.seconds)
            .copy(sleepTimerMode = SleepTimerMode.END_OF_TRACK)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)

        assertEquals(SleepTimerMode.OFF, t.state.sleepTimerMode)
        assertFalse(t.state.isPlaying)
        assertFalse(t.state.awaitingPlaybackProgress)
        assertEquals(listOf(Pause, StopKeepAlive), t.effects)
    }

    @Test
    fun `EnginePlaybackCompleted_等待态异常结束不算播完继续循环语义`() {
        // 异常结束（位置 60s/200s）不是「播完」：等待态保留，继续走循环语义推进。
        val before = stateOf(onlineSongs("a", "b")).copy(
            isPlaying = true,
            sleepTimerMode = SleepTimerMode.END_OF_TRACK,
            position = 60.seconds,
            duration = 200.seconds,
            platformPosition = 60.seconds,
        )
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)

        assertEquals(SleepTimerMode.END_OF_TRACK, t.state.sleepTimerMode)
        assertEquals(1, t.state.currentIndex)
        assertTrue(t.state.awaitingPlaybackProgress)
    }

    @Test
    fun `EngineError_原始错误入状态且待推进标志清理`() {
        val before = playing(onlineSongs("a"))
            .copy(awaitingPlaybackProgress = true, isResolvingUrl = true, manualRetryInFlight = true)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.EngineError("boom"))

        assertEquals("boom", t.state.resolveError)
        assertFalse(t.state.isResolvingUrl)
        assertFalse(t.state.awaitingPlaybackProgress)
        assertFalse(t.state.manualRetryInFlight)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `EngineError_空消息回落兜底文案`() {
        val nullMsg = PlaybackReducer.reduce(playing(onlineSongs("a")), PlaybackEvent.EngineError(null))
        assertEquals("播放失败，请重试", nullMsg.state.resolveError)

        val emptyMsg = PlaybackReducer.reduce(playing(onlineSongs("a")), PlaybackEvent.EngineError(""))
        assertEquals("播放失败，请重试", emptyMsg.state.resolveError)
    }

    @Test
    fun `NetworkChanged_切换网络只写标志`() {
        val t = PlaybackReducer.reduce(PlaybackState(isWifiNetwork = true), PlaybackEvent.NetworkChanged(false))
        assertFalse(t.state.isWifiNetwork)
        assertTrue(t.effects.isEmpty()) // 音质重读与失败重试归 Store 闸门管线
    }

    @Test
    fun `NetworkChanged_同值无操作`() {
        val before = PlaybackState(isWifiNetwork = false)
        assertRejected(before, PlaybackReducer.reduce(before, PlaybackEvent.NetworkChanged(false)))
    }

    @Test
    fun `AppForegroundChanged_归约层无状态可写`() {
        // 后台门由 Store 消费（恢复链的后台判据）；PlaybackState 无后台字段。
        val before = playing(onlineSongs("a"))
        val t = PlaybackReducer.reduce(before, PlaybackEvent.AppForegroundChanged(backgrounded = true))
        assertEquals(before, t.state)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `VolumeChanged_引擎侧瞬态音量不改写用户设置`() {
        // 音频焦点 duck 的引擎音量是瞬态；state.volume 是用户设置，禁止覆盖。
        val t = PlaybackReducer.reduce(PlaybackState(volume = 0.8), PlaybackEvent.VolumeChanged(0.2))
        assertEquals(0.8, t.state.volume, 0.0)
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `LoopModeChanged_外部循环模式对齐队列`() {
        val before = stateOf(onlineSongs("a"), loopMode = AppLoopMode.OFF)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.LoopModeChanged(AppLoopMode.ONE))

        assertEquals(AppLoopMode.ONE, t.state.loopMode)
        assertEquals(0, t.state.queueRevision) // 同 _applyLoopMode：不涨
        assertTrue(t.effects.isEmpty())
    }

    @Test
    fun `LoopModeChanged_同值无操作`() {
        val before = stateOf(onlineSongs("a"), loopMode = AppLoopMode.ALL)
        assertRejected(before, PlaybackReducer.reduce(before, PlaybackEvent.LoopModeChanged(AppLoopMode.ALL)))
    }

    @Test
    fun `PlaybackProgressConfirmed_清理等待推进标志`() {
        val before = playing(onlineSongs("a")).copy(awaitingPlaybackProgress = true)
        val t = PlaybackReducer.reduce(before, PlaybackEvent.PlaybackProgressConfirmed)

        assertFalse(t.state.awaitingPlaybackProgress)
        assertTrue(t.state.isPlaying) // 其余字段不动
        assertEquals(30.seconds, t.state.position)
    }

    // ═══════════════════════ 7 类竞态 ═══════════════════════

    @Test
    fun `竞态1_快速连续切歌_末态为第二目标且过期transition被丢弃`() {
        val before = playing(onlineSongs("a", "b", "c"), currentIndex = 0)

        val first = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))
        val second = reduceIntent(first.state, PlaybackIntent.Next(autoPlay = true))

        assertEquals(2, second.state.currentIndex)
        assertEquals("c", second.state.currentSong?.id)

        // 旧曲 b 的 transition 迟到 → 身份对账丢弃
        val stale = PlaybackReducer.reduce(second.state, PlaybackEvent.EngineMediaItemTransition(1))
        assertEquals(second.state, stale.state)

        // 新曲 c 的 transition 到达 → 确认（无变化）
        val fresh = PlaybackReducer.reduce(second.state, PlaybackEvent.EngineMediaItemTransition(2))
        assertEquals(second.state, fresh.state)
    }

    @Test
    fun `竞态2_旧曲目回调迟到被身份对账丢弃`() {
        val before = playing(onlineSongs("a", "b", "c"), currentIndex = 0)
        val afterNext = reduceIntent(before, PlaybackIntent.Next(autoPlay = true)).state

        // 旧曲 a 的 transition 晚于新装载到达
        val lateOld = PlaybackReducer.reduce(afterNext, PlaybackEvent.EngineMediaItemTransition(0))
        assertEquals(afterNext, lateOld.state)
        assertEquals(1, afterNext.currentIndex)
        assertEquals("b", afterNext.currentSong?.id)
    }

    @Test
    fun `竞态3_暂停早于准备完成_状态不自相矛盾`() {
        val before = playing(onlineSongs("a", "b"), currentIndex = 0)

        val afterPlayAt = reduceIntent(before, PlaybackIntent.PlayAt(index = 1)).state
        assertTrue(afterPlayAt.awaitingPlaybackProgress)

        val afterPause = reduceIntent(afterPlayAt, PlaybackIntent.Pause).state
        assertFalse(afterPause.awaitingPlaybackProgress)

        val afterReady = PlaybackReducer.reduce(afterPause, PlaybackEvent.EnginePlaybackStateChanged(3)).state
        val afterNotPlaying = PlaybackReducer.reduce(afterReady, PlaybackEvent.EngineIsPlayingChanged(false)).state

        assertFalse(afterNotPlaying.isPlaying)
        assertFalse(afterNotPlaying.awaitingPlaybackProgress) // 不挂「等待推进」
        assertFalse(afterNotPlaying.playbackNotReady)
        assertEquals(1, afterNotPlaying.currentIndex)
    }

    @Test
    fun `竞态4_播放结束与手动切歌交错_两种顺序均有确定末态`() {
        val s0 = playing(localSongs("a", "b"), currentIndex = 0, loopMode = AppLoopMode.OFF)

        // 序1：Completed 先、Next 后（Completed 推进到 b；Next 在队尾 OFF → 提示停机）
        val orderA = reduceIntent(
            PlaybackReducer.reduce(s0, PlaybackEvent.EnginePlaybackCompleted).state,
            PlaybackIntent.Next(autoPlay = true),
        ).state

        // 序2：Next 先、Completed 后（Next 推进到 b；Completed 在队尾 OFF → 提示停机）
        val orderB = PlaybackReducer.reduce(
            reduceIntent(s0, PlaybackIntent.Next(autoPlay = true)).state,
            PlaybackEvent.EnginePlaybackCompleted,
        ).state

        // 两种处理序均收敛到同一队列位置与等待标志（isPlaying / playbackNotReady
        // 反映各自的引擎事实：序2 的 Completed 来自 STATE_ENDED，收敛终态；
        // 序1 的 Next 只发 Pause 效果，等引擎事件——两者确定但不同，符合架构）。
        assertEquals(1, orderA.currentIndex)
        assertEquals(1, orderB.currentIndex)
        assertFalse(orderA.awaitingPlaybackProgress)
        assertFalse(orderB.awaitingPlaybackProgress)
        assertEquals(orderA.queue, orderB.queue)

        // 确定性：同一顺序重放结果一致
        val orderA2 = reduceIntent(
            PlaybackReducer.reduce(s0, PlaybackEvent.EnginePlaybackCompleted).state,
            PlaybackIntent.Next(autoPlay = true),
        ).state
        assertEquals(orderA, orderA2)

        // Completed 在已结束态为 no-op
        val duplicate = PlaybackReducer.reduce(orderB, PlaybackEvent.EnginePlaybackCompleted)
        assertEquals(orderB, duplicate.state)
    }

    @Test
    fun `竞态5_seek手势与进度回调交错_乐观值保留`() {
        val before = playing(localSongs("a"), position = 100.seconds, duration = 200.seconds)

        val afterStart = reduceIntent(before, PlaybackIntent.SeekGestureStarted(wasPlaying = true)).state
        val afterPaused = PlaybackReducer.reduce(afterStart, PlaybackEvent.EngineIsPlayingChanged(false)).state
        // 手势期间暂停点的常量采样
        val duringDrag = PlaybackReducer.reduce(afterPaused, PlaybackEvent.EnginePositionChanged(100.seconds)).state
        assertEquals(100.seconds, duringDrag.position)
        assertEquals(100.seconds, duringDrag.platformPosition)

        val afterComplete = reduceIntent(
            duringDrag,
            PlaybackIntent.SeekGestureCompleted(sessionId = 1, position = 150.seconds),
        ).state
        assertEquals(150.seconds, afterComplete.position)

        // 引擎尚未落地的旧采样：平台位置持续更新，展示位置保留乐观目标
        val staleSample = PlaybackReducer.reduce(afterComplete, PlaybackEvent.EnginePositionChanged(120.seconds)).state
        assertEquals(120.seconds, staleSample.platformPosition)
        assertEquals(150.seconds, staleSample.position)

        // 平台追上后恢复同步
        val caughtUp = PlaybackReducer.reduce(staleSample, PlaybackEvent.EnginePositionChanged(150.seconds)).state
        assertEquals(150.seconds, caughtUp.position)
        val advanced = PlaybackReducer.reduce(caughtUp, PlaybackEvent.EnginePositionChanged(150.5.seconds)).state
        assertEquals(150.5.seconds, advanced.position)
    }

    @Test
    fun `竞态6_释放后旧事件_空队列下全部惰性`() {
        // 归约器层保证：清空后迟到的 completed / transition 不能复活当前曲或改动队列。
        // isPlaying 的迟到 true 事件由 Store 请求代次闸门丢弃（台本 §3.6），不在纯函数职责内。
        val cleared = reduceIntent(playing(localSongs("a", "b")), PlaybackIntent.ClearQueue).state

        val afterCompleted = PlaybackReducer.reduce(cleared, PlaybackEvent.EnginePlaybackCompleted)
        assertEquals(cleared, afterCompleted.state)

        val afterTransition = PlaybackReducer.reduce(cleared, PlaybackEvent.EngineMediaItemTransition(0))
        assertEquals(cleared, afterTransition.state)

        val afterIsPlaying = PlaybackReducer.reduce(cleared, PlaybackEvent.EngineIsPlayingChanged(false)).state
        assertTrue(afterIsPlaying.queue.isEmpty)
        assertNull(afterIsPlaying.currentSong)
        assertEquals(-1, afterIsPlaying.currentIndex)
    }

    @Test
    fun `竞态7_队列变化与自动下一首交错_索引一致且空队列停机`() {
        // 序1：先播完推进、再删队首
        val s0 = playing(localSongs("a", "b", "c"), currentIndex = 1, loopMode = AppLoopMode.OFF)
        val orderA = reduceIntent(
            PlaybackReducer.reduce(s0, PlaybackEvent.EnginePlaybackCompleted).state,
            PlaybackIntent.RemoveAt(index = 0),
        ).state

        // 序2：先删队首、再播完推进
        val orderB = PlaybackReducer.reduce(
            reduceIntent(s0, PlaybackIntent.RemoveAt(index = 0)).state,
            PlaybackEvent.EnginePlaybackCompleted,
        ).state

        assertEquals("c", orderA.currentSong?.id)
        assertEquals("c", orderB.currentSong?.id)
        assertEquals(orderA.currentIndex, orderB.currentIndex) // 索引一致

        // 空队列停机：单曲队列两种到达空态的方式
        val single = playing(localSongs("a"), loopMode = AppLoopMode.OFF)
        val emptiedByRemove = reduceIntent(single, PlaybackIntent.RemoveAt(index = 0)).state
        val afterLateCompleted = PlaybackReducer.reduce(emptiedByRemove, PlaybackEvent.EnginePlaybackCompleted).state
        assertTrue(afterLateCompleted.queue.isEmpty)
        assertEquals(-1, afterLateCompleted.currentIndex)

        val completedSingle = PlaybackReducer.reduce(single, PlaybackEvent.EnginePlaybackCompleted).state
        val emptiedByRemove2 = reduceIntent(completedSingle, PlaybackIntent.RemoveAt(index = 0)).state
        assertTrue(emptiedByRemove2.queue.isEmpty)
        assertEquals(-1, emptiedByRemove2.currentIndex)
    }

    // ═══════════════════════ §4 附加行：边界/合法性/恢复/幂等 ═══════════════════════

    @Test
    fun `空队列播放类意图全部拒绝`() {
        val empty = PlaybackState()
        assertRejected(empty, reduceIntent(empty, PlaybackIntent.Resume))
        assertRejected(empty, reduceIntent(empty, PlaybackIntent.Next(autoPlay = true)))
        assertRejected(empty, reduceIntent(empty, PlaybackIntent.Previous(autoPlay = true)))
        assertRejected(empty, reduceIntent(empty, PlaybackIntent.PlayAt(index = 0)))
        assertRejected(empty, reduceIntent(empty, PlaybackIntent.SeekTo(10.seconds)))
        assertRejected(empty, reduceIntent(empty, PlaybackIntent.RetryCurrent))
        assertRejected(empty, reduceIntent(empty, PlaybackIntent.ToggleFavorite))
    }

    @Test
    fun `isPlaying只由引擎事件写入_播放类意图不乐观写`() {
        val paused = playing(localSongs("a")).copy(isPlaying = false)

        assertFalse(reduceIntent(paused, PlaybackIntent.Resume).state.isPlaying)
        assertFalse(reduceIntent(paused, PlaybackIntent.Next(autoPlay = true)).state.isPlaying)
        assertFalse(reduceIntent(paused, PlaybackIntent.PlayAt(index = 0)).state.isPlaying)

        val live = playing(localSongs("a"))
        assertTrue(reduceIntent(live, PlaybackIntent.Pause).state.isPlaying)
        assertTrue(reduceIntent(live, PlaybackIntent.Stop).state.isPlaying)
    }

    @Test
    fun `重复事件幂等_进度确认两次不改变末态`() {
        val before = playing(onlineSongs("a")).copy(awaitingPlaybackProgress = true)
        val once = PlaybackReducer.reduce(before, PlaybackEvent.PlaybackProgressConfirmed).state
        val twice = PlaybackReducer.reduce(once, PlaybackEvent.PlaybackProgressConfirmed)
        assertEquals(once, twice.state)
        assertTrue(twice.effects.isEmpty())
    }

    @Test
    fun `错误恢复入口_错误后手动重试清错误并按断点重备`() {
        val before = stateOf(localSongs("a")).copy(
            resolveError = "播放失败，请重试",
            isPlaying = false,
            position = 33.seconds,
        )
        val t = reduceIntent(before, PlaybackIntent.RetryCurrent)

        assertNull(t.state.resolveError)
        assertTrue(t.state.awaitingPlaybackProgress)
        val prepare = t.effects.first() as Prepare
        assertEquals(33_000L, prepare.startPositionMs)
        assertTrue(prepare.playWhenReady)
    }

    @Test
    fun `相同输入相同输出_纯函数可重放`() {
        val before = playing(onlineSongs("a", "b", "c"))
        val t1 = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))
        val t2 = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))
        assertEquals(t1, t2)

        val e1 = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)
        val e2 = PlaybackReducer.reduce(before, PlaybackEvent.EnginePlaybackCompleted)
        assertEquals(e1, e2)
    }

    @Test
    fun `本地曲有路径时免解析_在线曲有地址时免解析`() {
        val localReady = testSong("l1", isOnline = false, localPath = "/music/l1.flac")
        val t1 = reduceIntent(PlaybackState(), PlaybackIntent.PlaySingleSong(localReady))
        assertFalse(t1.state.isResolvingUrl)
        assertTrue(t1.effects.first() is Prepare)

        val onlineReady = testSong("o1", url = "http://cdn/o1.mp3")
        val t2 = reduceIntent(PlaybackState(), PlaybackIntent.PlaySingleSong(onlineReady))
        assertFalse(t2.state.isResolvingUrl)
        assertTrue(t2.effects.first() is Prepare)
    }

    @Test
    fun `切歌重置位置与时长基准_旧曲基准不泄漏`() {
        val before = playing(localSongs("a", "b"), position = 100.seconds, duration = 200.seconds)
        val t = reduceIntent(before, PlaybackIntent.Next(autoPlay = true))

        assertEquals(Duration.ZERO, t.state.position)
        assertEquals(Duration.ZERO, t.state.platformPosition)
        assertNull(t.state.duration)
        assertNull(t.state.resolveError)
    }
}
