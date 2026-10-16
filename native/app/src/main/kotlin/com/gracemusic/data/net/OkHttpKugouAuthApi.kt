package com.gracemusic.data.net

import com.gracemusic.player.model.safePlaybackErrorMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * [KugouAuthApi] 的 OkHttp 实现：GET 本机 Rust 服务器登录系列端点
 * （`/login` 系列、`/captcha/sent`、`/user/detail`），语义对位 lite
 * `kugou_api_client.dart` 登录域与 kugou_api_server/rust 对应模块
 * （各方法 KDoc 见 [KugouAuthApi]）。
 *
 * ## 请求形态（同 [OkHttpKugouApi]）
 * - 路径逐段拼接（`addPathSegment`）——整段 `"login/cellphone"` 会被
 *   URL 编码成 `%2F` 导致 404；
 * - OkHttp 超时 connect 10s / read 15s；URL 不进日志（安全约束）。
 *
 * ## `_getAllowNonOk` 等价语义（对位 lite kugou_api_client.dart:409-441）
 * **任何 HTTP 响应都尝试解析 body**——Rust 会把上游业务失败（多账号
 * 34175、偶发业务包装 502 等）放在非 2xx 响应里，丢弃 body 即丢功能。
 * 只有 503 + local_server_busy（[busyKind]）与连接类 IOException 才归
 * [LoginAttempt.LocalFailure]。
 *
 * ## body 判据优先级（classify，显式函数）
 * 1. `error_code == 34175` → [LoginAttempt.AccountChoiceRequired]
 *    （特判先于一切，空列表也判多账号，不得退化为 Failed）；
 * 2. `data.info_list`（含 userid 的条目）→ [LoginAttempt.AccountChoiceRequired]；
 * 3. 成功证据（data/顶层 token、userid 或 status==1 / status==4 或
 *    code==200 或二维码句柄证据）→ [LoginAttempt.Success]；
 * 4. `error_code` 非 0 → [LoginAttempt.Failed]（文案经 [convergeMessage]
 *    收敛，绝不外泄 URL / token / 上游原始报文）；
 * 5. 其余（解析失败 / 无证据无错误码）→ [LoginAttempt.Failed] 兜底文案。
 *
 * ## 协程取消
 * CancellationException 一律原样重抛（不伪装成 Failed）。
 *
 * 已知限制：OkHttp 同步 execute 阻塞 IO 线程，协程取消后最多再阻塞至
 * read 超时（15s）才响应取消——对 UI 交互无正确性影响，仅为线程占用
 * （同 [OkHttpKugouApi] 登记）。
 *
 * @param endpoint 服务器就绪端口来源（生产走 [ManagerKugouServerEndpoint]）。
 * @param client HTTP 客户端（默认 10s/15s 超时；测试可注入）。
 */
class OkHttpKugouAuthApi(
    private val endpoint: KugouServerEndpoint,
    private val client: OkHttpClient = DEFAULT_CLIENT,
) : KugouAuthApi {

    // ------------------------------------------------------------------
    // KugouAuthApi
    // ------------------------------------------------------------------

    override suspend fun loginByCellphone(mobile: String, code: String, userid: String?): LoginAttempt =
        attempt(LOGIN_CELLPHONE_SEGMENTS, buildList {
            add("mobile" to mobile)
            add("code" to code)
            if (!userid.isNullOrEmpty()) add("userid" to userid)
        })

    override suspend fun sendCaptcha(mobile: String): LoginAttempt =
        attempt(CAPTCHA_SENT_SEGMENTS, listOf("mobile" to mobile))

    override suspend fun createQrLogin(key: String): LoginAttempt =
        attempt(LOGIN_QR_CREATE_SEGMENTS, listOf("key" to key, "qrimg" to "true") + timestampParam())

    override suspend fun checkQrLogin(key: String): LoginAttempt =
        attempt(LOGIN_QR_CHECK_SEGMENTS, listOf("key" to key) + timestampParam())

    override suspend fun qrKey(): LoginAttempt =
        attempt(LOGIN_QR_KEY_SEGMENTS, timestampParam())

    override suspend fun createWxLogin(): LoginAttempt =
        attempt(LOGIN_WX_CREATE_SEGMENTS, emptyList())

    override suspend fun checkWxLogin(uuid: String): LoginAttempt =
        attempt(LOGIN_WX_CHECK_SEGMENTS, listOf("uuid" to uuid) + timestampParam())

    override suspend fun loginByOpenplat(code: String): LoginAttempt =
        attempt(LOGIN_OPENPLAT_SEGMENTS, listOf("code" to code))

    override suspend fun refreshLogin(token: String, userid: String): LoginAttempt =
        attempt(LOGIN_TOKEN_SEGMENTS, listOf("token" to token, "userid" to userid))

    override suspend fun fetchUserDetail(): LoginAttempt =
        attempt(USER_DETAIL_SEGMENTS, emptyList())

    // ------------------------------------------------------------------
    // 单请求执行
    // ------------------------------------------------------------------

    /**
     * 端口探测 → GET → 分类。失败分层：
     * - 端口未就绪 / 连接类 IOException → [LoginAttempt.LocalFailure]；
     * - 503 + local_server_busy → [LoginAttempt.LocalFailure]（SERVER_BUSY）；
     * - 其余（含非 2xx 但 body 可解析的 `_getAllowNonOk` 语义）→ [classify]。
     */
    private suspend fun attempt(
        pathSegments: List<String>,
        params: List<Pair<String, String>>,
    ): LoginAttempt {
        val port = endpoint.portOrNull()
            ?: return LoginAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE)

        return when (val outcome = execute(port, pathSegments, params)) {
            is RawOutcome.Local -> LoginAttempt.LocalFailure(outcome.kind)
            is RawOutcome.Ok -> classify(outcome.body)
        }
    }

    /**
     * 单次 GET。分类：
     * - 连接类 IOException（拒绝连接 / 读超时等）→ [RawOutcome.Local]
     *   （SERVER_UNAVAILABLE，对位 lite :362-366 local uri 判定）；
     * - 503 + local_server_busy + retryable=true → [RawOutcome.Local]
     *   （SERVER_BUSY，对位 lite :381-391）；
     * - 其余任何状态码 → [RawOutcome.Ok]（body 原文，交由 [classify]
     *   按 `_getAllowNonOk` 语义解析——非 2xx 也可能是 34175 / 业务包装）。
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
                    if (response.code == HTTP_BUSY_STATUS) {
                        busyKind(body)?.let { RawOutcome.Local(it) } ?: RawOutcome.Ok(body)
                    } else {
                        RawOutcome.Ok(body)
                    }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: java.io.IOException) {
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

    // ------------------------------------------------------------------
    // body 判据（_getAllowNonOk 等价语义）
    // ------------------------------------------------------------------

    /**
     * body 分类（判据优先级见类 KDoc §body 判据优先级）。
     *
     * 成功判据综合 lite `_isBizOk`（kugou_api_client.dart:3482-3488：
     * error_code 为 0 或缺失且 status 为 1 或缺失）与 Rust 特殊状态
     * （qr_check status==4 已确认，login.rs:451；qr_create code==200，
     * login.rs:494）。
     */
    private fun classify(body: String): LoginAttempt {
        val json = parseJsonObject(body) ?: return LoginAttempt.Failed(null, FALLBACK_MESSAGE)
        val data = extractData(json)
        val errorCode = json.long("error_code") ?: data.long("error_code")

        // 1) 34175 多账号特判（先于一切，空列表同样判多账号）
        if (errorCode == ERR_MULTI_ACCOUNT) {
            return LoginAttempt.AccountChoiceRequired(parseAccounts(data))
        }
        // 2) info_list 兜底键非空 → 多账号（对位 lite _parseLoginUserList :1449-1464）
        parseAccounts(data).takeIf { it.isNotEmpty() }
            ?.let { return LoginAttempt.AccountChoiceRequired(it) }

        // 3) 成功证据
        val token = data.string("token") ?: json.string("token")
        val userid = data.string("userid") ?: data.string("user_id") ?: json.string("userid")
        val vipToken = data.string("vip_token") ?: json.string("vip_token")
        val status = data.long("status") ?: json.long("status")
        val qrImage = firstOfKeys(data, QR_IMAGE_KEYS) ?: firstOfKeys(json, QR_IMAGE_KEYS)
        val handle = firstOfKeys(data, HANDLE_KEYS) ?: firstOfKeys(json, HANDLE_KEYS)
        val hasSuccessEvidence = token != null || userid != null ||
            status == STATUS_OK || status == STATUS_QR_CONFIRMED ||
            json.long("code") == HTTP_OK.toLong() ||
            qrImage != null || handle != null
        if (hasSuccessEvidence) {
            return LoginAttempt.Success(
                LoginData(token = token, userid = userid, vipToken = vipToken, qrImage = qrImage, handle = handle),
            )
        }

        // 4) 有错误码（非 0 非 34175）→ Failed，文案收敛
        if (errorCode != null && errorCode != 0L) {
            val rawMessage = data.string("error_msg") ?: json.string("error_msg")
                ?: json.string("msg") ?: data.string("msg")
            return LoginAttempt.Failed(errorCode.toInt(), convergeMessage(rawMessage))
        }
        // 5) 无证据无错误码（含畸形 body）→ 兜底
        return LoginAttempt.Failed(null, FALLBACK_MESSAGE)
    }

    /**
     * 多账号列表解析：info_list / user_list / userList / lists / list
     * 兜底键（对位 lite kugou_provider.dart:1449-1464），userid 为空的
     * 条目过滤。
     */
    private fun parseAccounts(data: JsonObject): List<LoginAccount> {
        val raw = ACCOUNT_LIST_KEYS.firstNotNullOfOrNull { key -> data.element(key) as? JsonArray }
            ?: return emptyList()
        return raw.mapNotNull { element ->
            val obj = element as? JsonObject ?: return@mapNotNull null
            val userid = obj.string("userid") ?: obj.string("user_id")
                ?: obj.string("userId") ?: obj.string("id")
            userid?.let {
                LoginAccount(
                    userid = it,
                    token = obj.string("token"),
                    vipToken = obj.string("vip_token"),
                    nickname = obj.string("nickname") ?: obj.string("user_name") ?: obj.string("name"),
                )
            }
        }
    }

    /**
     * 失败文案收敛：经 [safePlaybackErrorMessage] 折叠（未知串一律折叠，
     * 绝不外泄 URL / token / 上游原始报文）；播放兜底值在登录域无意义，
     * 替换为登录兜底文案——等价收敛（同样「未知串折叠」的安全性质）。
     */
    private fun convergeMessage(errorMsg: String?): String {
        val raw = errorMsg?.takeIf { it.isNotBlank() } ?: return FALLBACK_MESSAGE
        val converged = safePlaybackErrorMessage(raw) ?: return FALLBACK_MESSAGE
        return if (converged == PLAYBACK_FALLBACK) FALLBACK_MESSAGE else converged
    }

    private fun timestampParam(): List<Pair<String, String>> =
        listOf("timestamp" to System.currentTimeMillis().toString())

    // ------------------------------------------------------------------
    // JSON 手工导航（kotlinx.serialization，畸形输入一律返回 null 不崩溃）
    // ------------------------------------------------------------------

    /**
     * data 层提取（lite `_extractData`）：有 data 用 data（对象直用 /
     * 数组取首个对象），无 data（缺失或 JSON null）用根——微信轮询等
     * 透传响应无 data 层，必须回根。
     */
    private fun extractData(root: JsonObject): JsonObject = when (val candidate = root["data"]) {
        null, is JsonNull -> root
        is JsonObject -> candidate
        is JsonArray -> (candidate.firstOrNull() as? JsonObject) ?: JsonObject(emptyMap())
        else -> JsonObject(emptyMap())
    }

    private fun JsonObject.element(key: String): JsonElement? {
        val value = this[key]
        return if (value == null || value is JsonNull) null else value
    }

    private fun JsonObject.string(key: String): String? {
        val primitive = element(key) as? JsonPrimitive ?: return null
        return primitive.content.takeIf { it.isNotBlank() }
    }

    private fun JsonObject.long(key: String): Long? {
        val primitive = element(key) as? JsonPrimitive ?: return null
        return primitive.longOrNull
    }

    /** 多键兜底取首个非空字符串（值经 string 校验非空白）。 */
    private fun firstOfKeys(json: JsonObject, keys: List<String>): String? =
        keys.firstNotNullOfOrNull { json.string(it) }

    private fun parseJsonObject(body: String): JsonObject? = try {
        Json.parseToJsonElement(body) as? JsonObject
    } catch (e: SerializationException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }

    /** 单次 HTTP 的原始分类（内部使用，不外泄）。 */
    private sealed interface RawOutcome {

        /** 任何非忙状态的响应（含非 2xx 的业务包装，body 待 [classify]）。 */
        data class Ok(val body: String) : RawOutcome

        /** 本地服务器层失败（整请求中止）。 */
        data class Local(val kind: LocalFailureKind) : RawOutcome
    }

    private companion object {
        /** 登录失败兜底文案（经收敛后；不含 URL / token / 上游细节）。 */
        const val FALLBACK_MESSAGE = "登录失败，请重试"

        /** safePlaybackErrorMessage 的播放兜底值（收敛后在登录域替换为 FALLBACK_MESSAGE）。 */
        const val PLAYBACK_FALLBACK = "播放失败，请重试"

        /** 通用业务成功状态（lite _isBizOk :3482-3488）。 */
        const val STATUS_OK = 1L

        /** 扫码已确认状态（Rust login.rs:451 status==4）。 */
        const val STATUS_QR_CONFIRMED = 4L

        /** 多账号待选择错误码（lite kugou_provider.dart:1374）。 */
        const val ERR_MULTI_ACCOUNT = 34175L

        /** busy 判据的状态码（lite :381-391）。 */
        const val HTTP_BUSY_STATUS = 503

        /** HTTP OK（classify 成功证据 code==200 用）。 */
        const val HTTP_OK = 200

        val LOGIN_CELLPHONE_SEGMENTS = listOf("login", "cellphone")
        val CAPTCHA_SENT_SEGMENTS = listOf("captcha", "sent")
        val LOGIN_QR_KEY_SEGMENTS = listOf("login", "qr", "key")
        val LOGIN_QR_CREATE_SEGMENTS = listOf("login", "qr", "create")
        val LOGIN_QR_CHECK_SEGMENTS = listOf("login", "qr", "check")
        val LOGIN_WX_CREATE_SEGMENTS = listOf("login", "wx", "create")
        val LOGIN_WX_CHECK_SEGMENTS = listOf("login", "wx", "check")
        val LOGIN_OPENPLAT_SEGMENTS = listOf("login", "openplat")
        val LOGIN_TOKEN_SEGMENTS = listOf("login", "token")
        val USER_DETAIL_SEGMENTS = listOf("user", "detail")

        /** 多账号列表兜底键（对位 lite kugou_provider.dart:1452-1457）。 */
        val ACCOUNT_LIST_KEYS = listOf("info_list", "user_list", "userList", "lists", "list")

        /** 二维码图片兜底键（Rust qr_create 返回 base64，login.rs:496；qrimg 为 query 名）。 */
        val QR_IMAGE_KEYS = listOf("base64", "qrimg", "qrcode_img", "qr_img")

        /** 轮询句柄兜底键（qr_key 的 qrcode、wx_create 的 uuid）。 */
        val HANDLE_KEYS = listOf("qrcode", "uuid", "key")

        val DEFAULT_CLIENT: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
            .readTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
            .build()
    }
}
