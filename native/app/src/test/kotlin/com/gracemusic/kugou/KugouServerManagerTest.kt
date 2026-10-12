package com.gracemusic.kugou

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration.Companion.seconds

/**
 * [KugouServerManager] 状态机单测（纯 JVM，不碰 native——FakeGateway 隔离）。
 *
 * 覆盖方案承诺的语义：懒启动幂等、并发单飞、代次失效、停止安全、
 * 显式 start 的存活校验/停等重开、超时与异常归位 FAILED。
 *
 * 调度约定：manager 的 scope 使用与 runTest 同一 scheduler 的
 * UnconfinedTestDispatcher——launch 的任务执行到首个挂起点为止，
 * 配合 advanceUntilIdle() 可确定性推进，无真实时间等待。
 */
class KugouServerManagerTest {

    private lateinit var scheduler: TestCoroutineScheduler
    private lateinit var scope: CoroutineScope
    private lateinit var fake: FakeGateway

    private val dataDir = "/data/user/0/com.gracemusic.app/files"

    @Before
    fun setUp() {
        scheduler = TestCoroutineScheduler()
        scope = CoroutineScope(UnconfinedTestDispatcher(scheduler))
        fake = FakeGateway()
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun manager(startTimeout: kotlin.time.Duration = 30.seconds) =
        KugouServerManager(fake, scope, dataDir, startTimeout)

    // ------------------------------------------------------------------
    // 基础状态
    // ------------------------------------------------------------------

    @Test
    fun `initial state is STOPPED with port 0`() = runTest {
        val m = manager()
        assertEquals(KugouServerState.STOPPED, m.status.value.state)
        assertEquals(0, m.status.value.port)
        assertEquals(0, fake.startCalls.get())
    }

    @Test
    fun `blank dataDir is rejected`() {
        try {
            KugouServerManager(fake, scope, "  ")
            fail("dataDir 为空应抛 IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            // 期望路径
        }
    }

    // ------------------------------------------------------------------
    // 懒启动 ensureStarted
    // ------------------------------------------------------------------

    @Test
    fun `ensureStarted starts server and becomes READY`() = runTest {
        val m = manager()
        val result = CompletableDeferred<Int>()
        scope.launch { result.complete(m.ensureStarted()) }
        advanceUntilIdle()

        assertEquals(fake.startResult, result.await())
        assertEquals(KugouServerState.READY, m.status.value.state)
        assertEquals(fake.startResult, m.status.value.port)
        assertEquals(1, fake.startCalls.get())
        assertEquals(dataDir, fake.lastDataDir)
    }

    @Test
    fun `ensureStarted is idempotent when READY`() = runTest {
        val m = manager()
        val first = CompletableDeferred<Int>()
        val second = CompletableDeferred<Int>()
        scope.launch { first.complete(m.ensureStarted()) }
        advanceUntilIdle()
        scope.launch { second.complete(m.ensureStarted()) }
        advanceUntilIdle()

        assertEquals(fake.startResult, first.await())
        assertEquals(fake.startResult, second.await())
        assertEquals(1, fake.startCalls.get())
    }

    @Test
    fun `concurrent ensureStarted is single-flight`() = runTest {
        val m = manager()
        val results = (1..5).map { CompletableDeferred<Int>() }
        results.forEach { deferred ->
            scope.launch { deferred.complete(m.ensureStarted()) }
        }
        advanceUntilIdle()

        results.forEach { assertEquals(fake.startResult, it.await()) }
        assertEquals("5 个并发懒启动只允许一次 native start", 1, fake.startCalls.get())
    }

    @Test
    fun `ensureStarted during STARTING joins in-flight start`() = runTest {
        val m = manager()
        fake.gateStart = true
        val first = CompletableDeferred<Int>()
        val second = CompletableDeferred<Int>()
        scope.launch { first.complete(m.ensureStarted()) }
        advanceUntilIdle()
        assertEquals(KugouServerState.STARTING, m.status.value.state)

        scope.launch { second.complete(m.ensureStarted()) }
        advanceUntilIdle()
        fake.startLatch.complete(Unit)
        advanceUntilIdle()

        assertEquals(fake.startResult, first.await())
        assertEquals(fake.startResult, second.await())
        assertEquals(1, fake.startCalls.get())
        assertEquals(KugouServerState.READY, m.status.value.state)
    }

    @Test
    fun `start failure returns 0 state FAILED and retry succeeds`() = runTest {
        val m = manager()
        fake.startResult = 0
        val failed = CompletableDeferred<Int>()
        scope.launch { failed.complete(m.ensureStarted()) }
        advanceUntilIdle()

        assertEquals(0, failed.await())
        assertEquals(KugouServerState.FAILED, m.status.value.state)

        fake.startResult = 46000
        val retry = CompletableDeferred<Int>()
        scope.launch { retry.complete(m.ensureStarted()) }
        advanceUntilIdle()

        assertEquals(46000, retry.await())
        assertEquals(KugouServerState.READY, m.status.value.state)
        assertEquals(2, fake.startCalls.get())
    }

    @Test
    fun `gateway exception becomes FAILED without escaping`() = runTest {
        val m = manager()
        fake.startError = RuntimeException("dlopen boom")
        val result = CompletableDeferred<Int>()
        scope.launch { result.complete(m.ensureStarted()) }
        advanceUntilIdle()

        assertEquals(0, result.await())
        assertEquals(KugouServerState.FAILED, m.status.value.state)

        // 失败后可恢复
        fake.startError = null
        val retry = CompletableDeferred<Int>()
        scope.launch { retry.complete(m.ensureStarted()) }
        advanceUntilIdle()
        assertEquals(fake.startResult, retry.await())
        assertEquals(KugouServerState.READY, m.status.value.state)
    }

    @Test
    fun `start timeout becomes FAILED`() = runTest {
        val m = manager(startTimeout = 5.seconds)
        fake.gateStart = true // native start 永不返回
        val result = CompletableDeferred<Int>()
        scope.launch { result.complete(m.ensureStarted()) }
        advanceUntilIdle()
        assertEquals(KugouServerState.STARTING, m.status.value.state)

        scheduler.advanceTimeBy(6_000)
        advanceUntilIdle()

        assertEquals(0, result.await())
        assertEquals(KugouServerState.FAILED, m.status.value.state)
        fake.startLatch.complete(Unit) // 收尾：放掉底层挂起的 start，避免协程泄漏
    }

    // ------------------------------------------------------------------
    // 停止
    // ------------------------------------------------------------------

    @Test
    fun `stop from READY ends STOPPED with one native stop`() = runTest {
        val m = manager()
        val started = CompletableDeferred<Int>()
        scope.launch { started.complete(m.ensureStarted()) }
        advanceUntilIdle()

        val stopped = CompletableDeferred<Unit>()
        scope.launch { m.stop(); stopped.complete(Unit) }
        advanceUntilIdle()

        stopped.await()
        assertEquals(KugouServerState.STOPPED, m.status.value.state)
        assertEquals(0, m.status.value.port)
        assertEquals(1, fake.stopCalls.get())
    }

    @Test
    fun `concurrent stop is single-flight`() = runTest {
        val m = manager()
        val started = CompletableDeferred<Int>()
        scope.launch { started.complete(m.ensureStarted()) }
        advanceUntilIdle()

        fake.gateStop = true
        val dones = (1..3).map { CompletableDeferred<Unit>() }
        dones.forEach { done ->
            scope.launch { m.stop(); done.complete(Unit) }
        }
        advanceUntilIdle()
        assertEquals(KugouServerState.STOPPING, m.status.value.state)

        fake.stopLatch.complete(Unit)
        advanceUntilIdle()

        dones.forEach { it.await() }
        assertEquals("3 个并发 stop 只允许一次 native stop", 1, fake.stopCalls.get())
        assertEquals(KugouServerState.STOPPED, m.status.value.state)
    }

    @Test
    fun `stop when STOPPED is no-op`() = runTest {
        val m = manager()
        val done = CompletableDeferred<Unit>()
        scope.launch { m.stop(); done.complete(Unit) }
        advanceUntilIdle()

        done.await()
        assertEquals(0, fake.stopCalls.get())
        assertEquals(KugouServerState.STOPPED, m.status.value.state)
    }

    @Test
    fun `stop error still ends STOPPED`() = runTest {
        val m = manager()
        val started = CompletableDeferred<Int>()
        scope.launch { started.complete(m.ensureStarted()) }
        advanceUntilIdle()

        fake.stopError = RuntimeException("stop boom")
        val done = CompletableDeferred<Unit>()
        scope.launch { m.stop(); done.complete(Unit) }
        advanceUntilIdle()

        done.await()
        assertEquals(KugouServerState.STOPPED, m.status.value.state)
        assertEquals(1, fake.stopCalls.get())
    }

    @Test
    fun `ensureStarted during STOPPING returns 0 without restart`() = runTest {
        val m = manager()
        val started = CompletableDeferred<Int>()
        scope.launch { started.complete(m.ensureStarted()) }
        advanceUntilIdle()

        fake.gateStop = true
        scope.launch { m.stop() }
        advanceUntilIdle()
        assertEquals(KugouServerState.STOPPING, m.status.value.state)

        val duringStop = CompletableDeferred<Int>()
        scope.launch { duringStop.complete(m.ensureStarted()) }
        advanceUntilIdle()

        assertEquals("停止进行中懒启动不打断停止，按未就绪快速失败", 0, duringStop.await())
        assertEquals(1, fake.startCalls.get())

        fake.stopLatch.complete(Unit)
        advanceUntilIdle()
        assertEquals(KugouServerState.STOPPED, m.status.value.state)
        assertEquals(1, fake.startCalls.get())
    }

    // ------------------------------------------------------------------
    // 显式 start
    // ------------------------------------------------------------------

    @Test
    fun `explicit start with alive server returns port without restart`() = runTest {
        val m = manager()
        val started = CompletableDeferred<Int>()
        scope.launch { started.complete(m.ensureStarted()) }
        advanceUntilIdle()

        fake.isRunningResult = true
        val again = CompletableDeferred<Int>()
        scope.launch { again.complete(m.start()) }
        advanceUntilIdle()

        assertEquals(fake.startResult, again.await())
        assertEquals(1, fake.startCalls.get())
        assertTrue(fake.isRunningCalls.get() >= 1)
        assertEquals(KugouServerState.READY, m.status.value.state)
    }

    @Test
    fun `explicit start with dead server restarts`() = runTest {
        val m = manager()
        val started = CompletableDeferred<Int>()
        scope.launch { started.complete(m.ensureStarted()) }
        advanceUntilIdle()

        fake.isRunningResult = false // 进程内服务器已死
        fake.startResult = 47000
        val restarted = CompletableDeferred<Int>()
        scope.launch { restarted.complete(m.start()) }
        advanceUntilIdle()

        assertEquals(47000, restarted.await())
        assertEquals(2, fake.startCalls.get())
        assertEquals(KugouServerState.READY, m.status.value.state)
        assertEquals(47000, m.status.value.port)
    }

    @Test
    fun `explicit start during STOPPING waits then restarts`() = runTest {
        val m = manager()
        val started = CompletableDeferred<Int>()
        scope.launch { started.complete(m.ensureStarted()) }
        advanceUntilIdle()

        fake.gateStop = true
        scope.launch { m.stop() }
        advanceUntilIdle()

        fake.startResult = 48000
        val restart = CompletableDeferred<Int>()
        scope.launch { restart.complete(m.start()) }
        advanceUntilIdle()
        assertEquals("停止完成前显式 start 应等待", KugouServerState.STOPPING, m.status.value.state)

        fake.stopLatch.complete(Unit)
        advanceUntilIdle()

        assertEquals(48000, restart.await())
        assertEquals(2, fake.startCalls.get())
        assertEquals(KugouServerState.READY, m.status.value.state)
    }

    // ------------------------------------------------------------------
    // 代次失效
    // ------------------------------------------------------------------

    @Test
    fun `stop during start discards stale start completion`() = runTest {
        val m = manager()
        fake.gateStart = true
        val started = CompletableDeferred<Int>()
        scope.launch { started.complete(m.ensureStarted()) }
        advanceUntilIdle()
        assertEquals(KugouServerState.STARTING, m.status.value.state)

        fake.gateStop = true
        scope.launch { m.stop() }
        advanceUntilIdle()
        assertEquals(KugouServerState.STOPPING, m.status.value.state)

        // 旧代次启动姗姗完成：端口有效但代次已被停止接管，不得改写状态
        fake.startLatch.complete(Unit)
        advanceUntilIdle()
        assertEquals(KugouServerState.STOPPING, m.status.value.state)

        fake.stopLatch.complete(Unit)
        advanceUntilIdle()

        assertEquals(0, started.await())
        assertEquals(KugouServerState.STOPPED, m.status.value.state)
        assertEquals(0, m.status.value.port)
        assertEquals(1, fake.startCalls.get())
        assertEquals(1, fake.stopCalls.get())
    }

    // ------------------------------------------------------------------
    // Fake
    // ------------------------------------------------------------------

    private class FakeGateway : KugouServerGateway {
        val startCalls = AtomicInteger()
        val stopCalls = AtomicInteger()
        val isRunningCalls = AtomicInteger()

        var startResult = 45678
        var startError: Throwable? = null
        var stopError: Throwable? = null
        var isRunningResult = true
        var lastDataDir: String? = null

        /** true 时 start 阻塞到 [startLatch] 放行——模拟慢速 native 启动。 */
        var gateStart = false
        val startLatch = CompletableDeferred<Unit>()

        /** true 时 stop 阻塞到 [stopLatch] 放行——模拟停止进行中窗口。 */
        var gateStop = false
        val stopLatch = CompletableDeferred<Unit>()

        override suspend fun start(dataDir: String): Int {
            startCalls.incrementAndGet()
            lastDataDir = dataDir
            if (gateStart) startLatch.await()
            startError?.let { throw it }
            return startResult
        }

        override suspend fun stop() {
            stopCalls.incrementAndGet()
            if (gateStop) stopLatch.await()
            stopError?.let { throw it }
        }

        override suspend fun isRunning(): Boolean {
            isRunningCalls.incrementAndGet()
            return isRunningResult
        }
    }
}
