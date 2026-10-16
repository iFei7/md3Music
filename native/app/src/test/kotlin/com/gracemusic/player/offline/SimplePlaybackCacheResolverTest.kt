package com.gracemusic.player.offline

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
import java.io.File
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * [SimplePlaybackCacheResolver] 行为测试（Robolectric + 真 `SimpleCache`/`CacheDataSource`）。
 *
 * 缓存状态一律用**真管线**构造：经 `store.dataSourceFactory`（真 `CacheDataSource`）
 * 读一个 `file://` 上游，读完 → 完整缓存；只读一部分 → 部分缓存。
 * 这样断言的「命中/未命中」不是自说自话，而是真缓存写出的状态。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class SimplePlaybackCacheResolverTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    private class InMemorySourceMemory : ResolvedSourceMemory {
        val map = LinkedHashMap<String, String>()
        override fun read(key: String): String? = map[key]
        override fun write(key: String, source: String) {
            map[key] = source
        }
    }

    /** 记录「是否经该调度器派发」，用于断言查询不内联在调用线程上。 */
    private class RecordingDispatcher(
        private val delegate: CoroutineDispatcher,
    ) : CoroutineDispatcher() {
        @Volatile
        var dispatched = false

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            dispatched = true
            delegate.dispatch(context, block)
        }
    }

    private fun newStore(
        memory: ResolvedSourceMemory = InMemorySourceMemory(),
    ): PlaybackCacheStore = PlaybackCacheStore(
        context,
        PlaybackCacheConfig(
            directoryName = "resolver-test-" + UUID.randomUUID(),
            maxBytes = PlaybackCacheStore.DEFAULT_MAX_CACHE_BYTES,
        ),
        memory,
    )

    /** 经真 CacheDataSource 读上游 [bytes] 字节（读完 → 完整缓存）。 */
    private fun seed(
        store: PlaybackCacheStore,
        key: String,
        totalBytes: Int = 4096,
        readBytes: Long = totalBytes.toLong(),
    ) {
        val upstream = File(context.cacheDir, "upstream-" + UUID.randomUUID() + ".bin")
        upstream.writeBytes(ByteArray(totalBytes) { (it % 251).toByte() })
        val dataSource = store.dataSourceFactory.createDataSource()
        val spec = DataSpec.Builder().setUri(Uri.fromFile(upstream)).setKey(key).build()
        try {
            dataSource.open(spec)
            val buffer = ByteArray(512)
            var read = 0L
            while (read < readBytes) {
                val wanted = minOf(buffer.size.toLong(), readBytes - read).toInt()
                val n = dataSource.read(buffer, 0, wanted)
                if (n == C.RESULT_END_OF_INPUT) break
                read += n
            }
        } finally {
            dataSource.close()
        }
    }

    // ------------------------------------------------------------------
    // 命中语义
    // ------------------------------------------------------------------

    @Test
    fun `未缓存时返回 null`() = runBlocking {
        val resolver = SimplePlaybackCacheResolver(newStore())
        assertNull(resolver.resolveCachedSource("s1", "128"))
    }

    @Test
    fun `已完整缓存且记住源时返回该源`() = runBlocking {
        val memory = InMemorySourceMemory()
        val store = newStore(memory)
        val resolver = SimplePlaybackCacheResolver(store)

        val songId = "s1"
        val quality = "128"
        seed(store, PlaybackCacheKeys.key(songId, quality))
        resolver.rememberResolvedSource(songId, quality, "https://cdn.example.com/a.mp3?sig=1")

        assertEquals(
            "命中必须返回上次成功解析到的源",
            "https://cdn.example.com/a.mp3?sig=1",
            resolver.resolveCachedSource(songId, quality),
        )
    }

    @Test
    fun `已完整缓存但未记住源时返回 null`() = runBlocking {
        val store = newStore()
        val resolver = SimplePlaybackCacheResolver(store)
        seed(store, PlaybackCacheKeys.key("s1", "128"))

        assertNull(
            "字节在盘上但没有可打开的 URI（未记住源），不得伪造命中",
            resolver.resolveCachedSource("s1", "128"),
        )
    }

    @Test
    fun `只缓存一部分时返回 null`() = runBlocking {
        val store = newStore()
        val resolver = SimplePlaybackCacheResolver(store)
        seed(store, PlaybackCacheKeys.key("s1", "128"), totalBytes = 4096, readBytes = 1024)
        resolver.rememberResolvedSource("s1", "128", "https://cdn.example.com/a.mp3?sig=1")

        assertNull("部分缓存不得命中", resolver.resolveCachedSource("s1", "128"))
    }

    @Test
    fun `音质档不同则互不命中`() = runBlocking {
        val store = newStore()
        val resolver = SimplePlaybackCacheResolver(store)
        seed(store, PlaybackCacheKeys.key("s1", "128"))
        resolver.rememberResolvedSource("s1", "128", "src-128")

        assertEquals("src-128", resolver.resolveCachedSource("s1", "128"))
        assertNull("320 档未缓存，不得复用 128 档的缓存", resolver.resolveCachedSource("s1", "320"))
    }

    @Test
    fun `rememberResolvedSource 覆盖旧值`() = runBlocking {
        val store = newStore()
        val resolver = SimplePlaybackCacheResolver(store)
        seed(store, PlaybackCacheKeys.key("s1", "128"))

        resolver.rememberResolvedSource("s1", "128", "old")
        resolver.rememberResolvedSource("s1", "128", "new")
        assertEquals("new", resolver.resolveCachedSource("s1", "128"))
    }

    // ------------------------------------------------------------------
    // 空实现
    // ------------------------------------------------------------------

    @Test
    fun `NoOp 实现恒返回 null 且 remember 无副作用`() = runBlocking {
        val noOp = NoOpPlaybackCacheResolver
        assertNull(noOp.resolveCachedSource("s1", "128"))
        noOp.rememberResolvedSource("s1", "128", "https://cdn/x?sig=1")
        assertNull("NoOp 必须始终未命中（不得因 remember 而命中）", noOp.resolveCachedSource("s1", "128"))
    }

    // ------------------------------------------------------------------
    // 线程
    // ------------------------------------------------------------------

    @Test
    fun `查询与写入都经注入的调度器派发_不在调用线程内联执行`() = runBlocking {
        val store = newStore()
        val dispatcher = RecordingDispatcher(kotlinx.coroutines.Dispatchers.IO)
        val resolver = SimplePlaybackCacheResolver(store, dispatcher)

        resolver.resolveCachedSource("s1", "128")
        assertTrue("resolveCachedSource 必须经 ioDispatcher 派发（不得在主线程做磁盘 I/O）", dispatcher.dispatched)

        dispatcher.dispatched = false
        resolver.rememberResolvedSource("s1", "128", "src")
        assertTrue("rememberResolvedSource 必须经 ioDispatcher 派发", dispatcher.dispatched)
    }

    @Test
    fun `未缓存时在读源记忆之前短路`() = runBlocking {
        val memory = object : ResolvedSourceMemory {
            var readCalled = false
            override fun read(key: String): String? {
                readCalled = true
                return "should-not-be-read"
            }

            override fun write(key: String, source: String) = Unit
        }
        val store = PlaybackCacheStore(
            context,
            PlaybackCacheConfig("short-circuit-" + UUID.randomUUID(), 1L shl 20),
            memory,
        )
        val resolver = SimplePlaybackCacheResolver(store)

        assertNull(resolver.resolveCachedSource("s1", "128"))
        assertFalse("未命中必须在读源记忆之前短路（少一次无谓的磁盘读）", memory.readCalled)
    }
}
