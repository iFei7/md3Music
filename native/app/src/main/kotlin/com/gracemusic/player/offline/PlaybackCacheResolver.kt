package com.gracemusic.player.offline

/**
 * 在线歌曲「播放缓存」查询端口（**冻结契约，逐字实现，不得改名/改签名**）。
 *
 * ## 为什么需要它
 * 产品要求（2026-10-15 提出，见 `docs/native/phase-5-offline-playlist.md`）：
 * 断网时播放在线歌单，若当前曲之后的曲目未缓存，应绕到歌单中下一首**已缓存**曲目
 * 继续播放；若不存在任何可播放的缓存曲目则停止播放；网络恢复后**不**自动续播，
 * 等用户手动操作。
 *
 * 落地该行为的前提是能回答「这首歌是否已缓存」。本接口即该能力的**唯一查询入口**，
 * 生产实现为 [SimplePlaybackCacheResolver]（Media3 `SimpleCache` + `CacheDataSource`）。
 *
 * ## 语义基准
 * 对位 Dart `PlayerProvider.resolveLocalAudioPath(songId, quality) -> Future<String?>`
 * （`player_provider.dart:3129-3131`、`:3368-3370`、`:4275-4278`）：
 * 命中返回可直接喂给播放引擎的音源，未命中返回 `null`。
 *
 * ## 偏离登记（相对 Dart，**重要**）
 * 1. **返回值的形态不同**：Dart 返回**本地绝对路径**（`String?`，可直接喂给 just_audio）；
 *    native 返回**上次成功解析到的音源 URL**（`String?`）。原因是 native 的缓存是
 *    Media3 `CacheDataSource` 的**透明读缓存**——命中时引擎仍按**原 URL** 打开，
 *    由 `CacheDataSource` 在内部改读缓存文件，播放项因此无需改写 URI。
 *    这也是「缓存键必须与易变的签名 URL 解耦」的原因：键取 `songId|quality`，
 *    见 [PlaybackCacheKeys]。
 * 2. **新增写入口** [rememberResolvedSource]：Dart 侧缓存路径由私有构建注入、
 *    与解析结果同源，无需单独记忆；native 的 `CacheDataSource` 只缓存**字节**，
 *    不知道「这个字节流属于哪首歌」，故需把「`songId|quality` → 上次解析到的 URL」
 *    单独持久化，离线时才能重建可播放的播放项。
 *
 * ## 与产品约束的关系
 * 「只允许播放缓存，不实现离线下载、离线曲库、下载队列、断点下载或下载任务管理」
 * ——本接口只**查询**播放缓存是否命中，不提供下载、不提供缓存管理。
 * 缓存写入是「边播边缓存」的副作用（`CacheDataSource` 透明写），不是独立的下载功能。
 *
 * ## 实现约束
 * - 实现必须是**可取消**的挂起函数，不得在主线程做阻塞 I/O；
 * - 调用方（`PlaybackStore`）负责代次校验：迟到结果不得覆盖更新的播放请求；
 * - 实现**不得**抛业务异常——查不到一律返回 `null`（显式失败不静默，但不以异常传播）。
 */
interface PlaybackCacheResolver {

    /**
     * 查询某曲在指定音质档下是否已有**可播放**的本地缓存。
     *
     * @param songId 歌曲唯一标识（与 [com.gracemusic.data.model.Song.id] 同源，通常为小写 hash）。
     * @param quality 音质档（`AudioQuality.value`：`128` / `320` / `flac` / `high` / `viper_tape`）。
     * @return 命中 → 可直接喂给引擎的播放源字符串（= 该曲上次成功解析到的音源 URL）；
     *   未命中 → `null`。
     */
    suspend fun resolveCachedSource(songId: String, quality: String): String?

    /** 记录一次成功解析到的音源，供离线时重建播放项。 */
    suspend fun rememberResolvedSource(songId: String, quality: String, source: String)
}

/**
 * [PlaybackCacheResolver] 的默认空实现（恒「未缓存」）。
 *
 * ⚠️ **接线前必须注意**：若在「离线判定已接线」而「缓存实现仍为 [NoOpPlaybackCacheResolver]」
 * 的状态下接线，所有曲目都会被判为未缓存，行为会退化为「离线时立即停止播放」。
 * 生产接线（`di/PlayerModule.kt`）绑定的是 [SimplePlaybackCacheResolver]。
 */
object NoOpPlaybackCacheResolver : PlaybackCacheResolver {
    override suspend fun resolveCachedSource(songId: String, quality: String): String? = null
    override suspend fun rememberResolvedSource(songId: String, quality: String, source: String) = Unit
}
