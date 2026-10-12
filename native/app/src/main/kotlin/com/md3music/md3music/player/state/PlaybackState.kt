package com.md3music.md3music.player.state

import com.md3music.md3music.data.model.Song
import com.md3music.md3music.player.model.AppLoopMode
import com.md3music.md3music.player.model.AudioQuality
import com.md3music.md3music.player.model.SleepTimerMode
import com.md3music.md3music.player.model.safePlaybackErrorMessage
import com.md3music.md3music.player.queue.PlaybackQueue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 播放域的**唯一**状态快照（MVI 的 `State`）。
 *
 * 字段与 lib/providers/player_provider.dart 对外暴露的全部 getter 一一对应，
 * 使 UI 层从 `watch<PlayerProvider>()` 迁移到 `collectAsState(store.state)` 时
 * 不需要改变消费习惯。字段来源见各属性 KDoc 里标注的 Dart 行号。
 *
 * **队列状态内聚在 [queue]**：Dart 的 `_playlist` / `_originalPlaylist` /
 * `_currentIndex` / `_shuffleEnabled` / `_loopMode` 五个字段合并为
 * [PlaybackQueue] 一个值，避免「同一个结构在两个地方各存一份」导致的不一致
 * （Dart 侧正是靠散落各处的 `_playlist[idx] = ...` 手工同步，才有屡次状态错位）。
 * [currentSong] / [playlist] / [currentIndex] / [loopMode] / [shuffleEnabled]
 * 作为只读派生属性保留，UI 侧的调用点无需改动。
 *
 * **哪些字段是「存储的」、哪些是「派生的」**：Dart 里 `isAwaitingPlaybackProgress`
 * 依赖 `_playbackProgressGate.isPending(request)`（闸门对象 + 请求号），
 * `sleepTimerRemaining` 依赖 `_sleepTimerEndTime` 与当前时刻。这两者在 native 侧
 * 都在 [PlaybackStore] 里算出**结果**后再写入本状态（[awaitingPlaybackProgress] /
 * [sleepTimerRemaining]），好处是 UI 拿到的状态是纯数据、可直接做
 * `distinctUntilChanged` 与截图比对，不再依赖读取时刻。
 *
 * **两个高频通道的处置（Dart 的 `positionNotifier` / `sleepTimerRemainingNotifier`）**：
 * Dart 之所以单独开 notifier，是因为 `ChangeNotifier` 只有「全量通知」一种粒度，
 * 位置流每 ~200ms 触发全量重建会让整页抖动。native 侧不需要这个补丁——
 * [PlaybackStore] 另开两条 `StateFlow`（位置、定时剩余）供进度条/歌词订阅，
 * 本状态里的 [position] / [sleepTimerRemaining] 只是低频快照（切歌/暂停/seek
 * 时的一致性基准）。详见 PlaybackStore 的通道划分说明。
 */
data class PlaybackState(
    /** 队列（播放顺序、当前曲、随机、循环）。 */
    val queue: PlaybackQueue = PlaybackQueue(),

    /** 是否处于播放态。Dart `_isPlaying`，是**乐观缓存**而非平台真相。 */
    val isPlaying: Boolean = false,

    /**
     * 已发出播放/恢复命令，但平台位置尚未确认真实推进
     * （player_provider.dart:517-522，UI 据此显示「等待音频进度」）。
     */
    val awaitingPlaybackProgress: Boolean = false,

    /**
     * 播放流未就绪（`processingState != ready`，含 loading/buffering）。
     *
     * Dart 原注释强调**必须用 `!= ready` 判定**：切歌加载走 loading 而非
     * buffering，若只判 buffering，切歌加载期间歌词逐字动画会「前进→回吸」
     * 锯齿抽搐（player_provider.dart:523-528）。
     */
    val playbackNotReady: Boolean = false,

    /**
     * 平台上报的最近位置（**不含本地乐观写入**）。
     *
     * 「拿本地位置与外部基准比较」的逻辑必须用它：Dart [position] 会被
     * `_updatePosition(seekTo)` 乐观写成目标位置，在线源没真正定位时比较结果
     * 是假的（player_provider.dart:666-672）。
     */
    val platformPosition: Duration = Duration.ZERO,

    /** 当前展示位置（可能为乐观写入的目标位置）。 */
    val position: Duration = Duration.ZERO,

    /** 时长；未知时为 null。 */
    val duration: Duration? = null,

    /** 应用内音量（0.0..1.0）。 */
    val volume: Double = 1.0,

    /** 播放速率（0.25..4.0）。 */
    val speed: Double = 1.0,

    /** 是否正在通过 API 解析当前曲目的播放地址。 */
    val isResolvingUrl: Boolean = false,

    /** 原始错误串（**不要直接上屏**，UI 必须走 [resolveErrorForDisplay]）。 */
    val resolveError: String? = null,

    /** 用户手动重试是否在途（player_provider.dart:702）。 */
    val manualRetryInFlight: Boolean = false,

    /** 用户设置的音质档位。 */
    val audioQuality: AudioQuality = AudioQuality.STANDARD,

    /** 实际播放音质码（可能因降级而与 [audioQuality] 不同）。 */
    val actualPlayingQuality: String? = null,

    /** 睡眠定时模式。 */
    val sleepTimerMode: SleepTimerMode = SleepTimerMode.OFF,

    /**
     * 倒计时剩余时间（null = 未启用倒计时）。
     *
     * 仅 [SleepTimerMode.COUNTDOWN] 下有值；[SleepTimerMode.END_OF_TRACK] 是
     * 「等待当前曲播完」的到点态，没有倒计时可言，恒为 null
     * （player_provider.dart:724-732）。
     */
    val sleepTimerRemaining: Duration? = null,

    /** 「定时结束后播完当前歌曲」的勾选态。 */
    val stopAfterTimerEnds: Boolean = false,

    /** 交叉淡化开关。 */
    val crossfadeEnabled: Boolean = false,

    /** 交叉淡化时长，默认 4 秒（`SettingsRepository.kCrossfadeDefaultSeconds`）。 */
    val crossfadeDuration: Duration = DEFAULT_CROSSFADE_DURATION,

    /** 当前是否处于 WiFi 类网络（决定用哪套音质偏好）。 */
    val isWifiNetwork: Boolean = true,

    /** 音质降级 Toast 的展示开关（实验设置）。 */
    val showQualityDowngradeToast: Boolean = false,

    /** 本地音乐是否关闭评论区（player_provider.dart:1326-1329）。 */
    val closeLocalMusicComments: Boolean = true,

    /**
     * 队列修订号：任何「队列结构或播放顺序」的变化都自增，供下游判断
     * 缓存的预加载/交叉淡化产物是否已作废。
     */
    val queueRevision: Int = 0,
) {
    // ─────────────────── 队列派生（UI 调用点兼容 Dart 命名） ───────────────────

    val currentSong: Song? get() = queue.currentSong

    val playlist: List<Song> get() = queue.playlist

    val currentIndex: Int get() = queue.currentIndex

    val loopMode: AppLoopMode get() = queue.loopMode

    val shuffleEnabled: Boolean get() = queue.shuffleEnabled

    // ─────────────────────────── 派生展示值 ───────────────────────────

    /** 可展示的播放错误文案（原始串被收敛，见 [safePlaybackErrorMessage]）。 */
    val resolveErrorForDisplay: String? get() = safePlaybackErrorMessage(resolveError)

    /** 音质档位展示名。 */
    val audioQualityLabel: String get() = audioQuality.label

    /** 是否启用了睡眠定时（倒计时**或**已进入到点等待态），player_provider.dart:753-755。 */
    val isSleepTimerActive: Boolean get() = sleepTimerMode != SleepTimerMode.OFF

    /**
     * 当前歌曲的实际音质标签，1:1 移植自 player_provider.dart:761-782：
     * 本地歌曲优先用 `song.quality` 推断，在线歌曲优先显示实际播放音质
     * （降级后可能与用户设置不同），若尚无实际音质则回退到用户设置值。
     *
     * **一处 P2 依赖**：在线分支在 Dart 里走 `KugouQuality.labelOf(code)`（酷狗
     * 音质码 → 展示名，属数据层）。P2 落地前，本属性对**已知 5 档**码值用与
     * `AudioQuality.label` 一致的映射，未知码值原样展示（与 Dart 的
     * `default: return song.quality!` 兜底行为同构）。P2 完成后把
     * [onlineQualityLabelOf] 换成 `KugouQuality::labelOf` 即可，无需改调用点。
     */
    fun currentQualityLabel(
        onlineQualityLabelOf: (String) -> String = { code -> defaultOnlineQualityLabel(code) },
    ): String {
        val song = currentSong
        if (song != null && !song.isOnline && song.quality != null) {
            return when (song.quality) {
                "128" -> "标准音质"
                "320" -> "高音质"
                "flac" -> "无损音质"
                "high" -> "Hi-Res"
                else -> song.quality
            }
        }
        val actual = actualPlayingQuality
        if (actual != null) return onlineQualityLabelOf(actual)
        return audioQuality.label
    }

    companion object {
        /** `SettingsRepository.kCrossfadeDefaultSeconds` = 4。 */
        val DEFAULT_CROSSFADE_DURATION: Duration = 4.seconds
    }
}

/**
 * 在线音质码 → 展示名。P2 的 `KugouQuality.labelOf` 落地前的最小实现，
 * 覆盖本项目会用到的 5 档；未知名原样返回（等价 Dart 的 `default` 分支）。
 *
 * 刻意放在**顶层**而非伴生对象里：这样 [PlaybackState.currentQualityLabel] 的
 * 默认参数可以用简单的函数引用替换而不触发作用域解析问题。
 */
fun defaultOnlineQualityLabel(code: String): String = when (code) {
    "128" -> "标准音质"
    "320" -> "高音质"
    "flac" -> "无损音质"
    "high" -> "Hi-Res"
    "viper_tape" -> "蝰蛇母带"
    else -> code
}
