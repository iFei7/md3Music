package com.gracemusic.player.store

import android.util.Log
import androidx.annotation.MainThread
import com.gracemusic.data.model.Song
import com.gracemusic.data.source.LoudnessCache
import com.gracemusic.data.source.ResolutionResult
import com.gracemusic.data.source.SongUrlResolver
import com.gracemusic.player.gate.CdnStallWindowDecision
import com.gracemusic.player.gate.PlaybackProgressGate
import com.gracemusic.player.gate.PlaybackRequestGate
import com.gracemusic.player.gate.PositionRewindGate
import com.gracemusic.player.gate.classifyCdnStallWindow
import com.gracemusic.player.gate.shouldHandlePlaybackErrorEvent
import com.gracemusic.player.session.PlaybackSessionBridge
import com.gracemusic.player.session.PlaybackSessionRegistry
import com.gracemusic.player.session.PlayerCommand
import com.gracemusic.player.state.PlaybackEvent
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.player.state.PlaybackState
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Qualifier
import javax.inject.Singleton

/** [PlaybackStore] 持有的应用级协程作用域限定符（进程存续，不随 UI 重建）。 */
@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class StoreScope

/**
 * 播放域归约入口与编排层（MVI 的 `Store`）——台本 §3.6 契约实现。
 *
 * 职责收敛为五件事，其余一律不碰（UI / 数据 / Rust / 通知渲染各有其主）：
 * 1. **状态面**：[state] 低频快照 + [position] 高频位置流（两条通道的划分见
 *    [PlaybackState] 类 KDoc）；
 * 2. **派发**：意图（请求）/ 事件（已发生事实）/ [PlayerCommand]（系统层命令）
 *    三个入口，全部经 [PlaybackReducer] 唯一归约路径；
 * 3. **副作用执行**：归约产出的 [PlaybackEffect] 列表按序执行（引擎调用真发，
 *    未落地能力只登记 TODO 日志，**不伪造成功**）；
 * 4. **系统命令桥接**：实现 [PlaybackSessionBridge] 并 attach 到
 *    [PlaybackSessionRegistry]（媒体键 / 通知 / 蓝牙的命令终点）；
 * 5. **闸门管线**：请求代次 / 进度确认 / 位置回退抑制 / 错误入口过滤 / CDN 看门狗
 *    （见下方「闸门管线」节，全部为 Store 私有，不进归约器）。
 *
 * ## 线程模型（铁律）
 * **全部派发与效果执行在调用线程同步完成，入口契约 = 应用主线程**
 * （media3 `ExoPlayerImpl` 的 `verifyApplicationThread()` 约束，
 * `ExoPlayerPlaybackEngineAdapter` 入口同样显式校验）。主线程限定即天然串行，
 * 因此本类**不用 Mutex**——加锁会掩盖「从后台线程派发」这类模型错误，
 * 让它们在真机上表现为难以复现的状态错位。位置收集协程与生产 DI 注入的
 * 作用域同为 `Dispatchers.Main.immediate`（见 `di/PlayerModule.kt`）。
 *
 * ## init 顺序（attach 必须最后）
 * 1. 初始化 [state] / [position] 与内部字段（闸门、代次、时钟、保活对账态）；
 * 2. `engine.addListener(listener)`；
 * 3. 启动 `engine.positionFlow` 收集协程；
 * 4. 启动 CDN 看门狗 ticker 协程（见 [runCdnStallWatchdog]）；
 * 5. **最后** `registry.attach(this)`——attach 会同步重放缓冲命令，走
 *    `dispatch(command)` 全链路，此时监听与位置管线必须已就绪。
 *
 * 空队列上重放的 `Play` 是归约器已定义的 no-op（`Resume` 无当前曲 → 状态
 * 原样 + 空效果），安全。**登记**：队列恢复（T-P1-10/11）落地后，attach
 * 时机应调整为「上次队列恢复完成时」而非构造时，否则冷启动的耳机键唤醒
 * 会落在空队列上（`PlaybackSessionRegistry.attach` KDoc 同此要求）。
 *
 * ## PlayerCommand → PlaybackIntent 翻译表（台本 §3.6）
 * | 命令 | 意图 | 备注 |
 * |---|---|---|
 * | `Play` | `Resume` | |
 * | `Pause` | `Pause` | |
 * | `TogglePlayPause` | 按 `state.isPlaying` 映射 `Pause` / `Resume` | 权威引擎收敛值，非乐观缓存 |
 * | `Next` | `Next(autoPlay = false)` | 系统侧下一首只装载不出声的语义由命令词表定义 |
 * | `Previous` | `Previous(autoPlay = false)` | 同上 |
 * | `Stop` | `Stop` | 唯一使请求闸门 invalidate 的入口 |
 * | `ToggleFavorite` | `ToggleFavorite` | |
 * | `SeekTo(ms)` | `SeekTo(ms)` | 毫秒 → Duration |
 * | `SeekBy(δ)` | `SeekBy(δ)` | 同上 |
 * | `SetPlayWhenReady(true)` | `Resume` | |
 * | `SetPlayWhenReady(false)` | `Pause` | |
 *
 * ## 效果执行器（when 穷尽 16 个子类型）
 * - 引擎类（[PlaybackEffect.Prepare] / [PlaybackEffect.Play] / [PlaybackEffect.Pause] /
 *   [PlaybackEffect.Stop] / [PlaybackEffect.SeekTo] / [PlaybackEffect.SeekBy] /
 *   [PlaybackEffect.SetVolume] / [PlaybackEffect.SetSpeed]）→ `engine.*` 同名调用，
 *   字段名即方法签名（[PlaybackEffect] 设计契约），无二次翻译；
 * - 服务类（[PlaybackEffect.StartKeepAlive] / [PlaybackEffect.StopKeepAlive]）→
 *   [PlaybackKeepAlive]（Store 侧按目标态去重，服务本身亦幂等）；
 * - 解析类：[PlaybackEffect.ResolveSongUrl] → [SongUrlResolver]（T-P1-05，
 *   异步执行 + 回写收尾，见 [resolveSongUrl]）；
 * - 数据/系统类 → **只登记 TODO 日志，不伪造成功**：
 *   `RetryPlayback`（T-P1-06 恢复链；
 *   **归约器不产生本效果**，生产者随恢复链落地，届时语义 = 从平台位置重备）、
 *   `PersistPlaybackCursor`（T-P1-10）、`PersistFavoriteToggle` / `PersistPreference`
 *   （T-P2 数据/设置层）、`RefreshSystemNotification`（T-P1-03+ session 刷新）、
 *   `ShowMessage`（Toast 出口）。
 *
 * ## 闸门管线（Store 私有；调用点与 lite `player_provider.dart` 逐条对应）
 * - **PlaybackRequestGate**（代次主轴）：播放族意图（装载起播 / 传输恢复 /
 *   切歌 / 重试 / seek，见 [isPlaybackRequestIntent]）派发前 `issue()`；
 *   `Stop` 意图处理后 `invalidate()`。**仅 Stop invalidate**——Dart 的
 *   `pause()` 同样 invalidate（player_provider.dart:3921），此处按任务契约
 *   不收窄到暂停：native 的媒体错误只属于当前时间线，暂停期错误照常上浮
 *   更符合用户预期（登记为与 Dart 的差异）。
 * - **PlaybackProgressGate + PositionRewindGate**（位置管线，见 [onPositionSample]）：
 *   采样先过回退抑制（整条丢弃：不进位置流、不进进度门），再写 [position]
 *   流；`observe` 首真 → 投 `PlaybackProgressConfirmed` + `EnginePositionChanged`
 *   （刷新快照基准）并 disarm；其余按 ~1s 低频补发 `EnginePositionChanged`
 *   （台本 §3.6；Dart 每采样全量 notify，native 收敛）。`begin` / `arm` 的
 *   时机在 Prepare / Play 效果执行处（baseline = 效果执行后 `state.position`，
 *   对应 Dart `_setUrlAndPlay` 的 `seekTo ?? 0`）。
 * - **PlaybackErrorEventGate**（错误入口）：`shouldHandlePlaybackErrorEvent(
 *   errorCode, isCurrentRequest, loadCompleted)`。**errorCode 透传缺口**：
 *   适配器 `onError` 仅带收敛文案、不透传 media3 errorCode，故传哨兵
 *   [ERROR_CODE_NOT_PROVIDED]（≠ lite 中断码 10000000：native 无该自定义码，
 *   语义 = 非中断错误）；透传登记 T-P1-03/T-P1-06。`loadCompleted` 判据见
 *   [loadCompleted] 字段 KDoc（对 Dart setUrl Future 通道的 native 适配）。
 * - **PlaybackStallPolicy**（CDN 看门狗）：自有 ticker 协程每 ~2s 评估一次
 *   （不挂位置采集通道——StateFlow 合并相等值，位置冻结即无新采样，见
 *   [runCdnStallWatchdog]），`REFRESH_SOURCE` → `dispatch(RetryCurrent)`
 *   （带最小间隔 + 每曲重试上限防循环）。常量逐值对应 lite
 *   player_provider.dart:411-446/1877（见伴生）。
 * - **PlaybackRecoveryBudget + PlaybackRecoveryFlight**（自动恢复链）：
 *   **本阶段不接**——恢复链的重新解析依赖 T-P1-05 解析器，且错误码透传缺口
 *   使其无法区分可重试失败；手动恢复已由 `RetryCurrent` → Prepare 效果覆盖
 *   （本地曲目真实可用）。API 与 Dart 链 B 顺序（先预算后单飞）见交回报告。
 *
 * ## EngineListener 桥接（内部监听，全部主线程回调）
 * - `onPlaybackStateChanged` / `onDurationChanged` / `onPlaybackCompleted` →
 *   同名事件直投；
 * - `onIsPlayingChanged` → 投事件后**保活对账**（按归约后 `state.isPlaying`
 *   调 [PlaybackKeepAlive]，覆盖通知栏 PLAY_PAUSE 不经意图的路径）；
 * - `onCurrentSongChanged(songId)` → 在**当前队列**中解析下标（找不到 /
 *   null → 丢弃并记日志）→ `EngineMediaItemTransition(index)`，归约器按身份
 *   对账丢弃过期 transition（快速切歌的迟到回调不会把状态拽回旧曲）；
 * - `onError(message)` → 过 ErrorEventGate 后才投 `EngineError`。
 *
 * ## 生命周期
 * 进程级单例，不随 Activity/Composable 重建；UI 只订阅 [state] / [position]
 * 并发意图。**本类不 release 引擎**（进程存续）；release 仅测试与显式拆卸路径
 * （适配器 release 后回调全部丢弃，见 `ExoPlayerPlaybackEngineAdapter`）。
 */
@Singleton
@MainThread
class PlaybackStore @Inject constructor(
    private val engine: PlaybackEngine,
    private val registry: PlaybackSessionRegistry,
    private val keepAlive: PlaybackKeepAlive,
    private val songUrlResolver: SongUrlResolver,
    private val loudnessCache: LoudnessCache,
    @StoreScope private val scope: CoroutineScope,
) : PlaybackSessionBridge {

    // ─────────────────────────── 状态面 ───────────────────────────

    private val _state = MutableStateFlow(PlaybackState())

    /** 低频状态快照（切歌/暂停/seek/错误等一致性基准；高频位置见 [position]）。 */
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    private val _position = MutableStateFlow(Duration.ZERO)

    /**
     * 高频位置流（引擎采样转发，约 200ms 一跳）。
     *
     * 装载窗内被 [PositionRewindGate] 判为假回退的采样**不进入本流**
     * （进度条不闪回）；`state.position` 只是低频快照，进度条 / 歌词应订阅本流。
     */
    val position: StateFlow<Duration> = _position.asStateFlow()

    // ─────────────────────────── 内部字段 ───────────────────────────

    /**
     * 单调时钟源（epoch 毫秒）。
     *
     * 生产取 [System.currentTimeMillis]；测试注入虚拟时间驱动看门狗与节流窗口，
     * 无需 sleep（与闸门族 `now` 参数同一设计取向）。
     */
    internal var clock: () -> Long = { System.currentTimeMillis() }

    private val listener: EngineListener = StoreEngineListener()

    // —— 闸门（Store 私有，不进归约器）——
    private val requestGate = PlaybackRequestGate()
    private val progressGate = PlaybackProgressGate()
    private val rewindGate = PositionRewindGate()

    /**
     * 最近一次 `issue()` 的代次（错误归属与进度观察的钥匙）。
     *
     * `Stop` 的 `invalidate()` **不更新本字段**——停在最后的已发代次上，
     * 使停机后的迟到错误 `isCurrent` 为假（ Dart 以 `_diagnosticPlaybackRequest`
     * 捕获装载时请求作同款对账，player_provider.dart:602-603）。
     */
    private var activeRequestGen: Int = 0

    /**
     * 装载完成事实（ErrorEventGate 的 `loadCompleted` 形参）。
     *
     * 判据是「自上次 invalidate 以来是否有过 Prepare / Play 效果执行」的
     * **粘性**事实，而非「当前代次是否发出过」的字面判据——原因：
     * 1. native 的 seek 不触发重新装载（同一媒体项 `engine.seekTo`），装载完成
     *    事实不因 seek 作废；字面判据会把 seek 之后的中游错误全部压制
     *    （Dart 的 `seek()` 不触碰请求闸门，同类错误照常上浮，
     *    player_provider.dart:4208-4228）；
     * 2. native 无 Dart 的 setUrl Future 通道（装载阶段错误在本通道可见），
     *    「已装载」只能用「引擎收到过 Prepare/Play」近似——这是对 Dart 语义的
     *    native 适配，登记于台本契约。
     */
    private var loadCompleted: Boolean = false

    /** 低频快照节流时间戳（~1s，见 [SNAPSHOT_REFRESH_INTERVAL_MS]）。 */
    private var lastSnapshotAt: Long = clock()

    /** 保活对账态（Store 侧去重；服务本身幂等，两路驱动不重复触达）。 */
    private var keepAliveEngaged: Boolean = false

    // —— CDN 看门狗状态（Dart player_provider.dart:411-447 字段镜像）——
    /** 最近一次装载（Prepare 效果）时刻；装载保护窗 [LOAD_GUARD_WINDOW_MS] 内不看门狗。 */
    private var lastLoadStartedAt: Long = 0L

    /** 速率检测宽限期截止时刻（起播/跳转定位后的重缓冲窗口）。 */
    private var rateCheckGraceUntil: Long = 0L

    /** 速率检测基位（平台位置）。 */
    private var rateCheckPos: Duration = Duration.ZERO

    /** 速率检测基线时刻。 */
    private var rateCheckTime: Long = clock()

    /** 是否已看过至少一个完整检测窗（Dart `_rateCheckSeenPlay`：至少两窗才动作）。 */
    private var rateCheckSeenPlay: Boolean = false

    /** 看门狗重试计费的曲目（换曲重置，Dart `_stallSongId`）。 */
    private var stallSongId: String? = null

    /** 当前曲已执行的看门狗换源次数（上限 [STALL_MAX_RETRIES]）。 */
    private var stallRetries: Int = 0

    /** 最近一次看门狗换源时刻；null = 从未换源（不受最小间隔约束）。 */
    private var lastStallRefreshAt: Long? = null

    init {
        // 顺序即契约：字段 → 监听 → 位置管线 → 看门狗 ticker → attach（KDoc「init 顺序」节）。
        // 响度缓存一次性预热（对位 lite 启动预热 warmLoudnessCache；内部有幂等守卫）。
        loudnessCache.warmUp()
        engine.addListener(listener)
        scope.launch {
            engine.positionFlow.collect { sample -> onPositionSample(sample) }
        }
        scope.launch {
            runCdnStallWatchdog()
        }
        registry.attach(this)
    }

    // ─────────────────────────── 派发入口 ───────────────────────────

    /**
     * 派发一个意图（UI / 外部调用方的请求）。
     *
     * 播放族意图派发前 `issue()` 记代次（使在途装载/解析失效）；
     * [PlaybackIntent.Stop] 处理后 `invalidate()`。归约 → 发布状态 → 按序执行
     * 效果，全部在调用线程同步完成（主线程串行）。
     */
    fun dispatch(intent: PlaybackIntent) {
        if (isPlaybackRequestIntent(intent)) {
            activeRequestGen = requestGate.issue()
        }
        apply(PlaybackReducer.reduce(_state.value, intent))
        if (intent is PlaybackIntent.Stop) {
            invalidatePlaybackRequest()
        }
    }

    /**
     * 派发一个事件（引擎 / 系统已发生的事实）。
     *
     * 事件不触发副作用之外的任何闸门操作（不 issue / 不 invalidate——
     * 代次只由意图推进）；正常路径由内部监听回调驱动，公开仅便于测试与
     * 未来的系统事件源（网络变化等）接入。
     */
    fun dispatch(event: PlaybackEvent) {
        apply(PlaybackReducer.reduce(_state.value, event))
    }

    /**
     * 桥接入口：系统层命令 → 意图翻译表（见类 KDoc 表）→ 归约。
     *
     * @return 恒 `true`：Store 在 attach 后即就绪（本阶段无队列恢复窗口，
     *   见类 KDoc 对 T-P1-10/11 的登记）；`false` 的语义（尚未就绪、调用方
     *   应暂存）由 [PlaybackSessionRegistry] 在未 attach 窗口承担。
     */
    override fun dispatch(command: PlayerCommand): Boolean {
        dispatch(command.toIntent())
        return true
    }

    /** [PlayerCommand] → [PlaybackIntent] 翻译表（台本 §3.6，逐一对应）。 */
    private fun PlayerCommand.toIntent(): PlaybackIntent = when (this) {
        PlayerCommand.Play -> PlaybackIntent.Resume
        PlayerCommand.Pause -> PlaybackIntent.Pause
        PlayerCommand.TogglePlayPause ->
            if (_state.value.isPlaying) PlaybackIntent.Pause else PlaybackIntent.Resume

        PlayerCommand.Next -> PlaybackIntent.Next(autoPlay = false)
        PlayerCommand.Previous -> PlaybackIntent.Previous(autoPlay = false)
        PlayerCommand.Stop -> PlaybackIntent.Stop
        PlayerCommand.ToggleFavorite -> PlaybackIntent.ToggleFavorite
        is PlayerCommand.SeekTo -> PlaybackIntent.SeekTo(positionMs.milliseconds)
        is PlayerCommand.SeekBy -> PlaybackIntent.SeekBy(deltaMs.milliseconds)
        is PlayerCommand.SetPlayWhenReady ->
            if (playWhenReady) PlaybackIntent.Resume else PlaybackIntent.Pause
    }

    /** 归约 + 发布 + 按序执行效果（先发布状态再执行效果，效果不丢、不乱序）。 */
    private fun apply(transition: PlaybackTransition) {
        _state.value = transition.state
        transition.effects.forEach { effect -> execute(effect) }
    }

    // ─────────────────────────── 效果执行器 ───────────────────────────

    /**
     * 副作用执行器（when 穷尽 [PlaybackEffect] 全部 16 个子类型）。
     *
     * 引擎类字段名即引擎方法签名（[PlaybackEffect] 设计契约）；解析类投
     * [resolveSongUrl] 异步执行；数据/系统类只登记 TODO 日志（带任务编号），
     * **禁止伪造成功**。
     */
    private fun execute(effect: PlaybackEffect) {
        when (effect) {
            is PlaybackEffect.Prepare -> {
                engine.prepare(effect.song, effect.startPositionMs, effect.playWhenReady)
                markLoadStarted(effect.startPositionMs)
                beginProgressBaseline()
            }

            is PlaybackEffect.Play -> {
                engine.play()
                loadCompleted = true
                beginProgressBaseline()
            }

            is PlaybackEffect.Pause -> {
                engine.pause()
                // Dart invalidate 路径的闸门收敛（player_provider.dart:587-592） minus
                // 请求闸门 invalidate（本阶段仅 Stop invalidate，见类 KDoc）。
                rewindGate.disarm()
                progressGate.reset()
            }

            is PlaybackEffect.Stop -> {
                engine.stop()
                rewindGate.disarm()
                progressGate.reset()
            }

            is PlaybackEffect.SeekTo -> engine.seekTo(effect.positionMs)
            is PlaybackEffect.SeekBy -> engine.seekBy(effect.deltaMs)
            is PlaybackEffect.SetVolume -> engine.setVolume(effect.volume)
            is PlaybackEffect.SetSpeed -> engine.setSpeed(effect.speed)
            is PlaybackEffect.StartKeepAlive -> setKeepAlive(engaged = true)
            is PlaybackEffect.StopKeepAlive -> setKeepAlive(engaged = false)
            is PlaybackEffect.ResolveSongUrl -> resolveSongUrl(effect.song)

            is PlaybackEffect.RetryPlayback ->
                Log.w(
                    TAG,
                    "RetryPlayback 未执行：恢复链 TODO T-P1-06" +
                        "（归约器不产生本效果、生产者随恢复链落地；songId=${effect.songId}）",
                )

            is PlaybackEffect.RefreshSystemNotification ->
                Log.w(TAG, "RefreshSystemNotification 未执行：session 通知刷新 TODO T-P1-03+")

            is PlaybackEffect.PersistPlaybackCursor ->
                Log.w(TAG, "PersistPlaybackCursor 未执行：播放游标落盘 TODO T-P1-10")

            is PlaybackEffect.PersistFavoriteToggle ->
                Log.w(
                    TAG,
                    "PersistFavoriteToggle 未执行：收藏仓库 TODO T-P2 数据层（songId=${effect.songId}）",
                )

            is PlaybackEffect.PersistPreference ->
                Log.w(TAG, "PersistPreference 未执行：设置仓库 TODO T-P2 设置层（key=${effect.key}）")

            is PlaybackEffect.ShowMessage ->
                Log.i(TAG, "ShowMessage 未展示：Toast 出口 TODO（message=${effect.message}）")
        }
    }

    // ─────────────────────────── 音源解析执行器 ───────────────────────────

    /**
     * 音源解析执行器（T-P1-05）：把 [PlaybackEffect.ResolveSongUrl] 接到
     * [SongUrlResolver]，打通「解析 → 回写 → 重备」在线播放全链路。
     *
     * 语义要点：
     * - 请求音质取解析发起时的 `_state.value.audioQuality.value`（API 码，
     *   见 [com.gracemusic.player.model.AudioQuality]）；
     * - 解析是 suspend 网络操作，**不得在 dispatch 调用线程同步执行**——投到
     *   [scope]（`@StoreScope`，Main.immediate）异步完成；结果一律经
     *   `dispatch` 走归约器唯一写入路径，不在本方法直写状态；
     * - 成功回写走 `UpdateSong(song.copy(url), actualQuality)`：归约器的
     *   解析回写收尾自动清 `isResolvingUrl` / `manualRetryInFlight` 并重备，
     *   实际音质（F-SRC-006）随回写进入状态；**迟到回写**（歌曲已不是当前曲）
     *   由归约器 `updateSong` 的身份判定自然降级为纯写写（无害，url 仍入队
     *   作缓存）；**多请求在途并发安全**——回写按 song.id 身份命中队列项，
     *   不依赖「仍是当前曲」；
     * - 试听 URL 也会回写重备（lite 最后手段语义：final 降级兜底接受试听）；
     * - 失败走 `EngineError(r.message)`：Failure 文案已在 resolver 收敛为
     *   安全文案（无 URL / 无上游细节），直接入 `resolveError`，不经
     *   `safePlaybackErrorMessage` 二次折叠；
     * - **Store 不写响度缓存**：[SongUrlResolver.resolve] 内部已写
     *   [LoudnessCache.remember]，此处不重复。
     */
    private fun resolveSongUrl(song: Song) {
        val requestedQuality: String = _state.value.audioQuality.value
        scope.launch {
            when (val result: ResolutionResult = songUrlResolver.resolve(song, requestedQuality)) {
                is ResolutionResult.Success ->
                    dispatch(PlaybackIntent.UpdateSong(song.copy(url = result.url), result.actualQuality))

                is ResolutionResult.Failure ->
                    dispatch(PlaybackEvent.EngineError(result.message))
            }
        }
    }

    // ─────────────────────────── 引擎监听桥接 ───────────────────────────

    /**
     * [EngineListener] 的 Store 实现（内部）：引擎事实 → 事件派发 + 闸门 + 对账。
     *
     * 全部回调由适配器保证主线程派发、同一事实不重复转发；本类只做翻译与过滤。
     */
    private inner class StoreEngineListener : EngineListener {

        override fun onPlaybackStateChanged(playbackState: Int) {
            dispatch(PlaybackEvent.EnginePlaybackStateChanged(playbackState))
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            dispatch(PlaybackEvent.EngineIsPlayingChanged(isPlaying))
            // 事件路径保活对账：通知栏 PLAY_PAUSE 由 media3 直接驱动 ExoPlayer、
            // 不经意图（台本 §1.3），此处按归约后的权威 isPlaying 收敛保活。
            reconcileKeepAlive()
        }

        override fun onDurationChanged(durationMs: Long?) {
            // 引擎侧毫秒 → 事件侧 Duration（null = 未知时长，语义直通）。
            dispatch(PlaybackEvent.EngineDurationChanged(durationMs?.milliseconds))
        }

        override fun onCurrentSongChanged(songId: String?) {
            if (songId == null) {
                // 时间线已空（stop reset 路径）：无对账对象，丢弃。
                Log.w(TAG, "onCurrentSongChanged(null)：时间线已空，丢弃（无对账对象）")
                return
            }
            // 单曲时间线下引擎自身下标恒 0、不具身份信息；mediaId（= song.id）在
            // 当前队列中解析出的下标才是身份对账的钥匙（PlaybackReducer 规则 6）。
            val index = _state.value.playlist.indexOfFirst { it.id == songId }
            if (index < 0) {
                // 迟到/未知 transition（快速切歌后旧曲回调、已出队曲目）：丢弃。
                Log.w(TAG, "onCurrentSongChanged($songId)：当前队列中无此曲，丢弃（迟到/未知 transition）")
                return
            }
            dispatch(PlaybackEvent.EngineMediaItemTransition(index))
        }

        override fun onPlaybackCompleted() {
            dispatch(PlaybackEvent.EnginePlaybackCompleted)
        }

        override fun onError(message: String) {
            val isCurrentRequest = requestGate.isCurrent(activeRequestGen)
            val shouldHandle = shouldHandlePlaybackErrorEvent(
                errorCode = ERROR_CODE_NOT_PROVIDED,
                isCurrentRequest = isCurrentRequest,
                loadCompleted = loadCompleted,
            )
            if (shouldHandle) {
                dispatch(PlaybackEvent.EngineError(message))
            } else {
                Log.w(
                    TAG,
                    "错误事件被 PlaybackErrorEventGate 过滤" +
                        "（isCurrentRequest=$isCurrentRequest, loadCompleted=$loadCompleted）：$message",
                )
            }
        }
    }

    // ─────────────────────────── 位置管线 ───────────────────────────

    /**
     * 引擎位置采样处理（高频，~200ms 一跳）：
     * 1. [PositionRewindGate.shouldSuppress] 为真 → **整条丢弃**（不进位置流、
     *    不进进度门——装载窗内的假回退对两方都是噪声）；
     * 2. 写 [position] 流；
     * 3. [PlaybackProgressGate.observe] 首真 → 投 `PlaybackProgressConfirmed`
     *    （清理 `awaitingPlaybackProgress`）+ `EnginePositionChanged`（刷新快照
     *    基准）并 disarm 回退闸门；
     * 4. 否则按 ~1s 低频补发 `EnginePositionChanged`（台本 §3.6 快照刷新）。
     *
     * CDN 看门狗**不在**本通道驱动（StateFlow 合并相等值，见
     * [runCdnStallWatchdog]）；注意采样不变时 StateFlow 不向采集器重发，
     * 位置冻结期本方法不会被调用——那正是看门狗 ticker 的存在意义。
     */
    private fun onPositionSample(sample: Duration) {
        val now = clock()
        if (rewindGate.shouldSuppress(sample, now)) return
        _position.value = sample
        if (progressGate.observe(activeRequestGen, sample)) {
            dispatch(PlaybackEvent.PlaybackProgressConfirmed)
            dispatch(PlaybackEvent.EnginePositionChanged(sample))
            rewindGate.disarm()
            lastSnapshotAt = now
        } else if (now - lastSnapshotAt >= SNAPSHOT_REFRESH_INTERVAL_MS) {
            dispatch(PlaybackEvent.EnginePositionChanged(sample))
            lastSnapshotAt = now
        }
    }

    /**
     * Prepare / Play 效果执行时的进度基线登记（Dart `_setUrlAndPlay` 的
     * `begin(request, baseline: seekTo ?? 0)` + `arm(seekTo)`，player_provider.dart:3757-3768；
     * Resume 的 begin 见 :4121）。
     *
     * baseline = **效果执行后**的 `state.position`（归约已发布新状态）：
     * 新装载/重备的基线是续播位置，起播是 0。arm 的 floor 同 baseline——
     * `floor <= 0` 时闸门自行 disarm（没有明确回退目标）。
     */
    private fun beginProgressBaseline() {
        val baseline = _state.value.position
        progressGate.begin(activeRequestGen, baseline)
        rewindGate.arm(floor = baseline, now = clock())
    }

    // ─────────────────────────── CDN 看门狗 ───────────────────────────

    /**
     * CDN 看门狗 ticker：每 [RATE_CHECK_INTERVAL_MS] 评估一次（Dart 的评估
     * 挂在 ~200ms positionStream tick 上，native 收敛为 2s 周期协程）。
     *
     * **为什么不能挂在位置采集协程上**：[PlaybackEngine.positionFlow] 是
     * StateFlow，**相等值被合并、不向采集器重发**——CDN 限速的典型形态
     * （位置冻结在同一秒）恰好让采样停止到达，挂在采集通道上的看门狗将
     * 永远等不到第二次评估。故 ticker 直接读 `engine.positionFlow.value`
     * （StateFlow 的当前值随时可读，无需订阅）与 `engine.bufferedPositionMs`
     * 的实时真相。
     */
    private suspend fun runCdnStallWatchdog() {
        while (currentCoroutineContext().isActive) {
            delay(RATE_CHECK_INTERVAL_MS)
            observeCdnStallWindow(engine.positionFlow.value, clock())
        }
    }

    /**
     * CDN 限速看门狗评估（Dart player_provider.dart:1574-1610 的 native 移植）。
     *
     * 判据逐条对应 Dart：平台播放中（`engine.isPlaying`，非状态缓存）、装载
     * 保护窗外（[LOAD_GUARD_WINDOW_MS]）、当前曲在线、平台位置 ≥ 45s、
     * 起播/跳转宽限期外、检测间隔 ≥ 2s。Dart 的 `_handlingCompletion` 守卫
     * 在 native 天然成立：Completed 处理与 tick 同在一条主线程串行完成，且
     * 播完/推进后位置基准归零（< 45s 不再评估）。
     *
     * `REFRESH_SOURCE` → `dispatch(RetryCurrent)`：本地曲目不受看门狗管辖
     * （在线门）；在线曲目经 T-P1-05 解析器真实换源（RetryCurrent →
     * ResolveSongUrl → 回写重备，见 [resolveSongUrl]）。
     */
    private fun observeCdnStallWindow(sample: Duration, now: Long) {
        if (!engine.isPlaying) return
        if (now - lastLoadStartedAt < LOAD_GUARD_WINDOW_MS) return
        val song = _state.value.currentSong ?: return
        if (!song.isOnline) return
        if (sample.inWholeSeconds < STALL_MIN_POSITION_SEC) return
        if (now < rateCheckGraceUntil) return
        if (now - rateCheckTime < RATE_CHECK_INTERVAL_MS) return

        val elapsed = (now - rateCheckTime).milliseconds
        val advanced = sample - rateCheckPos
        val bufferedHeadroom = (engine.bufferedPositionMs - sample.inWholeMilliseconds)
            .coerceAtLeast(0L)
            .milliseconds
        val decision = classifyCdnStallWindow(
            advanced = advanced,
            elapsed = elapsed,
            bufferedHeadroom = bufferedHeadroom,
            minimumBufferedHeadroom = MIN_BUFFERED_HEADROOM_FOR_STALL_WAIT,
            minimumPlaybackRate = MIN_PLAYBACK_RATE,
        )
        if (rateCheckSeenPlay && decision == CdnStallWindowDecision.REFRESH_SOURCE) {
            handleCdnStall(song, now)
        }
        rateCheckPos = sample
        rateCheckTime = now
        rateCheckSeenPlay = true
    }

    /**
     * REFRESH_SOURCE 的处理（Dart `_handleCdnStall`，player_provider.dart:2192-2212 的前半；
     * 重试耗尽后的音质降级不在本阶段范围）。
     *
     * 防循环三道：最小间隔 [STALL_REFRESH_MIN_INTERVAL_MS]（native 侧叠加，
     * Dart 无对应常量）、每曲 [STALL_MAX_RETRIES] 次上限（Dart :419）、
     * 归约器自身的在途守卫（`manualRetryInFlight` / `isResolvingUrl`）。
     */
    private fun handleCdnStall(song: Song, now: Long) {
        if (!requestGate.isCurrent(activeRequestGen)) return
        if (_state.value.isResolvingUrl) return
        if (stallSongId != song.id) {
            stallSongId = song.id
            stallRetries = 0
        }
        val lastRefresh = lastStallRefreshAt
        if (lastRefresh != null && now - lastRefresh < STALL_REFRESH_MIN_INTERVAL_MS) return
        if (stallRetries >= STALL_MAX_RETRIES) {
            Log.w(
                TAG,
                "CDN 换源重试已耗尽（每曲 $STALL_MAX_RETRIES 次，Dart player_provider.dart:419）；" +
                    "音质降级路径不在本阶段范围（songId=${song.id}）",
            )
            return
        }
        stallRetries++
        lastStallRefreshAt = now
        Log.w(
            TAG,
            "CDN 限速且缓冲不足：REFRESH_SOURCE → dispatch(RetryCurrent)" +
                "（songId=${song.id}，第 $stallRetries/$STALL_MAX_RETRIES 次）",
        )
        dispatch(PlaybackIntent.RetryCurrent)
    }

    // ─────────────────────────── 内部辅助 ───────────────────────────

    /** 装载开始（Prepare 效果）：记装载完成事实、装载窗、速率检测基线与宽限期。 */
    private fun markLoadStarted(startPositionMs: Long?) {
        loadCompleted = true
        val now = clock()
        lastLoadStartedAt = now
        // 装载即重置速率检测基线（Dart _setUrlAndPlay:3761-3763）。
        rateCheckPos = Duration.ZERO
        rateCheckTime = now
        rateCheckSeenPlay = false
        // 起播/跳转定位后的重缓冲宽限期（Dart _armRateCheckGrace:453-458：仅
        // seekTo > 0 时开启；native 的 seek 效果同样挂载，防止把 seek 后重缓冲
        // 误判成限速——T-P1-05 缺失时误判会把状态卡死在 isResolvingUrl）。
        if (startPositionMs != null && startPositionMs > 0) {
            rateCheckGraceUntil = now + RATE_CHECK_STARTUP_GRACE_MS
        }
    }

    /**
     * Stop 后的请求作废：代次 invalidate + 装载事实作废 + 闸门收敛。
     *
     * [activeRequestGen] 不随 invalidate 更新（停在最后已发代次），使停机后
     * 迟到错误的 `isCurrent` 为假。
     */
    private fun invalidatePlaybackRequest() {
        requestGate.invalidate()
        loadCompleted = false
        rewindGate.disarm()
        progressGate.reset()
    }

    /** 播放族意图判定（派发前 issue；台本 §3.6 清单，SeekTo/SeekBy 在内）。 */
    private fun isPlaybackRequestIntent(intent: PlaybackIntent): Boolean = when (intent) {
        is PlaybackIntent.PlaySingleSong,
        is PlaybackIntent.PlayOnlineSingleSong,
        is PlaybackIntent.PlayPlaylistFrom,
        is PlaybackIntent.PlayOnlinePlaylistFrom,
        is PlaybackIntent.PlayCloudPlaylistFrom,
        is PlaybackIntent.PlayAt,
        is PlaybackIntent.Resume,
        is PlaybackIntent.Next,
        is PlaybackIntent.Previous,
        is PlaybackIntent.RetryCurrent,
        is PlaybackIntent.SeekTo,
        is PlaybackIntent.SeekBy,
        -> true

        else -> false
    }

    /** 保活目标态切换（Store 侧去重；服务幂等，意图效果路径与事件对账路径共用）。 */
    private fun setKeepAlive(engaged: Boolean) {
        if (keepAliveEngaged == engaged) return
        keepAliveEngaged = engaged
        if (engaged) keepAlive.start() else keepAlive.stop()
    }

    /** 事件路径保活对账：按归约后的权威 `state.isPlaying` 收敛（覆盖不经意图的路径）。 */
    private fun reconcileKeepAlive() {
        setKeepAlive(_state.value.isPlaying)
    }

    private companion object {

        const val TAG = "PlaybackStore"

        /**
         * errorCode 透传缺口哨兵：适配器 `onError` 仅带收敛文案、不透传
         * media3 errorCode（登记 T-P1-03/T-P1-06）。
         *
         * ≠ [com.gracemusic.player.gate.INTERRUPTED_PLAYER_LOAD_ERROR_CODE]
         * （10000000）：native 无该自定义中断码，本哨兵语义 = 「非中断错误」，
         * 不过早拦截——能否区分切歌中断要等 errorCode 透传落地。
         */
        const val ERROR_CODE_NOT_PROVIDED = -1

        // ── CDN 看门狗常量（逐值对应 lite player_provider.dart，行号见注释）──

        /** 看门狗最小平台位置（秒）。Dart `_stallMinPositionSec`（:411）。 */
        const val STALL_MIN_POSITION_SEC = 45

        /** 速率检测间隔（毫秒）。Dart `_rateCheckInterval`（:413）。 */
        const val RATE_CHECK_INTERVAL_MS = 2_000L

        /** 最低可接受播放速率。Dart `_minPlaybackRate`（:414）。 */
        const val MIN_PLAYBACK_RATE = 0.5

        /** 「等待缓冲」所需的最小剩余缓冲。Dart `_minBufferedHeadroomForStallWait`（:416-418）。 */
        val MIN_BUFFERED_HEADROOM_FOR_STALL_WAIT = 10.seconds

        /** 每曲看门狗换源次数上限。Dart `_stallMaxRetries`（:419）。 */
        const val STALL_MAX_RETRIES = 3

        /** 起播/跳转定位后的速率检测宽限期（毫秒）。Dart `_rateCheckStartupGrace`（:446）。 */
        const val RATE_CHECK_STARTUP_GRACE_MS = 15_000L

        /** 装载保护窗（毫秒）：装载刚开始的一段时间内不看门狗。Dart `_urlLoadGuardWindow`（:1877）。 */
        const val LOAD_GUARD_WINDOW_MS = 3_000L

        /**
         * 看门狗换源最小间隔（毫秒）——**native 侧防循环下限，Dart 无对应常量**
         * （Dart 以防重试上限 3 次/曲为主）。检测窗为 2s，不叠时间下限会在
         * 单个卡死窗口内连续触发；取 10s 与 Dart 缓冲余量同量级。
         */
        const val STALL_REFRESH_MIN_INTERVAL_MS = 10_000L

        /**
         * 低频快照刷新间隔（毫秒）——台本 §3.6「~1s 低频
         * `dispatch(EnginePositionChanged)` 刷新快照」。Dart 对每个采样全量
         * notifyListeners；native 的 [PlaybackState] 只是低频基准，高频走
         * [PlaybackStore.position]，故收敛为 1s。
         */
        const val SNAPSHOT_REFRESH_INTERVAL_MS = 1_000L
    }
}
