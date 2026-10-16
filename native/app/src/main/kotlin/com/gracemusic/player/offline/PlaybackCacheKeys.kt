package com.gracemusic.player.offline

import com.gracemusic.player.model.AudioQuality

/**
 * 播放缓存键的唯一构造入口。
 *
 * ## 为什么键必须与 URL 解耦
 * 在线音源 URL 是**易变的签名链接**：同一首歌每次解析得到的 URL 可能不同
 * （签名/过期时间/token 参数变化），而 `CacheKeyFactory.DEFAULT`
 * （`media3-datasource:1.4.1`，`androidx/media3/datasource/cache/CacheKeyFactory.java:26-27`）
 * 的默认键是 `dataSpec.key ?: dataSpec.uri.toString()`。若不显式设置
 * `MediaItem.customCacheKey`，缓存键就会退化为**每次都可能不同的 URL**，
 * 缓存永远无法命中。故本工程显式把键固定为 `songId|quality`。
 *
 * ## 键的组成
 * `"<songId>|<quality>"`：同一首歌的不同音质档对应**不同的音频文件**（128/320/flac
 * 是三个不同的资源），必须落在不同的缓存键上，否则会互相覆盖。
 *
 * ## 三处必须使用同一键
 * 1. 引擎写入路径：`ExoPlayerPlaybackEngineAdapter.prepare` →
 *    `MediaItem.Builder.setCustomCacheKey(...)`；
 * 2. 命中查询路径：[PlaybackCacheStore.isFullyCached]；
 * 3. 源记忆路径：[ResolvedSourceMemory]。
 *
 * ## 偏离登记（相对冻结契约的字面）
 * 契约要求适配器设置 `"<songId>|<quality>"`，其中 `quality` 取「该曲当前实际音质档」。
 * 适配器 `prepare(song, startPositionMs, playWhenReady)` 的签名（冻结，不得改）
 * **不携带音质档**，故适配器取 [com.gracemusic.data.model.Song.quality]
 * （该曲接口返回的音质标记）；为 null 时回落 [DEFAULT_QUALITY]。
 *
 * ⚠️ **已知一致性风险（登记）**：若 `PlaybackStore`（S-B 负责接线）查询
 * `resolveCachedSource(songId, quality)` 时传入的是**用户设置档位**
 * （`AudioQuality.value`）而非 `Song.quality`，两侧键会不一致，缓存永不命中。
 * 最小风险选择：本文件把键构造收敛到单一入口，S-B 接线时**必须**复用
 * [key] 且两侧 quality 来源一致。见报告「遗留风险 / 未完成项」。
 */
object PlaybackCacheKeys {

    /**
     * 适配器拿不到该曲音质档时的兜底档位。
     *
     * 取 [AudioQuality.STANDARD]（`"128"`）——与 `AudioQuality.fromStoredValue`
     * 的兜底一致（`player_provider.dart:1229-1234`：无法识别时回落标准音质）。
     */
    val DEFAULT_QUALITY: String = AudioQuality.STANDARD.value

    /** 构造缓存键 `"<songId>|<quality>"`。 */
    fun key(songId: String, quality: String): String = "$songId|$quality"
}
