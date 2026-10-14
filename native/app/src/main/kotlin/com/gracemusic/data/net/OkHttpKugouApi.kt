package com.gracemusic.data.net

import com.gracemusic.kugou.KugouServerManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 服务器就绪端口来源——[OkHttpKugouApi] 对 [KugouServerManager] 的收窄依赖面。
 *
 * 收窄为单方法函数接口的原因：KugouServerManager 是 final class 且持有
 * Mutex 状态机，无法在纯 JVM 测试中 fake；端口 seam 让 MockWebServer 直接
 * 冒充 Rust 服务器监听端口，生产装配仍走真 Manager（见
 * [ManagerKugouServerEndpoint]）。返回 null 表示服务器未就绪（调用方映射
 * [LocalFailureKind.SERVER_UNAVAILABLE]）。
 */
fun interface KugouServerEndpoint {

    /** 返回就绪服务器的监听端口；未就绪返回 null。 */
    suspend fun portOrNull(): Int?
}

/**
 * 生产装配的端口来源：包一层真 [KugouServerManager]。
 *
 * 懒启动语义（对位 lite 拦截器的 onServerNeeded——应用启动不预热，首次
 * API 请求才拉起服务器，Md3MusicApp 因此保持最小不动）：
 * 1. `ensureStarted()`：READY 幂等直返；STOPPED/FAILED 触发启动（单飞）；
 *    STARTING 加入在途启动。返回 >0 即就绪端口；
 * 2. 返回 0（FAILED / STOPPING 快速失败 / 启动尚未完成）→ 等待
 *    `status.first { isReady }`，上限 [readyTimeout]（默认 8s，对位 lite
 *    拦截器就绪等待），超时返回 null → 调用方报服务器不可用。
 *
 * @param readyTimeout 就绪等待上限（默认 8s；测试注入短时长验证超时路径）。
 */
class ManagerKugouServerEndpoint(
    private val manager: KugouServerManager,
    private val readyTimeout: Duration = DEFAULT_READY_WAIT,
) : KugouServerEndpoint {

    override suspend fun portOrNull(): Int? {
        val direct = manager.ensureStarted()
        if (direct > 0) return direct
        return try {
            withTimeout(readyTimeout) {
                manager.status.first { it.isReady }
            }.port.takeIf { it > 0 }
        } catch (e: TimeoutCancellationException) {
            // 外部取消抛的是普通 CancellationException，不会被此处误吞
            null
        }
    }

    companion object {
        /** 就绪等待上限（对位 lite 拦截器 8s）。 */
        val DEFAULT_READY_WAIT: Duration = 8.seconds
    }
}

/**
 * [KugouApi] 的 OkHttp 实现：GET 本机 Rust 服务器 `/song/url`、
 * `/user/cloud/url`，语义 1:1 对位 lite `kugou_api_client.dart`。
 *
 * ## 请求形态
 * - 路径逐段拼接（`addPathSegment("song") + addPathSegment("url")`）——
 *   整段 `"song/url"` 会被 URL 编码成 `/song%2Furl` 导致 404（台本 §1.2）；
 * - OkHttp 超时 connect 10s / read 15s；URL 不进日志（安全约束）。
 *
 * ## 单请求内重试矩阵（lite getSongUrl :1092-1265，20028/20018/VIP 通道不实现）
 * 1. 首发 HTTP 层失败（非 200 或 200 但 body 非 JSON 对象）且
 *    `downgrade=true` 且请求档非 standard → 改 `quality=128` 重试一次；
 * 2. `fail_process` 含 `buy` 且请求档非 standard → standard 重试一次
 *    （**先于 url 检查**，防试听 URL 抢跑；`downgrade=false` 直接判死）；
 *    该分支重试后仍无 url 直接判死，不再试听（lite :1220-1221）；
 * 3. 无 url → `free_part=1` 试听一次（native 恒非 VIP，lite :1236-1262）；
 *    试听沿用当前请求档（若已降级为 128 则用 128，lite 的 params 原地改写语义）。
 *
 * ## 解析（lite `KugouPlayUrl.fromJson`，kugou_models.dart:779-820）
 * - data 层缺失/为非对象时用根对象兜底（lite `_extractData`）；
 * - url / play_url 别名，List 取 first；quality 回写档缺失时回退请求档
 *   （主链路）/ '128'（试听与 buy 分支，fromJson 默认值）；
 * - isTrial = fail_process 含 'buy' 或 0 < fileSize < 200KB；
 * - 响度 volume/volume_lufs + volume_peak/volumePeak 别名（data 层优先）。
 *
 * ## 错误分流（lite `_get`/`_playbackLocalFailure` :316-391）
 * - 503 + `error=local_server_busy` + `retryable=true` → SERVER_BUSY（整链中止）；
 * - 回环连接类 IOException → SERVER_UNAVAILABLE（整链中止）；
 * - 其余（502/畸形 JSON/业务判死）→ Unavailable（链继续）；
 * - CancellationException 一律原样重抛。
 *
 * 已知限制：OkHttp 同步 execute 阻塞 IO 线程，协程取消后最多再阻塞至
 * read 超时（15s）才响应取消——对 45s 链总超时无正确性影响，仅为线程占用。
 *
 * @param endpoint 服务器就绪端口来源（生产走 [ManagerKugouServerEndpoint]）。
 * @param client HTTP 客户端（默认 10s/15s 超时；测试可注入）。
 */
class OkHttpKugouApi(
    private val endpoint: KugouServerEndpoint,
    private val client: OkHttpClient = DEFAULT_CLIENT,
) : KugouApi {

    /** 生产便捷构造：直接绑定真 KugouServerManager（DI 装配入口）。 */
    constructor(manager: KugouServerManager) : this(ManagerKugouServerEndpoint(manager))

    // ------------------------------------------------------------------
    // KugouApi
    // ------------------------------------------------------------------

    override suspend fun songUrl(request: SongUrlRequest): SongUrlAttempt {
        val port = endpoint.portOrNull()
            ?: return SongUrlAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE)

        // 首发（lite :1118-1138；hash 小写 :1094，album 参数非空才带 :1097-1098）
        var currentQuality = request.quality
        val firstJson = when (val outcome = execute(port, SONG_URL_SEGMENTS, songParams(request, currentQuality, freePart = false))) {
            is RawOutcome.Local -> return SongUrlAttempt.LocalFailure(outcome.kind)
            RawOutcome.HttpFailed -> {
                // HTTP 层失败 → standard 重试一次（lite :1124-1138）
                if (!request.downgrade || request.quality == QUALITY_STANDARD) {
                    return SongUrlAttempt.Unavailable
                }
                currentQuality = QUALITY_STANDARD
                when (val retry = execute(port, SONG_URL_SEGMENTS, songParams(request, QUALITY_STANDARD, freePart = false))) {
                    is RawOutcome.Local -> return SongUrlAttempt.LocalFailure(retry.kind)
                    RawOutcome.HttpFailed -> return SongUrlAttempt.Unavailable
                    is RawOutcome.Ok -> retry.json
                }
            }
            is RawOutcome.Ok -> outcome.json
        }

        val data = extractData(firstJson)

        // 20028 设备重注册 / 20018 token 刷新：native 无会话层（T-P2-07 登记）→ 判死
        // （lite :1143-1194 有会话层重试，本阶段登记偏离）
        if (data.long("errcode") == ERR_DEVICE_REREGISTER) return SongUrlAttempt.Unavailable
        if (data.long("status") == 2L && data.long("error_code") == ERR_TOKEN_REFRESH) {
            return SongUrlAttempt.Unavailable
        }

        // buy → standard 重试（先于 url 检查，lite :1196-1222）
        if (data.containsInList("fail_process", "buy") && request.quality != QUALITY_STANDARD) {
            if (!request.downgrade) return SongUrlAttempt.Unavailable
            val retry = execute(port, SONG_URL_SEGMENTS, songParams(request, QUALITY_STANDARD, freePart = false))
            val fallbackData = when (retry) {
                is RawOutcome.Local -> return SongUrlAttempt.LocalFailure(retry.kind)
                RawOutcome.HttpFailed -> return SongUrlAttempt.Unavailable
                is RawOutcome.Ok -> extractData(retry.json)
            }
            val fallbackUrl = firstUrl(fallbackData) ?: return SongUrlAttempt.Unavailable
            return SongUrlAttempt.Resolved(
                url = fallbackUrl,
                quality = fallbackData.string("quality") ?: QUALITY_STANDARD,
                isTrial = isTrial(fallbackData),
                fileSize = firstLong(fallbackData, FILE_SIZE_KEYS),
                bitRate = firstLong(fallbackData, BIT_RATE_KEYS),
                lufs = loudness(firstJson, fallbackData, LUFS_KEYS),
                peakDb = loudness(firstJson, fallbackData, PEAK_KEYS),
            )
        }

        // url 检查（lite :1224-1234）
        val url = firstUrl(data)
        if (url != null) {
            return SongUrlAttempt.Resolved(
                url = url,
                quality = data.string("quality") ?: request.quality,
                isTrial = isTrial(data),
                fileSize = firstLong(data, FILE_SIZE_KEYS),
                bitRate = firstLong(data, BIT_RATE_KEYS),
                lufs = loudness(firstJson, data, LUFS_KEYS),
                peakDb = loudness(firstJson, data, PEAK_KEYS),
            )
        }

        // 无 url → free_part=1 试听一次（恒非 VIP，lite :1236-1262）
        val trial = execute(port, SONG_URL_SEGMENTS, songParams(request, currentQuality, freePart = true))
        val trialData = when (trial) {
            is RawOutcome.Local -> return SongUrlAttempt.LocalFailure(trial.kind)
            RawOutcome.HttpFailed -> return SongUrlAttempt.Unavailable
            is RawOutcome.Ok -> extractData(trial.json)
        }
        val trialUrl = firstUrl(trialData) ?: return SongUrlAttempt.Unavailable
        return SongUrlAttempt.Resolved(
            url = trialUrl,
            quality = trialData.string("quality") ?: QUALITY_STANDARD,
            isTrial = true,
            fileSize = firstLong(trialData, FILE_SIZE_KEYS),
            bitRate = firstLong(trialData, BIT_RATE_KEYS),
            // lite :1254-1260 试听构造不携带响度字段
            lufs = null,
            peakDb = null,
        )
    }

    override suspend fun cloudUrl(request: CloudUrlRequest): CloudUrlAttempt {
        val port = endpoint.portOrNull()
            ?: return CloudUrlAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE)

        val params = buildList {
            add("hash" to request.hash)
            if (!request.albumId.isNullOrEmpty()) add("album_id" to request.albumId)
            if (request.name.isNotEmpty()) add("name" to request.name)
            if (!request.albumAudioId.isNullOrEmpty()) add("album_audio_id" to request.albumAudioId)
        }
        return when (val outcome = execute(port, CLOUD_URL_SEGMENTS, params)) {
            is RawOutcome.Local -> CloudUrlAttempt.LocalFailure(outcome.kind)
            RawOutcome.HttpFailed -> CloudUrlAttempt.Unavailable
            is RawOutcome.Ok -> {
                val url = firstUrl(extractData(outcome.json))
                if (url != null) CloudUrlAttempt.Resolved(url) else CloudUrlAttempt.Unavailable
            }
        }
    }

    // ------------------------------------------------------------------
    // HTTP 执行
    // ------------------------------------------------------------------

    /**
     * 单次 GET。分类：
     * - 200 且 body 为 JSON 对象 → [RawOutcome.Ok]；
     * - 503 + local_server_busy → [RawOutcome.Local]（SERVER_BUSY）；
     * - 其余非 200 / 200 但 body 非 JSON 对象 → [RawOutcome.HttpFailed]（可降级重试）；
     * - 连接类 IOException → [RawOutcome.Local]（SERVER_UNAVAILABLE）。
     */
    private suspend fun execute(
        port: Int,
        pathSegments: List<String>,
        params: List<Pair<String, String>>,
    ): RawOutcome {
        val url: HttpUrl = HttpUrl.Builder()
            .scheme("http")
            .host("127.0.0.1")
            .port(port)
            .apply {
                pathSegments.forEach { addPathSegment(it) }
                params.forEach { (name, value) -> addQueryParameter(name, value) }
            }
            .build()
        val httpRequest = Request.Builder().url(url).get().build()
        return try {
            withContext(Dispatchers.IO) {
                client.newCall(httpRequest).execute().use { response ->
                    val body = response.body?.string().orEmpty()
                    if (response.code != HTTP_OK) {
                        busyKind(body)?.let { RawOutcome.Local(it) } ?: RawOutcome.HttpFailed
                    } else {
                        parseJsonObject(body)?.let { RawOutcome.Ok(it) } ?: RawOutcome.HttpFailed
                    }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: java.io.IOException) {
            // 回环连接类失败（拒绝连接/读超时等，对位 lite :362-366 local uri 判定）
            RawOutcome.Local(LocalFailureKind.SERVER_UNAVAILABLE)
        }
    }

    /** 503 + `error=local_server_busy` + `retryable=true` → SERVER_BUSY（lite :381-391）。 */
    private fun busyKind(body: String): LocalFailureKind? {
        val json = parseJsonObject(body) ?: return null
        val isBusy = json.string("error") == "local_server_busy" &&
            json.element("retryable")?.let { (it as? JsonPrimitive)?.booleanOrNull } == true
        return if (isBusy) LocalFailureKind.SERVER_BUSY else null
    }

    /** 请求参数组装（hash 小写、quality 字符串透传、album 参数非空才带）。 */
    private fun songParams(
        request: SongUrlRequest,
        quality: String,
        freePart: Boolean,
    ): List<Pair<String, String>> = buildList {
        add("hash" to request.hash.lowercase())
        add("quality" to quality)
        if (!request.albumId.isNullOrEmpty()) add("album_id" to request.albumId)
        if (!request.albumAudioId.isNullOrEmpty()) add("album_audio_id" to request.albumAudioId)
        request.ppageId?.let { add("ppage_id" to it) }
        if (freePart) add("free_part" to "1")
    }

    // ------------------------------------------------------------------
    // JSON 手工导航（kotlinx.serialization，畸形输入一律返回 null / 0 不崩溃）
    // ------------------------------------------------------------------

    /**
     * data 层提取（lite `_extractData` :1074-1081）：有 data 用 data
     * （对象直用 / 数组取首个对象），无 data（缺失或 JSON null）用根。
     */
    private fun extractData(root: JsonObject): JsonObject = when (val candidate = root["data"]) {
        null, is JsonNull -> root
        is JsonObject -> candidate
        is JsonArray -> (candidate.firstOrNull() as? JsonObject) ?: JsonObject(emptyMap())
        else -> JsonObject(emptyMap())
    }

    /** url / play_url 别名取首个非空地址：字符串非空，或数组取首个非空元素。 */
    private fun firstUrl(data: JsonObject): String? =
        URL_KEYS.firstNotNullOfOrNull { key -> firstNonBlankString(data[key]) }

    private fun firstNonBlankString(element: JsonElement?): String? = when (element) {
        null, is JsonNull -> null
        is JsonArray -> element.firstNotNullOfOrNull { firstNonBlankString(it) }
        is JsonPrimitive -> element.content.takeIf { it.isNotBlank() }
        else -> null
    }

    /** isTrial 双条件：fail_process 含 'buy' 或 0 < fileSize < 200KB（kugou_models.dart:792-803）。 */
    private fun isTrial(data: JsonObject): Boolean {
        val fileSize = firstLong(data, FILE_SIZE_KEYS)
        return data.containsInList("fail_process", "buy") ||
            (fileSize > 0 && fileSize < TRIAL_FILE_SIZE_LIMIT)
    }

    /** 响度解析：主别名优先于次别名，data 层优先于根（lite 合并 map 语义 :780-784）。 */
    private fun loudness(root: JsonObject, data: JsonObject, keys: Pair<String, String>): Double? {
        val (primary, secondary) = keys
        val value = data.double(primary)
            ?: root.double(primary)
            ?: data.double(secondary)
            ?: root.double(secondary)
        return value?.takeIf { it.isFinite() }
    }

    private fun JsonObject.element(key: String): JsonElement? {
        val value = this[key]
        return if (value == null || value is JsonNull) null else value
    }

    private fun JsonObject.string(key: String): String? {
        val primitive = element(key) as? JsonPrimitive ?: return null
        return primitive.content.takeIf { it.isNotBlank() }
    }

    /** 数字字段解析：数值直取，数值字符串宽容解析（对位 Dart _parseInt/_optDouble）。 */
    private fun JsonObject.long(key: String): Long? {
        val primitive = element(key) as? JsonPrimitive ?: return null
        return primitive.longOrNull ?: primitive.content.toLongOrNull()
    }

    private fun JsonObject.double(key: String): Double? {
        val primitive = element(key) as? JsonPrimitive ?: return null
        return primitive.doubleOrNull ?: primitive.content.toDoubleOrNull()
    }

    private fun firstLong(data: JsonObject, keys: List<String>): Long =
        keys.firstNotNullOfOrNull { data.long(it) } ?: 0L

    /** fail_process 数组是否含指定标记（非数组形态视为不含）。 */
    private fun JsonObject.containsInList(key: String, marker: String): Boolean {
        val array = element(key) as? JsonArray ?: return false
        return array.any { (it as? JsonPrimitive)?.content == marker }
    }

    private fun parseJsonObject(body: String): JsonObject? = try {
        Json.parseToJsonElement(body) as? JsonObject
    } catch (e: SerializationException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }

    /** 单次 HTTP 的原始分类（内部使用，不外泄）。 */
    private sealed interface RawOutcome {

        /** 200 且 body 为 JSON 对象。 */
        data class Ok(val json: JsonObject) : RawOutcome

        /** 非 200（非 busy）或 body 非 JSON 对象 → HTTP 层失败，可降级重试。 */
        data object HttpFailed : RawOutcome

        /** 本地服务器层失败（整链中止）。 */
        data class Local(val kind: LocalFailureKind) : RawOutcome
    }

    private companion object {
        const val QUALITY_STANDARD = "128"
        const val HTTP_OK = 200

        /** 试听片段大小上限：0 < fileSize < 200KB（kugou_models.dart:793）。 */
        const val TRIAL_FILE_SIZE_LIMIT: Long = 200L * 1024

        /** 设备需重注册（native 无会话层 → 判死，登记偏离）。 */
        const val ERR_DEVICE_REREGISTER = 20028L

        /** token 需刷新（同上）。 */
        const val ERR_TOKEN_REFRESH = 20018L

        val SONG_URL_SEGMENTS = listOf("song", "url")
        val CLOUD_URL_SEGMENTS = listOf("user", "cloud", "url")
        val URL_KEYS = listOf("url", "play_url")
        val FILE_SIZE_KEYS = listOf("fileSize", "file_size", "FileSize", "filesize")
        val BIT_RATE_KEYS = listOf("bitRate", "bit_rate", "BitRate", "bitrate")
        val LUFS_KEYS = "volume" to "volume_lufs"
        val PEAK_KEYS = "volume_peak" to "volumePeak"

        val DEFAULT_CLIENT: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
            .readTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
            .build()
    }
}
