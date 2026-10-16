package com.gracemusic.player.offline

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.ContentMetadataMutations
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * [PlaybackCacheStore] 行为测试（Robolectric + **真** `SimpleCache` / `CacheDataSource`）。
 *
 * ## 为什么必须 Robolectric
 * `SimpleCache` / `CacheDataSource` 依赖 `android.util.Log` 等 Android 运行时；
 * 纯 JUnit 下会抛 `Stub!`（与仓库既有引擎测试一致）。
 *
 * ## 断言策略（诚实边界）
 * - **命中判定**用「直接经 `SimpleCache` 公开写接口落盘」的方式构造缓存状态：
 *   `startReadWrite`（建立索引项并锁定区间）→ `startFile` → 写字节 → `commitFile`，
 *   与 `CacheDataSink` 内部路径一致（官方 1.4.1 `CacheDataSink.java:240-278`）；
 *   `exo_len` 元数据用 `applyContentMetadataMutations` 显式写入，等价
 *   `CacheDataSource.java:805-825` 在回源时写长度的行为。
 *   这样每个用例的缓存形态**完全确定**，不依赖网络/时序。
 * - **另有一组端到端用例**（[经 CacheDataSource 完整读完后判定为已完整缓存] /
 *   [经 CacheDataSource 只读一部分时不算已完整缓存]）走真实
 *   `store.dataSourceFactory` + `file://` 上游，验证「真管线写出的 exo_len 与 span
 *   能让判定成立」——即上面的手工构造不是自说自话。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class PlaybackCacheStoreTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    /** 进程内假实现：不落盘，用于把「源记忆」与「缓存判定」解耦测试。 */
    private class InMemorySourceMemory : ResolvedSourceMemory {
        val map = LinkedHashMap<String, String>()
        override fun read(key: String): String? = map[key]
        override fun write(key: String, source: String) {
            map[key] = source
        }
    }

    private fun newStore(
        maxBytes: Long = PlaybackCacheStore.DEFAULT_MAX_CACHE_BYTES,
        memory: ResolvedSourceMemory = InMemorySourceMemory(),
    ): PlaybackCacheStore = PlaybackCacheStore(
        context,
        PlaybackCacheConfig(
            directoryName = "cache-test-" + UUID.randomUUID(),
            maxBytes = maxBytes,
        ),
        memory,
    )

    /** 声明资源总长度（等价 CacheDataSource 回源时写 `exo_len`）。 */
    private fun declareContentLength(store: PlaybackCacheStore, key: String, length: Long) {
        store.cache.applyContentMetadataMutations(
            key,
            ContentMetadataMutations.setContentLength(ContentMetadataMutations(), length),
        )
    }

    /** 落盘一段真实数据 span（与 CacheDataSink 内部路径同序）。 */
    private fun seedSpan(store: PlaybackCacheStore, key: String, position: Long, bytes: Int) {
        val cache = store.cache
        val hole = cache.startReadWrite(key, position, C.LENGTH_UNSET.toLong())
        val file = cache.startFile(key, position, C.LENGTH_UNSET.toLong())
        file.writeBytes(ByteArray(bytes))
        cache.commitFile(file, bytes.toLong())
        cache.releaseHoleSpan(hole)
    }

    // ------------------------------------------------------------------
    // 命中判定
    // ------------------------------------------------------------------

    @Test
    fun `未写入任何数据时判定为未完整缓存`() {
        val store = newStore()
        assertFalse(store.isFullyCached(PlaybackCacheKeys.key("s1", "128")))
    }

    @Test
    fun `仅声明长度但无数据 span 时判定为未完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", "128")
        declareContentLength(store, key, 1000)
        assertFalse("exo_len 已知但没有真实数据 span，不得判为已缓存", store.isFullyCached(key))
    }

    @Test
    fun `写入完整数据后判定为已完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", "128")
        seedSpan(store, key, position = 0, bytes = 1000)
        declareContentLength(store, key, 1000)
        assertTrue(store.isFullyCached(key))
    }

    @Test
    fun `部分缓存_hole_不算已完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", "128")
        // 只播到 400/1000 字节（模拟用户中途切歌）。
        seedSpan(store, key, position = 0, bytes = 400)
        declareContentLength(store, key, 1000)
        assertFalse("尾部 [400,1000) 是 hole，不得判为已缓存", store.isFullyCached(key))
    }

    @Test
    fun `未知长度_未声明exo_len_一律判为未完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", "128")
        seedSpan(store, key, position = 0, bytes = 1000)
        // 刻意不声明 exo_len：无法证明「已经到头」，保守判未缓存。
        assertFalse(store.isFullyCached(key))
    }

    @Test
    fun `多段连续 span 覆盖完整长度时判定为已完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", "128")
        seedSpan(store, key, position = 0, bytes = 400)
        seedSpan(store, key, position = 400, bytes = 600)
        declareContentLength(store, key, 1000)
        assertTrue("两段无缝相接且覆盖到 exo_len，应判为已缓存", store.isFullyCached(key))
    }

    @Test
    fun `span 之间有空隙时判定为未完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", "128")
        seedSpan(store, key, position = 0, bytes = 400)
        seedSpan(store, key, position = 600, bytes = 400)
        declareContentLength(store, key, 1000)
        assertFalse("间隙 [400,600) 未覆盖，不得判为已缓存", store.isFullyCached(key))
    }

    @Test
    fun `第一个 span 不从 0 开始时判定为未完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", "128")
        seedSpan(store, key, position = 200, bytes = 800)
        declareContentLength(store, key, 1000)
        assertFalse("头部 [0,200) 未覆盖，不得判为已缓存", store.isFullyCached(key))
    }

    @Test
    fun `不同缓存键互不干扰`() {
        val store = newStore()
        val cached = PlaybackCacheKeys.key("s1", "128")
        seedSpan(store, cached, position = 0, bytes = 1000)
        declareContentLength(store, cached, 1000)
        assertTrue(store.isFullyCached(cached))
        assertFalse(
            "同曲不同音质档是不同资源，不得互相命中",
            store.isFullyCached(PlaybackCacheKeys.key("s1", "320")),
        )
    }

    // ------------------------------------------------------------------
    // media3 1.4.1 术语对账（hole 语义）
    // ------------------------------------------------------------------

    @Test
    fun `media3_1_4_1 用 isCached 表达 hole 语义_没有 isHole 字段`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("s1", "128")

        // 未缓存区间查询返回的是 hole span（真实对象，不是手工构造）。
        val hole = store.cache.startReadWrite(key, 0, C.LENGTH_UNSET.toLong())
        assertFalse("hole span 的 isCached 必须为 false", hole.isCached)
        assertTrue("hole span 的 isHoleSpan() 必须为 true", hole.isHoleSpan())
        store.cache.releaseHoleSpan(hole)

        seedSpan(store, key, position = 0, bytes = 100)
        val real = store.cache.getCachedSpans(key).first()
        assertTrue("真实数据 span 的 isCached 必须为 true", real.isCached)
        assertFalse(real.isHoleSpan())
    }

    // ------------------------------------------------------------------
    // LRU 淘汰
    // ------------------------------------------------------------------

    @Test
    fun `LRU 淘汰后判定翻转`() {
        val store = newStore(maxBytes = 1000)
        val keyA = PlaybackCacheKeys.key("a", "128")
        val keyB = PlaybackCacheKeys.key("b", "128")

        seedSpan(store, keyA, position = 0, bytes = 600)
        declareContentLength(store, keyA, 600)
        assertTrue(store.isFullyCached(keyA))

        // 再写入 600 字节 → 总量 1200 > 1000 → 淘汰最久未使用的 A。
        // （A 与 B 的 lastTouchTimestamp 若相同，LRU 比较器按 key 升序兜底，仍是 A 先出。）
        seedSpan(store, keyB, position = 0, bytes = 600)
        declareContentLength(store, keyB, 600)

        assertTrue("B 应留在缓存中", store.isFullyCached(keyB))
        assertFalse("A 已被 LRU 淘汰，判定必须翻转", store.isFullyCached(keyA))
    }

    // ------------------------------------------------------------------
    // 源记忆
    // ------------------------------------------------------------------

    @Test
    fun `源记忆_写入_读取_覆盖`() {
        val memory = InMemorySourceMemory()
        val store = newStore(memory = memory)
        val key = PlaybackCacheKeys.key("s1", "320")

        assertNull("未记住时返回 null", store.resolvedSource(key))

        store.rememberResolvedSource(key, "https://cdn.example.com/a.mp3?sig=1")
        assertEquals("https://cdn.example.com/a.mp3?sig=1", store.resolvedSource(key))

        store.rememberResolvedSource(key, "https://cdn.example.com/a.mp3?sig=2")
        assertEquals("覆盖后必须读到新值", "https://cdn.example.com/a.mp3?sig=2", store.resolvedSource(key))
    }

    @Test
    fun `源记忆_不同键互不干扰`() {
        val store = newStore()
        store.rememberResolvedSource(PlaybackCacheKeys.key("s1", "128"), "src-128")
        store.rememberResolvedSource(PlaybackCacheKeys.key("s1", "320"), "src-320")
        assertEquals("src-128", store.resolvedSource(PlaybackCacheKeys.key("s1", "128")))
        assertEquals("src-320", store.resolvedSource(PlaybackCacheKeys.key("s1", "320")))
    }

    @Test
    fun `SharedPreferences 源记忆可跨实例读取_进程重启后仍可重建`() {
        val key = "sp-test-" + UUID.randomUUID()
        SharedPreferencesResolvedSourceMemory(context).write(key, "https://cdn/x?sig=abc")
        // 新实例 = 模拟进程重启后重新构造。
        val reread = SharedPreferencesResolvedSourceMemory(context).read(key)
        assertEquals("https://cdn/x?sig=abc", reread)
    }

    // ------------------------------------------------------------------
    // 单例性 / 目录锁
    // ------------------------------------------------------------------

    @Test
    fun `缓存实例惰性构造且重复访问为同一实例`() {
        val store = newStore()
        assertSame(store.cache, store.cache)
    }

    @Test
    fun `同一目录的第二个 SimpleCache 实例被拒绝_故必须单例`() {
        val config = PlaybackCacheConfig(
            directoryName = "cache-lock-" + UUID.randomUUID(),
            maxBytes = 1L shl 20,
        )
        val first = PlaybackCacheStore(context, config, InMemorySourceMemory())
        assertNotNull("首个实例可正常构造", first.cache)

        val second = PlaybackCacheStore(context, config, InMemorySourceMemory())
        assertThrows(IllegalStateException::class.java) { second.cache }
    }

    // ------------------------------------------------------------------
    // 端到端：真 CacheDataSource + file:// 上游
    // ------------------------------------------------------------------

    @Test
    fun `经 CacheDataSource 完整读完后判定为已完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("e2e-full", "128")
        val payload = ByteArray(4096) { (it % 251).toByte() }
        val upstream = writeTempUpstream(payload)

        readThroughCache(store, key, upstream, limit = payload.size.toLong())

        assertTrue("完整读完应判为已缓存", store.isFullyCached(key))
    }

    @Test
    fun `经 CacheDataSource 只读一部分时不算已完整缓存`() {
        val store = newStore()
        val key = PlaybackCacheKeys.key("e2e-partial", "128")
        val payload = ByteArray(4096) { (it % 251).toByte() }
        val upstream = writeTempUpstream(payload)

        readThroughCache(store, key, upstream, limit = 1024)

        assertFalse("只读了一部分，判定必须为未缓存", store.isFullyCached(key))
    }

    private fun writeTempUpstream(payload: ByteArray): Uri {
        val file = File(context.cacheDir, "upstream-" + UUID.randomUUID() + ".bin")
        file.writeBytes(payload)
        return Uri.fromFile(file)
    }

    /**
     * 经 [PlaybackCacheStore.dataSourceFactory]（真 `CacheDataSource`）读取上游，
     * 最多读 [limit] 字节后关闭。
     *
     * `DataSpec.key` 显式设为缓存键——等价引擎侧 `MediaItem.setCustomCacheKey`
     * 经 `ProgressiveMediaPeriod.java:1127` 落到 `DataSpec.key` 的链路。
     */
    private fun readThroughCache(
        store: PlaybackCacheStore,
        key: String,
        upstreamUri: Uri,
        limit: Long,
    ) {
        val dataSource = store.dataSourceFactory.createDataSource()
        val spec = DataSpec.Builder().setUri(upstreamUri).setKey(key).build()
        try {
            dataSource.open(spec)
            val buffer = ByteArray(512)
            var read = 0L
            while (read < limit) {
                val wanted = minOf(buffer.size.toLong(), limit - read).toInt()
                val n = dataSource.read(buffer, 0, wanted)
                if (n == C.RESULT_END_OF_INPUT) break
                read += n
            }
        } finally {
            dataSource.close()
        }
    }
}
