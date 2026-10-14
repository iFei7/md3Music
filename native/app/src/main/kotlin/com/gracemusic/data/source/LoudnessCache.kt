package com.gracemusic.data.source

/**
 * 响度持久化存储抽象（T-P1-05，B 侧；台本 §2 冻结契约）。
 *
 * 生产实现 [LoudnessStorePrefs]（SharedPreferences）；测试用假实现记录载荷。
 * [load] 返回条目三元组 (url, lufs, peak)；[save] 全量覆写（截断由实现负责）。
 */
interface LoudnessStore {
    /** 读取全部持久化条目（损坏数据由实现容错为空表/部分条目）。 */
    fun load(): List<Triple<String, Double, Double?>>

    /** 全量覆写持久化条目（写前截前 300 条）。 */
    fun save(entries: List<Triple<String, Double, Double?>>)
}

/**
 * 音量均衡响度缓存：url → (LUFS, 峰值 dB)（T-P1-05，B 侧；台本 §2 冻结契约）。
 *
 * 1:1 对位 lite `kugou_models.dart:10-56`（全局 Map + SP 持久化）与
 * `:822-838`（`_rememberLoudness` 写入时机）。语义要点：
 *
 * - **写入条件**（lite `:826`）：url 非空 && lufs 有限（NaN/±Infinity 不写）；
 * - **插入序**：内部 [LinkedHashMap]（Java 实现为插入序）——更新同 url 先
 *   remove 再 put（刷新序，lite `:827-828`）；超过 [MAX_ENTRIES] 按
 *   插入顺序淘汰最旧（lite `:831-833` while 循环）；
 * - **持久化**：每次写入同步调 [LoudnessStore.save]（异常吞掉，对位 lite
 *   `:41-50` 持久化整体 try/catch；磁盘异步性由 SP `apply()` 提供）；
 * - **预热**：[warmUp] 一次性守卫（lite `:22-23` `_kugouLoudnessLoaded`），
 *   重复调用不再触发 [LoudnessStore.load]；预热条目同样过写入条件校验；
 * - 无 TTL（lite 语义）；内存封顶与持久化截断口径一致（300）。
 *
 * 线程安全：内部方法对 map 操作加锁（lite 侧单线程事件循环天然安全，
 * native 侧解析可能来自不同协程，显式同步补齐）。
 */
class LoudnessCache(private val store: LoudnessStore) {

    /** 单条响度值。 */
    private data class LoudnessValue(val lufs: Double, val peakDb: Double?)

    /** 插入序缓存（LinkedHashMap 保证迭代序=插入序，刷新靠先 remove）。 */
    private val entries: LinkedHashMap<String, LoudnessValue> = LinkedHashMap()

    /** 一次性预热守卫（对位 lite `_kugouLoudnessLoaded`）。 */
    @Volatile
    private var warmedUp: Boolean = false

    /** 按播放 url 查询已解析的响度，无则 null（对位 lite `loudnessForUrl` :53-56）。 */
    fun loudnessForUrl(url: String): Pair<Double, Double?>? {
        if (url.isEmpty()) return null
        synchronized(this) {
            val value: LoudnessValue = entries[url] ?: return null
            return Pair(value.lufs, value.peakDb)
        }
    }

    /**
     * 记录一次解析得到的响度（对位 lite `_rememberLoudness` :822-838）。
     * 写入条件不满足时静默忽略；满足时刷新序写入 + 淘汰 + 持久化。
     */
    fun remember(url: String, lufs: Double, peakDb: Double?) {
        if (url.isEmpty() || !lufs.isFinite()) return
        synchronized(this) {
            entries.remove(url)
            entries[url] = LoudnessValue(lufs, peakDb)
            while (entries.size > MAX_ENTRIES) {
                entries.remove(entries.keys.first())
            }
        }
        try {
            store.save(snapshots())
        } catch (_: Exception) {
            // 持久化失败不影响内存缓存（对位 lite _persistLoudnessCache try/catch）。
        }
    }

    /**
     * 启动预热：把历史持久化条目一次性载入内存（对位 lite `warmLoudnessCache`）。
     * 重复调用为无操作；store 异常降级为空表。
     */
    fun warmUp() {
        synchronized(this) {
            if (warmedUp) return
            warmedUp = true
        }
        val loaded: List<Triple<String, Double, Double?>> = try {
            store.load()
        } catch (_: Exception) {
            emptyList()
        }
        synchronized(this) {
            for (entry in loaded) {
                val url: String = entry.first
                val lufs: Double = entry.second
                if (url.isEmpty() || !lufs.isFinite()) continue
                entries.remove(url)
                entries[url] = LoudnessValue(lufs, entry.third)
            }
        }
    }

    /** 当前缓存快照（插入序），供持久化与测试断言。 */
    private fun snapshots(): List<Triple<String, Double, Double?>> {
        synchronized(this) {
            return entries.entries.take(MAX_ENTRIES).map { item ->
                Triple(item.key, item.value.lufs, item.value.peakDb)
            }
        }
    }

    companion object {
        /** 缓存条数上限（内存与持久化同口径），与 lite `_kugouLoudnessMax` 一致。 */
        const val MAX_ENTRIES: Int = 300
    }
}
