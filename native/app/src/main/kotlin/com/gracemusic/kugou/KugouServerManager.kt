package com.gracemusic.kugou

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 本地酷狗 API 服务器生命周期状态机（纯 Kotlin，不依赖 Android 框架，可完整单测）。
 *
 * 语义对标 lib/services/kugou_server.dart + local_server_lifecycle.dart：
 * - **懒启动**：[ensureStarted] 幂等——READY 直接返回；STARTING 加入在途启动
 *   （单飞，多个并发调用只执行一次 native start）；STOPPING 期间不自动重启
 *   （请求方按未就绪快速失败）；STOPPED/FAILED 触发启动；
 * - **显式启动**：[start] 与 [ensureStarted] 的差别仅在于：READY 时先经
 *   gateway.isRunning() 校验存活（进程内 Rust 服务器可能已死），已死则重开；
 *   STOPPING 时等待停止完成后重开（对标 Dart start() 的 await _stopFuture）；
 * - **代次失效**：每次 beginStart/beginStop 自增 generation。旧代次的启动完成时
 *   若代次已变（被停止或更新的启动接管），不得改写状态、不得完成新等待者；
 * - **停止安全**：并发/重复 [stop] 单飞合并为同一次 native stop；STOPPED 时
 *   stop 为 no-op；停止尽力而为，native 抛错也归位 STOPPED；
 * - **native 串行化**：start/stop 的 native 调用经 nativeMutex 串行执行
 *   （对标 Dart 的 AsyncSerialQueue），避免 Rust 侧并发启停。
 *
 * 状态迁移（event → from → to）：
 * ```
 * ensureStarted/start  STOPPED/FAILED ──► STARTING ──start 成功──► READY
 *                                          │                     │
 *                                          └──start 失败/超时──► FAILED
 * stop                READY/STARTING/FAILED ──► STOPPING ──stop 完成──► STOPPED
 * ensureStarted       STOPPING ──► （不迁移，返回 0）
 * start(显式)         STOPPING ──等停止完成──► STOPPED ──► STARTING ──► ...
 * ```
 *
 * 异常契约：除协程取消外不向外抛异常——gateway 抛错一律转 [KugouServerState.FAILED]，
 * 等待方拿到 0（未就绪）自行决定重试时机。
 *
 * @param gateway native 操作面（单测注入 FakeGateway）。
 * @param scope 承载启停任务的协程作用域（应用级作用域；任务不随调用方取消而取消）。
 * @param dataDir device_info.json 持久化目录，透传给 gateway.start。
 * @param startTimeout 单次启动总超时（Rust 内部 10×1s 端口重试之外的总闸）。
 */
class KugouServerManager(
    private val gateway: KugouServerGateway,
    private val scope: CoroutineScope,
    private val dataDir: String,
    private val startTimeout: Duration = DEFAULT_START_TIMEOUT,
) {

    init {
        require(dataDir.isNotBlank()) {
            "dataDir 不能为空：Rust 侧用于持久化 device_info.json，空路径会导致启动即失败"
        }
    }

    private val stateMutex = Mutex()

    /** native 启停串行锁（对标 Dart AsyncSerialQueue）。 */
    private val nativeMutex = Mutex()

    private val _status = MutableStateFlow(KugouServerStatus())

    /** 当前状态快照流（状态 + 端口 + 代次的原子发布）。 */
    val status: StateFlow<KugouServerStatus> = _status.asStateFlow()

    // 不变量（均在 stateMutex 内与状态原子更新）：
    //   state == STARTING ⟺ startJob != null；state == STOPPING ⟺ stopJob != null。
    // 即使协程被外部取消，Job 引用仍非空（只是已取消），join 立即返回，不会破坏不变量。
    private var startJob: Job? = null
    private var stopJob: Job? = null

    /** 懒启动（幂等）：供在线请求链路在发起请求前调用。返回就绪端口，未就绪返回 0。 */
    suspend fun ensureStarted(): Int = startInternal(explicit = false)

    /**
     * 显式启动：供设置页重启、失败重试等场景调用。
     * 与 [ensureStarted] 的差异见类文档（READY 校验存活、STOPPING 等待后重开）。
     */
    suspend fun start(): Int = startInternal(explicit = true)

    /**
     * 显式停止（幂等、可重入）：READY/STARTING/FAILED 触发一次 native stop；
     * STOPPING 加入同一次停止；STOPPED 为 no-op。返回时停止已完成。
     */
    suspend fun stop() {
        val job = stateMutex.withLock {
            when (_status.value.state) {
                KugouServerState.STOPPED -> null
                KugouServerState.STOPPING -> stopJob
                else -> beginStopLocked()
            }
        }
        job?.join()
    }

    // ------------------------------------------------------------------
    // 启动主流程
    // ------------------------------------------------------------------

    private suspend fun startInternal(explicit: Boolean): Int {
        while (true) {
            val plan = stateMutex.withLock { planStartLocked(explicit) }
            when (plan) {
                is StartPlan.Ready -> return plan.port
                is StartPlan.ConfirmReady -> {
                    // 显式 start 且当前 READY：校验进程内服务器是否仍存活。
                    // 探测本身抛错时维持现状（不因一次探测失败触发重开）。
                    val alive = try {
                        gateway.isRunning()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        // 探测本身抛错时维持现状（不因一次探测失败触发重开）
                        true
                    }
                    if (alive) return plan.port
                    // 服务器已死：置 FAILED，下一轮循环走重开流程
                    stateMutex.withLock {
                        val snapshot = _status.value
                        if (snapshot.state == KugouServerState.READY) {
                            _status.value = KugouServerStatus(
                                KugouServerState.FAILED,
                                0,
                                snapshot.generation,
                            )
                        }
                    }
                }
                is StartPlan.JoinStart -> {
                    plan.job.join()
                    return readyPortOrZero()
                }
                is StartPlan.JoinStop -> {
                    // 显式 start 遇到停止进行中：等这次停止完成后重新评估（→ 重开）
                    plan.job.join()
                }
                is StartPlan.BeginStart -> {
                    plan.job.join()
                    return readyPortOrZero()
                }
            }
        }
    }

    /**
     * 在 stateMutex 内根据当前状态选择下一步动作（纯状态判断 + 必要的代次自增）。
     * explicit = 显式 start（校验存活、停止中等待后重开）；false = 懒启动。
     */
    private fun planStartLocked(explicit: Boolean): StartPlan {
        val snapshot = _status.value
        return when (snapshot.state) {
            KugouServerState.READY ->
                if (explicit) StartPlan.ConfirmReady(snapshot.port)
                else StartPlan.Ready(snapshot.port)

            KugouServerState.STARTING -> StartPlan.JoinStart(startJob!!)

            KugouServerState.STOPPING ->
                if (explicit) StartPlan.JoinStop(stopJob!!)
                else StartPlan.Ready(0) // 懒启动不打断显式停止：按未就绪快速失败

            KugouServerState.STOPPED, KugouServerState.FAILED -> beginStartLocked()
        }
    }

    private fun beginStartLocked(): StartPlan.BeginStart {
        val generation = _status.value.generation + 1
        _status.value = KugouServerStatus(KugouServerState.STARTING, 0, generation)
        val job = scope.launch { runStart(generation) }
        startJob = job
        return StartPlan.BeginStart(job)
    }

    private suspend fun runStart(generation: Int) {
        try {
            val port = withNativeLock {
                try {
                    withTimeout(startTimeout) { gateway.start(dataDir) }
                } catch (e: TimeoutCancellationException) {
                    // 启动超时：放弃本次启动（底层 native 调用可能仍在后台跑完，
                    // 结果会因代次失效被丢弃），按失败处理让等待方尽快失败。
                    0
                }
            }
            if (port <= 0) {
                markStartFailed(generation)
                return
            }
            stateMutex.withLock {
                val snapshot = _status.value
                if (generation == snapshot.generation &&
                    snapshot.state == KugouServerState.STARTING
                ) {
                    startJob = null
                    _status.value = KugouServerStatus(KugouServerState.READY, port, generation)
                }
                // 代次已变（被停止/更新的启动接管）：静默丢弃，不触碰新代次状态
            }
        } catch (e: CancellationException) {
            throw e // scope 销毁等外部取消：向上传播，不做状态搬运
        } catch (e: Throwable) {
            // gateway.start 抛错（含 JNI 链接失败转换而来的 IllegalStateException）：
            // 转 failed 态供后续重试；绝不让异常逃逸到 scope（避免拖垮宿主）。
            markStartFailed(generation)
        }
    }

    /** 标记本次启动失败（自行获取 stateMutex；代次已变则静默丢弃）。 */
    private suspend fun markStartFailed(generation: Int) {
        stateMutex.withLock {
            val snapshot = _status.value
            if (generation == snapshot.generation &&
                snapshot.state == KugouServerState.STARTING
            ) {
                startJob = null
                _status.value = KugouServerStatus(KugouServerState.FAILED, 0, generation)
            }
        }
    }

    // ------------------------------------------------------------------
    // 停止主流程
    // ------------------------------------------------------------------

    private fun beginStopLocked(): Job {
        val generation = _status.value.generation + 1
        _status.value = KugouServerStatus(KugouServerState.STOPPING, 0, generation)
        val job = scope.launch { runStop(generation) }
        stopJob = job
        return job
    }

    private suspend fun runStop(generation: Int) {
        try {
            withNativeLock { gateway.stop() }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // 停止尽力而为：native 抛错也归位 STOPPED（端口已无意义），
            // 与 Dart stop() 终态一致（markServerStopped 无条件执行）。
        }
        stateMutex.withLock {
            val snapshot = _status.value
            if (generation == snapshot.generation &&
                snapshot.state == KugouServerState.STOPPING
            ) {
                stopJob = null
                _status.value = KugouServerStatus(KugouServerState.STOPPED, 0, generation)
            }
        }
    }

    // ------------------------------------------------------------------
    // 内部工具
    // ------------------------------------------------------------------

    private fun readyPortOrZero(): Int =
        _status.value.let { if (it.state == KugouServerState.READY) it.port else 0 }

    private suspend fun <T> withNativeLock(block: suspend () -> T): T =
        nativeMutex.withLock { block() }

    private sealed interface StartPlan {
        /** 直接返回端口（READY 且无需校验 / 懒启动遇 STOPPING 返回 0）。 */
        data class Ready(val port: Int) : StartPlan

        /** READY 但需先校验存活。 */
        data class ConfirmReady(val port: Int) : StartPlan

        /** 加入在途启动（单飞）。 */
        data class JoinStart(val job: Job) : StartPlan

        /** 等待在途停止完成（显式 start 专用）。 */
        data class JoinStop(val job: Job) : StartPlan

        /** 新发起的一次启动。 */
        data class BeginStart(val job: Job) : StartPlan
    }

    companion object {
        /**
         * 单次启动总超时。Rust 内部端口重试上限为 10×1s，此处 30s 覆盖
         * dlopen + listen + 重试全链路，超时即 failed（对标 Dart _waitForReady）。
         */
        val DEFAULT_START_TIMEOUT: Duration = 30.seconds
    }
}
