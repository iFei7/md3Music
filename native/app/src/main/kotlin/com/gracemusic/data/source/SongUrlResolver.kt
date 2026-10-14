package com.gracemusic.data.source

import com.gracemusic.data.model.Song
import com.gracemusic.data.net.CloudUrlAttempt
import com.gracemusic.data.net.CloudUrlRequest
import com.gracemusic.data.net.KugouApi
import com.gracemusic.data.net.SongUrlAttempt
import com.gracemusic.data.net.SongUrlRequest
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 解析结果（台本 §2 冻结契约）。
 *
 * [ResolutionResult.Success.actualQuality] 语义（台本执行步骤 3-④）：
 * 服务端回写档——链内命中时取回写值；本地曲/云盘直连无服务端回写 →
 * 传调用方请求档（不虚标）。
 */
sealed interface ResolutionResult {
    /** 解析成功：[url] 可直接喂给播放引擎；[lufs]/[peakDb] 为服务端响度（常缺，F-SRC-008）。 */
    data class Success(
        val song: Song,
        val url: String,
        val actualQuality: String,
        val isTrial: Boolean,
        val lufs: Double?,
        val peakDb: Double?,
    ) : ResolutionResult

    /** 解析失败：文案已收敛，不含 URL / 上游内部信息。 */
    data class Failure(val message: String) : ResolutionResult
}

/**
 * 音源解析器（T-P1-05，B 侧）：/song/url 降级链 + 云盘先行 + 本地直返的
 * 三分流入口（台本 §1.1/§2）。
 *
 * 语义基准：lite `kugou_api_client.dart:1338-1507`（降级链/链驱动/三段兜底）、
 * `player_provider.dart:3602-3686`（云盘先行 resolveCloudUrl）、
 * `:5639-5706`（本地分流 _resolvePlaybackUrl）。
 *
 * ## 链驱动（对位 lite getSongUrlWithFallback :1395-1507）
 *
 * 1. `downgradeChain(requested)` 逐档请求 [KugouApi.songUrl]；
 * 2. 结果为空 url / isTrial → 跳过该档（lite :1434-1436：试听兜底统一放到
 *    链尾，防止链被 30s 试听短路）；
 * 3. **仅当回写档 == 请求档才立即返回**（lite :1439-1447）——上游常静默降档，
 *    「拿到了链接」不等于「拿到了请求的音质」；
 * 4. 否则按 [qualityRank] 留 best（更高才替换）；**回写档认不出（非法字符串）
 *    按无证据处理，不参与 best 竞争**（Sonify 思路 ③「没有证据就不猜」；
 *    刻意偏离 lite :1448-1451——lite rank 默认 0，非法档可与 128 竞争 best，
 *    native 收紧以避免 UI 虚标无法归类的档位）；
 * 5. 单档异常吞掉继续；[CancellationException] 原样重抛；
 * 6. `SongUrlAttempt.LocalFailure`（服务器忙/不可用）立即中止整链并上抛
 *    Failure（lite onLocalFailure + cancelToken :1407-1412）；
 * 7. 总超时 [totalTimeout]（默认 45s，对位 lite :1400 totalTimeout 参数），
 *    超时转 Failure（对位 lite cancelToken 超时后各档取消 → 返回 null）。
 *
 * ## 链后三段兜底（lite :1457-1503）
 *
 * best（有则返回）→ `ppage_id=356753938` standard（试听跳过，lite :1467-1486，
 * 收藏页解锁无版权曲目且必须先于试听兜底）→ standard + downgrade=true
 * （试听可接受，最后手段，lite :1488-1501）→ 全败 Failure。
 *
 * ## 三分流
 *
 * - 本地（!isOnline）：localPath 非空直返，不发请求（lite :5674-5677）；
 * - 云盘（isCloud）：先 [KugouApi.cloudUrl]（lite :3652-3669），Resolved 直返，
 *   其余（含 LocalFailure）回退在线链（lite :3670 catch-all 回退）；
 * - 在线：走链。
 *
 * ## 与 lite 的刻意偏离登记
 *
 * - 20028 设备重注册 / 20018 token 刷新 / VIP `/song/url/new` 通道不实现
 *   （native 无会话层，台本 §1.1；20028/20018 由 A 侧记 Unavailable）；
 * - 超时文案：lite 超时上层报「无法获取播放链接」，native 统一「暂无可用音源」
 *   （失败文案收敛自定，不透传上游细节）；
 * - 本地路径不做 content:// 解析与 file:// 转换（lite :5678-5687 平台层职责，
 *   native 由扫描层在 localPath 写入前完成）。
 *
 * 成功即写响度缓存（`success` → [LoudnessCache.remember]，对位 lite
 * KugouPlayUrl.fromJson 末尾 `_rememberLoudness` 的调用时机）。
 */
class SongUrlResolver(
    private val api: KugouApi,
    private val loudnessCache: LoudnessCache,
    private val totalTimeout: Duration = DEFAULT_TOTAL_TIMEOUT,
) {
    /** Hilt 注入用构造器：默认 45s 总超时（超时值仅供测试注入）。 */
    @Inject
    constructor(api: KugouApi, loudnessCache: LoudnessCache) : this(api, loudnessCache, DEFAULT_TOTAL_TIMEOUT)

    /**
     * 解析可播 URL（台本 §2 冻结契约）。
     * 永不抛业务异常：失败一律返回 [ResolutionResult.Failure]；
     * 仅协程取消（外部作用域取消）原样重抛。
     */
    suspend fun resolve(song: Song, requestedQuality: String): ResolutionResult {
        // 三分流之一：本地曲直返，不发任何请求（lite :5674-5677）。
        if (!song.isOnline) {
            val localPath: String? = song.localPath
            if (localPath.isNullOrEmpty()) {
                return ResolutionResult.Failure(MSG_LOCAL_UNAVAILABLE)
            }
            return ResolutionResult.Success(
                song = song,
                url = localPath,
                actualQuality = requestedQuality,
                isTrial = false,
                lufs = null,
                peakDb = null,
            )
        }
        // 三分流之二：云盘先行（lite :3652-3686）。Resolved 直返；其余回退链。
        if (song.isCloud) {
            val cloudRequest: CloudUrlRequest = CloudUrlRequest(
                hash = song.id.lowercase(),
                albumId = song.albumId,
                name = song.title,
                albumAudioId = song.albumAudioId,
            )
            when (val cloudAttempt: CloudUrlAttempt = api.cloudUrl(cloudRequest)) {
                is CloudUrlAttempt.Resolved -> return ResolutionResult.Success(
                    song = song,
                    url = cloudAttempt.url,
                    actualQuality = requestedQuality,
                    isTrial = false,
                    lufs = null,
                    peakDb = null,
                )
                // Unavailable / LocalFailure 均回退在线降级链（lite :3670 catch-all）。
                is CloudUrlAttempt.Unavailable -> Unit
                is CloudUrlAttempt.LocalFailure -> Unit
            }
        }
        // 三分流之三：在线降级链（云盘回退也走这里）。
        return resolveOnline(song, requestedQuality)
    }

    /** 在线链 + 三段兜底，包在总超时内（lite cancelToken 语义）。 */
    private suspend fun resolveOnline(song: Song, requestedQuality: String): ResolutionResult {
        return try {
            withTimeout(totalTimeout) { resolveOnlineInsideTimeout(song, requestedQuality) }
        } catch (e: TimeoutCancellationException) {
            // 超时视作整体失败（lite cancelToken 超时 → 链中断 → 上层 null）。
            ResolutionResult.Failure(MSG_NO_SOURCE)
        }
        // 其他 CancellationException（外部取消）自然重抛，不吞。
    }

    /** 超时保护块内的实际链驱动与兜底。 */
    private suspend fun resolveOnlineInsideTimeout(
        song: Song,
        requestedQuality: String,
    ): ResolutionResult {
        val hash: String = song.id.lowercase()
        // 1. 降级链逐档请求（lite :1415-1455）。
        var best: SongUrlAttempt.Resolved? = null
        for (quality: String in downgradeChain(requestedQuality)) {
            val attempt: SongUrlAttempt? =
                requestOrNull(song, hash, quality = quality, downgrade = false, ppageId = null)
            if (attempt == null) continue
            when (attempt) {
                // 本地失败立即中止整链（lite stopAfterLocalFailure :1407-1412）。
                is SongUrlAttempt.LocalFailure -> return ResolutionResult.Failure(MSG_NETWORK)
                // 上游判死本档 → 下一档。
                is SongUrlAttempt.Unavailable -> continue
                is SongUrlAttempt.Resolved -> {
                    // 空链接/试听跳过（lite :1434-1436）。
                    if (attempt.url.isEmpty() || attempt.isTrial) continue
                    // 精确命中请求档 → 立即采用（lite :1439-1447）。
                    if (attempt.quality == quality) return success(song, attempt)
                    // 留 best：更高 rank 才替换；无证据档不参与竞争（见类 KDoc 偏离）。
                    val rank: Int? = qualityRank(attempt.quality)
                    if (rank != null) {
                        val bestRank: Int = best?.let { qualityRank(it.quality) } ?: -1
                        if (best == null || rank > bestRank) best = attempt
                    }
                }
            }
        }
        // 2. best 兜底（lite :1457-1465）。
        best?.let { return success(song, it) }
        // 3. ppage_id 收藏页兜底：standard 非试听才采用（lite :1467-1486）。
        val ppageAttempt: SongUrlAttempt? =
            requestOrNull(song, hash, quality = QUALITY_STANDARD, downgrade = false, ppageId = PPAGE_FALLBACK_ID)
        if (ppageAttempt is SongUrlAttempt.Resolved && ppageAttempt.url.isNotEmpty() && !ppageAttempt.isTrial) {
            return success(song, ppageAttempt)
        }
        // 4. 最后手段：standard + downgrade=true，试听可接受（lite :1488-1501）。
        val finalAttempt: SongUrlAttempt? =
            requestOrNull(song, hash, quality = QUALITY_STANDARD, downgrade = true, ppageId = null)
        if (finalAttempt is SongUrlAttempt.Resolved && finalAttempt.url.isNotEmpty()) {
            return success(song, finalAttempt)
        }
        return ResolutionResult.Failure(MSG_NO_SOURCE)
    }

    /**
     * 单次请求：异常吞掉返回 null 继续降级（lite :1452-1454 catch (_) continue）；
     * [CancellationException] 原样重抛（含总超时取消——withTimeout 边界会把它
     * 归一为 TimeoutCancellationException）。
     */
    private suspend fun requestOrNull(
        song: Song,
        hash: String,
        quality: String,
        downgrade: Boolean,
        ppageId: String?,
    ): SongUrlAttempt? {
        return try {
            api.songUrl(
                SongUrlRequest(
                    hash = hash,
                    quality = quality,
                    albumId = song.albumId,
                    albumAudioId = song.albumAudioId,
                    downgrade = downgrade,
                    ppageId = ppageId,
                ),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
    }

    /** 组装成功结果；响度有效则写缓存（对位 lite `_rememberLoudness` 时机）。 */
    private fun success(song: Song, attempt: SongUrlAttempt.Resolved): ResolutionResult.Success {
        val lufs: Double? = attempt.lufs
        if (lufs != null && lufs.isFinite() && attempt.url.isNotEmpty()) {
            loudnessCache.remember(attempt.url, lufs, attempt.peakDb)
        }
        return ResolutionResult.Success(
            song = song,
            url = attempt.url,
            actualQuality = attempt.quality,
            isTrial = attempt.isTrial,
            lufs = attempt.lufs,
            peakDb = attempt.peakDb,
        )
    }

    companion object {
        /** 总超时，与 lite getSongUrlWithFallback 默认一致（kugou_api_client.dart:1400）。 */
        val DEFAULT_TOTAL_TIMEOUT: Duration = 45.seconds

        /** 链后兜底请求的固定音质档。 */
        const val QUALITY_STANDARD: String = "128"

        /** 收藏页 page_id（lite :1479：已收藏无版权曲目的解锁通道）。 */
        const val PPAGE_FALLBACK_ID: String = "356753938"

        /** 本地文件不可用文案。 */
        const val MSG_LOCAL_UNAVAILABLE: String = "本地文件不可用"

        /** 本地失败（服务器忙/不可用）文案，与 PlaybackErrorMessages 映射表对齐。 */
        const val MSG_NETWORK: String = "播放失败，请检查网络"

        /** 音源全败文案。 */
        const val MSG_NO_SOURCE: String = "暂无可用音源"

        /**
         * 请求音质 → 降级链（1:1 对位 lite `downgradeChain` :1342-1386，
         * API 码为字符串；AudioQuality 的 [com.gracemusic.player.model.AudioQuality.value]
         * 即 API 码：128/320/flac/high/viper_tape）。
         */
        fun downgradeChain(quality: String): List<String> {
            return when (quality) {
                "viper_tape" -> listOf("viper_tape", "high", "flac", "320", "128")
                "high" -> listOf("high", "flac", "320", "128")
                "flac" -> listOf("flac", "320", "128")
                "320" -> listOf("320", "128")
                else -> listOf("128")
            }
        }

        /**
         * 音质档位排序：比较哪次尝试的结果更好（对位 lite `qualityRank` :1373-1386）。
         * 认不出的档返回 null（无证据，不参与 best 竞争——刻意偏离 lite 的
         * default→0，见类 KDoc）。
         */
        fun qualityRank(quality: String): Int? {
            return when (quality) {
                "viper_tape" -> 4
                "high" -> 3
                "flac" -> 2
                "320" -> 1
                "128" -> 0
                else -> null
            }
        }
    }
}
