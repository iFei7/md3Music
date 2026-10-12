package com.md3music.md3music.player.gate

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * 歌词请求生命周期移植锁测试（[LyricRequestKey] /
 * [LyricRequestDeduplicator] / [LyricNotFoundCache] / [LyricRetryPolicy]）。
 *
 * 场景对标 test/providers/lyric_request_lifecycle_test.dart：
 * - Key 归一化 identity/format/query；format 与本地文件 identity 互相隔离；
 * - 并发同键请求共享一个任务且只加载一次；完成后移除可重载；
 *   失败同样移除可重试；
 * - 负缓存 TTL 边界过期、LRU 刷新与容量逐出、remove/clear 立即失效；
 * - notFound 走 5 分钟负缓存冷却；瞬时/无效数据 250ms→10s 有界指数退避；
 *   found/canceled 不安排重试。
 *
 * 时间说明：全部使用虚拟时间（TestDispatcher + 注入时钟），无 sleep。
 */
@OptIn(ExperimentalCoroutinesApi::class)
class LyricRequestLifecycleTest {

    private fun key(identity: String, songName: String? = null) =
        LyricRequestKey.forRequest(identity = identity, format = "lrc", songName = songName)

    // ---- LyricRequestKey ----

    @Test
    fun `Key 归一化 identity format 与 query`() {
        val first = LyricRequestKey.forRequest(
            identity = " HASH-A ",
            format = " LRC ",
            songName = " Song Name ",
        )
        val second = LyricRequestKey.forRequest(
            identity = "hash-a",
            format = "lrc",
            songName = "song name",
        )

        assertEquals(first, second)
    }

    @Test
    fun `Key 保持 format 与本地文件 identity 互相隔离`() {
        assertNotEquals(
            key("local:C:/music/a.flac"),
            key("local:C:/music/b.flac"),
        )
        assertNotEquals(
            LyricRequestKey.forRequest("hash-a", "lrc", "同名歌曲"),
            LyricRequestKey.forRequest("hash-a", "krc", "同名歌曲"),
        )
    }

    // ---- LyricRequestDeduplicator ----

    @Test
    fun `并发同键请求共享一个任务且只加载一次`() = runTest {
        val deduplicator = LyricRequestDeduplicator<String>(this)
        val gate = kotlinx.coroutines.CompletableDeferred<String>()
        var loads = 0
        val requestKey = key("hash-a", songName = "Song")

        val first = deduplicator.run(requestKey) {
            loads++
            gate.await()
        }
        val second = deduplicator.run(requestKey) {
            loads++
            "unexpected"
        }

        assertSame(first, second)
        // load 在 TestDispatcher 上排队，runCurrent 后才真正启动一次
        runCurrent()
        assertEquals(1, loads)

        gate.complete("lyrics")
        advanceUntilIdle()

        assertEquals("lyrics", first.await())
        assertEquals("lyrics", second.await())
    }

    @Test
    fun `完成后的请求会被移除，后续刷新可重新加载`() = runTest {
        val deduplicator = LyricRequestDeduplicator<Int>(this)
        val requestKey = key("hash-a", songName = "Song")
        var loads = 0

        val first = deduplicator.run(requestKey) { ++loads }
        advanceUntilIdle()
        assertEquals(1, first.await())

        val second = deduplicator.run(requestKey) { ++loads }
        advanceUntilIdle()
        assertEquals(2, second.await())
    }

    @Test
    fun `失败请求同样被移除，瞬时失败可重试`() = runTest {
        val deduplicator = LyricRequestDeduplicator<String>(this)
        val requestKey = key("hash-a", songName = "Song")

        val first = deduplicator.run(requestKey) {
            throw IllegalStateException("temporary")
        }
        advanceUntilIdle()
        val error = runCatching { first.await() }.exceptionOrNull()
        assertTrue("失败原因应原样传播", error is IllegalStateException)

        val second = deduplicator.run(requestKey) { "recovered" }
        advanceUntilIdle()
        assertEquals("recovered", second.await())
    }

    // ---- LyricNotFoundCache ----

    @Test
    fun `负缓存按注入时钟在 TTL 边界过期`() {
        var now = 0L
        val cache = LyricNotFoundCache(ttl = 5.minutes, capacity = 4) { now }
        val song = key("hash-a")

        cache.put(song)
        assertTrue(cache.contains(song))
        now += 5.minutes.inWholeMilliseconds
        assertFalse("到达 TTL 闭边界即过期", cache.contains(song))
    }

    @Test
    fun `负缓存刷新 LRU 顺序并按容量逐出最旧条目`() {
        var now = 0L
        val cache = LyricNotFoundCache(ttl = 5.minutes, capacity = 2) { now }
        val first = key("hash-a")
        val second = key("hash-b")
        val third = key("hash-c")

        cache.put(first)
        now += 1.seconds.inWholeMilliseconds
        cache.put(second)
        assertTrue(cache.contains(first)) // 访问后移到队尾
        now += 1.seconds.inWholeMilliseconds
        cache.put(third)

        assertTrue(cache.contains(first))
        assertFalse(cache.contains(second))
        assertTrue(cache.contains(third))
    }

    @Test
    fun `remove 与 clear 立即失效`() {
        val cache = LyricNotFoundCache(ttl = 5.minutes, capacity = 2) { 0L }
        val first = key("hash-a")
        val second = key("hash-b")
        cache.put(first)
        cache.put(second)

        cache.remove(first)
        assertFalse(cache.contains(first))
        cache.clear()
        assertFalse(cache.contains(second))
    }

    @Test
    fun `容量或 TTL 非正时 put 为 no-op`() {
        val zeroCapacity = LyricNotFoundCache(ttl = 5.minutes, capacity = 0) { 0L }
        zeroCapacity.put(key("hash-a"))
        assertFalse(zeroCapacity.contains(key("hash-a")))

        val zeroTtl = LyricNotFoundCache(ttl = 0.seconds, capacity = 4) { 0L }
        zeroTtl.put(key("hash-a"))
        assertFalse(zeroTtl.contains(key("hash-a")))
    }

    // ---- LyricRetryPolicy ----

    @Test
    fun `确认无词走负缓存冷却`() {
        assertEquals(5.minutes, LyricRetryPolicy.delayFor(LyricLookupStatus.NOT_FOUND, 1))
    }

    @Test
    fun `瞬时与无效结果走有界指数退避`() {
        assertEquals(
            250.milliseconds,
            LyricRetryPolicy.delayFor(LyricLookupStatus.TRANSIENT_FAILURE, 1),
        )
        assertEquals(
            500.milliseconds,
            LyricRetryPolicy.delayFor(LyricLookupStatus.INVALID_DATA, 2),
        )
        assertEquals(
            10.seconds,
            LyricRetryPolicy.delayFor(LyricLookupStatus.TRANSIENT_FAILURE, 20),
        )
    }

    @Test
    fun `退避指数边界钳制在 250ms 到 10s`() {
        // failureCount = 0 → 指数 -1 钳到 0 → 250ms
        assertEquals(
            250.milliseconds,
            LyricRetryPolicy.delayFor(LyricLookupStatus.TRANSIENT_FAILURE, 0),
        )
        // failureCount = 8 → 指数 7 钳到 6 → 250*64=16000 → 钳到 10000ms
        assertEquals(
            10.seconds,
            LyricRetryPolicy.delayFor(LyricLookupStatus.INVALID_DATA, 8),
        )
        // failureCount = 7 → 指数 6 → 16000 → 10000ms（上界）
        assertEquals(
            10.seconds,
            LyricRetryPolicy.delayFor(LyricLookupStatus.TRANSIENT_FAILURE, 7),
        )
    }

    @Test
    fun `found 与 canceled 不安排重试`() {
        assertEquals(
            0.seconds,
            LyricRetryPolicy.delayFor(LyricLookupStatus.FOUND, 1),
        )
        assertEquals(
            0.seconds,
            LyricRetryPolicy.delayFor(LyricLookupStatus.CANCELED, 1),
        )
    }
}
