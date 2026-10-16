package com.gracemusic.player.store

import com.gracemusic.data.model.Song
import com.gracemusic.player.gate.PlaybackRecoveryBudget
import com.gracemusic.player.gate.PlaybackRecoveryFailureKind
import com.gracemusic.player.gate.PlaybackRecoveryFlight
import com.gracemusic.player.gate.classifyPlaybackRecoveryFailure
import com.gracemusic.player.model.PlaybackErrorInfo
import com.gracemusic.player.model.PlaybackErrorOrigin
import com.gracemusic.player.model.PlaybackRecoveryAction
import com.gracemusic.player.model.recoveryActionFor
import com.gracemusic.player.state.PlaybackIntent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 恢复执行器向宿主（[PlaybackStore]）索取的上下文与动作（T-P1-06 B3）。
 *
 * 刻意保持窄接口：恢复执行器只「读事实、派意图」，不直接写状态、不碰引擎——
 * 状态变化一律经既有 Store/Reducer 契约（UDF：意图 → Reducer → 效果）。
 * 测试可用假宿主单独驱动 [RecoveryOrchestrator] 的决策与生命周期。
 */
internal interface RecoveryHost {

    /** 请求代次是否仍是最新（旧代次失败一律丢弃）。 */
    fun isRequestCurrent(gen: Int): Boolean

    /** 当前曲目（无当前曲返回 null）。 */
    fun currentSong(): Song?

    /** 当前队列长度（自动跳歌的「全部试过」上限依据）。 */
    fun playlistSize(): Int

    /** 是否正在解析音源（在途时不重复发起恢复）。 */
    fun isResolvingUrl(): Boolean

    /**
     * 网络是否可用（S-B R-4 收口：由宿主读真实
     * [com.gracemusic.player.offline.NetworkAvailabilityProvider]）。
     *
     * `false` 时 [classifyPlaybackRecoveryFailure] 归
     * [PlaybackRecoveryFailureKind.NETWORK_UNAVAILABLE]，[attemptRecovery] 在该分类门
     * **之后**才 `budget.tryConsume`，故离线失败**不消耗预算、不排期退避**。
     * 该分支此前因宿主硬编码 `true` 而不可达（风险 **R4-02**），现已关闭。
     */
    fun isNetworkAvailable(): Boolean

    /** 派发一个意图（走 Store 唯一归约路径）。 */
    fun dispatchIntent(intent: PlaybackIntent)
}

/**
 * 自动恢复执行器（T-P1-06 B3）——**复用** [PlaybackRecoveryBudget] +
 * [PlaybackRecoveryFlight]，不重造预算/单飞/代次。
 *
 * ## 职责
 * 1. 接收带错误分类与播放代次的失败（[onFailure]），验证仍属当前请求；
 * 2. 按 [recoveryActionFor] 的类别映射 + 预算选动作：
 *    - [PlaybackRecoveryAction.IGNORE]：忽略（用户取消 / 引擎释放）；
 *    - [PlaybackRecoveryAction.STOP]：停止自动恢复（错误态保留，等外部状态变化）；
 *    - [PlaybackRecoveryAction.RETRY]：预算内重新解析并重备（退避定时器驱动）；
 *    - [PlaybackRecoveryAction.SKIP]：解析失败自动跳下一首（边界见下）；
 * 3. 经受控执行器执行（一律经 [RecoveryHost.dispatchIntent] 派意图，不直调引擎）；
 * 4. 处理成功 / 失败 / 取消 / 超时 / 迟到回调（令牌 + 代次 + 曲目身份三重校验）；
 * 5. 每次失败最多触发一次有效恢复决策（单飞 + 退避去重 + 在途解析守卫）。
 *
 * ## R3-06 选型（必须二择一，见 phase-3-risks.md）
 * **选型 ①：恢复链决策后派发 `PlaybackIntent.RetryCurrent` 意图**，复用既有已
 * 验证路径（`RetryCurrent → ResolveSongUrl / Prepare → UpdateSong → 重备`）。
 * 据此 `PlaybackEffect.RetryPlayback` 已删除（无生产者、语义与 RetryCurrent 重叠）。
 *
 * ## 代次（不引入第三套体系）
 * - 播放请求代次：复用 [RecoveryHost.isRequestCurrent]（Store 的 `PlaybackRequestGate`）；
 * - 恢复单飞与定时器代次：复用 [PlaybackRecoveryFlight]（`inFlightToken` 单飞、
 *   `sequence` 作废迟到定时器）。
 *
 * ## 退避（复用 [PlaybackRecoveryBudget]）
 * - 预算按**单曲**计算（`tryConsume(songId)` 换歌即重置）；
 * - 默认 3 次、退避 30/60/120s（`budget.nextDelay` 在消费前读取，即第 N 次尝试
 *   前等待第 N 档退避）；
 * - **仅 `transientResolution` 才消耗预算**（登录门槛 / 付费 / 断网 / 用户取消
 *   不消耗）——经 [classifyPlaybackRecoveryFailure] 分类门后才 `tryConsume`。
 *
 * ## 与 Dart 的差异（逐条登记）
 * 1. **退避定时器不区分前后台**：Dart `_scheduleNextFailedRetry` 仅在
 *    `_isAppBackgrounded` 时排期；native 未引入前后台信号源（`AppForegroundChanged`
 *    无生产者），故前后台一律按退避重试——避免前台弱网永不恢复。
 * 2. **失败即排期重试**：Dart `_retryFailedPlayback` 仅由网络恢复 / 网络类型变化 /
 *    后台定时器触发；native 在失败事件当下即按退避排期（首次等待 30s），
 *    等价于把 Dart 的「外部触发」放宽为「定时触发」，并天然防快速重试风暴。
 * 3. **无登录态判定**：Dart 用 `!apiClient.isLoggedIn`；native 无会话层
 *    （T-P2-07），`authenticationRequired` 恒 false，改用 media3
 *    `ERROR_CODE_AUTHENTICATION_EXPIRED` 归 [com.gracemusic.player.model.PlaybackErrorCategory.AUTHENTICATION_REQUIRED]。
 *
 * ## 结构化并发
 * 定时器（退避 / 超时看门狗）绑定注入的 [scope]（生产 = `@StoreScope` =
 * `Dispatchers.Main.immediate`）；作用域取消（Service 销毁 / 进程级拆卸）即释放。
 * 等待一律用 `delay`（测试经 `TestScope` 虚拟时间驱动），禁止 `Thread.sleep` /
 * 真实 `Timer`；无界 Channel / 队列一律禁止。
 */
internal class RecoveryOrchestrator(
    private val scope: CoroutineScope,
    private val host: RecoveryHost,
) {

    /** 单曲有限恢复预算（1:1 移植 Dart，勿重写）。 */
    private val budget = PlaybackRecoveryBudget()

    /** 恢复单飞 + 定时器代次（1:1 移植 Dart，勿重写）。 */
    private val flight = PlaybackRecoveryFlight()

    /** 退避定时器 Job（null = 无排期）。 */
    private var backoffJob: Job? = null

    /** 超时看门狗 Job（null = 无在途恢复）。 */
    private var watchdogJob: Job? = null

    /** 当前在飞的恢复令牌（`null` = 无在途恢复）。 */
    private var inFlightToken: Int? = null

    /** 连续自动跳歌计数（成功 / 用户意图时归零；上限见 [maybeAutoSkip]）。 */
    private var consecutiveSkips: Int = 0

    /** 最近一次未决失败（供网络恢复 / 前台等外部触发重试）；用户意图时清空。 */
    private var pendingFailure: PlaybackErrorInfo? = null

    /**
     * 编排器自身派发的意图深度（> 0 表示正在自派发）。
     *
     * 恢复链会自派发 `RetryCurrent`（重试）与 `Next`（跳歌）——两者都是
     * 「播放族意图」，会触发宿主的 [onUserPlaybackIntent] 取消逻辑。若不加区分，
     * 自派发会立刻取消自己刚建立的恢复上下文（令牌 / 预算 / 跳歌计数）。
     * Store 全程主线程串行，深度计数无需同步。
     */
    private var selfDispatchDepth: Int = 0

    // ─────────────────────────── 对外入口 ───────────────────────────

    /**
     * 处理一次播放失败（T-P1-06 B3 ①②③④）。
     *
     * @param info 失败信息（含分类与曲目身份）。
     * @param gen 失败归属的播放请求代次（Store 的 `activeRequestGen`）。
     */
    fun onFailure(info: PlaybackErrorInfo, gen: Int) {
        if (!host.isRequestCurrent(gen)) return
        val song = host.currentSong()
        // 旧曲的迟到失败（解析路径带 songId）：绝不触发新曲的恢复动作。
        if (info.songId != null && info.songId != song?.id) return

        // 在途恢复期间到达的「另一条可重试引擎错误」：单飞去重——不并发第二次恢复、
        // 也不重置在途令牌与退避链，交由在途恢复自身的完成（成功 / 失败 / 看门狗）
        // 驱动下一步（B3 ⑧：并发错误不得重复消耗预算）。
        //
        // 判据用 [PlaybackErrorOrigin]：在途恢复（`RetryCurrent`）自身解析失败的
        // 「完成」事件 origin = RESOLUTION，**不**走此分支——它是恢复链的一环，
        // 必须按失败推进退避链（否则单曲队列会永久卡在第一次重试）。
        if (flight.inFlightToken != null &&
            info.origin == PlaybackErrorOrigin.ENGINE &&
            recoveryActionFor(info) == PlaybackRecoveryAction.RETRY
        ) {
            return
        }

        // 上一轮恢复若仍在飞（此处即其解析完成失败），本次错误即其失败：
        // 释放占位并作废其定时器。
        val wasRetrying = flight.inFlightToken != null
        releaseInFlight()
        stopTimers()

        when (recoveryActionFor(info)) {
            PlaybackRecoveryAction.IGNORE -> return

            PlaybackRecoveryAction.STOP -> {
                pendingFailure = null
                return
            }

            PlaybackRecoveryAction.SKIP -> {
                pendingFailure = info
                // 解析失败：顶层失败 → 自动跳下一首；恢复重试中的失败 → 继续退避链
                // （Dart：`next()` 内跳过不可播放曲；恢复链内失败 → `_scheduleNextFailedRetry`）。
                if (wasRetrying) scheduleBackoff() else maybeAutoSkip(info)
            }

            PlaybackRecoveryAction.RETRY -> {
                pendingFailure = info
                // 首次失败与「上一轮恢复刚失败」都按退避排期下一轮：
                // 首次 = budget.nextDelay = 30s；重试失败 = 60s / 120s（逐档）。
                scheduleBackoff()
            }
        }
    }

    /**
     * 外部触发（其它外部信号）后尝试重试未决失败。
     *
     * ## R-4 收口（S-B，2026-10-15）：**不再接网络恢复信号**
     * 本方法的 Dart 对位是 `_onNetworkChanged` → `_retryFailedPlayback()`
     * （player_provider.dart:1089-1095），语义原本是「网络恢复 → 自动重试」。
     * 产品决策 4 明确要求「网络恢复后**不**自动恢复播放，需等待用户手动操作」，
     * 故宿主 `PlaybackStore.dispatch(event)` 已**移除**
     * `PlaybackEvent.NetworkChanged → onExternalRecoveryTrigger()` 这一条连线。
     *
     * ## R-4 复核（T-P1-08 B4，2026-10-16）：**也不接前后台信号，当前无调用方**
     * 第四阶段为「回到前台尝试重试」保留了
     * `PlaybackEvent.AppForegroundChanged(!backgrounded) → onExternalRecoveryTrigger()`
     * 这条连线。T-P1-08 接入 `AppForegroundChanged` 的**真实生产者**
     * （`ProcessLifecycleAppForegroundMonitor`）时复核发现：该连线构成一条
     * 间接的「离线失败 → 网络恢复 → 用户切回 App → 自动续播」路径——
     * 与产品决策 4 的语义（用户未手动操作前不自动恢复）冲突。故一并移除。
     *
     * **能力本身保留**（不删除）：调用方**必须**确保它不会被
     * 「网络由离线转在线」或「应用回到前台」这两类事实驱动；
     * 当前生产代码**无调用方**（恢复重试只由 [scheduleBackoff] 的退避定时器驱动）。
     * 若后续任务（如显式的「重试」入口）需要它，调用点必须重新评估 R-4。
     *
     * 离线期间：`pendingFailure` 虽被记录，但 [attemptRecovery] 的分类门
     * （`networkAvailable = false` → `NETWORK_UNAVAILABLE`）会在消耗预算前返回，
     * 故离线不会产生任何重试，也不会耗尽预算。
     */
    fun onExternalRecoveryTrigger() {
        if (selfDispatchDepth > 0) return
        if (pendingFailure == null) return
        if (flight.inFlightToken != null) return
        cancelBackoff()
        attemptRecovery()
    }

    /**
     * 播放健康（真实推进 / 起播）——成功收敛：清预算、释放令牌、归零跳歌计数。
     *
     * 对应 Dart `_retryFailedPlayback` 成功分支的 `budget.reset` + `_resolveError = null`
     * （player_provider.dart:1157-1160）；失败文案由归约器在错误事件里承载，此处不写状态。
     */
    fun onPlaybackHealthy() {
        budget.reset(host.currentSong()?.id)
        releaseInFlight()
        flight.invalidate()
        consecutiveSkips = 0
        pendingFailure = null
        stopTimers()
    }

    /**
     * 用户播放意图（切歌 / 起播 / 重试 / seek / 暂停 / 停止 / 清空队列）——
     * 立即取消旧恢复任务（R3-06 与 B4 边界：新用户意图取消旧 Flight）。
     *
     * 对应 Dart `_resetAbnormalRetry`（player_provider.dart:2138-2145）：
     * `flight.invalidate()` + `budget.reset(_currentSong?.id)` + 停定时器。
     *
     * **编排器自派发的意图不触发本逻辑**（见 [selfDispatchDepth]）。
     */
    fun onUserPlaybackIntent() {
        if (selfDispatchDepth > 0) return
        releaseInFlight()
        flight.invalidate()
        budget.reset(host.currentSong()?.id)
        consecutiveSkips = 0
        pendingFailure = null
        stopTimers()
    }

    /** 释放全部定时器与占位（Service 销毁 / 引擎释放路径；幂等）。 */
    fun cancel() {
        releaseInFlight()
        flight.invalidate()
        pendingFailure = null
        consecutiveSkips = 0
        stopTimers()
    }

    // ─────────────────────────── 恢复动作 ───────────────────────────

    /**
     * 预算内重试：分类门 → 消耗预算 → 取单飞令牌 → 派 `RetryCurrent` → 起看门狗。
     *
     * 顺序严格对齐 Dart `_retryFailedPlayback`：**预算在分类门之后才消耗**
     * （player_provider.dart:1126-1135），故登录门槛 / 付费 / 断网 / 用户取消不消耗预算。
     */
    private fun attemptRecovery() {
        cancelBackoff()
        if (host.isResolvingUrl()) return
        val song = host.currentSong() ?: return
        if (!song.isOnline) return
        val kind = classifyPlaybackRecoveryFailure(
            hasFailure = true,
            userCanceled = false,
            authenticationRequired = false,
            paidContent = song.isLongAudio,
            networkAvailable = host.isNetworkAvailable(),
        )
        if (kind != PlaybackRecoveryFailureKind.TRANSIENT_RESOLUTION) return
        if (!budget.tryConsume(song.id)) {
            stopTimers()
            return
        }
        val token = flight.tryStart() ?: return
        inFlightToken = token
        // 先起看门狗再派意图：同步失败路径会经 onFailure → stopTimers 取消它，
        // 避免「失败后看门狗才被排期」留下悬挂任务。
        startWatchdog(token, song.id)
        try {
            dispatchSelf(PlaybackIntent.RetryCurrent)
        } catch (t: Throwable) {
            // 显式失败不静默、不伪造成功：释放令牌，错误态由既有 resolveError 承载。
            releaseInFlight()
            return
        }
    }

    /**
     * 排期下一次退避重试（复用 [PlaybackRecoveryBudget.nextDelay]）。
     *
     * 去重：已有排期 → 直接返回（防重复错误排多个定时器，B3 ⑧）。
     * 代次：捕获当前 `flight.sequence`，用户意图 / 成功会使定时器失效（迟到定时器
     * 不匹配新代次，不触发）。
     */
    private fun scheduleBackoff() {
        if (backoffJob != null) return
        val songId = host.currentSong()?.id ?: return
        val wait = budget.nextDelay ?: return
        val sequence = flight.sequence
        backoffJob = scope.launch {
            delay(wait)
            backoffJob = null
            if (flight.isCurrent(sequence) && host.currentSong()?.id == songId) {
                attemptRecovery()
            }
        }
    }

    /**
     * 恢复超时看门狗：在途恢复若超过 [RECOVERY_TIMEOUT_MS] 仍未收敛（成功/失败
     * 事件都未到达），释放令牌并按退避排下一轮——避免令牌永久占位。
     *
     * Dart 无显式超时（依赖 resolve Future 完成）；native 的 `RetryCurrent` 是
     * 「派意图 + 观察事件」的异步形态，需要看门狗兜底。登记为与 Dart 的差异。
     */
    private fun startWatchdog(token: Int, songId: String) {
        watchdogJob?.cancel()
        watchdogJob = scope.launch {
            delay(RECOVERY_TIMEOUT_MS)
            watchdogJob = null
            if (flight.isCurrent(token) && inFlightToken == token) {
                releaseInFlight()
                if (host.currentSong()?.id == songId) scheduleBackoff()
            }
        }
    }

    /**
     * 解析失败自动跳下一首（T-P1-06 B4）——严格按 Dart 的自动跳过语义
     * （player_provider.dart:3338-3343 / 4719-4723）：
     *
     * - **仅解析失败**（[PlaybackRecoveryAction.SKIP]）自动跳，引擎/HTTP 错误不跳
     *   （Dart 的 errorStream 处理器不调 `next()`）；
     * - 听书付费章节（[Song.isLongAudio]）不跳（整专辑大概率连续付费，自动切无意义）；
     * - 单曲队列（`playlistSize <= 1`）不跳；
     * - 上限 `playlistSize - 1` 次（等价 Dart `next()` 循环「全部试过」），
     *   防连续多首失败形成无限跳转；
     * - 具体「下一首是谁」完全委托归约器 `Next` 的既有队列语义
     *   （OFF 队尾提示 + 停机 / ALL 绕回 / ONE 多曲前进 / 随机候选顺序），
     *   本执行器不重写索引算术。
     */
    private fun maybeAutoSkip(info: PlaybackErrorInfo) {
        val song = host.currentSong() ?: return
        if (song.isLongAudio) return
        val size = host.playlistSize()
        if (size <= 1) return
        if (consecutiveSkips >= size - 1) return
        consecutiveSkips++
        dispatchSelf(PlaybackIntent.Next(autoPlay = true))
    }

    // ─────────────────────────── 内部辅助 ───────────────────────────

    /** 编排器自派发意图（期间宿主 [onUserPlaybackIntent] 不生效，见 [selfDispatchDepth]）。 */
    private fun dispatchSelf(intent: PlaybackIntent) {
        selfDispatchDepth++
        try {
            host.dispatchIntent(intent)
        } finally {
            selfDispatchDepth--
        }
    }

    /** 释放在飞令牌（仅当仍占有；旧任务 finally 不误释新任务）。 */
    private fun releaseInFlight() {
        inFlightToken?.let { flight.releaseIfOwned(it) }
        inFlightToken = null
        watchdogJob?.cancel()
        watchdogJob = null
    }

    private fun cancelBackoff() {
        backoffJob?.cancel()
        backoffJob = null
    }

    private fun stopTimers() {
        cancelBackoff()
        watchdogJob?.cancel()
        watchdogJob = null
    }

    private companion object {

        /**
         * 在途恢复的超时上限（毫秒）。取 20s：显著大于解析器单次 HTTP 超时
         * （OkHttp 连接/读超时同量级），避免正常慢网络被误判为卡死；同时保证
         * 令牌不会永久占位（看门狗兜底）。
         */
        const val RECOVERY_TIMEOUT_MS = 20_000L
    }
}
