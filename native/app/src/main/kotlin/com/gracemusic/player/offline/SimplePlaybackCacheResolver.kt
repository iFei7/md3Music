package com.gracemusic.player.offline

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * [PlaybackCacheResolver] 的真实实现：委托 [PlaybackCacheStore]。
 *
 * ## 语义
 * - [resolveCachedSource]：**仅当**该曲在指定音质档下已**完整**缓存、
 *   且记住过对应的源时，才返回该源；否则 `null`（不猜测、不降级、不抛异常）。
 * - [rememberResolvedSource]：写入「`songId|quality` → 源」的记忆。
 *
 * 缓存键统一由 [PlaybackCacheKeys.key] 构造，与引擎写入路径
 * （`ExoPlayerPlaybackEngineAdapter` 的 `setCustomCacheKey`）**共用同一入口**，
 * 保证「写入的键」与「查询的键」逐字一致。
 *
 * ## 线程（**不得在主线程做磁盘 I/O**）
 * 命中判定会读 `SimpleCache` 的磁盘索引、源记忆会读 SharedPreferences，
 * 两者都是磁盘 I/O。故两个方法都切换到 [ioDispatcher]（默认 [Dispatchers.IO]）。
 * `withContext` 天然**可取消**：调用方（`PlaybackStore`）取消协程即可中止查询。
 *
 * `ioDispatcher` 可注入，仅供测试断言「不在主线程执行」与替换为受控调度器。
 */
class SimplePlaybackCacheResolver(
    private val store: PlaybackCacheStore,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : PlaybackCacheResolver {

    override suspend fun resolveCachedSource(songId: String, quality: String): String? =
        withContext(ioDispatcher) {
            val key = PlaybackCacheKeys.key(songId, quality)
            if (!store.isFullyCached(key)) {
                null
            } else {
                store.resolvedSource(key)
            }
        }

    override suspend fun rememberResolvedSource(songId: String, quality: String, source: String) {
        withContext(ioDispatcher) {
            store.rememberResolvedSource(PlaybackCacheKeys.key(songId, quality), source)
        }
    }
}
