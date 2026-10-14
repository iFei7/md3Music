package com.gracemusic.player.state

import com.gracemusic.data.model.Song
import com.gracemusic.player.gate.AudioFocusInterruptionMode
import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.model.AudioQuality
import com.gracemusic.player.model.PlaylistSortBy
import kotlin.time.Duration

/**
 * 播放域意图词汇表（MVI 的 `Intent`）——**由 UI / 外部调用方发出**。
 *
 * 覆盖 lib/providers/player_provider.dart 里全部**会改变状态**的公开方法，
 * 逐条对应关系见各子类型的 KDoc。约定：
 *
 * 1. **单向、无返回值**。需要返回值的交互（拖动进度条要拿会话号）不建模成
 *    Intent，见 [SeekGestureStarted] 的说明。
 * 2. **只描述「想做什么」，不含「怎么做」**。`PlayPlaylistFrom` 不携带 URL，
 *    也不指明用哪个 API；解析策略由队列项自身（[Song.isCloud] / 是否在线）
 *    与 store 内的 resolver 决定——这与 Dart 里 `playPlaylist` /
 *    `playOnlinePlaylist` / `playCloudPlaylist` 三个入口的差异一致。
 * 3. 系统层（媒体键 / 通知 / MediaSession）来的命令走
 *    [com.gracemusic.player.session.PlayerCommand]，由 store 翻译成本
 *    词汇表后再归约，保证**只有一条归约路径**。
 *
 * 与 [PlaybackEvent] 的区分：本接口是「请求」，[PlaybackEvent] 是「已发生的事实」。
 * 归约器两者都吃，但事件不产生副作用（不触发网络解析、不落盘），只有意图会。
 */
sealed interface PlaybackIntent {

    // ───────────────────────── 装载与起播 ─────────────────────────

    /** 播放单曲：不存在于队列时以「单曲队列」起播。Dart `playSong`。 */
    data class PlaySingleSong(val song: Song) : PlaybackIntent

    /** 播放单曲（在线，走在线解析路径）。Dart `playOnlineSong`。 */
    data class PlayOnlineSingleSong(val song: Song) : PlaybackIntent

    /**
     * 装载队列并从 [startIndex] 起播。Dart `playPlaylist`。
     *
     * 队列按「是否在线」自动分流解析；`isCloud` 的曲目走云盘 URL 解析。
     */
    data class PlayPlaylistFrom(val songs: List<Song>, val startIndex: Int) : PlaybackIntent

    /** 装载队列并起播（在线专用入口）。Dart `playOnlinePlaylist`。 */
    data class PlayOnlinePlaylistFrom(val songs: List<Song>, val startIndex: Int) : PlaybackIntent

    /** 装载云盘队列并起播。Dart `playCloudPlaylist`。 */
    data class PlayCloudPlaylistFrom(val songs: List<Song>, val startIndex: Int) : PlaybackIntent

    /** 播放队列中指定下标的歌曲（播放列表面板点击）。Dart `playSongAt`。 */
    data class PlayAt(val index: Int) : PlaybackIntent

    // ───────────────────────── 传输控制 ─────────────────────────

    /** 继续播放（用户主动恢复）。Dart `resume`。 */
    data object Resume : PlaybackIntent

    /** 暂停（用户主动暂停）。Dart `pause`。 */
    data object Pause : PlaybackIntent

    /** 暂停但**不视作用户意图**（拖动进度条前置暂停）。Dart `pauseForSeek`。 */
    data object PauseForSeek : PlaybackIntent

    /** 绝对定位。Dart `seek`。 */
    data class SeekTo(val position: Duration) : PlaybackIntent

    /** 相对定位（通知栏 / 蓝牙的 ±10s、±15s）。Dart 侧由 UI 折算成绝对位置。 */
    data class SeekBy(val delta: Duration) : PlaybackIntent

    /** 下一首。[autoPlay] = false 时只装载不出声（用于预加载验证）。Dart `next`。 */
    data class Next(val autoPlay: Boolean = true) : PlaybackIntent

    /** 上一首。Dart `previous`。 */
    data class Previous(val autoPlay: Boolean = true) : PlaybackIntent

    /** 重试当前曲目（手动重试，计数独立于自动恢复额度）。Dart `retryCurrentPlayback`。 */
    data object RetryCurrent : PlaybackIntent

    /** 停止并清空播放状态（不改变队列？——Dart 由 `clearPlaylist` 承担。此处仅停引擎）。 */
    data object Stop : PlaybackIntent

    /**
     * 拖动进度条开始（事务开始）。
     *
     * **不建模为「返回会话号」**：Dart 的 `beginSeekSession({required bool wasPlaying}) → int`
     * 需要把会话号回传给 `completeSeekSession`。MVI 的 Intent 约定无返回值，
     * 因此会话号由 [PlaybackStore.beginSeekSession] 这一薄封装直接返回，
     * 封装内部照旧派发本 Intent——保证状态只由归约器修改。
     */
    data class SeekGestureStarted(val wasPlaying: Boolean) : PlaybackIntent

    /** 拖动进度条结束（事务结束，落到 [position]）。Dart `completeSeekSession`。 */
    data class SeekGestureCompleted(val sessionId: Int, val position: Duration) : PlaybackIntent

    // ───────────────────────── 队列编辑 ─────────────────────────

    /** 追加歌曲到队列（按 id 去重）。Dart `appendPlaylist`。 */
    data class AppendToQueue(val songs: List<Song>) : PlaybackIntent

    /** 在当前曲之后插入（「下一首播放」）。Dart `insertAfterCurrent`。 */
    data class InsertAfterCurrent(val songs: List<Song>) : PlaybackIntent

    /** 删除队列中指定下标的歌曲。Dart `removeFromPlaylist`。 */
    data class RemoveAt(val index: Int) : PlaybackIntent

    /** 批量删除（编辑模式）。Dart `removeManyFromPlaylist`。 */
    data class RemoveMany(val songIds: Set<String>) : PlaybackIntent

    /** 重排（`ReorderableListView` 约定：`oldIndex < newIndex` 时 newIndex 需 -1）。Dart `reorderPlaylist`。 */
    data class ReorderQueue(val oldIndex: Int, val newIndex: Int) : PlaybackIntent

    /** 按维度重排整个队列。Dart `sortPlaylist`。 */
    data class SortQueue(val by: PlaylistSortBy, val ascending: Boolean = true) : PlaybackIntent

    /**
     * 更新队列中同 id 歌曲的字段（回写 localPath / url）。Dart `updateSongInPlaylist`。
     *
     * [actualQuality] 是解析回写专用载荷（词汇表第二处增补，F-SRC-006：
     * 实际播放音质随解析回写进入状态）：仅 [PlaybackEffect.ResolveSongUrl]
     * 执行器在解析成功后的回写携带服务端回写档；其余调用方（NAS 下载回写
     * localPath 等）保持默认 null——归约器对 null 不动现有
     * `actualPlayingQuality`，防止误清。
     */
    data class UpdateSong(val song: Song, val actualQuality: String? = null) : PlaybackIntent

    /** 清空队列并停止播放。Dart `clearPlaylist`。 */
    data object ClearQueue : PlaybackIntent

    // ───────────────────────── 播放偏好 ─────────────────────────

    /** 循环模式三态切换。Dart `toggleLoopMode`。 */
    data object ToggleLoopMode : PlaybackIntent

    /** 合并后的模式循环（含随机）。Dart `cyclePlayMode`。 */
    data object CyclePlayMode : PlaybackIntent

    /** 设置音量（内部 clamp 到 0.0..1.0）。Dart `setVolume`。 */
    data class SetVolume(val volume: Double) : PlaybackIntent

    /** 设置播放速率（内部 clamp 到 0.25..4.0）。Dart `setSpeed`。 */
    data class SetSpeed(val speed: Double) : PlaybackIntent

    /** 设置音质档位（会触发当前曲重新解析）。Dart `setAudioQuality`。 */
    data class SetAudioQuality(val quality: AudioQuality) : PlaybackIntent

    /** 设置/取消睡眠定时（null = 取消）。Dart `setSleepTimer`。 */
    data class SetSleepTimer(val duration: Duration?) : PlaybackIntent

    /** 设置「定时结束后播完当前歌曲」偏好。Dart `setStopAfterCurrentTrack`。 */
    data class SetStopAfterCurrentTrack(val enabled: Boolean) : PlaybackIntent

    /** 忽略音频焦点开关。Dart `setIgnoreAudioFocus`。 */
    data class SetIgnoreAudioFocus(val enabled: Boolean) : PlaybackIntent

    /** 音频焦点中断策略。Dart `setAudioFocusInterruptionMode`。 */
    data class SetAudioFocusInterruptionMode(val mode: AudioFocusInterruptionMode) : PlaybackIntent

    /** 音质降级提示开关。Dart `setShowQualityDowngradeToast`。 */
    data class SetShowQualityDowngradeToast(val enabled: Boolean) : PlaybackIntent

    /** 「记忆播放状态」开关。Dart `setRestoreMemoryEnabled`。 */
    data class SetRestoreMemoryEnabled(val enabled: Boolean) : PlaybackIntent

    /** 本地音乐关闭评论区开关。Dart `setCloseLocalMusicComments`。 */
    data class SetCloseLocalMusicComments(val enabled: Boolean) : PlaybackIntent

    // ───────────────────────── 派生刷新与落盘 ─────────────────────────

    /** 网络变化后重读该网络的音质偏好并生效。Dart `refreshQualityForNetwork` / `_loadQualityForNetwork`。 */
    data object RefreshQualityForNetwork : PlaybackIntent

    /** 重读交叉淡化与自动混音设置。Dart `refreshCrossfadeSettings` / `refreshAutomixSettings`。 */
    data object RefreshCrossfadeSettings : PlaybackIntent

    /** 主动刷新媒体通知（封面/收藏态）。Dart `refreshNotification`。 */
    data object RefreshNotification : PlaybackIntent

    /** 立即落盘游标并等待写入队列排空（退到桌面 / 退出前）。Dart `flushPersistence`。 */
    data object FlushPersistence : PlaybackIntent

    // ───────────────────────── 收藏 ─────────────────────────

    /**
     * 切换当前曲的收藏态。
     *
     * 来源是媒体通知的收藏按钮（T44 的
     * `Md3SessionCommands.CUSTOM_ACTION_TOGGLE_FAVORITE`）与 UI 收藏按钮。
     * Dart 侧收藏由 `FavoritesProvider` 独立承担、未进 PlayerProvider；native
     * 把它纳入播放域是因为通知栏按钮必须经 MediaSession 回转到这里。
     */
    data object ToggleFavorite : PlaybackIntent
}

/**
 * 播放域上行事件（引擎 / 系统已发生的事实）。
 *
 * 拆成独立类型而不是复用 [PlaybackIntent]，是为了让归约器能区分
 * 「请求」与「事实」：Dart 里两者挤在同一个 `ChangeNotifier` 的回调与公开
 * 方法上，导致「谁该触发副作用」界限模糊（例如 `_updatePosition` 被用户 seek
 * 与位置流回调共用，只能靠 `PositionRewindGate` 事后补救）。native 侧保留同一
 * 套闸门，但把来源显式分开，便于按来源分别断言副作用。
 *
 * 全部事件由 [PlaybackStore] 订阅引擎/系统后投递，**不对外开放**。
 */
sealed interface PlaybackEvent {

    /** 引擎播放态变化（[androidx.media3.common.Player.STATE_IDLE] / `BUFFERING` / `READY` / `ENDED` 的会话态转换）。 */
    data class EnginePlaybackStateChanged(val playbackState: Int) : PlaybackEvent

    /** 引擎 `isPlaying` 变化。 */
    data class EngineIsPlayingChanged(val isPlaying: Boolean) : PlaybackEvent

    /** 引擎位置推进（已经过 [com.gracemusic.player.gate.PositionRewindGate] 抑制判定）。 */
    data class EnginePositionChanged(val position: Duration) : PlaybackEvent

    /** 引擎时长变化。 */
    data class EngineDurationChanged(val duration: Duration?) : PlaybackEvent

    /** 引擎切曲（当前媒体项变化）。 */
    data class EngineMediaItemTransition(val mediaItemIndex: Int) : PlaybackEvent

    /** 引擎播完当前曲（自然结束）。驱动 `_handlePlaybackCompleted` 的等价逻辑。 */
    data object EnginePlaybackCompleted : PlaybackEvent

    /** 引擎错误。 */
    data class EngineError(val message: String?) : PlaybackEvent

    /** 网络变化（WiFi 类 / 移动数据）。 */
    data class NetworkChanged(val isWifi: Boolean) : PlaybackEvent

    /** 应用前后台变化（决定自动恢复是否允许、诊断采样是否开启）。 */
    data class AppForegroundChanged(val backgrounded: Boolean) : PlaybackEvent

    /** 音量变化由引擎侧生效（音频焦点 duck / 恢复）。 */
    data class VolumeChanged(val volume: Double) : PlaybackEvent

    /** 循环模式由外部（设置页）改变，需与队列状态对齐。 */
    data class LoopModeChanged(val mode: AppLoopMode) : PlaybackEvent

    /**
     * 平台位置首次真实推进已确认（清理 [PlaybackState.awaitingPlaybackProgress]）。
     *
     * 由 PlaybackStore 订阅引擎位置流、经 `PlaybackProgressGate` 判定「本次
     * 请求基线之后首次真实前进」后投递；**不得由引擎直接产生**——引擎只上报
     * 位置采样（[EnginePositionChanged]），「是否算真实推进」是闸门语义，
     * 归 Store。理由见 `PlaybackState.kt` KDoc：`awaitingPlaybackProgress`
     * 在 Dart 侧依赖 `_playbackProgressGate.isPending(request)`（闸门对象 +
     * 请求号），native 把它收敛成状态字段并由本事件清理，同时避免 Store
     * 绕过归约器直写状态（违反唯一写入方）。
     */
    data object PlaybackProgressConfirmed : PlaybackEvent
}
