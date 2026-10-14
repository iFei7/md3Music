package com.gracemusic.player.store

import com.gracemusic.data.model.Song
import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.model.AudioQuality
import com.gracemusic.player.model.PlaybackErrorInfo
import com.gracemusic.player.model.PlaylistSortBy
import com.gracemusic.player.model.SleepTimerMode
import com.gracemusic.player.model.afterStopAfterCurrentTrackDisabled
import com.gracemusic.player.model.toggled
import com.gracemusic.player.queue.NextBoundary
import com.gracemusic.player.queue.PlaybackQueue
import com.gracemusic.player.queue.PreviousWrapAction
import com.gracemusic.player.queue.QueueMutation
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
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.ZERO

/**
 * 播放域纯归约器（MVI 的 `Reducer`）——台本 §3.5 契约实现。
 *
 * 输入 `(PlaybackState, PlaybackIntent | PlaybackEvent)`，输出
 * [PlaybackTransition]（新状态 + 效果列表）。**零 Android 依赖**：不 import
 * android.*、不碰 ExoPlayer / Rust / IO / 协程；纯函数、可重放（同输入同输出，
 * 随机子路径的随机源经 [random] 参数注入）。
 *
 * ## 总规则（台本 §3.5）
 * 1. **isPlaying 只由引擎事件写入**（[PlaybackEvent.EngineIsPlayingChanged]，
 *    以及 `STATE_*` 的终态推导）。播放类意图只发效果 + 置
 *    [PlaybackState.awaitingPlaybackProgress]，禁止意图乐观写 isPlaying——
 *    通知栏 PLAY_PAUSE 由 media3 直接驱动 ExoPlayer 时 Store 收不到意图，
 *    乐观写会让状态与平台真相脱节（Dart 的乐观写在 native 是有害的）。
 * 2. **position 与 platformPosition 分离**：seek 意图乐观写
 *    [PlaybackState.position]；[PlaybackEvent.EnginePositionChanged] 写
 *    [PlaybackState.platformPosition] 并同步 position（落后于乐观目标的采样
 *    被抑制——状态里没有「seek 手势进行中」专属字段，「平台位置落后于乐观
 *    位置」即手势/乐观窗的判据，详见 [enginePositionChanged]）。
 * 3. **队列操作一律委托 [PlaybackQueue]** 并消费 [com.gracemusic.player.queue.QueueMutation]
 *    标志：`structuralChange` → `queueRevision + 1`；`removedCurrentSong` →
 *    重定位 + 重备效果；`emptied` → 停机效果。索引算术只准调用队列既有方法
 *    （next/previous 边界不对称是刻意保留的 Dart 行为）。
 * 4. **非法操作明确拒绝**（状态原样 + 空效果），规则见 [validateSeekTarget]
 *    与各意图 KDoc：空队列/无当前曲播放、越界索引、未知时长 seek、ENDED 后 seek。
 * 5. **Completed 循环语义**用 [PlaybackQueue.nextBoundary()]：ONE→重播 /
 *    ALL→推进（队尾绕回队首）/ OFF→队尾提示 + 停机；单曲队列的绕回动作用
 *    [PlaybackQueue.previousWrapAction()]（与 next 不对称，Dart 既有设计）。
 * 6. **transition 事件按身份对账**：[PlaybackEvent.EngineMediaItemTransition]
 *    携带的 `mediaItemIndex` 是 Store 把引擎上报的 mediaId（= [Song.id]）在
 *    **当前队列**中解析出的下标（单曲时间线下引擎自身下标恒 0，不具身份信息），
 *    与 `currentIndex` 不符 → 过期事件，忽略（绝不回采旧索引）。
 *
 * ## 与 lite `player_provider.dart` 的逐项核对结论（一致项从略，差异项如下）
 * 1. **isPlaying 意图乐观写**（Dart `pause()`/`resume()` 置 `_isPlaying`）：
 *    native 按上面规则 1 不写，改由引擎事件收敛——媒体 3 的 isPlaying 事件
 *    可靠，且通知栏路径刻意不投意图（台本 §1.3）。
 * 2. **播完队尾语义**（Dart `_handlePlaybackCompleted` 在非 FM、非单曲循环时
 *    把 `_currentIndex` 置 0 继续播，player_provider.dart:2089-2103）：native
 *    按台本规定 OFF→队尾提示 + 停机（与 `next()` 的边界一致），ALL→绕回队首。
 *    登记为刻意差异：Dart 该路径实际表现为「列表循环」，与 AppLoopMode.OFF
 *    的 KDoc 声明（「播完即停」）自相矛盾，取 KDoc/台本语义。
 * 3. **删除当前曲后的续播**（Dart `removeFromPlaylist` 重建后无条件
 *    `playCommand()`，player_provider.dart:5010-5013）：native 按
 *    `playWhenReady = state.isPlaying` 重备，不复活用户主动暂停的播放。
 * 4. **`EngineMediaItemTransition` 采纳语义**（Dart sequenceState 处理器在
 *    索引不一致时**采纳**引擎索引，player_provider.dart:1786-1792）：native
 *    单曲时间线 + 命令翻译表（台本 §3.6）保证引擎不会自行切歌，故只确认、
 *    不采纳——否则快速切歌的迟到 transition 会把状态拽回旧曲。
 * 5. **seek 落点**（Dart `_updatePosition` 无条件同步每个采样）：native 在
 *    平台位置落后于乐观目标时保留乐观值（规则 2），手势/装载窗内不回闪。
 * 6. **切歌重置 duration**（Dart 不重置、等 durationStream 迟到刷新）：
 *    native 在切歌/停机路径置 null，避免旧曲时长泄漏到新曲（并以此执行
 *    「未知时长 seek」拒绝）。
 * 7. **恢复类刷新意图**（`RefreshQualityForNetwork` / `RefreshCrossfadeSettings`）：
 *    归约器无仓库读取能力，只作触发器；Store 读设置后经
 *    [PlaybackIntent.SetAudioQuality] 回灌（保持唯一归约路径）。
 *    交叉淡化因词汇表无对应意图，暂为 no-op（已登记待增补）。
 * 8. **焦点/记忆类偏好**（`SetIgnoreAudioFocus` / `SetAudioFocusInterruptionMode`
 *    / `SetRestoreMemoryEnabled`）：[PlaybackState] 23 字段无对应存储位，
 *    归约器只发 [PersistPreference] 效果，由 Store 同步引擎（台本 §2.3）。
 *
 * ## PersistPreference 键名约定（Store 执行器据此路由仓库）
 * | 键 | 来源 |
 * |---|---|
 * | `player_volume` | Dart `pause`/`setVolume` 的 SharedPreferences 键（player_provider.dart:5255） |
 * | `settings_default_quality_wifi` / `_mobile` | Dart `SettingsRepository._keyQualityWifi/_keyQualityMobile` |
 * | `settings_ignore_audio_focus` | Dart `_keyIgnoreAudioFocus` |
 * | `settings_audio_focus_interruption_mode` | Dart settings_repository.dart:613 |
 * | `settings_show_quality_downgrade_toast` | Dart settings_repository.dart:617 |
 * | `settings_restore_memory` | Dart `_keyRestoreMemory` |
 * | `settings_close_local_music_comments` | Dart settings_repository.dart:742 |
 *
 * ## Completed 的重复投递防护
 * 适配器契约（台本 §3.3）：`onPlaybackCompleted` 仅在进入 `STATE_ENDED` 时
 * 触发一次；vendored `ExoPlayerImpl.java:2158-2162` 保证
 * `onPlaybackStateChanged` 先于 `onIsPlayingChanged` 派发，故 Completed 总是
 * 紧邻 ENDED 状态事件到达。归约器另设硬守卫（[isEngineTerminal]）：引擎已
 * 进入终态（notReady 且 isPlaying 已收敛为 false 且无在途请求）时 Completed
 * 为 no-op。注意 `EnginePlaybackStateChanged(ENDED)` **只写**
 * `playbackNotReady`（不抢写 isPlaying），否则 ENDED 先于 Completed 到达时
 * 会把首次播完误判为重复。
 */
object PlaybackReducer {

    // ─────────────────── media3 Player.STATE_* 镜像（零 Android 依赖） ───────────────────

    /** `androidx.media3.common.Player.STATE_IDLE`。 */
    private const val PLAYER_STATE_IDLE = 1

    /** `androidx.media3.common.Player.STATE_BUFFERING`。 */
    private const val PLAYER_STATE_BUFFERING = 2

    /** `androidx.media3.common.Player.STATE_READY`。 */
    private const val PLAYER_STATE_READY = 3

    /** `androidx.media3.common.Player.STATE_ENDED`。 */
    private const val PLAYER_STATE_ENDED = 4

    // ─────────────────── 常量 ───────────────────

    /** 队尾提示文案（Dart `next()`：`showToast('已经是最后一首了')`，player_provider.dart:4575）。 */
    private const val QUEUE_END_MESSAGE = "已经是最后一首了"

    /** 错误兜底文案（Dart errorStream 处理器硬编码，player_provider.dart:1705；未知错误经 `safePlaybackErrorMessage` 收敛）。 */
    private const val DEFAULT_PLAYBACK_ERROR = "播放失败，请重试"

    private const val KEY_PLAYER_VOLUME = "player_volume"
    private const val KEY_QUALITY_WIFI = "settings_default_quality_wifi"
    private const val KEY_QUALITY_MOBILE = "settings_default_quality_mobile"
    private const val KEY_IGNORE_AUDIO_FOCUS = "settings_ignore_audio_focus"
    private const val KEY_AUDIO_FOCUS_INTERRUPTION_MODE = "settings_audio_focus_interruption_mode"
    private const val KEY_SHOW_QUALITY_DOWNGRADE_TOAST = "settings_show_quality_downgrade_toast"
    private const val KEY_RESTORE_MEMORY = "settings_restore_memory"
    private const val KEY_CLOSE_LOCAL_MUSIC_COMMENTS = "settings_close_local_music_comments"

    // ─────────────────── 公开面 ───────────────────

    /**
     * 归约一个意图（UI / 外部调用方的请求）。
     *
     * @param random 随机源，仅随机子路径（`load` 的随机装载、`cyclePlayMode`
     *   进入随机）消耗；生产传默认值，测试传固定种子保证可复现。
     */
    fun reduce(
        state: PlaybackState,
        intent: PlaybackIntent,
        random: Random = Random.Default,
    ): PlaybackTransition = when (intent) {
        // ── 装载与起播 ──
        is PlaybackIntent.PlaySingleSong -> playSingleSong(state, intent.song, forceResolve = false)
        is PlaybackIntent.PlayOnlineSingleSong -> playSingleSong(state, intent.song, forceResolve = true)
        is PlaybackIntent.PlayPlaylistFrom ->
            playPlaylist(state, intent.songs, intent.startIndex, forceResolve = false, random = random)
        is PlaybackIntent.PlayOnlinePlaylistFrom ->
            playPlaylist(state, intent.songs, intent.startIndex, forceResolve = true, random = random)
        is PlaybackIntent.PlayCloudPlaylistFrom ->
            playPlaylist(state, intent.songs, intent.startIndex, forceResolve = true, random = random)
        is PlaybackIntent.PlayAt -> playAt(state, intent.index)

        // ── 传输控制 ──
        is PlaybackIntent.Resume -> resume(state)
        is PlaybackIntent.Pause -> pause(state)
        is PlaybackIntent.PauseForSeek -> pauseForSeek(state)
        is PlaybackIntent.SeekTo -> seekTo(state, intent.position)
        is PlaybackIntent.SeekBy -> seekBy(state, intent.delta)
        is PlaybackIntent.Next -> next(state, intent.autoPlay)
        is PlaybackIntent.Previous -> previous(state, intent.autoPlay)
        is PlaybackIntent.RetryCurrent -> retryCurrent(state)
        is PlaybackIntent.Stop -> stop(state)
        is PlaybackIntent.SeekGestureStarted -> seekGestureStarted(state, intent.wasPlaying)
        is PlaybackIntent.SeekGestureCompleted -> seekGestureCompleted(state, intent.position)

        // ── 队列编辑 ──
        is PlaybackIntent.AppendToQueue -> appendToQueue(state, intent.songs)
        is PlaybackIntent.InsertAfterCurrent -> insertAfterCurrent(state, intent.songs)
        is PlaybackIntent.RemoveAt -> removeAt(state, intent.index)
        is PlaybackIntent.RemoveMany -> removeMany(state, intent.songIds)
        is PlaybackIntent.ReorderQueue -> reorderQueue(state, intent.oldIndex, intent.newIndex)
        is PlaybackIntent.SortQueue -> sortQueue(state, intent.by, intent.ascending)
        is PlaybackIntent.UpdateSong -> updateSong(state, intent.song, intent.actualQuality)
        is PlaybackIntent.ClearQueue -> clearQueue(state)

        // ── 播放偏好 ──
        is PlaybackIntent.ToggleLoopMode -> toggleLoopMode(state)
        is PlaybackIntent.CyclePlayMode -> cyclePlayMode(state, random)
        is PlaybackIntent.SetVolume -> setVolume(state, intent.volume)
        is PlaybackIntent.SetSpeed -> setSpeed(state, intent.speed)
        is PlaybackIntent.SetAudioQuality -> setAudioQuality(state, intent.quality)
        is PlaybackIntent.SetSleepTimer -> setSleepTimer(state, intent.duration)
        is PlaybackIntent.SetStopAfterCurrentTrack -> setStopAfterCurrentTrack(state, intent.enabled)
        is PlaybackIntent.SetIgnoreAudioFocus ->
            persistOnly(state, PersistPreference(KEY_IGNORE_AUDIO_FOCUS))
        is PlaybackIntent.SetAudioFocusInterruptionMode ->
            persistOnly(state, PersistPreference(KEY_AUDIO_FOCUS_INTERRUPTION_MODE))
        is PlaybackIntent.SetShowQualityDowngradeToast ->
            showQualityDowngradeToast(state, intent.enabled)
        is PlaybackIntent.SetRestoreMemoryEnabled ->
            persistOnly(state, PersistPreference(KEY_RESTORE_MEMORY))
        is PlaybackIntent.SetCloseLocalMusicComments -> closeLocalMusicComments(state, intent.enabled)

        // ── 派生刷新与落盘 ──
        is PlaybackIntent.RefreshQualityForNetwork -> unchanged(state)
        is PlaybackIntent.RefreshCrossfadeSettings -> unchanged(state)
        is PlaybackIntent.RefreshNotification -> PlaybackTransition(state, RefreshSystemNotification)
        is PlaybackIntent.FlushPersistence -> PlaybackTransition(state, PersistPlaybackCursor)

        // ── 收藏 ──
        is PlaybackIntent.ToggleFavorite -> toggleFavorite(state)
    }

    /** 归约一个事件（引擎 / 系统已发生的事实；不触发网络解析与落盘）。 */
    fun reduce(state: PlaybackState, event: PlaybackEvent): PlaybackTransition = when (event) {
        is PlaybackEvent.EnginePlaybackStateChanged -> playbackStateChanged(state, event.playbackState)
        is PlaybackEvent.EngineIsPlayingChanged -> isPlayingChanged(state, event.isPlaying)
        is PlaybackEvent.EnginePositionChanged -> enginePositionChanged(state, event.position)
        is PlaybackEvent.EngineDurationChanged -> PlaybackTransition(state.copy(duration = event.duration))
        is PlaybackEvent.EngineMediaItemTransition -> mediaItemTransition(state, event.mediaItemIndex)
        is PlaybackEvent.EnginePlaybackCompleted -> playbackCompleted(state)
        is PlaybackEvent.EngineError -> engineError(state, event.info)
        is PlaybackEvent.NetworkChanged -> networkChanged(state, event.isWifi)
        is PlaybackEvent.AppForegroundChanged -> unchanged(state)
        is PlaybackEvent.VolumeChanged -> unchanged(state)
        is PlaybackEvent.LoopModeChanged -> loopModeChanged(state, event.mode)
        is PlaybackEvent.PlaybackProgressConfirmed -> progressConfirmed(state)
    }

    // ═══════════════════════ 装载与起播 ═══════════════════════

    /**
     * 单曲起播（Dart `playSong`，player_provider.dart:3036-3128）。
     *
     * 队列换成「单曲队列」（保留 shuffle / loopMode——Dart 直接赋值三个字段，
     * 不触碰这两个），`queueRevision+1`，位置基准归零，错误清除。
     * [forceResolve] = true 时走在线解析入口（Dart `playOnlineSong`：无论是否
     * 已带 url 都重新解析，player_provider.dart:3130+）。
     */
    private fun playSingleSong(
        state: PlaybackState,
        song: Song,
        forceResolve: Boolean,
    ): PlaybackTransition {
        val queue = state.queue.withSongs(
            playlist = listOf(song),
            originalPlaylist = listOf(song),
            currentIndex = 0,
        )
        return launchSong(state, queue, song, forceResolve)
    }

    /**
     * 装载队列并从 [startIndex] 起播（Dart `playPlaylist` / `playOnlinePlaylist` /
     * `playCloudPlaylist`，player_provider.dart:3286 / 3377 / 3592）。
     *
     * 空列表拒绝（Dart 首行 `if (songs.isEmpty) return;`）。装载委托
     * [PlaybackQueue.load]（随机模式下起始曲恒在第 0 位）。
     */
    private fun playPlaylist(
        state: PlaybackState,
        songs: List<Song>,
        startIndex: Int,
        forceResolve: Boolean,
        random: Random,
    ): PlaybackTransition {
        if (songs.isEmpty()) return unchanged(state)
        val queue = state.queue.load(songs, startIndex, random) ?: return unchanged(state)
        val song = queue.currentSong ?: return unchanged(state)
        return launchSong(state, queue, song, forceResolve)
    }

    /** 播放队列中指定下标（Dart `playSongAt`，player_provider.dart:4684-4728）。越界拒绝。 */
    private fun playAt(state: PlaybackState, index: Int): PlaybackTransition {
        if (index < 0 || index >= state.queue.playlist.size) return unchanged(state)
        val song = state.queue.playlist[index]
        return launchSong(state, state.queue.positionedAt(index), song, forceResolve = false)
    }

    /**
     * 起播一个「已定位当前曲」的队列：装载 + 起播的公共收尾。
     *
     * 效果：在线且无可用音源（或强制解析）→ [ResolveSongUrl]（TODO T-P1-05），
     * 否则 [Prepare]（起播）；恒带 [StartKeepAlive] 与 [PersistPlaybackCursor]
     * （Dart `_savePlaylistIfChanged`）。状态：`isResolvingUrl` 按是否待解析，
     * `awaitingPlaybackProgress = true`（新请求已发、平台未确认推进），位置基准
     * 归零，`queueRevision+1`（Dart `playSong` / `_loadPlaylist` 均自增）。
     */
    private fun launchSong(
        state: PlaybackState,
        queue: PlaybackQueue,
        song: Song,
        forceResolve: Boolean,
    ): PlaybackTransition {
        val resolving = forceResolve || needsUrlResolution(song)
        val effects = buildList {
            add(if (resolving) ResolveSongUrl(song) else Prepare(song, startPositionMs = null, playWhenReady = true))
            add(StartKeepAlive)
            add(PersistPlaybackCursor)
        }
        return PlaybackTransition(
            state.copy(
                queue = queue,
                isResolvingUrl = resolving,
                resolveError = null,
                awaitingPlaybackProgress = true,
                position = ZERO,
                platformPosition = ZERO,
                duration = null,
                queueRevision = state.queueRevision + 1,
                manualRetryInFlight = false,
            ),
            effects,
        )
    }

    // ═══════════════════════ 传输控制 ═══════════════════════

    /**
     * 继续播放（Dart `resume`，player_provider.dart:4117-4206）。
     *
     * 无当前曲拒绝（空队列播放）。`needsReload`（Dart 同名单义：
     * `_playbackNotReady || _isResolvingUrl`）时重备当前曲——携带当前位置作
     * 起始点（Dart 传 null 由平台从 0 起，native 显式续位，见类 KDoc 差异项
     * 之外的实现选择），否则直接 [Play]。
     */
    private fun resume(state: PlaybackState): PlaybackTransition {
        val song = state.currentSong ?: return unchanged(state)
        val needsReload = state.playbackNotReady || state.isResolvingUrl
        val resolving = needsReload && needsUrlResolution(song)
        val effects = buildList {
            if (needsReload) {
                add(
                    if (resolving) {
                        ResolveSongUrl(song)
                    } else {
                        Prepare(
                            song = song,
                            startPositionMs = state.position.inWholeMilliseconds.takeIf { it > 0 },
                            playWhenReady = true,
                        )
                    },
                )
            } else {
                add(Play)
            }
            add(StartKeepAlive)
            add(PersistPlaybackCursor)
        }
        return PlaybackTransition(
            state.copy(
                isResolvingUrl = resolving,
                awaitingPlaybackProgress = true,
                manualRetryInFlight = false,
            ),
            effects,
        )
    }

    /**
     * 暂停（Dart `pause`，player_provider.dart:3901-3988）。
     *
     * isPlaying 不写（规则 1，引擎事件收敛）；清理等待推进标志（Dart
     * `_invalidatePlaybackRequest` → 闸门 reset → `isAwaitingPlaybackProgress`
     * 转假）。效果含 [StopKeepAlive]（播放会话结束）。
     */
    private fun pause(state: PlaybackState): PlaybackTransition = PlaybackTransition(
        state.copy(
            awaitingPlaybackProgress = false,
            manualRetryInFlight = false,
        ),
        Pause,
        StopKeepAlive,
        PersistPlaybackCursor,
    )

    /**
     * 拖动进度条前置暂停（Dart `pauseForSeek`，player_provider.dart:4018-4027）。
     *
     * 与 [pause] 的差别：不停保活（手势结束即恢复，会话未结束）、不落盘。
     * Dart 的 `_invalidatePlaybackRequest` 会清 `_isResolvingUrl`，此处对齐。
     */
    private fun pauseForSeek(state: PlaybackState): PlaybackTransition = PlaybackTransition(
        state.copy(
            awaitingPlaybackProgress = false,
            isResolvingUrl = false,
            manualRetryInFlight = false,
        ),
        Pause,
    )

    /**
     * 绝对定位（Dart `seek`，player_provider.dart:4208-4228）。
     *
     * 乐观写 [PlaybackState.position]（UI 立即响应，不等平台采样）；
     * `platformPosition` 不动（等引擎确认）。非法目标见 [validateSeekTarget]。
     */
    private fun seekTo(state: PlaybackState, position: Duration): PlaybackTransition {
        val target = validateSeekTarget(state, position) ?: return unchanged(state)
        return PlaybackTransition(state.copy(position = target), SeekTo(target.inWholeMilliseconds), PersistPlaybackCursor)
    }

    /**
     * 相对定位（通知栏 / 蓝牙 ±10s、±15s；Dart 侧由 UI 折算成绝对位置）。
     *
     * 目标 = `position + delta`（ clamped 到合法区间，见 [validateSeekTarget]）；
     * 引擎侧发 [SeekBy]（相对引擎自身当前位置，即用户实际听到的位置）。
     */
    private fun seekBy(state: PlaybackState, delta: Duration): PlaybackTransition {
        val target = validateSeekTarget(state, state.position + delta) ?: return unchanged(state)
        return PlaybackTransition(state.copy(position = target), SeekBy(delta.inWholeMilliseconds), PersistPlaybackCursor)
    }

    /**
     * seek 目标合法性（台本 §3.5 非法操作清单的 seek 部分）：
     *
     * 1. 无当前曲 → 拒绝（空队列/无当前曲不定位）；
     * 2. `duration == null`（未知时长）→ 拒绝——进度语义不成立（UI 的进度条
     *    同样依赖已知时长才能渲染）；Dart 不拒绝、由平台 clamp，此处更严格；
     * 3. 目标越界 → **钳位**到 `[0, duration]`（对齐 Dart：just_audio 内部
     *    clamp，player_provider.dart:4222 直接下传）；
     * 4. 引擎终态（播完已停机）→ 拒绝，判据见 [isEngineTerminal]。
     */
    private fun validateSeekTarget(state: PlaybackState, target: Duration): Duration? {
        if (state.currentSong == null) return null
        val duration = state.duration ?: return null
        if (isEngineTerminal(state)) return null
        return target.coerceIn(ZERO, duration)
    }

    /**
     * 引擎终态判据（「ENDED 后」的可推导表达）：
     * 播放流未就绪 **且** isPlaying 已收敛为 false **且** 没有任何在途的
     * 播放/解析/重试请求。播完停机（`EnginePlaybackStateChanged(ENDED)` 置
     * `playbackNotReady`、Completed 停机分支收敛 isPlaying）即命中；装载 /
     * 缓冲期 isPlaying 仍为 true 不误伤。
     */
    private fun isEngineTerminal(state: PlaybackState): Boolean =
        state.playbackNotReady &&
            !state.isPlaying &&
            !state.awaitingPlaybackProgress &&
            !state.isResolvingUrl &&
            !state.manualRetryInFlight

    /**
     * 下一首（Dart `next`，player_provider.dart:4543-4630）。
     *
     * 空队列拒绝。边界判定委托 [PlaybackQueue.nextBoundary]：
     * - `HintAndPause`（OFF 停在末曲）：提示 + 暂停 + 停保活（Dart 同：
     *   `showToast` + `pause`，不再落盘）；
     * - `RestartSingle`（ONE 且仅一首）：定位回 0，autoPlay 时续播；
     * - `Proceed`：取 [PlaybackQueue.nextCandidateIndices] 首候选切歌
     *   （ALL 队尾绕回队首；OFF 非队尾前进一位）。`currentIndex < 0` 的退化
     *   队列按 Dart 的 `(_currentIndex + 1) % n` 落 0；单曲 + ALL 绕回起点
     *   时 Dart `break` 后无操作，此处同样 no-op。
     */
    private fun next(state: PlaybackState, autoPlay: Boolean): PlaybackTransition {
        if (state.queue.isEmpty) return unchanged(state)
        return when (val boundary = state.queue.nextBoundary()) {
            is NextBoundary.Nothing -> unchanged(state)
            is NextBoundary.HintAndPause -> PlaybackTransition(
                state.copy(
                    awaitingPlaybackProgress = false,
                    manualRetryInFlight = false,
                ),
                ShowMessage(QUEUE_END_MESSAGE),
                Pause,
                StopKeepAlive,
            )
            is NextBoundary.RestartSingle -> restartCurrent(state, autoPlay)
            is NextBoundary.Proceed -> {
                val target = nextAdvanceTarget(state) ?: return unchanged(state)
                switchToIndex(state, target, autoPlay)
            }
        }
    }

    /**
     * 上一首（Dart `previous`，player_provider.dart:4632-4682）。
     *
     * 候选序列委托 [PlaybackQueue.previousCandidateIndices]（**无队尾截断**，
     * 与 next 不对称是刻意保留的 Dart 行为）。绕回起点时按
     * [PlaybackQueue.previousWrapAction]：ALL → 仅落盘（Dart `break`）；
     * OFF/ONE → 定位回 0（Dart `seek(Duration.zero)`，不补 play——引擎保持
     * 自身 playWhenReady，与 next 的 RestartSingle 不对称）。
     */
    private fun previous(state: PlaybackState, autoPlay: Boolean): PlaybackTransition {
        if (state.queue.isEmpty) return unchanged(state)
        val candidates = state.queue.previousCandidateIndices()
        if (candidates.isNotEmpty()) return switchToIndex(state, candidates.first(), autoPlay)
        // 绕回起点（单曲队列）；currentIndex < 0 的退化队列按 Dart 的
        // `prevIndex > 0 ? prevIndex - 1 : length - 1` 落到末位。
        val fallback = if (state.queue.currentIndex < 0) state.queue.playlist.lastIndex else null
        if (fallback != null) return switchToIndex(state, fallback, autoPlay)
        return when (state.queue.previousWrapAction()) {
            PreviousWrapAction.NoOp -> PlaybackTransition(
                state.copy(manualRetryInFlight = false),
                PersistPlaybackCursor,
            )
            PreviousWrapAction.RestartCurrent -> restartCurrent(state, autoPlay = false)
        }
    }

    /**
     * 手动重试当前曲（Dart `retryCurrentPlayback`，player_provider.dart:4056-4115）。
     *
     * 守卫与 Dart 一致：重试在途或解析在途 → 拒绝；无当前曲 → 拒绝。
     * 在线曲丢弃可能过期的 url（Dart `copyWith(clearUrl: true)` 并回写队列）
     * 后走解析；本地曲直接带当前位置重备。`manualRetryInFlight` 置位，
     * 由引擎事件 / 新播放请求 / 错误清除。
     */
    private fun retryCurrent(state: PlaybackState): PlaybackTransition {
        if (state.manualRetryInFlight || state.isResolvingUrl) return unchanged(state)
        val song = state.currentSong ?: return unchanged(state)
        val queue = if (song.isOnline) state.queue.replaceCurrent(song.copy(url = null)) else state.queue
        val resolving = song.isOnline || needsUrlResolution(song)
        val effects = buildList {
            add(
                if (resolving) {
                    ResolveSongUrl(song)
                } else {
                    Prepare(
                        song = song,
                        startPositionMs = state.position.inWholeMilliseconds.takeIf { it > 0 },
                        playWhenReady = true,
                    )
                },
            )
            add(StartKeepAlive)
            add(PersistPlaybackCursor)
        }
        return PlaybackTransition(
            state.copy(
                queue = queue,
                isResolvingUrl = resolving,
                resolveError = null,
                awaitingPlaybackProgress = true,
                manualRetryInFlight = true,
            ),
            effects,
        )
    }

    /**
     * 停止并清空播放状态（不改变队列；Dart 无对应公开方法，语义取
     * `clearPlaylist` 的停机部分，player_provider.dart:4748-4756）。
     *
     * 位置/时长/错误基准归零；isPlaying 不写（规则 1）。
     */
    private fun stop(state: PlaybackState): PlaybackTransition = PlaybackTransition(
        state.copy(
            awaitingPlaybackProgress = false,
            position = ZERO,
            platformPosition = ZERO,
            duration = null,
            resolveError = null,
            manualRetryInFlight = false,
        ),
        Stop,
        StopKeepAlive,
        PersistPlaybackCursor,
    )

    /**
     * 拖动开始（Dart `beginSeekSession`，player_provider.dart:4030-4039）。
     *
     * `wasPlaying` 时前置暂停（Dart `pauseForSeek`）；恢复播放的决策不在
     * 归约器——[PlaybackIntent.SeekGestureCompleted] 不携带 `wasPlaying`
     * （MVI 意图无返回值、无跨调用记忆），由 Store 的
     * `beginSeekSession` 薄封装按会话号登记并在完成后回灌
     * [PlaybackIntent.Resume]（与 Dart `completeSeekSession` 的条件恢复等价）。
     */
    private fun seekGestureStarted(state: PlaybackState, wasPlaying: Boolean): PlaybackTransition =
        if (wasPlaying) {
            PlaybackTransition(
                state.copy(
                    awaitingPlaybackProgress = false,
                    isResolvingUrl = false,
                    manualRetryInFlight = false,
                ),
                Pause,
            )
        } else {
            unchanged(state)
        }

    /**
     * 拖动结束（Dart `completeSeekSession` 的 seek 部分，player_provider.dart:4042-4052）。
     *
     * 合法性同 [seekTo]（未知时长/终态拒绝）；乐观写目标位置，引擎落
     * [SeekTo]。会话号由 Store 校验（归约器无会话注册表），恢复播放由 Store
     * 薄封装负责（见 [seekGestureStarted]）。
     */
    private fun seekGestureCompleted(state: PlaybackState, position: Duration): PlaybackTransition {
        val target = validateSeekTarget(state, position) ?: return unchanged(state)
        return PlaybackTransition(state.copy(position = target), SeekTo(target.inWholeMilliseconds), PersistPlaybackCursor)
    }

    // ═══════════════════════ 队列编辑 ═══════════════════════

    /** 追加（Dart `appendPlaylist` 的列表部分，player_provider.dart:4762-4781）。全重复 → no-op。 */
    private fun appendToQueue(state: PlaybackState, songs: List<Song>): PlaybackTransition {
        val mutation = state.queue.append(songs)
        return structuralQueueUpdate(state, mutation)
    }

    /** 当前曲后插入（Dart `insertAfterCurrent`，player_provider.dart:4826-4902）。无可插入 → no-op。 */
    private fun insertAfterCurrent(state: PlaybackState, songs: List<Song>): PlaybackTransition {
        val mutation = state.queue.insertAfterCurrent(songs)
        return structuralQueueUpdate(state, mutation)
    }

    /**
     * 删除指定下标（Dart `removeFromPlaylist`，player_provider.dart:4919-5021）。
     *
     * 越界拒绝（`applied = false`）。三种结局：
     * - `emptied` → 停机效果（Stop + 停保活）+ 播放基准归零；
     * - `removedCurrent` → 重定位 + 重备（`playWhenReady = isPlaying`，见类
     *   KDoc 差异项 3：不复活用户主动暂停的播放）；
     * - 其余 → 仅结构更新（Dart 不重建引擎队列，避免打断当前播放）。
     */
    private fun removeAt(state: PlaybackState, index: Int): PlaybackTransition {
        val removal = state.queue.removeAt(index)
        if (!removal.applied) return unchanged(state)
        return when {
            removal.emptied -> emptied(state, removal.queue)
            removal.removedCurrent -> reprepareCurrent(state, removal.queue)
            else -> PlaybackTransition(
                state.copy(queue = removal.queue, queueRevision = state.queueRevision + 1),
                PersistPlaybackCursor,
            )
        }
    }

    /**
     * 批量删除（Dart `removeManyFromPlaylist`，player_provider.dart:5128-5157）。
     *
     * 含当前曲时队列内部已复用 `removeAt` 的重定位逻辑，此处按
     * `removedCurrentSong` / `emptied` 标志分派同一组结局。
     */
    private fun removeMany(state: PlaybackState, songIds: Set<String>): PlaybackTransition {
        val mutation = state.queue.removeMany(songIds)
        return when {
            mutation.emptied -> emptied(state, mutation.queue)
            mutation.removedCurrentSong != null -> reprepareCurrent(state, mutation.queue)
            mutation.structuralChange -> structuralQueueUpdate(state, mutation)
            else -> unchanged(state)
        }
    }

    /** 重排（Dart `reorderPlaylist`，player_provider.dart:5034-5073）。非法/原地 → no-op。 */
    private fun reorderQueue(state: PlaybackState, oldIndex: Int, newIndex: Int): PlaybackTransition {
        val mutation = state.queue.reorder(oldIndex, newIndex)
        return structuralQueueUpdate(state, mutation)
    }

    /** 按维度排序（Dart `sortPlaylist`，player_provider.dart:5083-5121）。`QUEUE` 或不足 2 首 → no-op。 */
    private fun sortQueue(state: PlaybackState, by: PlaylistSortBy, ascending: Boolean): PlaybackTransition {
        val mutation = state.queue.sortWith(by, ascending)
        return structuralQueueUpdate(state, mutation)
    }

    /**
     * 回写同 id 歌曲字段（Dart `updateSongInPlaylist`，player_provider.dart:4809-4818）。
     *
     * 两条路径：
     * - **解析回写收尾**：更新的是当前曲且 `isResolvingUrl = true`（即
     *   [ResolveSongUrl] 执行器解析成功后的回写）→ 清解析标志并按
     *   `awaitingPlaybackProgress`（起播意图的播放意愿）重备，携带当前位置
     *   作起始点。这闭合了「意图发解析 → Store 执行 → 回写 → 重备」的环路；
     *   同时 [actualQuality] 非空时写入 `actualPlayingQuality`（F-SRC-006：
     *   服务端回写档随解析进入状态，UI 可见降级）；null 不动现值——防其他
     *   UpdateSong 调用方（NAS 回写 localPath 等）误清实际音质；
     * - **纯写写**（NAS 下载回写 localPath 等）：只换队列项，不重备
     *   （Dart 同样不打断播放）。
     *
     * 队列中无同 id 曲目 → no-op。
     *
     * **命中判据不能用队列相等性**：[Song.equals] 仅按 id 比较，字段级更新
     * （localPath / url 回写）不改变队列的相等性结果，必须按 id 显式命中。
     */
    private fun updateSong(state: PlaybackState, song: Song, actualQuality: String?): PlaybackTransition {
        if (state.queue.playlist.none { it.id == song.id }) return unchanged(state)
        val updated = state.queue.updateSong(song).queue
        val isCurrent = song.id == updated.currentSong?.id
        if (isCurrent && state.isResolvingUrl) {
            return PlaybackTransition(
                state.copy(
                    queue = updated,
                    isResolvingUrl = false,
                    manualRetryInFlight = false,
                    actualPlayingQuality = actualQuality ?: state.actualPlayingQuality,
                ),
                Prepare(
                    song = song,
                    startPositionMs = state.position.inWholeMilliseconds.takeIf { it > 0 },
                    playWhenReady = state.awaitingPlaybackProgress,
                ),
            )
        }
        return PlaybackTransition(state.copy(queue = updated))
    }

    /**
     * 清空队列并停止（Dart `clearPlaylist`，player_provider.dart:4730-4760）。
     *
     * `queueRevision+1`；播放基准归零、错误清除；isPlaying 不写（规则 1，
     * 引擎 stop 事件收敛）。恒为结构变更（空队列也不例外）。
     */
    private fun clearQueue(state: PlaybackState): PlaybackTransition {
        val mutation = state.queue.cleared()
        return emptied(state, mutation.queue)
    }

    // ═══════════════════════ 播放偏好 ═══════════════════════

    /**
     * 循环模式三态切换（Dart `toggleLoopMode` → `_applyLoopMode`，
     * player_provider.dart:5159-5213）。
     *
     * **不涨 `queueRevision`**（Dart `_applyLoopMode` 没有 `_queueRevision++`，
     * 只作废预加载）；`preparedArtifactInvalid` 由队列方法表达，交叉淡化产物
     * 的作废归 Store（T-P1-07）。
     */
    private fun toggleLoopMode(state: PlaybackState): PlaybackTransition {
        val mutation = state.queue.withLoopMode(state.queue.loopMode.toggled())
        if (mutation.queue == state.queue) return unchanged(state)
        return PlaybackTransition(state.copy(queue = mutation.queue), PersistPlaybackCursor)
    }

    /**
     * 模式循环（Dart `cyclePlayMode`，player_provider.dart:5178-5198）：
     * 不循环 → 列表循环 → 单曲循环 → 随机 → 不循环。
     *
     * `queueRevision` 仅在含随机切换的分支自增（Dart `toggleShuffle` 自增、
     * `_applyLoopMode` 不自增）。随机源经 [random] 注入。
     */
    private fun cyclePlayMode(state: PlaybackState, random: Random): PlaybackTransition {
        val mutation = state.queue.cyclePlayMode(random)
        if (mutation.queue == state.queue) return unchanged(state)
        val revision = if (mutation.structuralChange) state.queueRevision + 1 else state.queueRevision
        return PlaybackTransition(state.copy(queue = mutation.queue, queueRevision = revision), PersistPlaybackCursor)
    }

    /** 设置音量（Dart `setVolume`，player_provider.dart:5248-5258）。内部 clamp 0.0..1.0。 */
    private fun setVolume(state: PlaybackState, volume: Double): PlaybackTransition {
        val target = volume.coerceIn(0.0, 1.0)
        return PlaybackTransition(
            state.copy(volume = target),
            SetVolume(target.toFloat()),
            PersistPreference(KEY_PLAYER_VOLUME),
        )
    }

    /** 设置速率（Dart `setSpeed`，player_provider.dart:5260-5264）。内部 clamp 0.25..4.0。 */
    private fun setSpeed(state: PlaybackState, speed: Double): PlaybackTransition {
        val target = speed.coerceIn(0.25, 4.0)
        return PlaybackTransition(state.copy(speed = target), SetSpeed(target.toFloat()))
    }

    /**
     * 设置音质档位（Dart `setAudioQuality` + `_applyQualityToCurrent`，
     * player_provider.dart:5266-5420）。
     *
     * 同值 → no-op（Dart 首行守卫）。变更后：清实际音质、按当前网络键落盘；
     * 当前曲为在线曲时重新解析（Dart `_applyQualityToCurrent`：`isResolvingUrl`
     * 置位并按断点续播），本地曲不动。
     */
    private fun setAudioQuality(state: PlaybackState, quality: AudioQuality): PlaybackTransition {
        if (quality == state.audioQuality) return unchanged(state)
        val song = state.currentSong
        val resolving = song != null && song.isOnline
        val effects = buildList {
            add(PersistPreference(if (state.isWifiNetwork) KEY_QUALITY_WIFI else KEY_QUALITY_MOBILE))
            if (resolving) add(ResolveSongUrl(song))
        }
        return PlaybackTransition(
            state.copy(
                audioQuality = quality,
                actualPlayingQuality = null,
                isResolvingUrl = resolving,
                awaitingPlaybackProgress = if (resolving) state.isPlaying || state.awaitingPlaybackProgress else state.awaitingPlaybackProgress,
                manualRetryInFlight = false,
            ),
            effects,
        )
    }

    /**
     * 设置/取消睡眠定时（Dart `setSleepTimer`，player_provider.dart:5279-5324）。
     *
     * 模式经 [SleepTimerMode.forTimerStart]；取消（null）时连同到点等待态
     * 与「播完当前歌曲」勾选一起清掉（Dart 同）。倒计时每秒的走字由 Store
     * 的定时器写 `sleepTimerRemaining`（PlaybackState KDoc 的高频通道约定）。
     */
    private fun setSleepTimer(state: PlaybackState, duration: Duration?): PlaybackTransition = PlaybackTransition(
        state.copy(
            sleepTimerMode = SleepTimerMode.forTimerStart(duration),
            sleepTimerRemaining = duration,
            stopAfterTimerEnds = if (duration == null) false else state.stopAfterTimerEnds,
        ),
    )

    /**
     * 「定时结束后播完当前歌曲」勾选（Dart `setStopAfterCurrentTrack`，
     * player_provider.dart:5332-5338）。
     *
     * 取消时若已进入到点等待态（END_OF_TRACK）则撤销回 OFF（Dart 同，
     * `afterStopAfterCurrentTrackDisabled`），但不打断播放。
     */
    private fun setStopAfterCurrentTrack(state: PlaybackState, enabled: Boolean): PlaybackTransition =
        PlaybackTransition(
            state.copy(
                stopAfterTimerEnds = enabled,
                sleepTimerMode = if (!enabled) state.sleepTimerMode.afterStopAfterCurrentTrackDisabled() else state.sleepTimerMode,
            ),
        )

    /**
     * 音质降级提示开关（Dart `setShowQualityDowngradeToast`，player_provider.dart:1294-1300）。
     * 内存 + 落盘；无幂等守卫（Dart 无条件写）。
     */
    private fun showQualityDowngradeToast(state: PlaybackState, enabled: Boolean): PlaybackTransition =
        PlaybackTransition(
            state.copy(showQualityDowngradeToast = enabled),
            PersistPreference(KEY_SHOW_QUALITY_DOWNGRADE_TOAST),
        )

    /**
     * 本地音乐关闭评论区开关（Dart `setCloseLocalMusicComments`，player_provider.dart:1336-1343）。
     * 同值 → no-op（Dart 首行守卫）。
     */
    private fun closeLocalMusicComments(state: PlaybackState, enabled: Boolean): PlaybackTransition {
        if (state.closeLocalMusicComments == enabled) return unchanged(state)
        return PlaybackTransition(
            state.copy(closeLocalMusicComments = enabled),
            PersistPreference(KEY_CLOSE_LOCAL_MUSIC_COMMENTS),
        )
    }

    // ═══════════════════════ 收藏 ═══════════════════════

    /**
     * 切换当前曲收藏态（Dart 由 FavoritesProvider 独立承担；native 纳入播放域
     * 因为通知栏收藏按钮必须经 MediaSession 回转，见意图 KDoc）。
     *
     * [PlaybackState] 无收藏字段（收藏态属数据层 P2），归约器只发
     * [PersistFavoriteToggle]；无当前曲 → no-op。
     */
    private fun toggleFavorite(state: PlaybackState): PlaybackTransition {
        val song = state.currentSong ?: return unchanged(state)
        return PlaybackTransition(state, PersistFavoriteToggle(song.id))
    }

    // ═══════════════════════ 事件 ═══════════════════════

    /**
     * 引擎播放态变化（Dart playerStateStream 处理器，player_provider.dart:1715-1746）。
     *
     * - `playbackNotReady = (playbackState != READY)`——Dart 原注释强调必须
     *   用 `!= ready` 判定（切歌加载走 loading 不走 buffering）；
     * - IDLE → isPlaying / awaiting 收敛为 false（无音源，不可能在播）；
     * - ENDED → **只写** `playbackNotReady` 与 awaiting，不抢写 isPlaying：
     *   vendored `ExoPlayerImpl.java:2158-2183` 保证 ENDED 状态事件先于
     *   isPlaying 事件派发，且适配器在 ENDED 回调内同步触发 Completed
     *   （`ExoPlayerPlaybackEngineAdapter.kt:219-220`）——若此处抢先清
     *   isPlaying，[playbackCompleted] 的重复投递守卫会把**首次**播完误判
     *   为重复。isPlaying 交给随后的 `EngineIsPlayingChanged(false)` 收敛。
     */
    private fun playbackStateChanged(state: PlaybackState, playbackState: Int): PlaybackTransition {
        val notReady = playbackState != PLAYER_STATE_READY
        return when (playbackState) {
            PLAYER_STATE_ENDED -> PlaybackTransition(
                state.copy(
                    playbackNotReady = true,
                    awaitingPlaybackProgress = false,
                ),
            )
            PLAYER_STATE_IDLE -> PlaybackTransition(
                state.copy(
                    playbackNotReady = true,
                    isPlaying = false,
                    awaitingPlaybackProgress = false,
                ),
            )
            else -> PlaybackTransition(state.copy(playbackNotReady = notReady))
        }
    }

    /**
     * 引擎 isPlaying 变化（Dart playingStream 处理器，player_provider.dart:1628-1644）。
     *
     * 唯一的 isPlaying 权威写入口（规则 1）。暂停时清理等待推进标志；
     * 起播时顺手清 `manualRetryInFlight`（重试已 concluded—— Dart 在重试
     * Future 的 finally 里清，native 以「真正开始播放」为收敛点）。
     */
    private fun isPlayingChanged(state: PlaybackState, isPlaying: Boolean): PlaybackTransition =
        PlaybackTransition(
            state.copy(
                isPlaying = isPlaying,
                awaitingPlaybackProgress = if (isPlaying) state.awaitingPlaybackProgress else false,
                manualRetryInFlight = if (isPlaying) false else state.manualRetryInFlight,
            ),
        )

    /**
     * 引擎位置推进（Dart `_observePlatformPosition` + `_updatePosition`，
     * player_provider.dart:643-696；换源抑制由 Store 的 PositionRewindGate
     * 前置完成，到达归约器的采样已是放行值）。
     *
     * `platformPosition` 无条件写（平台真相）；`position` 仅当平台**不落后**
     * 于乐观目标时同步。判据的由来：状态里没有「seek 手势进行中」字段，
     * 「平台位置落后于乐观位置」即手势窗/乐观窗（[seekTo] /
     * [seekGestureCompleted] 写入目标后、引擎尚未落地的窗口）——窗内采样
     * （暂停中的常量位置、缓冲旧值）不回改用户看到的目标，平台追上或超过
     * 后自动恢复同步。Dart 是无条件同步每个采样，此处是有条件（见类 KDoc
     * 差异项 5）。
     */
    private fun enginePositionChanged(state: PlaybackState, position: Duration): PlaybackTransition =
        PlaybackTransition(
            state.copy(
                platformPosition = position,
                position = if (position >= state.position) position else state.position,
            ),
        )

    /**
     * 引擎切曲确认（Dart sequenceStateStream 处理器，player_provider.dart:1772-1803）。
     *
     * 单曲时间线 + 命令翻译表下引擎不会自行切歌，本事件只是**确认**：
     * `mediaItemIndex`（Store 把 mediaId 解析到当前队列的下标）与
     * `currentIndex` 不符 → 过期事件（快速切歌的迟到 transition），忽略；
     * 相符 → 确认，无状态变化。**绝不回采引擎索引**（与 Dart 的采纳语义
     * 不同，见类 KDoc 差异项 4）。
     */
    private fun mediaItemTransition(state: PlaybackState, mediaItemIndex: Int): PlaybackTransition {
        if (mediaItemIndex != state.currentIndex) return unchanged(state)
        return unchanged(state)
    }

    /**
     * 引擎播完当前曲（Dart `_handlePlaybackCompleted` 的循环语义部分，
     * player_provider.dart:1880-2135）。
     *
     * 1. **重复投递守卫**：引擎已终态（[isEngineTerminal]）→ no-op（台本
     *    §3.5 竞态 4「Completed 在已结束态为 no-op」）；
     * 2. **睡眠定时到点等待态**（END_OF_TRACK）：当前曲**自然**播完 → 复位
     *    模式 + 暂停 + 停保活（Dart player_provider.dart:1937-1943；异常结束
     *    不算播完，判据见 [isAbnormalCompletion]，此时继续走循环语义）；
     * 3. **单曲循环（ONE）**：在线曲异常结束（URL 过期/流中断）→ 丢弃旧
     *    地址、从断点重解析（Dart player_provider.dart:1955-1981；重试预算
     *    归 Store 恢复链，台本 §3.6）；否则从头重播（SeekTo(0) + Play）；
     * 4. **其余（ALL/OFF）**：委托 [PlaybackQueue.nextBoundary]——队尾 +
     *    OFF → 提示 + 停机；其余 → 推进（ALL 队尾绕回队首，见类 KDoc 差异项 2）。
     *
     * 异常结束的重试计数（`_abnormalEndRetries`）与故障歌曲摘除不在
     * [PlaybackState] 字段内，归 Store 恢复链（`RecoveryOrchestrator`，
     * T-P1-06），此处只做纯状态迁移。
     */
    private fun playbackCompleted(state: PlaybackState): PlaybackTransition {
        if (state.queue.isEmpty) return unchanged(state)
        if (isEngineTerminal(state)) return unchanged(state)

        if (state.sleepTimerMode == SleepTimerMode.END_OF_TRACK && !isAbnormalCompletion(state)) {
            return PlaybackTransition(
                state.copy(
                    sleepTimerMode = SleepTimerMode.OFF,
                    isPlaying = false,
                    playbackNotReady = true,
                    awaitingPlaybackProgress = false,
                ),
                Pause,
                StopKeepAlive,
            )
        }

        if (state.queue.loopMode == AppLoopMode.ONE) {
            val song = state.currentSong
            if (song != null && song.isOnline && isAbnormalCompletion(state)) {
                val cleared = song.copy(url = null)
                return PlaybackTransition(
                    state.copy(
                        queue = state.queue.replaceCurrent(cleared),
                        isResolvingUrl = true,
                        awaitingPlaybackProgress = true,
                        manualRetryInFlight = false,
                    ),
                    ResolveSongUrl(cleared),
                    StartKeepAlive,
                )
            }
            return PlaybackTransition(
                state.copy(
                    awaitingPlaybackProgress = true,
                    position = ZERO,
                    platformPosition = ZERO,
                    manualRetryInFlight = false,
                ),
                SeekTo(0L),
                Play,
                StartKeepAlive,
            )
        }

        return when (val boundary = state.queue.nextBoundary()) {
            is NextBoundary.Nothing -> unchanged(state)
            is NextBoundary.HintAndPause -> PlaybackTransition(
                state.copy(
                    isPlaying = false,
                    playbackNotReady = true,
                    awaitingPlaybackProgress = false,
                    manualRetryInFlight = false,
                ),
                ShowMessage(QUEUE_END_MESSAGE),
                Pause,
                StopKeepAlive,
            )
            // ONE 已在上方处理，此处仅剩 ALL/OFF；RestartSingle 防御性映射为重播。
            is NextBoundary.RestartSingle -> PlaybackTransition(
                state.copy(
                    awaitingPlaybackProgress = true,
                    position = ZERO,
                    platformPosition = ZERO,
                    manualRetryInFlight = false,
                ),
                SeekTo(0L),
                Play,
                StartKeepAlive,
            )
            is NextBoundary.Proceed -> {
                val target = nextAdvanceTarget(state) ?: return unchanged(state)
                switchToIndex(state, target, playWhenReady = true)
            }
        }
    }

    /**
     * 引擎/解析错误（Dart player errorStream 处理器，player_provider.dart:1649-1710；
     * 入口过滤 `shouldHandlePlaybackErrorEvent` 归 Store 闸门，台本 §3.6）。
     *
     * 原始错误串入 [PlaybackState.resolveError]（上屏必须走
     * `resolveErrorForDisplay` 收敛）；空消息回落 [DEFAULT_PLAYBACK_ERROR]
     * （Dart 硬编码同一串，避免平台细节外泄）。isPlaying 不写（规则 1）；
     * `_failedPlaybackPosition`（断点续播基准）不在状态字段内，由 Store 的
     * 恢复链持有。
     *
     * **纯函数约束（T-P1-06 B1）**：本函数只做状态迁移，不做 IO、不选恢复动作。
     * [PlaybackErrorInfo.category] 虽为派生属性，但分类函数是纯函数；恢复决策
     * （重试 / 跳歌 / 停止）归 Store 的 `RecoveryOrchestrator`。
     */
    private fun engineError(state: PlaybackState, info: PlaybackErrorInfo): PlaybackTransition = PlaybackTransition(
        state.copy(
            isResolvingUrl = false,
            resolveError = info.message?.takeIf { it.isNotEmpty() } ?: DEFAULT_PLAYBACK_ERROR,
            awaitingPlaybackProgress = false,
            manualRetryInFlight = false,
        ),
    )

    /**
     * 网络变化（Dart `_onNetworkChanged`，player_provider.dart:1089-1095）。
     *
     * 同值 → no-op；变更只写 [PlaybackState.isWifiNetwork]。音质重读
     * （`_loadQualityForNetwork`）与失败重试（`_retryFailedPlayback`）归
     * Store 侧流水线（台本 §3.6：恢复链经预算/单飞闸门后派发
     * `PlaybackIntent.RetryCurrent`，见 `RecoveryOrchestrator`）。
     */
    private fun networkChanged(state: PlaybackState, isWifi: Boolean): PlaybackTransition {
        if (state.isWifiNetwork == isWifi) return unchanged(state)
        return PlaybackTransition(state.copy(isWifiNetwork = isWifi))
    }

    /**
     * 循环模式由外部改变（设置页）。与 [toggleLoopMode] 同样不涨
     * `queueRevision`；同值 → no-op。
     */
    private fun loopModeChanged(state: PlaybackState, mode: AppLoopMode): PlaybackTransition {
        val mutation = state.queue.withLoopMode(mode)
        if (mutation.queue == state.queue) return unchanged(state)
        return PlaybackTransition(state.copy(queue = mutation.queue))
    }

    /**
     * 平台位置首次真实推进已确认（台本 §3.4）。
     *
     * 唯一职责：清理 [PlaybackState.awaitingPlaybackProgress]。Dart 在
     * `_observePlatformPosition` 里顺带做全量 notify（低频状态条刷新），
     * native 由 Store 观察状态发射完成，归约器只清标志。
     */
    private fun progressConfirmed(state: PlaybackState): PlaybackTransition =
        PlaybackTransition(state.copy(awaitingPlaybackProgress = false))

    // ═══════════════════════ 私有辅助 ═══════════════════════

    /** 无变化迁移（状态原样 + 空效果）——非法操作的明确拒绝。 */
    private fun unchanged(state: PlaybackState): PlaybackTransition = PlaybackTransition(state)

    /** 纯落盘效果（焦点/记忆类偏好无状态字段时的形态）。 */
    private fun persistOnly(state: PlaybackState, effect: PlaybackEffect): PlaybackTransition =
        PlaybackTransition(state, effect)

    /**
     * 曲目是否需要先解析播放地址：无 url 且（在线 / 云盘 / 本地也无路径）。
     * 与引擎 `prepare` 的拒绝语义互补（引擎对无音源曲目不装载不伪造）。
     */
    private fun needsUrlResolution(song: Song): Boolean =
        song.url == null && (song.isOnline || song.isCloud || song.localPath == null)

    /**
     * next / 播完推进的目标下标（Dart `next()` 循环体的 `(_currentIndex + 1) % n`
     * 语义，player_provider.dart:4590-4592）：
     * - 候选序列非空 → 首候选（next 的非队尾截断由 [PlaybackQueue.nextCandidateIndices]
     *   表达，ALL 队尾绕回队首）；
     * - 候选为空且 `currentIndex < 0`（无当前曲的退化队列）→ 0；
     * - 候选为空且 `currentIndex >= 0`（单曲 + ALL 绕回起点）→ null（Dart
     *   `break` 后无操作，调用方按 no-op 处理）。
     */
    private fun nextAdvanceTarget(state: PlaybackState): Int? {
        val candidates = state.queue.nextCandidateIndices()
        if (candidates.isNotEmpty()) return candidates.first()
        return if (state.queue.currentIndex < 0) 0 else null
    }

    /**
     * 切到指定下标并起播/预载（next / previous / 播完推进的公共路径）。
     *
     * 位置基准归零、错误清除、`awaitingPlaybackProgress = playWhenReady`
     * （Dart：请求已发 → 闸门 pending → `isAwaitingPlaybackProgress` 跟随
     * 播放意愿）。**不涨 `queueRevision`**（Dart `next`/`previous` 不自增，
     * 只有装载/增删/排序/随机切换自增）。
     */
    private fun switchToIndex(
        state: PlaybackState,
        target: Int,
        playWhenReady: Boolean,
    ): PlaybackTransition {
        val song = state.queue.playlist.getOrNull(target) ?: return unchanged(state)
        val queue = state.queue.positionedAt(target)
        val resolving = needsUrlResolution(song)
        val effects = buildList {
            add(if (resolving) ResolveSongUrl(song) else Prepare(song, startPositionMs = null, playWhenReady = playWhenReady))
            if (playWhenReady) add(StartKeepAlive)
            add(PersistPlaybackCursor)
        }
        return PlaybackTransition(
            state.copy(
                queue = queue,
                isResolvingUrl = resolving,
                resolveError = null,
                awaitingPlaybackProgress = playWhenReady,
                position = ZERO,
                platformPosition = ZERO,
                duration = null,
                manualRetryInFlight = false,
            ),
            effects,
        )
    }

    /**
     * 重播当前曲（next 的 RestartSingle / previous 的 RestartCurrent）。
     *
     * Dart `next` 单曲循环末曲：`seek(0)` + `autoPlay` 时 `playCommand`；
     * `previous` 绕回：仅 `seek(0)`（不补 play，与 next 不对称——引擎保持
     * 自身 playWhenReady）。
     */
    private fun restartCurrent(state: PlaybackState, autoPlay: Boolean): PlaybackTransition {
        val effects = buildList {
            add(SeekTo(0L))
            if (autoPlay) {
                add(Play)
                add(StartKeepAlive)
            }
            add(PersistPlaybackCursor)
        }
        return PlaybackTransition(
            state.copy(
                awaitingPlaybackProgress = autoPlay,
                position = ZERO,
                platformPosition = ZERO,
                manualRetryInFlight = false,
            ),
            effects,
        )
    }

    /**
     * 结构变更的队列更新：换队列 + `queueRevision+1` + 落盘。
     * 非结构变更（全重复追加、越界重排等）→ no-op。
     */
    private fun structuralQueueUpdate(
        state: PlaybackState,
        mutation: QueueMutation,
    ): PlaybackTransition {
        if (!mutation.structuralChange) return unchanged(state)
        return PlaybackTransition(
            state.copy(queue = mutation.queue, queueRevision = state.queueRevision + 1),
            PersistPlaybackCursor,
        )
    }

    /** 队列被清空的停机路径（RemoveAt/RemoveMany/ClearQueue 的 emptied 结局）。 */
    private fun emptied(state: PlaybackState, queue: PlaybackQueue): PlaybackTransition = PlaybackTransition(
        state.copy(
            queue = queue,
            awaitingPlaybackProgress = false,
            position = ZERO,
            platformPosition = ZERO,
            duration = null,
            resolveError = null,
            queueRevision = state.queueRevision + 1,
            manualRetryInFlight = false,
        ),
        Stop,
        StopKeepAlive,
        PersistPlaybackCursor,
    )

    /**
     * 删除当前曲后的重定位 + 重备（Dart removeFromPlaylist 的 wasCurrent
     * 分支，player_provider.dart:4968-5013）。
     *
     * `playWhenReady = state.isPlaying`（差异项 3：Dart 无条件 playCommand，
     * native 不复活用户主动暂停的播放）。位置基准归零（Dart `seek(0)`）。
     */
    private fun reprepareCurrent(state: PlaybackState, queue: PlaybackQueue): PlaybackTransition {
        val song = queue.currentSong ?: return emptied(state, queue)
        val resolving = needsUrlResolution(song)
        val effects = buildList {
            add(
                if (resolving) {
                    ResolveSongUrl(song)
                } else {
                    Prepare(song = song, startPositionMs = 0L, playWhenReady = state.isPlaying)
                },
            )
            if (state.isPlaying) add(StartKeepAlive)
            add(PersistPlaybackCursor)
        }
        return PlaybackTransition(
            state.copy(
                queue = queue,
                resolveError = null,
                awaitingPlaybackProgress = state.isPlaying,
                position = ZERO,
                platformPosition = ZERO,
                duration = null,
                queueRevision = state.queueRevision + 1,
                manualRetryInFlight = false,
            ),
            effects,
        )
    }

    /**
     * 异常结束判据（Dart `completedAbnormally` / `isAbnormal` / `isAbnormalEnd`
     * 同式，player_provider.dart:1920-1923）：
     * 位置超过 500ms 且明显未到歌曲时长的 80%——URL 过期 / 试听片段提前
     * completed 的形态；时长未知时无从判定，按正常结束。
     */
    private fun isAbnormalCompletion(state: PlaybackState): Boolean {
        val duration = state.duration ?: return false
        val position = state.position
        return position.inWholeMilliseconds > 500 &&
            duration.inWholeSeconds > 0 &&
            position.inWholeSeconds < duration.inWholeSeconds * 0.8
    }
}
