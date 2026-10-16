package com.gracemusic.player.offline

import android.annotation.SuppressLint
import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 播放缓存层构建参数。
 *
 * 独立成值对象（而非散落的常量）是为了让测试能用**隔离目录 + 极小上限**驱动
 * 「完整缓存判定」与「LRU 淘汰后判定翻转」两条路径；生产由
 * `di/PlayerModule.providePlaybackCacheConfig` 提供默认值。
 *
 * @property directoryName `context.cacheDir` 下的专用子目录名。
 *   **必须专用**：`SimpleCache` 的构造会**删除该目录内所有无法识别的文件**
 *   （vendored/官方 1.4.1 `SimpleCache.java:118-120` 的 KDoc 明示
 *   "the directory cannot be used to store other files"）。
 * @property maxBytes 缓存上限（字节）。见 [PlaybackCacheStore.DEFAULT_MAX_CACHE_BYTES]。
 */
data class PlaybackCacheConfig(
    val directoryName: String = PlaybackCacheStore.DEFAULT_DIRECTORY_NAME,
    val maxBytes: Long = PlaybackCacheStore.DEFAULT_MAX_CACHE_BYTES,
)

/**
 * 播放缓存层：Media3 `SimpleCache` + `CacheDataSource` 的唯一持有者。
 *
 * ## 职责边界（**只做基础设施，不做策略**）
 * 本类只回答两件事：
 * 1. 「某缓存键是否已**完整**缓存」（[isFullyCached]）；
 * 2. 「某缓存键上次成功解析到的源是什么」（[resolvedSource] / [rememberResolvedSource]）。
 * 离线跳歌、循环模式、停止播放等**策略**归 `PlaybackStore`（S-B），本类不参与。
 *
 * ## 单例与「同一目录只允许一个实例」
 * `SimpleCache` 用**进程级静态目录锁**保证同一目录只有一个实例，第二次构造直接抛
 * `IllegalStateException("Another SimpleCache instance uses the folder: ...")`
 * （官方 1.4.1 `SimpleCache.java:214-217`）。故本类由 Hilt 绑定为 `@Singleton`，
 * 且 [cache] 是 `by lazy`——进程内只会构造一次。
 *
 * ## 构造代价与线程（**主线程安全**）
 * `SimpleCache` 的构造会**同步阻塞**直到后台线程完成磁盘索引加载
 * （官方 1.4.1 `SimpleCache.java:227-242`：`conditionVariable.block()`）。
 * 而 `di/PlayerModule.provideMainAudioEngine` 标注 `@MainThread`，
 * 若在构建引擎时构造 `SimpleCache`，会在主线程产生一次磁盘 I/O（首次启动更明显）。
 *
 * 因此本类采用**两级惰性**：
 * - [cache] / [cacheDataSourceFactory] 均为 `by lazy`，**构造本类不触发**任何磁盘 I/O；
 * - [dataSourceFactory] 是一个**委托工厂**，真正的 `CacheDataSource.Factory` 在
 *   `createDataSource()` 时才构建——该方法由 ExoPlayer 在**加载线程**调用
 *   （`DataSource.Factory.createDataSource` 的调用点是媒体加载，非主线程）。
 *
 * 结论：把 [dataSourceFactory] 传给引擎构建（主线程）不会触发 `SimpleCache` 构造。
 * 该选择的代价：首次播放时在加载线程上多一次索引加载（不可见于主线程），
 * 且若加载线程此时正被其它任务占用，首个 `open` 会稍晚返回。
 *
 * ## 缓存索引（选择与偏离登记）
 * 用 `SimpleCache(File, CacheEvictor)` 的 **2 参构造**（legacy 文件索引），
 * 而非 `SimpleCache(File, CacheEvictor, DatabaseProvider)`（SQLite 索引）。
 * - 理由：2 参构造不引入 `media3-database` 的 `StandaloneDatabaseProvider`
 *   （无需新增依赖、无 `.db` 文件与其生命周期管理），本阶段范围最小。
 * - 代价：media3 官方标注 legacy 索引在**大缓存**下性能较差（该构造已 `@Deprecated`）。
 *   本工程缓存上限 512 MiB、条目数在数百量级，实测路径（单测）无问题。
 * - **后续收敛（登记）**：F-CACHE-009（缓存大小设置）接线时一并迁移到
 *   `StandaloneDatabaseProvider` 索引。
 *
 * ## 安全纪律（**强制**）
 * - 缓存的源 URL 可能含**鉴权参数**：本类**绝不写任何日志**（`Log.*` 一律不出现），
 *   不把 URL / 缓存键回显到异常信息、UI 或崩溃上报；
 * - 数据只落在**应用私有目录**：`context.cacheDir/<directoryName>`（缓存字节）
 *   与 [ResolvedSourceMemory] 的私有 SharedPreferences（键→源）。
 */
@SuppressLint("UnsafeOptInUsageError")
@OptIn(UnstableApi::class)
@Singleton
class PlaybackCacheStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val config: PlaybackCacheConfig,
    private val sourceMemory: ResolvedSourceMemory,
) {

    /**
     * 供引擎使用的数据源工厂。
     *
     * 刻意用**委托工厂**包一层（而不是直接暴露 `CacheDataSource.Factory`）：
     * `CacheDataSource.Factory` 在构造时就需要一个 `Cache` 实例，而 `SimpleCache`
     * 构造会阻塞读索引——直接暴露会让「构建引擎」（主线程）触发磁盘 I/O。
     * 委托后，真正的构建推迟到 `createDataSource()`（加载线程）。
     *
     * 未配置上游时 ExoPlayer 的行为与改造前**完全一致**（见 [AudioEngineConfig.dataSourceFactory]
     * 的 KDoc）——本工厂只是把「先查缓存、未命中回源、边播边写」插在中间。
     */
    val dataSourceFactory: DataSource.Factory = DataSource.Factory {
        cacheDataSourceFactory.createDataSource()
    }

    /**
     * 缓存实例（`by lazy`，线程安全：`SYNCHRONIZED`）。
     *
     * `internal` 仅用于同模块单测断言「单例性」与「目录锁」，不对外暴露。
     */
    internal val cache: SimpleCache by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        // 2 参构造使用 legacy 文件索引（不引入 media3-database 的 DatabaseProvider）。
        // 选择理由与后续收敛见 KDoc「缓存索引」段。
        @Suppress("DEPRECATION")
        SimpleCache(
            File(context.cacheDir, config.directoryName),
            LeastRecentlyUsedCacheEvictor(config.maxBytes),
        )
    }

    /**
     * 缓存数据源工厂（`by lazy`；首次访问会构造 [cache]）。
     *
     * 标志位 [CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR]：缓存读写异常时
     * **回退到纯网络读取**而不是让播放直接失败——缓存是加速设施，不应成为
     * 新的播放失败来源（磁盘满、索引损坏、权限异常等）。
     */
    private val cacheDataSourceFactory: CacheDataSource.Factory by
        lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
            CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(DefaultDataSource.Factory(context))
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        }

    // ------------------------------------------------------------------
    // 命中判定
    // ------------------------------------------------------------------

    /**
     * 缓存键对应的资源是否已**完整**缓存。
     *
     * ## 判定规则（含源码依据）
     * 1. 取 `SimpleCache.getContentMetadata(key)` 的 `KEY_CONTENT_LENGTH`（`"exo_len"`）。
     *    该值由 `CacheDataSource` 在**回源**时写入：已知长度时取 `Content-Length`
     *    （`CacheDataSource.java:805-808`），读到流末尾时取实际读到的字节数
     *    （`CacheDataSource.java:823-825`）。**未知（`C.LENGTH_UNSET`）一律判为未缓存**。
     * 2. `SimpleCache.getCachedSpans(key)` 返回**按 position 升序**的已落盘 span
     *    （`SimpleCache.java:305-311` + `CacheSpan.compareTo`）。自 position 0 起
     *    逐段累加覆盖区间；任一 `isCached == false`（持久化 hole）或出现**空隙**
     *    （下一段起点 > 已覆盖终点）即判为未缓存。
     * 3. 覆盖区间达到 `exo_len` 即判为**已完整缓存**。
     *
     * 为什么不能只看「存在 position==0 的 span」：`CacheDataSink` 在**部分**读完后
     * 也会 `commitFile` 一个从 0 开始的真实数据 span（`CacheDataSink.java:263-278`），
     * 仅凭 span 起点无法区分「播到一半」与「播完」。`exo_len` 提供了长度基准，
     * 这是本工程采用的更可靠判据（对应任务 §5.1「若你能拿到 contentLength，以源码为准」）。
     *
     * ## 术语对齐
     * media3 1.4.1 的 `CacheSpan` **没有** `isHole` 字段（那是更早版本的命名），
     * 等价语义为 `isCached`（`CacheSpan.java:39`、`:87-89`：`isHoleSpan() = !isCached`）。
     * 本实现的「hole 不算已缓存」即 `!span.isCached` 分支。
     *
     * @param cacheKey 由 [PlaybackCacheKeys.key] 构造的键。
     */
    fun isFullyCached(cacheKey: String): Boolean {
        val contentLength = ContentMetadata.getContentLength(cache.getContentMetadata(cacheKey))
        // C.LENGTH_UNSET 为 Int(-1)；未写入 exo_len 或写入非法值一律判未缓存。
        if (contentLength <= 0L) return false
        var covered = 0L
        for (span in cache.getCachedSpans(cacheKey)) {
            if (!span.isCached) return false // 持久化的 hole：区间断开
            if (span.position > covered) return false // 出现空隙（前一段未覆盖到这里）
            val spanEnd = if (span.isOpenEnded()) Long.MAX_VALUE else span.position + span.length
            if (spanEnd > covered) covered = spanEnd
            if (covered >= contentLength) return true
        }
        return false
    }

    // ------------------------------------------------------------------
    // 源记忆（键 → 上次成功解析到的源）
    // ------------------------------------------------------------------

    /** 读取缓存键上次成功解析到的源；未记住时 `null`。 */
    fun resolvedSource(cacheKey: String): String? = sourceMemory.read(cacheKey)

    /** 记住（或覆盖）缓存键对应的源。 */
    fun rememberResolvedSource(cacheKey: String, source: String) =
        sourceMemory.write(cacheKey, source)

    companion object {
        /** 缓存专用子目录名（`context.cacheDir` 下）。 */
        const val DEFAULT_DIRECTORY_NAME = "playback_cache"

        /**
         * 缓存上限（字节）：**512 MiB**。
         *
         * ## 临时决策登记
         * 这是「F-CACHE-009 缓存大小设置接线」前的**显式常量兜底**：
         * 产品侧的「缓存大小」设置项尚未落地（设置层 F-CACHE-009 未接线），
         * 本阶段先固定 512 MiB，避免无上限增长。F-CACHE-009 接线后，
         * 此处应改为读用户设置（并支持运行时重建 evictor / 触发一次裁剪）。
         *
         * 取值理由：单曲无损（flac / Hi-Res）约 30-60 MiB，512 MiB 约可容纳
         * 8-15 首，足够覆盖「断网时歌单内跳到下一首已缓存曲目」的典型场景，
         * 又不会在低端机上造成存储压力（`cacheDir` 本身受系统配额约束）。
         */
        const val DEFAULT_MAX_CACHE_BYTES: Long = 512L * 1024 * 1024
    }
}
