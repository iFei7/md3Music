package com.gracemusic.data.net

/**
 * 登录/账号相关接口的统一结果（不抛业务异常）。
 *
 * 实现方 [com.gracemusic.data.net.OkHttpKugouAuthApi] 通过 OkHttp 访问
 * 本机 Rust 服务器的登录系列端点，语义对位 lite `kugou_api_client.dart`
 * 登录域（对位行号见各成员 KDoc）。判据等价于 lite 的 `_getAllowNonOk`
 * （kugou_api_client.dart:409-441）：**任何 HTTP 响应都尝试解析 body**
 * ——Rust 会把上游业务失败（如多账号 34175）包装成 HTTP 502，但 body
 * 仍带可用数据，丢弃即丢功能。
 *
 * 设计约束：
 * - 所有返回值均为 sealed 结果（不抛业务异常），协程取消仍以
 *   CancellationException 传播；
 * - [LoginAttempt.Failed.message] 一律经收敛处理（见实现的
 *   convergeMessage），绝不外泄 URL / token / 上游原始报文；
 * - [LoginData] / [LoginAccount] 的 toString 均脱敏（token 打码），
 *   可直接进日志。
 */
sealed interface LoginAttempt {

    /** 业务成功（HTTP 2xx 且未判死）。 */
    data class Success(val data: LoginData) : LoginAttempt

    /**
     * 多账号待选择（对位 lite 的 `error_code=34175`：Rust 把它包成 HTTP 502，
     * 但 body 里带 `data.info_list` 账号列表，必须读 body 而不是当失败）。
     *
     * 对位 lite kugou_provider.dart:1360-1381（loginByPhone 消费）与
     * :1449-1464（_parseLoginUserList 多键兜底 info_list/user_list/
     * userList/lists/list，userid 为空的条目过滤）。
     */
    data class AccountChoiceRequired(val accounts: List<LoginAccount>) : LoginAttempt

    /** 上游业务失败（token 失效 / 验证码错 / 二维码过期 等）。 */
    data class Failed(val errorCode: Int?, val message: String) : LoginAttempt

    /** 本地服务器层失败（忙 / 不可达）→ 调用方应稍后重试。 */
    data class LocalFailure(val kind: LocalFailureKind) : LoginAttempt
}

/**
 * 登录接口成功返回中已抽取的字段。
 *
 * toString 脱敏：token / vipToken / qrImage 一律打码 `***`（可空显示 `?`），
 * userid 保留明文（非敏感标识，且多账号选择回填需要）。
 */
data class LoginData(
    val token: String? = null,
    val userid: String? = null,
    val vipToken: String? = null,
    /** 二维码 base64 data URL（`/login/qr/create` 的 `qrimg`），可空。 */
    val qrImage: String? = null,
    /** 二维码 key / 微信 uuid（轮询句柄），可空。 */
    val handle: String? = null,
) {
    override fun toString(): String =
        "LoginData(token=${mask(token)}, userid=$userid, " +
            "vipToken=${mask(vipToken)}, qrImage=${mask(qrImage)}, handle=${mask(handle)})"

    private companion object {
        fun mask(value: String?): String = if (value == null) "?" else "***"
    }
}

/**
 * 多账号列表中的一项（对位 lite `KugouLoginAccount`，
 * kugou_models.dart:2373-2397；token / vipToken 为 native 契约增补——
 * 二次登录（loginByCellphone 带 userid）与凭据回填需要）。
 *
 * toString 脱敏：token / vipToken 打码 `***`（可空显示 `?`），
 * userid / nickname 保留明文。
 */
data class LoginAccount(
    val userid: String,
    val token: String? = null,
    val vipToken: String? = null,
    val nickname: String? = null,
) {
    override fun toString(): String =
        "LoginAccount(userid=$userid, token=${mask(token)}, " +
            "vipToken=${mask(vipToken)}, nickname=$nickname)"

    private companion object {
        fun mask(value: String?): String = if (value == null) "?" else "***"
    }
}

/**
 * 登录/账号接口契约：全部走本机 Rust 服务器（懒启动 + 就绪等待由实现侧
 * [com.gracemusic.data.net.OkHttpKugouAuthApi] 经 [KugouServerEndpoint]
 * 完成，对位 [OkHttpKugouApi] 的同款语义）。
 *
 * 请求一律 GET + query（对位 lite `_get` / `_getAllowNonOk` 形态）。
 */
interface KugouAuthApi {

    /**
     * 手机验证码登录。`/login/cellphone`，query: mobile / code[, userid]。
     *
     * lite 对位：kugou_api_client.dart:3296-3309（loginByCellphone，
     * 唯一使用 `_getAllowNonOk` 的登录入口）；Rust 路由：
     * kugou_api_server/rust/src/modules/login.rs:139（handle_cellphone）。
     *
     * 抽取：data.token / data.userid / data.vip_token；多账号场景
     * （error_code=34175）返回 [LoginAttempt.AccountChoiceRequired]，
     * 携带 userid 再次调用本方法即完成登录（对位 lite
     * loginByPhoneWithAccount，kugou_provider.dart:1394-1422）。
     */
    suspend fun loginByCellphone(mobile: String, code: String, userid: String? = null): LoginAttempt

    /**
     * 发送手机验证码。`/captcha/sent`，query: mobile。
     *
     * lite 对位：kugou_api_client.dart:3437-3442（sendCaptcha；注意
     * :3382-3387 的 sendLoginCaptcha 是同一端点的重复定义，本契约取
     * 其一）；Rust 路由：kugou_api_server/rust/src/modules/misc.rs:136
     * （handle_captcha_sent，透传上游 /v7/send_mobile_code）。
     *
     * 抽取：仅判业务状态（status==1），无 token 类字段。
     */
    suspend fun sendCaptcha(mobile: String): LoginAttempt

    /**
     * 生成扫码登录二维码。`/login/qr/create`，query: key / qrimg=true / timestamp。
     *
     * lite 对位：kugou_api_client.dart:3337-3353（createLoginQr）；
     * Rust 路由：kugou_api_server/rust/src/modules/login.rs:484
     * （handle_qr_create，本地生成 PNG data URL 返回 data.url /
     * data.base64）。
     *
     * key 参数由调用方用 `System.currentTimeMillis()` 生成——`/login/qr/key`
     * 在 lite 虽有独立接口（见 [qrKey]），但其语义只是向上游申请一个
     * key；native 契约选择客户端自生成时间戳 key，需要服务端签发时
     * 再调 [qrKey]。
     *
     * 抽取：data.base64（qrimg=true 时的 PNG data URL）→ [LoginData.qrImage]。
     */
    suspend fun createQrLogin(key: String): LoginAttempt

    /**
     * 查询扫码状态。`/login/qr/check`，query: key / timestamp。
     *
     * lite 对位：kugou_api_client.dart:3355-3369（checkLoginQr）；
     * Rust 路由：kugou_api_server/rust/src/modules/login.rs:439
     * （handle_qr_check，透传上游 /v2/get_userinfo_qrcode，status==4
     * 已确认时把 token / userid / vip_token 提升到 body）。
     *
     * 三态（按 body 判据）：status==4 → [LoginAttempt.Success]（带
     * token）；无成功证据且无 error_code → [LoginAttempt.Failed]
     * （errorCode=null，扫码前继续轮询）；带 error_code →
     * [LoginAttempt.Failed]（二维码过期等）。
     */
    suspend fun checkQrLogin(key: String): LoginAttempt

    /**
     * 生成酷狗扫码登录 key。`/login/qr/key`，query: timestamp。
     *
     * lite 对位：kugou_api_client.dart:3321-3335（getLoginQrKey——
     * lite 确有独立接口，非客户端自生成，故本契约保留本方法）；
     * Rust 路由：kugou_api_server/rust/src/modules/login.rs:506
     * （handle_qr_key，透传上游 /v2/qrcode）。
     *
     * 抽取：data.qrcode（key 字符串）→ [LoginData.handle]；
     * data.qrcode_img → [LoginData.qrImage]。
     */
    suspend fun qrKey(): LoginAttempt

    /**
     * 生成微信授权二维码。`/login/wx/create`。
     *
     * lite 对位：kugou_api_client.dart:3398-3400（createLoginWx）；
     * Rust 路由：kugou_api_server/rust/src/modules/login.rs:649
     * （handle_wx_create，上游换 ticket 后生成 uuid）。
     *
     * 抽取：data.uuid（uuid 兜底键 qrcode / key）→ [LoginData.handle]。
     */
    suspend fun createWxLogin(): LoginAttempt

    /**
     * 查询微信扫码状态。`/login/wx/check`，query: uuid / timestamp。
     *
     * lite 对位：kugou_api_client.dart:3403-3411（checkLoginWx）；
     * Rust 路由：kugou_api_server/rust/src/modules/login.rs:623
     * （handle_wx_check，透传微信长连接响应 body）。
     *
     * 抽取：与 [checkQrLogin] 同构（status==1 或 token 证据 → Success）。
     */
    suspend fun checkWxLogin(uuid: String): LoginAttempt

    /**
     * 微信 code 换 token。`/login/openplat`，query: code。
     *
     * lite 对位：kugou_api_client.dart:3390-3395（loginByOpenplat）；
     * Rust 路由：kugou_api_server/rust/src/modules/login.rs:332
     * （handle_openplat，POST /v6/login_by_openplat）。
     *
     * 抽取：data.token / data.userid / data.vip_token。
     */
    suspend fun loginByOpenplat(code: String): LoginAttempt

    /**
     * 刷新登录态。`/login/token`，query: token / userid。
     *
     * lite 对位：kugou_api_client.dart:3371-3379（refreshLogin；
     * 消费侧 _tryRefreshToken :3413-3435）；Rust 路由：
     * kugou_api_server/rust/src/modules/login.rs:523（handle_token）。
     *
     * 抽取：data.token / data.userid / data.vip_token。
     */
    suspend fun refreshLogin(token: String, userid: String): LoginAttempt

    /**
     * 读取当前登录用户资料（兼作令牌校验）。`/user/detail`。
     *
     * lite 对位：kugou_api_client.dart:3446-3468（getUserDetail，
     * 使用 `_getAllowNonOk` + noCache：Rust 偶发把上游业务错误包装为
     * HTTP 502 但 body 仍带 data 用户信息；业务失败时返回 null 由
     * 调用方按失败处理——native 侧即 [LoginAttempt.Failed]）；
     * 校验语义另见 :3470-3488（checkTokenValid / _isBizOk）；
     * Rust 路由：kugou_api_server/rust/src/modules/user.rs:499
     * （handle_detail），路由注册 mod.rs:122。
     *
     * 抽取：data.userid（nickname 等展示字段属 UI 层职责，不在网络契约内）。
     */
    suspend fun fetchUserDetail(): LoginAttempt
}
