package com.gracemusic.data.source

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LoudnessCache] 全分支锁测试（纯 JUnit4 + 假 [LoudnessStore]，无 Android）。
 *
 * 语义基准：lite `kugou_models.dart:10-56`（持久化/预热）与 `:822-838`
 * （_rememberLoudness：写入条件 / 刷新序 / 300 条插入序淘汰）。方法名即断言。
 */
class LoudnessCacheTest {

    // ------------------------------------------------------------------
    // 写入条件（lite :826：lufs != null && isFinite && url 非空）
    // ------------------------------------------------------------------

    @Test
    fun `remember_正常写入_可按url读取并持久化`() {
        val store = RecordingStore()
        val cache = LoudnessCache(store)
        cache.remember("https://cdn/a", -14.5, -1.0)
        assertEquals(Pair(-14.5, -1.0 as Double?), cache.loudnessForUrl("https://cdn/a"))
        assertEquals(1, store.saved.size)
        val payload = store.saved.last()
        assertEquals(1, payload.size)
        assertEquals("https://cdn/a", payload[0].first)
        assertEquals(-14.5, payload[0].second, 1e-9)
        assertEquals(-1.0, payload[0].third!!, 1e-9)
    }

    @Test
    fun `remember_url为空_不写不持久化`() {
        val store = RecordingStore()
        val cache = LoudnessCache(store)
        cache.remember("", -14.5, null)
        assertNull(cache.loudnessForUrl(""))
        assertEquals(0, store.saved.size)
    }

    @Test
    fun `remember_lufs为NaN_不写不持久化`() {
        val store = RecordingStore()
        val cache = LoudnessCache(store)
        cache.remember("https://cdn/a", Double.NaN, null)
        assertNull(cache.loudnessForUrl("https://cdn/a"))
        assertEquals(0, store.saved.size)
    }

    @Test
    fun `remember_lufs为Infinity_不写不持久化`() {
        val store = RecordingStore()
        val cache = LoudnessCache(store)
        cache.remember("https://cdn/a", Double.POSITIVE_INFINITY, null)
        assertNull(cache.loudnessForUrl("https://cdn/a"))
        assertEquals(0, store.saved.size)
    }

    @Test
    fun `remember_peak为null_lufs正常_仍写入且peak存null`() {
        val store = RecordingStore()
        val cache = LoudnessCache(store)
        cache.remember("https://cdn/a", -14.5, null)
        assertEquals(Pair(-14.5, null), cache.loudnessForUrl("https://cdn/a"))
    }

    // ------------------------------------------------------------------
    // 300 条插入序淘汰 + 刷新序（lite :827-833）
    // ------------------------------------------------------------------

    @Test
    fun `remember_超过300条_淘汰最旧条目`() {
        val cache = LoudnessCache(RecordingStore())
        for (i in 1..301) {
            cache.remember("https://cdn/$i", -14.0, null)
        }
        // 第 1 条被淘汰，第 2 条与最新一条仍在。
        assertNull(cache.loudnessForUrl("https://cdn/1"))
        assertEquals(Pair(-14.0, null), cache.loudnessForUrl("https://cdn/2"))
        assertEquals(Pair(-14.0, null), cache.loudnessForUrl("https://cdn/301"))
    }

    @Test
    fun `remember_重写同url_刷新插入序使其变最新`() {
        val cache = LoudnessCache(RecordingStore())
        for (i in 1..300) {
            cache.remember("https://cdn/$i", -14.0, null)
        }
        // 重写第 1 条 → 它变最新；再插入新条 → 淘汰的是第 2 条而非第 1 条。
        cache.remember("https://cdn/1", -9.0, null)
        cache.remember("https://cdn/new", -10.0, null)
        assertNull(cache.loudnessForUrl("https://cdn/2"))
        assertEquals(Pair(-9.0, null), cache.loudnessForUrl("https://cdn/1"))
        assertEquals(Pair(-10.0, null), cache.loudnessForUrl("https://cdn/new"))
    }

    @Test
    fun `remember_持久化载荷_截断为前300条`() {
        val store = RecordingStore()
        val cache = LoudnessCache(store)
        for (i in 1..301) {
            cache.remember("https://cdn/$i", -14.0, null)
        }
        // 每次 remember 都全量持久化；最后一次载荷应为 300 条、首条是 cdn/2（最旧）。
        val payload = store.saved.last()
        assertEquals(300, payload.size)
        assertEquals("https://cdn/2", payload.first().first)
        assertEquals("https://cdn/301", payload.last().first)
    }

    // ------------------------------------------------------------------
    // 预热（lite :20-38 warmLoudnessCache）
    // ------------------------------------------------------------------

    @Test
    fun `warmUp_载入持久化条目_可按url读取`() {
        val store = RecordingStore()
        store.loaded = listOf(Triple("https://cdn/warm", -13.0, -0.5 as Double?))
        val cache = LoudnessCache(store)
        cache.warmUp()
        assertEquals(Pair(-13.0, -0.5 as Double?), cache.loudnessForUrl("https://cdn/warm"))
    }

    @Test
    fun `warmUp_仅执行一次_重复调用不再触发load`() {
        val store = RecordingStore()
        val cache = LoudnessCache(store)
        cache.warmUp()
        cache.warmUp()
        cache.warmUp()
        assertEquals(1, store.loadCount)
    }

    @Test
    fun `warmUp_跳过非法条目_空url与非有限lufs`() {
        val store = RecordingStore()
        store.loaded = listOf(
            Triple("", -14.0, null),
            Triple("https://cdn/nan", Double.NaN, null),
            Triple("https://cdn/inf", Double.NEGATIVE_INFINITY, null),
            Triple("https://cdn/ok", -14.0, null),
        )
        val cache = LoudnessCache(store)
        cache.warmUp()
        assertNull(cache.loudnessForUrl(""))
        assertNull(cache.loudnessForUrl("https://cdn/nan"))
        assertNull(cache.loudnessForUrl("https://cdn/inf"))
        assertEquals(Pair(-14.0, null), cache.loudnessForUrl("https://cdn/ok"))
    }

    @Test
    fun `warmUp_store抛异常_降级为空表不崩溃`() {
        val cache = LoudnessCache(ExplodingStore())
        cache.warmUp()
        assertNull(cache.loudnessForUrl("https://cdn/anything"))
    }

    @Test
    fun `remember_store抛异常_内存缓存仍生效不崩溃`() {
        // lite :41-50 持久化整体 try/catch：持久化失败不影响内存缓存。
        val cache = LoudnessCache(ExplodingStore())
        cache.remember("https://cdn/a", -14.0, null)
        assertEquals(Pair(-14.0, null), cache.loudnessForUrl("https://cdn/a"))
    }

    // ------------------------------------------------------------------
    // 持久化解析容错（LoudnessStorePrefs.parseLoudnessEntries，纯函数）
    // ------------------------------------------------------------------

    @Test
    fun `parseLoudnessEntries_正常数组_逐条还原`() {
        val raw = """[{"u":"https://cdn/a","l":-14.5,"p":-1.0},{"u":"https://cdn/b","l":-13.0}]"""
        val entries = LoudnessStorePrefs.parseLoudnessEntries(raw)
        assertEquals(2, entries.size)
        assertEquals("https://cdn/a", entries[0].first)
        assertEquals(-14.5, entries[0].second, 1e-9)
        assertEquals(-1.0, entries[0].third!!, 1e-9)
        assertEquals("https://cdn/b", entries[1].first)
        assertEquals(-13.0, entries[1].second, 1e-9)
        assertNull(entries[1].third)
    }

    @Test
    fun `parseLoudnessEntries_损坏JSON_返回空表不崩溃`() {
        assertTrue(LoudnessStorePrefs.parseLoudnessEntries("{not json").isEmpty())
        assertTrue(LoudnessStorePrefs.parseLoudnessEntries("????").isEmpty())
        assertTrue(LoudnessStorePrefs.parseLoudnessEntries("").isEmpty())
        assertTrue(LoudnessStorePrefs.parseLoudnessEntries("null").isEmpty())
    }

    @Test
    fun `parseLoudnessEntries_条目缺字段或类型不对_跳过坏条目保留好条目`() {
        val raw = """
            [
              {"l":-14.0},
              {"u":"","l":-14.0,"p":null},
              {"u":"https://cdn/x","l":"not-a-number"},
              {"u":"https://cdn/overflow","l":1.8e308,"p":null},
              {"u":42,"l":-14.0},
              "just-a-string",
              {"u":"https://cdn/good","l":-12.0,"p":-0.3}
            ]
        """.trimIndent()
        val entries = LoudnessStorePrefs.parseLoudnessEntries(raw)
        // 1.8e308 解析为 Infinity（非有限）→ 过滤；其余坏条目逐条跳过。
        assertEquals(1, entries.size)
        assertEquals("https://cdn/good", entries[0].first)
        assertEquals(-12.0, entries[0].second, 1e-9)
        assertEquals(-0.3, entries[0].third!!, 1e-9)
    }

    // ------------------------------------------------------------------
    // 测试工具
    // ------------------------------------------------------------------

    /** 记录型假 store。 */
    private class RecordingStore : LoudnessStore {
        val saved: MutableList<List<Triple<String, Double, Double?>>> = mutableListOf()
        var loaded: List<Triple<String, Double, Double?>> = emptyList()
        var loadCount: Int = 0

        override fun load(): List<Triple<String, Double, Double?>> {
            loadCount += 1
            return loaded
        }

        override fun save(entries: List<Triple<String, Double, Double?>>) {
            saved.add(entries)
        }
    }

    /** load/save 一律抛异常的假 store。 */
    private class ExplodingStore : LoudnessStore {
        override fun load(): List<Triple<String, Double, Double?>> = error("store 坏了")
        override fun save(entries: List<Triple<String, Double, Double?>>) = error("store 坏了")
    }
}
