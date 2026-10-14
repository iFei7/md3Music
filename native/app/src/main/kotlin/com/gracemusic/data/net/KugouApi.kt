package com.gracemusic.data.net

/**
 * 酷狗本地 API 网络层的冻结契约（T-P1-05 台本 §2，A/B 两侧严格按此签名）。
 *
 * 实现方 [com.gracemusic.data.net.OkHttpKugouApi] 通过 OkHttp 访问本机 Rust
 * 服务器（`/song/url`、`/user/cloud/url`），语义 1:1 对位 lite 的
 * `kugou_api_client.dart`（对位行号见各成员 KDoc）。
 *
 * 设计约束：
 * - 所有返回值均为 sealed 结果（不抛业务异常），调用方（B 侧
 *   SongUrlResolver 降级链）据此驱动链序；协程取消仍以 CancellationException 传播；
 * - [SongUrlAttempt.LocalFailure] 表示本地服务器层失败（忙 / 不可达），
 *   降级链收到后必须立即中止整链；[SongUrlAttempt.Unavailable] 表示
 *   上游判死本档，链可继续降级；
 * - URL / 上游原始报文不得进入日志与 UI 文案（安全约束）。
 */
interface KugouApi {

    /**
     * 获取在线播放地址（本机 Rust 服务器 `/song/url`）。
     *
     * 服务器懒启动 + 就绪等待（≤8s，对位 lite 拦截器）在此内部完成，
     * 不要求应用启动时预热——首次请求才触发 `ensureStarted`
     * （对位 lite `onServerNeeded` 语义），失败抛
     * [LocalFailureKind.SERVER_UNAVAILABLE] 语义结果。
     */
    suspend fun songUrl(request: SongUrlRequest): SongUrlAttempt

    /**
     * 获取云盘播放地址（本机 Rust 服务器 `/user/cloud/url`）。
     * 失败回退 `/song/url` 的决策由调用方（B 侧）负责。
     */
    suspend fun cloudUrl(request: CloudUrlRequest): CloudUrlAttempt
}

/**
 * `/song/url` 请求参数（对位 lite `getSongUrl` 入参，kugou_api_client.dart:1083-1099）。
 *
 * @param hash 歌曲 hash（song.id），实现侧保证以小写形式发送（lite :1094）。
 * @param quality API 码字符串：128/320/flac/high/viper_tape（对位
 *   [com.gracemusic.player.model.AudioQuality.value]，字符串透传给 Rust）。
 * @param albumId 专辑 id；非空才携带 `album_id` 参数（lite :1097）。
 * @param albumAudioId 专辑音频 id；非空才携带 `album_audio_id` 参数（lite :1098）。
 * @param downgrade HTTP 层失败后是否内部改 standard 重试一次（lite :1128-1136）。
 * @param ppageId 链后兜底传入 "356753938"（lite :1099；null 不携带）。
 */
data class SongUrlRequest(
    val hash: String,
    val quality: String,
    val albumId: String?,
    val albumAudioId: String?,
    val downgrade: Boolean,
    val ppageId: String? = null,
)

/** `/song/url` 单次解析结果（对位 lite `getSongUrl` 的三分类返回）。 */
sealed interface SongUrlAttempt {

    /**
     * 拿到可用播放地址。对位 lite 返回 `KugouPlayUrl`（fromJson 见
     * kugou_models.dart:779-820）。
     *
     * @param url CDN 播放地址（url / play_url 别名，List 取 first）。
     * @param quality 实际音质档（Rust 侧 stamp_quality 回写真实档；
     *   响应缺失时回退请求档 / '128'，见实现 KDoc）。
     * @param isTrial 试听片段标记：fail_process 含 'buy' 或
     *   0 < fileSize < 200KB（kugou_models.dart:792-803）。
     * @param fileSize 文件大小（fileSize/file_size/FileSize/filesize 别名，缺失 0）。
     * @param bitRate 码率（bitRate/bit_rate/BitRate/bitrate 别名，缺失 0）。
     * @param lufs 响度（volume / volume_lufs 别名；试听结果恒 null，
     *   对位 lite :1254-1260 试听构造不携带响度；真机 /song/url 常不返回响度，
     *   F-SRC-008 缓存常空属预期）。
     * @param peakDb 真峰值（volume_peak / volumePeak 别名；同 lufs 约定）。
     */
    data class Resolved(
        val url: String,
        val quality: String,
        val isTrial: Boolean,
        val fileSize: Long,
        val bitRate: Long,
        val lufs: Double?,
        val peakDb: Double?,
    ) : SongUrlAttempt

    /** 上游判死本档（无 url / buy 不降 / HTTP 层失败不再重试）→ 链继续。 */
    data object Unavailable : SongUrlAttempt

    /** 本地服务器层失败 → 整链中止。 */
    data class LocalFailure(val kind: LocalFailureKind) : SongUrlAttempt
}

/** 本地服务器失败种类（对位 lite `PlaybackUrlLocalFailure`，kugou_api_client.dart:44）。 */
enum class LocalFailureKind {

    /** 503 + `local_server_busy`：本机并发上限，稍后可重试（lite :381-391）。 */
    SERVER_BUSY,

    /** 回环连接类失败 / 就绪等待超时：本地服务器不可用（lite :362-366）。 */
    SERVER_UNAVAILABLE,
}

/**
 * `/user/cloud/url` 请求参数（对位 lite `getUserCloudUrl`，
 * kugou_api_client.dart:3553-3564；hash 即 song.id 原样透传、不小写）。
 *
 * @param hash 云盘文件 hash（song.id）。
 * @param albumId 专辑 id；非空才携带。
 * @param name 文件名（song.title）。
 * @param albumAudioId 专辑音频 id；非空才携带。
 */
data class CloudUrlRequest(
    val hash: String,
    val albumId: String?,
    val name: String,
    val albumAudioId: String?,
)

/** `/user/cloud/url` 结果（对位 lite `resolveCloudUrl`，player_provider.dart:3637-3678）。 */
sealed interface CloudUrlAttempt {

    /** 拿到云盘直链（data.url / data.play_url，List 取 first）。 */
    data class Resolved(val url: String) : CloudUrlAttempt

    /** 上游未给出直链（无 url / HTTP 层失败）→ 调用方回退 `/song/url`。 */
    data object Unavailable : CloudUrlAttempt

    /** 本地服务器层失败 → 整链中止（云盘先行分支同样不得回退）。 */
    data class LocalFailure(val kind: LocalFailureKind) : CloudUrlAttempt
}
