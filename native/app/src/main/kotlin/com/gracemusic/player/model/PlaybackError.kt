package com.gracemusic.player.model

import com.gracemusic.player.gate.shouldAutomaticallyRetryPlatformPlaybackError
import java.lang.reflect.Field
import java.lang.reflect.Method

/**
 * 播放失败的语义分类（T-P1-06 B1）。
 *
 * 台本要求恢复决策入口能区分「解析失败 / HTTP 网络错误 / 解码错误 / 音源失效 /
 * 超时 / 用户主动取消 / 引擎释放 / 内部错误」八类，并按类选恢复动作。本枚举即
 * 该分类词汇表，分类函数 [classifyPlaybackError] 为**纯函数**（只读入参、零 IO、
 * 零 Android 依赖），可被归约器与 Store 无副作用地调用。
 *
 * **不臆造**：只有拿到 media3 原始 `errorCode` / HTTP 状态码时才归入精确类别；
 * 拿不到（如解析失败只有文案）时按 [PlaybackErrorOrigin] 归入
 * [RESOLUTION_FAILED] 或兜底 [INTERNAL]，绝不含糊地当成可重试网络错误。
 */
enum class PlaybackErrorCategory {
    /** 音源解析失败（`SongUrlResolver` 拿不到可播放地址；无 platform errorCode）。 */
    RESOLUTION_FAILED,

    /** HTTP / 网络类瞬时错误（连接失败、超时、5xx、签名拒绝 401/403 等，可重解析）。 */
    HTTP_NETWORK,

    /** 超时（media3 `ERROR_CODE_TIMEOUT`）。 */
    TIMEOUT,

    /** 解码错误（解码器初始化/查询/解码失败，可有限重试）。 */
    DECODE,

    /** 音源失效（404/410、文件缺失、格式不受支持、DRM 等确定性不可重试问题）。 */
    SOURCE_INVALID,

    /** 需要登录（media3 `ERROR_CODE_AUTHENTICATION_EXPIRED` 等）。 */
    AUTHENTICATION_REQUIRED,

    /** 付费内容（media3 `ERROR_CODE_PREMIUM_ACCOUNT_REQUIRED`；听书 VIP 章节）。 */
    PAID_CONTENT,

    /** 用户主动取消 / 快速切歌中断（`INTERRUPTED_PLAYER_LOAD_ERROR_CODE`，良性信号）。 */
    USER_CANCELED,

    /** 引擎释放 / 会话断开（media3 `ERROR_CODE_DISCONNECTED`）。 */
    ENGINE_RELEASED,

    /** 内部/未知错误（无码或未归类码；保留有限重试，与 Dart 未知码策略一致）。 */
    INTERNAL,
}

/**
 * 失败来源——决定「解析失败」这一无平台错误码类别如何归类。
 *
 * - [ENGINE]：来自 [com.gracemusic.player.store.EngineListener.onError]（media3 引擎）；
 * - [RESOLUTION]：来自 `SongUrlResolver` 解析失败（无 platform errorCode，只有文案）。
 */
enum class PlaybackErrorOrigin {
    ENGINE,
    RESOLUTION,
}

/**
 * 一次播放失败的完整信息载体（T-P1-06 B1）。
 *
 * 设计选型说明：**用载体类型而非给 [com.gracemusic.player.store.EngineListener.onError]
 * 加参数**。理由：Kotlin 接口方法的默认参数要求实现方签名逐字一致，扩展形参会
 * 一次性打断所有既有实现（含测试假件），且后续再加字段会再次打断；载体类型把
 * 「文案 + 原始错误码 + 码名 + HTTP 状态码 + 来源 + 曲目身份」聚成一个可演进对象，
 * 签名稳定、调用点只多一个 `info.` 前缀。同时 `message` 仍是**已收敛文案**
 * （见 [safePlaybackErrorMessage]），原始异常细节绝不进入本对象。
 *
 * @property message 可展示文案（已收敛，无 URL/堆栈/Token）；空或 null 时归约器
 *   回落到兜底文案。
 * @property errorCode media3 `PlaybackException.errorCode`；拿不到为 null。
 * @property errorCodeName media3 `PlaybackException.getErrorCodeName()`；拿不到为 null。
 * @property httpStatusCode 从 cause 链提取的 HTTP 响应码；取不到为 null（不臆造）。
 * @property origin 失败来源（引擎 / 解析）。
 * @property songId 失败归属曲目 id（解析路径必填；引擎路径为 null——引擎错误
 *   无曲目身份，由 ErrorEventGate 的代次 + 粘性 loadCompleted 近似对账）。
 */
data class PlaybackErrorInfo(
    val message: String? = null,
    val errorCode: Int? = null,
    val errorCodeName: String? = null,
    val httpStatusCode: Int? = null,
    val origin: PlaybackErrorOrigin = PlaybackErrorOrigin.ENGINE,
    val songId: String? = null,
) {

    /**
     * 语义分类（纯函数派生属性，不参与 [PlaybackErrorInfo.equals]）。
     *
     * 放在派生属性而非构造参数：分类完全由原始字段决定，避免同一事实因构造方
     * 传入不同分类而产生不一致；也让载体本身保持「原始事实」的纯粹性。
     */
    val category: PlaybackErrorCategory
        get() = classifyPlaybackError(
            origin = origin,
            errorCode = errorCode,
            httpStatusCode = httpStatusCode,
        )

    companion object {

        /**
         * 解析失败载体（`SongUrlResolver` 失败路径）。
         *
         * @param songId 失败归属曲目 id——用于丢弃「切歌后旧曲的迟到失败」，
         *   防止其触发新曲的恢复动作。
         */
        fun resolutionFailure(message: String?, songId: String?): PlaybackErrorInfo =
            PlaybackErrorInfo(
                message = message,
                origin = PlaybackErrorOrigin.RESOLUTION,
                songId = songId,
            )
    }
}

// ───────────────────────── media3 PlaybackException 错误码镜像（零 Android 依赖） ─────────────────────────
//
// 逐值取自 androidx.media3.common.PlaybackException（1.4.1，javap 核验）：
// 与 PlaybackReducer 镜像 Player.STATE_* 的取向一致——归约/分类层不 import media3。

private const val ERROR_CODE_IO_UNSPECIFIED = 2000
private const val ERROR_CODE_IO_NETWORK_CONNECTION_FAILED = 2001
private const val ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT = 2002
private const val ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE = 2003
private const val ERROR_CODE_IO_BAD_HTTP_STATUS = 2004
private const val ERROR_CODE_IO_FILE_NOT_FOUND = 2005
private const val ERROR_CODE_IO_NO_PERMISSION = 2006
private const val ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED = 2007
private const val ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE = 2008

private const val ERROR_CODE_UNSPECIFIED = 1000
private const val ERROR_CODE_REMOTE_ERROR = 1001
private const val ERROR_CODE_BEHIND_LIVE_WINDOW = 1002
private const val ERROR_CODE_TIMEOUT = 1003
private const val ERROR_CODE_FAILED_RUNTIME_CHECK = 1004

private const val ERROR_CODE_PARSING_CONTAINER_MALFORMED = 3001
private const val ERROR_CODE_PARSING_MANIFEST_MALFORMED = 3002
private const val ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED = 3003
private const val ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED = 3004

private const val ERROR_CODE_DECODER_INIT_FAILED = 4001
private const val ERROR_CODE_DECODER_QUERY_FAILED = 4002
private const val ERROR_CODE_DECODING_FAILED = 4003
private const val ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES = 4004
private const val ERROR_CODE_DECODING_FORMAT_UNSUPPORTED = 4005
private const val ERROR_CODE_DECODING_RESOURCES_RECLAIMED = 4006

private const val ERROR_CODE_DISCONNECTED = -100
private const val ERROR_CODE_AUTHENTICATION_EXPIRED = -102
private const val ERROR_CODE_PREMIUM_ACCOUNT_REQUIRED = -103

/** 快速切歌中断码（与 `PlaybackErrorEventGate.INTERRUPTED_PLAYER_LOAD_ERROR_CODE` 同值）。 */
private const val INTERRUPTED_PLAYER_LOAD_ERROR_CODE = 10_000_000

/**
 * 纯分类函数：把原始错误码 / HTTP 状态码映射到 [PlaybackErrorCategory]。
 *
 * 判定顺序（先来源、再 HTTP、后平台码）：
 * 1. [PlaybackErrorOrigin.RESOLUTION] → [PlaybackErrorCategory.RESOLUTION_FAILED]；
 * 2. 切歌中断码 → [PlaybackErrorCategory.USER_CANCELED]（良性）；
 * 3. 认证/付费/断开类负码 → 对应类别；
 * 4. 有 HTTP 状态码时先按状态归类（404/410/400/422 → 音源失效；401/403/408/
 *    425/429/5xx → HTTP 网络）；
 * 5. 其余按 media3 平台码归类；未知码 → [PlaybackErrorCategory.INTERNAL]。
 *
 * 纯函数：无 IO、无 Android 依赖、同输入同输出。
 */
fun classifyPlaybackError(
    origin: PlaybackErrorOrigin,
    errorCode: Int?,
    httpStatusCode: Int?,
): PlaybackErrorCategory {
    if (origin == PlaybackErrorOrigin.RESOLUTION) {
        return PlaybackErrorCategory.RESOLUTION_FAILED
    }
    if (errorCode == INTERRUPTED_PLAYER_LOAD_ERROR_CODE) {
        return PlaybackErrorCategory.USER_CANCELED
    }
    when (errorCode) {
        ERROR_CODE_DISCONNECTED -> return PlaybackErrorCategory.ENGINE_RELEASED
        ERROR_CODE_AUTHENTICATION_EXPIRED -> return PlaybackErrorCategory.AUTHENTICATION_REQUIRED
        ERROR_CODE_PREMIUM_ACCOUNT_REQUIRED -> return PlaybackErrorCategory.PAID_CONTENT
    }
    // HTTP 状态码优先（能拿到时更精确）：与 classifyPlaybackSourceHttpFailure 分类表一致。
    when (httpStatusCode) {
        null -> Unit
        401, 403 -> return PlaybackErrorCategory.HTTP_NETWORK // 签名拒绝：可刷新链接
        404, 410 -> return PlaybackErrorCategory.SOURCE_INVALID
        408, 425, 429 -> return PlaybackErrorCategory.HTTP_NETWORK
        else -> {
            if (httpStatusCode >= 500) return PlaybackErrorCategory.HTTP_NETWORK
            if (httpStatusCode >= 400) return PlaybackErrorCategory.SOURCE_INVALID
        }
    }
    return when (errorCode) {
        null -> PlaybackErrorCategory.INTERNAL
        ERROR_CODE_TIMEOUT -> PlaybackErrorCategory.TIMEOUT
        ERROR_CODE_IO_UNSPECIFIED,
        ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE,
        ERROR_CODE_IO_BAD_HTTP_STATUS,
        // 文件缺失在 Dart 侧被列为「状态变化后可恢复」（playback_recovery_budget
        // 测试的保留重试清单含 2005），故归 HTTP 网络而非音源失效。
        ERROR_CODE_IO_FILE_NOT_FOUND,
        -> PlaybackErrorCategory.HTTP_NETWORK

        ERROR_CODE_IO_NO_PERMISSION,
        ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED,
        ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE,
        ERROR_CODE_PARSING_CONTAINER_MALFORMED,
        ERROR_CODE_PARSING_MANIFEST_MALFORMED,
        ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
        // 4004/4005 是「格式超出解码能力 / 格式不受支持」的确定性兼容问题
        // （shouldAutomaticallyRetryPlatformPlaybackError 明列不重试），
        // 归「音源失效」而非「解码错误」——重解析同一音源无法修复。
        ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
        -> PlaybackErrorCategory.SOURCE_INVALID

        ERROR_CODE_DECODER_INIT_FAILED,
        ERROR_CODE_DECODER_QUERY_FAILED,
        ERROR_CODE_DECODING_FAILED,
        ERROR_CODE_DECODING_RESOURCES_RECLAIMED,
        -> PlaybackErrorCategory.DECODE

        // 未知/其余码（含 1000/1001/1002/1004/5001-5004/DRM/自定义码）→ 内部错误。
        else -> PlaybackErrorCategory.INTERNAL
    }
}

/**
 * 失败 → 恢复动作（纯函数，T-P1-06 B1 的「每类到恢复动作映射」）。
 *
 * | 类别 | 动作 |
 * |---|---|
 * | [PlaybackErrorCategory.USER_CANCELED] / [PlaybackErrorCategory.ENGINE_RELEASED] | [IGNORE]（良性/无关） |
 * | [PlaybackErrorCategory.AUTHENTICATION_REQUIRED] / [PlaybackErrorCategory.PAID_CONTENT] | [STOP]（等待外部状态变化，不重试不跳） |
 * | [PlaybackErrorCategory.RESOLUTION_FAILED] | [SKIP]（自动跳下一首；见 B4） |
 * | [PlaybackErrorCategory.HTTP_NETWORK] / [PlaybackErrorCategory.TIMEOUT] | [RETRY]（预算内） |
 * | [PlaybackErrorCategory.DECODE] / [PlaybackErrorCategory.SOURCE_INVALID] / [PlaybackErrorCategory.INTERNAL] | 复用 [shouldAutomaticallyRetryPlatformPlaybackError]：可恢复 → [RETRY]，确定性/缺失 → [STOP] |
 *
 * 第 5 行**刻意复用**既有判定函数而非另写一套规则，保证与 Dart 的
 * `shouldAutomaticallyRetryPlatformPlaybackError`（3003/4004/4005 与 404/410/400/422
 * 阻断，其余保留重试）逐值一致。
 */
fun recoveryActionFor(info: PlaybackErrorInfo): PlaybackRecoveryAction = when (info.category) {
    PlaybackErrorCategory.USER_CANCELED,
    PlaybackErrorCategory.ENGINE_RELEASED,
    -> PlaybackRecoveryAction.IGNORE

    PlaybackErrorCategory.AUTHENTICATION_REQUIRED,
    PlaybackErrorCategory.PAID_CONTENT,
    -> PlaybackRecoveryAction.STOP

    PlaybackErrorCategory.RESOLUTION_FAILED -> PlaybackRecoveryAction.SKIP

    PlaybackErrorCategory.HTTP_NETWORK,
    PlaybackErrorCategory.TIMEOUT,
    -> PlaybackRecoveryAction.RETRY

    PlaybackErrorCategory.DECODE,
    PlaybackErrorCategory.SOURCE_INVALID,
    PlaybackErrorCategory.INTERNAL,
    -> if (
        shouldAutomaticallyRetryPlatformPlaybackError(
            isAndroid = true,
            errorCode = info.errorCode,
            httpStatusCode = info.httpStatusCode,
        )
    ) {
        PlaybackRecoveryAction.RETRY
    } else {
        PlaybackRecoveryAction.STOP
    }
}

/**
 * 恢复动作词汇表（见 [recoveryActionFor] 映射表）。
 *
 * - [IGNORE]：良性/无关，不做任何恢复；
 * - [STOP]：停止自动恢复（错误态保留，等待外部状态变化或用户操作）；
 * - [RETRY]：预算内重试（重新解析音源并重备）；
 * - [SKIP]：自动跳下一首（仅解析失败；边界见 B4）。
 */
enum class PlaybackRecoveryAction {
    IGNORE,
    STOP,
    RETRY,
    SKIP,
}

/**
 * 从异常 cause 链提取 HTTP 响应码；取不到返回 null（**不臆造**）。
 *
 * 为什么用反射而不是直接 import `HttpDataSource.InvalidResponseCodeException`：
 * `:app` 只声明了 media3-common / media3-decoder，media3-datasource 由
 * `:media3fork` 以 `implementation` 引入、不向消费者导出——直接引用会引入新的
 * 生产依赖（任务边界禁止）。反射只读、无副作用、失败即 null，符合「取不到就
 * null」的约束。
 *
 * 查找策略（逐层向上遍历 cause 链，最多 [MAX_CAUSE_DEPTH] 层防环）：
 * 1. 优先无参方法 `getResponseCode()`（返回 Int）；
 * 2. 退化到同名字段 `responseCode`（int）。
 */
fun extractHttpStatusCode(cause: Throwable?): Int? {
    var current = cause
    var depth = 0
    while (current != null && depth < MAX_CAUSE_DEPTH) {
        readResponseCode(current)?.let { return it }
        current = current.cause
        depth++
    }
    return null
}

private const val MAX_CAUSE_DEPTH = 8

private fun readResponseCode(throwable: Throwable): Int? {
    val type: Class<*> = throwable.javaClass
    val method: Method? = runCatching { type.getMethod("getResponseCode") }.getOrNull()
    if (method != null && method.parameterCount == 0 &&
        method.returnType == Int::class.javaPrimitiveType
    ) {
        val value = runCatching { method.invoke(throwable) as? Int }.getOrNull()
        if (value != null) return value
    }
    val field: Field? = runCatching { type.getField("responseCode") }.getOrNull()
    if (field != null && field.type == Int::class.javaPrimitiveType) {
        val value = runCatching { field.get(throwable) as? Int }.getOrNull()
        if (value != null) return value
    }
    return null
}
