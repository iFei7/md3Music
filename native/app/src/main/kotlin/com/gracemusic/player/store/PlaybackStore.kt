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
import com.gracemusic.player.model.AppLoopMode
import com.gracemusic.player.model.PlaybackErrorInfo
import com.gracemusic.player.offline.NetworkAvailabilityProvider
import com.gracemusic.player.offline.OfflineAdvancePolicy
import com.gracemusic.player.offline.PlaybackCacheKeys
import com.gracemusic.player.offline.PlaybackCacheResolver
import com.gracemusic.player.queue.PlaybackQueue
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
import kotlinx.coroutines.Job
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
 * 1. **状态面**：[state] 低频快照 + [position] / [sleepTimerRemaining] 两条
 *    高频通道（三条通道的划分见下方「两条高频通道」节与 [PlaybackState] 类 KDoc）；
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
 * ## 两条高频通道（T-P1-04；对位 lite `positionNotifier` / `sleepTimerRemainingNotifier`）
 * Dart 的 `ChangeNotifier` 只有「全量通知」一种粒度，位置流每 ~200ms 全量重建会让
 * 整页抖动（player_provider.dart:533-537 的 P0 注释）。native 的 [PlaybackState]
 * 是 `data class` + `MutableStateFlow`，本可天然按值去重，但**位置/倒计时每秒都在变**，
 * 写进 [state] 就等于每秒发射一次整状态——故仍按 Dart 的通道划分，把两类高频数据
 * 移出低频快照：
 *
 * | 通道 | 生产者 | 数据类型 | 消费者 | 频率 |
 * |---|---|---|---|---|
 * | [state] | 归约器（唯一写路径） | [PlaybackState] | 页面级/列表级 UI | 低频（切歌/暂停/seek/错误） |
 * | [position] | [onPositionSample]（引擎 `positionFlow` 采集） | [Duration] | 进度条/歌词 | ~200ms（引擎采样） |
 * | [sleepTimerRemaining] | [runSleepTimerTicker]（自有 1s ticker） | `Duration?` | 睡眠药丸倒计时 | 1s |
 *
 * **单一权威入口不破**：两条高频通道都**不写** [PlaybackState]——[state] 仍只由
 * [PlaybackReducer] 归约产出。高频通道只承载「高频数据」本身（位置值 / 剩余时间值），
 * 是 [state] 中 [PlaybackState.position] / [PlaybackState.sleepTimerRemaining]
 * 两个低频快照字段的**实时镜像**：快照字段供「读取时刻一致性」使用（切歌/暂停/seek
 * 基准），高频通道供逐帧渲染使用。
 *
 * **`sleepTimerRemaining` ticker 生命周期**（对位 player_provider.dart:5279-5324）：
 * - **启动**：派发 [PlaybackIntent.SetSleepTimer] 且 `duration != null` → 通道立即写
 *   `duration`（Dart 同款「设置即满额」），并启动一个 `delay(1s)` 循环协程；
 * - **暂停 / 恢复**：**无此状态**——睡眠定时是墙钟倒计时，播放暂停/恢复、切歌、
 *   [PlaybackIntent.Stop] 都**不**打断（Dart 的 `Timer.periodic` 只挂在
 *   `setSleepTimer` / 到点 / `dispose` 三处，见 :5280/:5303/:5832）；
 * - **取消**：`SetSleepTimer(null)` → 取消 Job + 通道写 `null`（Dart `_scheduleSleepNotifier(null)`）；
 * - **到点**：ticker 自行停止 + 通道写 `null`（Dart 同），**不暂停播放、不改
 *   `sleepTimerMode`**——到点执行语义（暂停 / `END_OF_TRACK` 迁移 / 勾选偏好）
 *   属 **T-P1-09**，此处只留 `TODO(T-P1-09)` 日志；
 * - **释放**：ticker 绑定注入的 [scope]（生产 `@StoreScope` = `Dispatchers.Main.immediate`），
 *   作用域取消（进程级拆卸 / Service 销毁）即释放；无界资源（无边界 Channel /
 *   永久不可取消协程）一律禁止。
 *
 * **时钟与虚拟时间**：ticker 的等待用 `delay`（测试的 `TestScope` 虚拟时间驱动），
 * 剩余量由 `deadline = clock() + duration` 与 `clock()` 之差算出（对位 Dart 的
 * `_sleepTimerEndTime.difference(DateTime.now())`）——比「每 tick 减 1s」更抗调度抖动，
 * 且 [clock] 已是既有测试注入点（与 CDN 看门狗同一取向）。
 *
 * **与 T-P1-09 的边界**：本阶段只交付「通道 + 定时器生命周期」。到点**不**暂停、
 * **不**迁移模式、**不**执行 `stopAfterTimerEnds`；`state.sleepTimerRemaining`
 * 在到点后停在设置值（不随秒刷新），到点后的状态收敛由 T-P1-09 经归约器完成。
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
 * ## 效果执行器（when 穷尽 15 个子类型）
 * - 引擎类（[PlaybackEffect.Prepare] / [PlaybackEffect.Play] / [PlaybackEffect.Pause] /
 *   [PlaybackEffect.Stop] / [PlaybackEffect.SeekTo] / [PlaybackEffect.SeekBy] /
 *   [PlaybackEffect.SetVolume] / [PlaybackEffect.SetSpeed]）→ `engine.*` 同名调用，
 *   字段名即方法签名（[PlaybackEffect] 设计契约），无二次翻译；
 * - 服务类（[PlaybackEffect.StartKeepAlive] / [PlaybackEffect.StopKeepAlive]）→
 *   [PlaybackKeepAlive]（Store 侧按目标态去重，服务本身亦幂等）；
 * - 解析类：[PlaybackEffect.ResolveSongUrl] → [SongUrlResolver]（T-P1-05，
 *   异步执行 + 回写收尾，见 [resolveSongUrl]）；
 * - 数据/系统类 → **只登记 TODO 日志，不伪造成功**：
 *   `PersistPlaybackCursor`（T-P1-10）、`PersistFavoriteToggle` / `PersistPreference`
 *   （T-P2 数据/设置层）、`RefreshSystemNotification`（T-P1-03+ session 刷新）、
 *   `ShowMessage`（Toast 出口）。
 *   **`RetryPlayback` 已删除**（T-P1-06 R3-06 选型①：恢复链决策后派发
 *   `PlaybackIntent.RetryCurrent`，复用既有路径，无需专用效果）。
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
 *   errorCode, isCurrentRequest, loadCompleted)`。T-P1-06 B1 起 errorCode 由适配器
 *   经 [PlaybackErrorInfo] 透传（拿不到才用哨兵 [ERROR_CODE_NOT_PROVIDED]）；
 *   切歌中断码 10000000（`INTERRUPTED_PLAYER_LOAD_ERROR_CODE`）被闸门直接忽略。
 *   `loadCompleted` 判据见 [loadCompleted] 字段 KDoc。
 * - **PlaybackStallPolicy**（CDN 看门狗）：自有 ticker 协程每 ~2s 评估一次
 *   （不挂位置采集通道——StateFlow 合并相等值，位置冻结即无新采样，见
 *   [runCdnStallWatchdog]），`REFRESH_SOURCE` → `dispatch(RetryCurrent)`
 *   （带最小间隔 + 每曲重试上限防循环）。常量逐值对应 lite
 *   player_provider.dart:411-446/1877（见伴生）。
 * - **PlaybackRecoveryBudget + PlaybackRecoveryFlight**（自动恢复链）：
 *   T-P1-06 已接线——[RecoveryOrchestrator] 复用二者做「分类 → 预算 → 单飞 →
 *   派 `RetryCurrent` / 自动跳歌」的决策与执行；错误分类经
 *   [com.gracemusic.player.model.classifyPlaybackError]（纯函数）。退避与看门狗
 *   定时器绑 [scope]，见 [RecoveryOrchestrator] KDoc。
 *
 * ## 离线前进判定（S-B，产品需求 2026-10-15）
 * 断网时「前进」不再盲目推进，而是**先过滤到已缓存曲目**；无任何可播缓存则
 * **停止（保留队列 + 错误态）**；网络恢复**不**自动续播/重试。
 *
 * **三条前进路径汇入同一处判定**（[tryOfflineAdvance]，收口唯一）：
 * | 路径 | 入口 | 判定调用点 |
 * |---|---|---|
 * | 自然播完推进 | `EnginePlaybackCompleted` 事件 | [dispatch] 事件侧（`replayCurrentFirst = true`） |
 * | 解析失败自动跳歌 | `RecoveryOrchestrator.maybeAutoSkip` → 自派发 `Next(autoPlay=true)` | [dispatch] 意图侧（`replayCurrentFirst = false`） |
 * | 用户手动下一首 | `PlaybackIntent.Next` / `PlayerCommand.Next` | [dispatch] 意图侧（`replayCurrentFirst = false`） |
 *
 * **判定流程**：`!networkAvailable` → 归约结果确属「前进」（见
 * [isOfflineFilterableForward]，用归约器自身产出判定，不重推索引算术）→
 * 取 [PlaybackQueue.nextCandidateIndices]（循环/随机/队尾截断的唯一入口，
 * 单曲 + ONE 补「重播当前曲」）→ 逐个**挂起**查询
 * [PlaybackCacheResolver.resolveCachedSource] → 首个非 null 者经
 * [OfflineAdvancePolicy] 判为 `Play` → 回写记忆到的源 + 既有
 * [PlaybackIntent.PlayAt] 继续播放；全 null → `Stop` →
 * [PlaybackIntent.OfflineNoPlayableCache]（保留队列 + 错误态，**不经恢复链**）。
 *
 * **代次校验**：枚举是挂起操作，每步复用 [PlaybackRequestGate] / [activeRequestGen]
 * （**不引入第三套代次体系**）；枚举期间用户发出新播放意图 → 本轮放弃、**不写状态**。
 *
 * **资源与取消**：枚举任务绑 [offlineAdvanceJob]，可取消；连续点「下一首」取消上一轮；
 * `Stop` / `ClearQueue` / 新播放族意图到达时取消；[scope] 取消时随作用域释放。
 * 无界 Channel / 无界队列 / 永久运行协程一律禁止。
 *
 * **禁止在归约器里做 I/O**：归约器仍是纯函数；网络查询（同步端口）在
 * [tryOfflineAdvance]，缓存查询（挂起 I/O）在 [startOfflineAdvance] 的受控协程。
 *
 * ## EngineListener 桥接（内部监听，全部主线程回调）
 * - `onPlaybackStateChanged` / `onDurationChanged` / `onPlaybackCompleted` →
 *   同名事件直投；
 * - `onIsPlayingChanged` → 投事件后**保活对账**（按归约后 `state.isPlaying`
 *   调 [PlaybackKeepAlive]，覆盖通知栏 PLAY_PAUSE 不经意图的路径）；
 * - `onCurrentSongChanged(songId)` → 在**当前队列**中解析下标（找不到 /
 *   null → 丢弃并记日志）→ `EngineMediaItemTransition(index)`，归约器按身份
 *   对账丢弃过期 transition（快速切歌的迟到回调不会把状态拽回旧曲）；
 * - `onError(info)` → 过 ErrorEventGate 后才经 [handlePlaybackFailure] 投
 *   `EngineError` 并驱动 [RecoveryOrchestrator] 恢复链。
 *
 * ## 生命周期
 * 进程级单例，不随 Activity/Composable 重建；UI 只订阅 [state] / [position] /
 * [sleepTimerRemaining] 并发意图。**本类不 release 引擎**（进程存续）；release
 * 仅测试与显式拆卸路径（适配器 release 后回调全部丢弃，见
 * `ExoPlayerPlaybackEngineAdapter`）。睡眠定时 ticker 与位置收集协程同绑 [scope]，
 * 作用域取消即释放；引擎 release **无** Store 可见信号（`EngineListener` 无释放
 * 回调），故引擎释放不单独取消 ticker——登记为待收敛项（见交回报告）。
 */
@Singleton
@MainThread
class PlaybackStore @Inject constructor(
    private val engine: PlaybackEngine,
    private val registry: PlaybackSessionRegistry,
    private val keepAlive: PlaybackKeepAlive,
    private val songUrlResolver: SongUrlResolver,
    private val loudnessCache: LoudnessCache,
    private val cacheResolver: PlaybackCacheResolver,
    private val networkAvailability: NetworkAvailabilityProvider,
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

    private val _sleepTimerRemaining = MutableStateFlow<Duration?>(null)

    /**
     * 高频睡眠定时剩余流（每秒一跳；`null` = 无进行中的倒计时）。
     *
     * 由 [runSleepTimerTicker] 每秒写一次；设置定时时立即写满额 `duration`
     * （对位 Dart `setSleepTimer` 的 `_scheduleSleepNotifier(duration)`，
     * player_provider.dart:5296），取消或到点时写 `null`（Dart 同，
     * `_scheduleSleepNotifier(null)`）。**本通道不写 [PlaybackState]**：
     * `state.sleepTimerRemaining` 只是低频快照（设置那一刻的值），
     * 每秒走字只走高频道，避免整页状态抖动（T-P1-04 通道划分）。
     */
    val sleepTimerRemaining: StateFlow<Duration?> = _sleepTimerRemaining.asStateFlow()

    // ─────────────────────────── 内部字段 ───────────────────────────

    /**
     * 单调时钟源（epoch 毫秒）。
     *
     * 生产取 [System.currentTimeMillis]；测试注入虚拟时间驱动看门狗与节流窗口，
     * 无需 sleep（与闸门族 `now` 参数同一设计取向）。
     */
    internal var clock: () -> Long = { System.currentTimeMillis() }

    private val listener: EngineListener = StoreEngineListener()

    /**
     * 自动恢复执行器（T-P1-06 B3）：复用预算 / 单飞 / 代次，只读事实、只派意图。
     *
     * 与 [listener] 同为 Store 私有；状态写入仍只经 [PlaybackReducer]（唯一写路径）。
     * 生命周期绑 [scope]（`@StoreScope`）：作用域取消即释放其退避 / 看门狗协程。
     */
    private val recovery = RecoveryOrchestrator(scope, StoreRecoveryHost())

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

    /**
     * 睡眠定时倒计时 ticker 的 Job（`null` = 无进行中的倒计时）。
     *
     * 生命周期见类 KDoc「两条高频通道」节：`SetSleepTimer(d)` 启动、
     * `SetSleepTimer(null)` 取消、到点自停、作用域取消即释放。Job 自身即
     * 「身份」——重设时先取消旧 Job 再启新 Job，取消是协作式的（`delay`
     * 抛 `CancellationException`），且 Store 全程主线程串行，故不存在
     * 「旧 ticker 迟到写入」的窗口，无需第二套代次体系。
     */
    private var sleepTimerTicker: Job? = null

    /**
     * 离线「前进」候选枚举任务（唯一在途任务；`null` = 无枚举在途）。
     *
     * 生命周期（见类 KDoc「离线前进判定」节）：
     * - **启动**：离线且发生「前进」触发（`Next` 意图 / 播完事件）时 [startOfflineAdvance]；
     * - **取消**：新的播放族意图 / `Stop` / `ClearQueue` 到达时 [cancelOfflineAdvance]；
     * - **自释放**：决策落定、派发前先置 `null`（避免派发的 `PlayAt` 触发自取消），
     *   随后任务自然结束；
     * - **作用域取消**：本 Job 是 [scope] 的子任务，`@StoreScope` 取消（进程级拆卸 /
     *   Service 销毁）即随之取消。
     *
     * 不引入第三套代次体系：正确性由 `PlaybackRequestGate` / [activeRequestGen]
     * 保证（见 [startOfflineAdvance]），本字段只负责**资源**（取消在途枚举）。
     */
    private var offlineAdvanceJob: Job? = null

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
     *
     * [PlaybackIntent.SetSleepTimer] 额外驱动高频倒计时 ticker 的启停
     * （见类 KDoc「两条高频通道」节）——**ticker 不写 [PlaybackState]**，
     * 只写 [sleepTimerRemaining] 高频通道，归约器仍是状态的唯一写路径。
     */
    fun dispatch(intent: PlaybackIntent) {
        if (isRecoveryCancellingIntent(intent)) {
            // 用户意图立即取消旧恢复任务（R3-06 / B4 边界；编排器自派发不触发，见 RecoveryOrchestrator）。
            recovery.onUserPlaybackIntent()
        }
        if (isPlaybackRequestIntent(intent)) {
            activeRequestGen = requestGate.issue()
        }
        if (isPlaybackRequestIntent(intent) || intent is PlaybackIntent.Stop || intent is PlaybackIntent.ClearQueue) {
            // 新用户动作取代在途枚举（资源释放；正确性另由代次校验保证）。
            cancelOfflineAdvance()
        }
        val transition = PlaybackReducer.reduce(_state.value, intent)
        // 离线「前进」判定（唯一入口）：命中则本轮归约**不落地**，改由受控枚举决定。
        // `Next` 触发不做「优先重播当前曲」（与归约器 next() 的前进语义一致）。
        if (isForwardAdvanceIntent(intent) && tryOfflineAdvance(transition, replayCurrentFirst = false)) return
        apply(transition)
        if (intent is PlaybackIntent.Stop) {
            invalidatePlaybackRequest()
        }
        if (intent is PlaybackIntent.SetSleepTimer) {
            reconcileSleepTimerTicker(intent.duration)
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
        val transition = PlaybackReducer.reduce(_state.value, event)
        // 离线「前进」判定（唯一入口）：自然播完驱动的推进同样受缓存过滤。
        // 播完触发在 ONE 模式优先重播当前曲（与归约器 playbackCompleted 的 ONE 分支一致）。
        if (isForwardAdvanceEvent(event) && tryOfflineAdvance(transition, replayCurrentFirst = true)) return
        apply(transition)
        // T-P1-06 B3 恢复链的外部触发与成功收敛（状态迁移已在上面完成，此处只驱动编排器）。
        when (event) {
            is PlaybackEvent.EngineIsPlayingChanged ->
                if (event.isPlaying) recovery.onPlaybackHealthy()

            is PlaybackEvent.PlaybackProgressConfirmed -> recovery.onPlaybackHealthy()

            // ── R-4 收口（S-B）：网络恢复**不得**触发自动重试/续播 ──
            // 原 `is PlaybackEvent.NetworkChanged -> recovery.onExternalRecoveryTrigger()`
            // 已移除：产品决策 4 要求「网络恢复后不自动恢复播放，需等待用户手动操作」。
            // 归约仍写 `isWifiNetwork`（仅标志，不产生任何播放/重试动作）。
            // 见 RecoveryOrchestrator.onExternalRecoveryTrigger 的 KDoc 收敛说明。
            is PlaybackEvent.AppForegroundChanged ->
                if (!event.backgrounded) recovery.onExternalRecoveryTrigger()

            else -> Unit
        }
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
                is ResolutionResult.Success -> {
                    // 源记忆写入口（S-B §4.3）：**唯一**写「键 → 上次成功解析到的源」的地方。
                    // 键的 quality 与引擎 `prepare` 的 `customCacheKey` 取同一来源
                    // （见 [cacheQualityOf]），三处键因此逐字一致。
                    rememberResolvedSourceSafely(song, result.url)
                    dispatch(PlaybackIntent.UpdateSong(song.copy(url = result.url), result.actualQuality))
                }

                is ResolutionResult.Failure ->
                    handlePlaybackFailure(PlaybackErrorInfo.resolutionFailure(result.message, song.id))
            }
        }
    }

    /**
     * 记录「`songId|quality` → 源」记忆（离线重建播放项的唯一写入口，S-B §4.3）。
     *
     * 缓存是**加速设施**：记忆写入失败（磁盘满 / 权限异常等）不得阻断播放，
     * 故显式降级并登记日志——**绝不记录 URL**（可能含鉴权参数，安全纪律）。
     * `CancellationException` 照常上抛（协作式取消不得被吞）。
     */
    private suspend fun rememberResolvedSourceSafely(song: Song, source: String) {
        try {
            cacheResolver.rememberResolvedSource(song.id, cacheQualityOf(song), source)
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            throw cancellation
        } catch (t: Throwable) {
            Log.w(TAG, "源记忆写入失败（缓存为加速设施，不阻断播放）：${t.javaClass.simpleName}")
        }
    }

    // ─────────────────────── 离线「前进」判定（S-B） ───────────────────────

    /**
     * 「前进」触发的**意图**侧判定（离线过滤的唯一入口之一）：用户 / 系统点「下一首」。
     *
     * 只有 `Next` 在此列：`Previous` 方向**刻意不收编**（产品决策 3：本次只对前进
     * 方向生效，`Previous` 保持既有行为并登记为待确认项）；用户手动 `PlayAt` /
     * `PlaySingleSong` 等是**显式选曲**，不做缓存过滤（产品决策：用户意图优先）。
     */
    private fun isForwardAdvanceIntent(intent: PlaybackIntent): Boolean = intent is PlaybackIntent.Next

    /**
     * 「前进」触发的**事件**侧判定：自然播完。
     *
     * 解析失败自动跳歌不在此列——它由 `RecoveryOrchestrator` 自派发
     * `PlaybackIntent.Next(autoPlay = true)`，经 [dispatch] 的意图侧判定收编，
     * 故三条前进路径（自然播完 / 失败跳歌 / 手动 Next）最终都汇入
     * [tryOfflineAdvance] 这一处。
     */
    private fun isForwardAdvanceEvent(event: PlaybackEvent): Boolean =
        event is PlaybackEvent.EnginePlaybackCompleted

    /**
     * 离线「前进」判定的**唯一收口**（三条前进路径共用）。
     *
     * @return `true` = 本轮已交由离线枚举处理（调用方**不得**再落地原归约结果）；
     *   `false` = 非离线 / 非前进 / 退化队列，走既有在线路径。
     *
     * 判定顺序（每步都是「不成立即放行既有行为」）：
     * 1. 网络可用 → `false`（在线路径零变化）；
     * 2. 归约结果不是「前进」（见 [isOfflineFilterableForward]）→ `false`；
     * 3. 队列为空或 `currentIndex` 无效（退化队列，归约器自会拒绝）→ `false`；
     * 4. 命中 → 启动受控枚举（挂起查询在 [startOfflineAdvance] 内），返回 `true`。
     *
     * **归约器保持纯函数**：本方法只读 `_state`、只调网络端口（同步无阻塞），
     * 不做任何缓存 I/O；缓存查询全部发生在 [startOfflineAdvance] 的挂起路径里。
     */
    private fun tryOfflineAdvance(transition: PlaybackTransition, replayCurrentFirst: Boolean): Boolean {
        if (networkAvailability.isNetworkAvailable()) return false
        if (!transition.isOfflineFilterableForward()) return false
        val queue = _state.value.queue
        if (queue.isEmpty || queue.currentIndex !in 0 until queue.size) return false
        startOfflineAdvance(replayCurrentFirst)
        return true
    }

    /**
     * 「该归约结果是否属于离线需要过滤的前进」——用**归约器自己的产出**判定，
     * 不重推索引算术、不重推边界判定：
     *
     * - 装载类效果（`Prepare` / `ResolveSongUrl`）：推进到新曲或重备（`switchToIndex` /
     *   `launchSong` / ONE 异常结束重解析）；
     * - `SeekTo` + `Play` 同时出现：重播当前曲（`restartCurrent` / ONE 播完重播 /
     *   `RestartSingle`）；
     * - `ShowMessage`：队尾提示（`HintAndPause`，OFF 模式到队尾）——离线时同样应走
     *   缓存判定，故一并收编。离线枚举沿用 `PlaybackQueue.nextCandidateIndices()` 的
     *   Dart `(_currentIndex + 1) % n` 语义：**起始位即队尾时仍会绕回队首方向**。这
     *   **刻意**对应产品需求原文「**循环到**歌单下一首已缓存歌曲，**若存在可播放的
     *   缓存歌曲则继续播放，若无任何可播放的歌曲则停止播放**」（全歌单**存在性**判定，
     *   而非「仅看当前索引之后」）。故离线路径**不**复用 `nextBoundary` 的
     *   `HintAndPause` 守卫。
     *
     * 反向排除（**必须保留**）：睡眠定时到点的 `Pause` + `StopKeepAlive`（无上述特征）、
     * 终态 / 空队列的 no-op、seek 手势的纯 `SeekTo`——它们都不是「前进」，
     * 不进入离线判定。
     */
    private fun PlaybackTransition.isOfflineFilterableForward(): Boolean =
        effects.any {
            it is PlaybackEffect.Prepare ||
                it is PlaybackEffect.ResolveSongUrl ||
                it is PlaybackEffect.ShowMessage
        } ||
            (effects.any { it is PlaybackEffect.SeekTo } && effects.any { it is PlaybackEffect.Play })

    /**
     * 启动离线前进枚举（受控执行器：挂起查询只在这里发生）。
     *
     * ## 代次校验（强制，复用既有机制，不引入第三套体系）
     * 捕获 [activeRequestGen] 作本轮代次；每次挂起返回后与派发前都过
     * `requestGate.isCurrent(gen)`——枚举期间用户发出任何播放族意图都会 `issue()`
     * 新代次，本轮随即**放弃且不写任何状态**。
     *
     * ## 资源与取消（强制）
     * 任务绑定 [offlineAdvanceJob]（可取消）：新一轮枚举先取消上一轮（连点「下一首」），
     * `Stop` / `ClearQueue` / 新的播放族意图到达时取消，`scope` 取消时随作用域释放。
     * 决策落定后**先置空引用再派发**，避免枚举自身派发的 `PlayAt` 触发自取消。
     *
     * ## 为什么先整体求值再调策略
     * [OfflineAdvancePolicy.choose] 是**纯函数**（不得挂起、不得 I/O），故先把候选的
     * 缓存查询全部求值成 `index → 源` 映射，再以纯谓词喂给策略。
     *
     * ## 探测短路（惰性契约，必须兑现）
     * [OfflineAdvancePolicy] 的 KDoc 已声明「惰性短路由调用方保证」（首个命中即停止
     * 查询），实现必须兑现：命中首个可播缓存候选后**立即 `break`**，不再探测后续候选。
     * 命中后继续探测是无谓的磁盘 I/O，而离线切歌是**用户可见延迟**。等价性：策略
     * [OfflineAdvancePolicy.choose] 仍按候选顺序返回**首个**命中，短路不改变决策结果。
     */
    private fun startOfflineAdvance(replayCurrentFirst: Boolean) {
        cancelOfflineAdvance()
        val gen = activeRequestGen
        val candidates = offlineAdvanceCandidates(_state.value.queue, replayCurrentFirst)
        offlineAdvanceJob = scope.launch {
            val sources = LinkedHashMap<Int, String>()
            for (index in candidates) {
                if (!requestGate.isCurrent(gen)) return@launch
                val song = _state.value.queue.playlist.getOrNull(index) ?: continue
                val source = cacheResolver.resolveCachedSource(song.id, cacheQualityOf(song)) ?: continue
                sources[index] = source
                // 命中首个可播缓存即停（惰性短路契约，见上方 KDoc「探测短路」）：
                // 策略仍取候选序首个命中，结果不变，省去后续无谓磁盘 I/O。
                break
            }
            if (!requestGate.isCurrent(gen)) return@launch
            when (val decision = OfflineAdvancePolicy.choose(candidates) { it in sources }) {
                is OfflineAdvancePolicy.Decision.Play -> {
                    if (!requestGate.isCurrent(gen)) return@launch
                    val index = decision.index
                    val source = sources[index] ?: return@launch
                    // 决策已定、即将派发：先解除引用（避免自身派发的 PlayAt 触发自取消）。
                    offlineAdvanceJob = null
                    playCachedCandidate(index, source)
                }

                OfflineAdvancePolicy.Decision.Stop -> {
                    if (!requestGate.isCurrent(gen)) return@launch
                    offlineAdvanceJob = null
                    // 停止语义 = 保留队列 + 错误态（不经恢复链，故不消耗预算 / 不排期退避）。
                    dispatch(PlaybackIntent.OfflineNoPlayableCache)
                }
            }
        }
    }

    /**
     * 离线候选下标序列：**复用** [PlaybackQueue.nextCandidateIndices]（循环 / 随机 /
     * 队尾截断语义的唯一入口，交接铁律 §4-7：不得重推索引算术），只补一处
     * **归约器已有**的特例：
     *
     * - `replayCurrentFirst`（播完事件 + `ONE` 单曲循环）时把当前下标置于候选首位——
     *   归约器的 `playbackCompleted` ONE 分支本就是「重播当前曲」，故离线也须先判
     *   当前曲是否已缓存（已缓存 → 重播；未缓存 → 继续向后找）；
     * - 单曲 + `ONE`：`nextCandidateIndices` 对 `n <= 1` 恒空，而归约器的
     *   `Next`/播完对「单曲 + ONE」是「重播当前曲」（`RestartSingle`），
     *   故把当前下标作为唯一候选。
     *
     * **绕回是刻意契约，不是意外**：`nextCandidateIndices` 沿用 Dart
     * `(_currentIndex + 1) % n` 语义，起始位即队尾时仍会**绕回队首方向**——对应产品
     * 需求「**循环到**歌单下一首已缓存歌曲，若存在可播放的缓存歌曲则继续播放，若无
     * 任何可播放的歌曲则停止播放」的**全歌单存在性**判定，而非「仅看当前索引之后」。
     */
    private fun offlineAdvanceCandidates(queue: PlaybackQueue, replayCurrentFirst: Boolean): List<Int> {
        val forward = queue.nextCandidateIndices()
        val base = when {
            queue.loopMode == AppLoopMode.ONE && replayCurrentFirst && queue.currentIndex >= 0 ->
                listOf(queue.currentIndex) + forward

            queue.size == 1 && queue.loopMode == AppLoopMode.ONE && queue.currentIndex == 0 ->
                listOf(0)

            else -> forward
        }
        return base.distinct()
    }

    /**
     * 切到已缓存候选并播放：把记忆到的源作为 [PlaybackIntent.PlayAt.source] 一并下发，
     * 由归约器把「回写源」与「起播」**合并为一次状态迁移**。
     *
     * 为什么要回写源：`CacheDataSource` 是**透明读缓存**——命中时引擎仍按**原 URL**
     * 打开，只是内部改读缓存文件。若队列项 `url` 为空，`launchSong` 会走
     * `ResolveSongUrl`（网络解析）→ 离线必失败。回写记忆到的源后，`Prepare`
     * 直接带着该 URL 装载，`customCacheKey = songId|quality` 命中缓存，全程不出网。
     *
     * 为什么回写与起播**必须合并为一次迁移**（不能先 `UpdateSong` 回写、再 `PlayAt`
     * 起播）：[com.gracemusic.data.model.Song.equals] 仅按 id 比较 → 纯字段级更新使
     * `state.copy(queue = updated)` 与旧 state **结构性相等** → 本类 `apply` 的
     * `_state.value = transition.state` 会被 `MutableStateFlow` 相等去重**吞掉**，
     * 回写不落入状态 → `PlayAt` 读到的 `url` 仍为 null → `needsUrlResolution` 为真
     * → 走离线必失败的 `ResolveSongUrl`。合并进 [PlaybackIntent.PlayAt] 后，
     * 归约器产出的迁移必然改变 `isResolvingUrl` / `awaitingPlaybackProgress` /
     * `position` / `queueRevision`，**不可能**被去重吞掉。
     *
     * 登记（偏离）：回写会让「离线期间切到的曲」在队列里留下一个可能已过期的
     * 签名 URL；这与既有行为一致（任何解析成功的曲目 URL 都会留在队列里被复用），
     * 且在线重试路径（`RetryCurrent`）会先清 URL 再重解析。
     */
    private fun playCachedCandidate(index: Int, source: String) {
        dispatch(PlaybackIntent.PlayAt(index, source))
    }

    /** 取消在途离线枚举（幂等；取消后旧协程不再有任何写入）。 */
    private fun cancelOfflineAdvance() {
        offlineAdvanceJob?.cancel()
        offlineAdvanceJob = null
    }

    /**
     * 缓存键的音质档**唯一来源**（S-B §4.3 三处键一致性的收敛点）。
     *
     * 取 [Song.quality]，为 null 时回落 [PlaybackCacheKeys.DEFAULT_QUALITY]——
     * 与引擎写入路径 `ExoPlayerPlaybackEngineAdapter.prepare` 的
     * `setCustomCacheKey(PlaybackCacheKeys.key(song.id, song.quality ?: DEFAULT_QUALITY))`
     * **逐字同源**。故：
     * 1. 引擎写入键 = 本方法 + [PlaybackCacheKeys.key]；
     * 2. [rememberResolvedSourceSafely] 的键 = 同上；
     * 3. [startOfflineAdvance] 查询键 = 同上。
     *
     * 已知一致性风险（S-A 登记，本阶段闭环）：解析回写的 `actualPlayingQuality`
     * 可能与 [Song.quality] 不同（降级），但引擎**始终**按 [Song.quality] 写键，
     * 故查询侧同样按 [Song.quality] 即命中——语义上「键代表请求档、字节可能是降级档」，
     * 登记为偏离（见报告）。
     */
    private fun cacheQualityOf(song: Song): String =
        song.quality ?: PlaybackCacheKeys.DEFAULT_QUALITY

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

        override fun onError(info: PlaybackErrorInfo) {
            val isCurrentRequest = requestGate.isCurrent(activeRequestGen)
            val shouldHandle = shouldHandlePlaybackErrorEvent(
                // T-P1-06 B1：透传原始 errorCode（拿不到才用哨兵）；切歌中断码
                // 10000000 在此被闸门直接忽略（良性信号）。
                errorCode = info.errorCode ?: ERROR_CODE_NOT_PROVIDED,
                isCurrentRequest = isCurrentRequest,
                loadCompleted = loadCompleted,
            )
            if (shouldHandle) {
                handlePlaybackFailure(info)
            } else {
                Log.w(
                    TAG,
                    "错误事件被 PlaybackErrorEventGate 过滤" +
                        "（errorCode=${info.errorCode}, isCurrentRequest=$isCurrentRequest, " +
                        "loadCompleted=$loadCompleted）：${info.message}",
                )
            }
        }
    }

    /**
     * 失败处理公共入口（T-P1-06 B1/B3）：先把错误落入状态（唯一写路径），再交恢复执行器决策。
     *
     * 两条失败来源都经此收口：引擎监听（过 ErrorEventGate 后）与音源解析失败
     * （`SongUrlResolver`，无 platform errorCode、带曲目身份）。
     *
     * 顺序要点：**先归约错误事件、后决策**——错误态（`resolveError` / 标志清理）
     * 先对用户可见，恢复决策（重试 / 跳歌 / 停止）再在其上发生；归约器保持纯函数，
     * 恢复动作全部由 [RecoveryOrchestrator] 经意图派发完成。
     */
    private fun handlePlaybackFailure(info: PlaybackErrorInfo) {
        val gen = activeRequestGen
        dispatch(PlaybackEvent.EngineError(info))
        recovery.onFailure(info, gen)
    }

    /**
     * 恢复执行器的宿主视图（T-P1-06 B3）：只读事实 + 派意图，不写状态、不碰引擎。
     */
    private inner class StoreRecoveryHost : RecoveryHost {

        override fun isRequestCurrent(gen: Int): Boolean = requestGate.isCurrent(gen)

        override fun currentSong(): Song? = _state.value.currentSong

        override fun playlistSize(): Int = _state.value.playlist.size

        override fun isResolvingUrl(): Boolean = _state.value.isResolvingUrl

        /**
         * 网络可用性（S-B R-4 收口）：读真实 [NetworkAvailabilityProvider]。
         *
         * 此前硬编码 `true`，使 `RecoveryOrchestrator` 的
         * [com.gracemusic.player.gate.PlaybackRecoveryFailureKind.NETWORK_UNAVAILABLE]
         * 分类分支**不可达**（风险 **R4-02**）。接线后：离线失败不消耗恢复预算、
         * 不排期退避（分类门在 `attemptRecovery` 里先于 `budget.tryConsume`）。
         * 端口契约保证「同步、无阻塞、绝不抛异常；无法判定时返回 true（保守）」。
         */
        override fun isNetworkAvailable(): Boolean = networkAvailability.isNetworkAvailable()

        override fun dispatchIntent(intent: PlaybackIntent) = dispatch(intent)
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

    // ───────────────────── 睡眠定时剩余通道（T-P1-04） ─────────────────────

    /**
     * 睡眠定时倒计时通道的启停（唯一入口；由 [dispatch] 的 `SetSleepTimer` 驱动）。
     *
     * - [duration] 非 null：取消旧 ticker → 通道立即写满额 → 启新 ticker；
     * - [duration] 为 null：取消 ticker → 通道写 `null`。
     *
     * **不做**到点执行（暂停 / `SleepTimerMode` 迁移 / `stopAfterTimerEnds`）——
     * 那属 T-P1-09。**不**在切歌 / [PlaybackIntent.Stop] / 暂停恢复时调用：
     * 睡眠定时是墙钟倒计时（Dart `Timer.periodic` 同，player_provider.dart:5297-5320）。
     */
    private fun reconcileSleepTimerTicker(duration: Duration?) {
        cancelSleepTimerTicker()
        if (duration == null) {
            _sleepTimerRemaining.value = null
            return
        }
        // 设置即写满额（Dart setSleepTimer 的 _scheduleSleepNotifier(duration)）。
        _sleepTimerRemaining.value = duration
        val deadlineMs = clock() + duration.inWholeMilliseconds
        val job = scope.launch { runSleepTimerTicker(deadlineMs) }
        sleepTimerTicker = job
        // 到点自停（或被取消）后清引用，维持「null = 无进行中的倒计时」不变量；
        // 身份比对防止被后续重设的新 Job 覆盖（Store 主线程串行，无并发窗口）。
        job.invokeOnCompletion { if (sleepTimerTicker === job) sleepTimerTicker = null }
    }

    /** 取消 ticker 并清引用（幂等；取消后旧协程不再有任何写入）。 */
    private fun cancelSleepTimerTicker() {
        sleepTimerTicker?.cancel()
        sleepTimerTicker = null
    }

    /**
     * 睡眠定时 ticker：每 [SLEEP_TIMER_TICK_INTERVAL_MS] 写一次剩余时间，
     * 到点（剩余 ≤ 0）写 `null` 并自停。
     *
     * 剩余量 = `deadlineMs - clock()`（对位 Dart `_sleepTimerEndTime.difference(now)`，
     * 抗调度抖动）；等待用 `delay`（测试经 `TestScope` 虚拟时间驱动，无 sleep）。
     * 到点分支只「停 ticker + 写 null」，**不**暂停、**不**迁移模式（T-P1-09）。
     */
    private suspend fun runSleepTimerTicker(deadlineMs: Long) {
        while (currentCoroutineContext().isActive) {
            delay(SLEEP_TIMER_TICK_INTERVAL_MS)
            val leftMs = deadlineMs - clock()
            if (leftMs <= 0L) {
                _sleepTimerRemaining.value = null
                Log.w(
                    TAG,
                    "睡眠定时到点：ticker 停止、通道写 null；" +
                        "到点执行（暂停 / END_OF_TRACK 迁移 / stopAfterTimerEnds）TODO T-P1-09",
                )
                return
            }
            _sleepTimerRemaining.value = leftMs.milliseconds
        }
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

    /**
     * 恢复取消类意图判定（T-P1-06）：用户主动播放意图 + 暂停 / 停止 / 清空队列
     * 都会取消旧恢复任务（Dart `_resetAbnormalRetry`，player_provider.dart:2138-2145）。
     *
     * `PauseForSeek`（拖动进度条前置暂停）**不**在此列——它是瞬态手势，不应打断
     * 待处理恢复。
     *
     * `OfflineNoPlayableCache`（S-B）在此列：离线无可播缓存是**终态**，旧恢复任务
     * 必须取消（否则退避定时器会在用户已停播后继续空转）。
     */
    private fun isRecoveryCancellingIntent(intent: PlaybackIntent): Boolean = when (intent) {
        is PlaybackIntent.Pause,
        is PlaybackIntent.Stop,
        is PlaybackIntent.ClearQueue,
        is PlaybackIntent.OfflineNoPlayableCache,
        -> true

        else -> isPlaybackRequestIntent(intent)
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
         * errorCode 透传缺口的**兜底哨兵**：适配器已透传 media3 `errorCode`
         * （T-P1-06 B1），仅当引擎未提供码时用本哨兵。
         *
         * ≠ [com.gracemusic.player.gate.INTERRUPTED_PLAYER_LOAD_ERROR_CODE]
         * （10000000）：本哨兵语义 = 「未提供错误码」，不过早拦截。
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

        /**
         * 睡眠定时 ticker 的走字间隔（毫秒）。Dart `Timer.periodic(Duration(seconds: 1))`
         * （player_provider.dart:5297）——每秒一次，与低频快照节流同量级但**走独立通道**。
         */
        const val SLEEP_TIMER_TICK_INTERVAL_MS = 1_000L
    }
}
