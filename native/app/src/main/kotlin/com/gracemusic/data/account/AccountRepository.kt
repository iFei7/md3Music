package com.gracemusic.data.account

import com.gracemusic.data.net.AuthHeaderProvider
import com.gracemusic.data.net.KugouAuthApi
import com.gracemusic.data.net.LoginAccount
import com.gracemusic.data.net.LoginAttempt
import com.gracemusic.data.net.LoginData
import com.gracemusic.data.secure.KugouCredentials
import com.gracemusic.data.secure.TokenStore
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 登录态状态机（账号仓库的对外状态面，UDF 的单一数据源）。
 *
 * 迁移图：
 * ```
 *                    ┌────────────────┐
 *        初始/登出 ──►│   LoggedOut    │◄──── 刷新失败/注销/恢复无凭证
 *                    └───────┬────────┘
 *            登录成功/选择账号/扫码确认/恢复有凭证
 *                    ┌───────▼────────┐
 *                    │   LoggedIn     │
 *                    └───────┬────────┘
 *                     refresh() 进入
 *                    ┌───────▼────────┐
 *                    │   Refreshing   │──成功──► LoggedIn（新凭证）
 *                    └───────────────┘──失败──► LoggedOut（清凭证）
 * ```
 */
sealed interface AuthState {

    /** 未登录（初始态 / 登出 / 会话失效）。 */
    data object LoggedOut : AuthState

    /**
     * 已登录。
     *
     * @param userid 当前账号（与 TokenStore 当前账号一致）。
     * @param nickname 昵称（仅多账号选择时可得；其余流程为 null——
     *   展示字段属 UI 层职责，见 KugouAuthApi.fetchUserDetail KDoc）。
     */
    data class LoggedIn(val userid: String, val nickname: String?) : AuthState

    /** 刷新中（[AccountRepository.refresh] 进行中；失败即登出）。 */
    data object Refreshing : AuthState
}

/**
 * 登录编排结果（不抛业务异常；协程取消仍以 CancellationException 传播）。
 *
 * - [Success]：登录成功且凭证已落盘；
 * - [NeedAccountChoice]：一个手机号绑定多账号，需用户选择后调
 *   [AccountRepository.chooseAccount]；
 * - [Failed]：上游/业务失败（验证码错、二维码过期等；`errorCode` 透传
 *   上游错误码，可空）；
 * - [LocalRetry]：本地服务器层失败或轮询等待态，调用方稍后重试/继续轮询。
 */
sealed interface LoginResult {

    data object Success : LoginResult

    data class NeedAccountChoice(val accounts: List<LoginAccount>) : LoginResult

    data class Failed(val message: String, val errorCode: Int? = null) : LoginResult

    data object LocalRetry : LoginResult
}

/**
 * 扫码登录会话（酷狗二维码）：[key] 为轮询句柄（仓库生成的时间戳），
 * [qrImage] 为二维码 data URL（可进 UI 展示），[handle] 为服务端返回的
 * 附加句柄（透传，暂仅记录）。
 */
data class QrLoginSession(
    val key: String,
    val qrImage: String?,
    val handle: String?,
)

/**
 * 微信扫码登录会话：[uuid] 为轮询句柄，[qrImage] 为二维码 data URL。
 */
data class WxLoginSession(
    val uuid: String,
    val qrImage: String?,
)

/**
 * 设备注册 seam（对位 lite `registerDevice`，kugou_api_client.dart:836-847）：
 * GET 本机 Rust 服务器 `/register/dev`，从响应 `data.dfid` 取 dfid。
 *
 * 独立成 seam 的理由：该请求与登录编排正交（冷启动即注册，无需登录态），
 * 且需要 Rust 服务器端口与 OkHttpClient（DI 装配见 KugouServerModule）。
 * 失败（服务器未就绪/网络/解析失败）返回 null——**不生成假 dfid**（对位
 * lite：register 失败则 dfid 保持 null，Rust login.rs:158-166 每请求
 * 随机兜底；本地臆造 dfid 会与 device_info.json 不一致，有风控风险）。
 */
fun interface DeviceRegistrar {
    /** 注册设备并返回 dfid；失败返回 null。 */
    suspend fun registerDevice(): String?
}

/**
 * 账号仓库（F-ACC-005）：登录编排 + 会话状态 + 凭证落盘 + 鉴权头刷新。
 *
 * ## 副作用顺序契约（登录成功路径，对位 lite setLoginCookies:625-660）
 * 1. `tokenStore.save(credentials)`——加密落盘（敏感凭证）；
 * 2. `tokenStore.setCurrentUserid(userid)`——记录当前账号；
 * 3. `headerProvider.update(credentials)`——刷新拦截器内存头；
 * 4. `_authState.value = LoggedIn`——最后发布状态（头就绪后才算登录）。
 *
 * 注销/失效路径（[clearSessionLocked]）逆序清理：clear → setCurrentUserid(null)
 * → headerProvider.update(null)（**不清 dfid**，对位 lite :598）→ LoggedOut。
 *
 * ## 并发
 * 全部会话变更操作经 [sessionMutex] 串行化（OkHttp 拦截器只读内存，不受影响）：
 * 连续两次登录不会产生「save 与 setCurrentUserid 交叉」的竞态。
 *
 * ## 刷新失败策略
 * [refresh] 失败（token 失效/上游拒）→ **清除本地凭证并登出**（LoggedOut）：
 * 失败不静默、不保留失效凭证，UI 据此跳登录页。dfid 保留。
 *
 * ## dfid 设备注册
 * [restoreSession] 先调 [ensureDeviceRegistered]（对位 lite `_autoConnect`
 * 先 registerDevice，kugou_provider.dart:113-115）：prefs 已有 dfid 则跳过
 * （Rust /register/dev 幂等，device_info.json 命中时返回同一值，跳过网络
 * 调用是等价优化）；否则经 [DeviceRegistrar] 注册。注册失败不阻断会话恢复。
 *
 * ## 安全
 * 类内**无任何日志调用**：token/vipToken 不进日志、不进异常消息；
 * 上游文案仅经 [LoginResult.Failed.message] 透出（实现侧已收敛，见
 * KugouAuthApi 契约）。
 *
 * @param authApi 登录系列网络接口（Rust 本地服务器）。
 * @param tokenStore 凭证加密存储（并行子任务实现，只消费接口）。
 * @param headerProvider 鉴权头内存缓存（拦截器读取侧）。
 * @param deviceRegistrar 设备注册 seam（dfid 来源）。
 */
@Singleton
class AccountRepository @Inject constructor(
    private val authApi: KugouAuthApi,
    private val tokenStore: TokenStore,
    private val headerProvider: AuthHeaderProvider,
    private val deviceRegistrar: DeviceRegistrar,
) {

    private val sessionMutex = Mutex()

    private val _authState = MutableStateFlow<AuthState>(AuthState.LoggedOut)

    /** 当前登录态（冷启动经 [restoreSession] 收敛）。 */
    val authState: StateFlow<AuthState> = _authState.asStateFlow()

    /** 当前昵称（仅多账号选择时可得；登出清空）。 */
    private var nickname: String? = null

    // ------------------------------------------------------------------
    // 手机验证码登录（对位 lite loginByPhone:1366-1391）
    // ------------------------------------------------------------------

    /** 手机验证码登录；多账号返回 [LoginResult.NeedAccountChoice]。 */
    suspend fun loginByCellphone(mobile: String, code: String): LoginResult = sessionMutex.withLock {
        when (val attempt = authApi.loginByCellphone(mobile, code)) {
            is LoginAttempt.Success -> completeLoginLocked(attempt.data, nickname = null)
            is LoginAttempt.AccountChoiceRequired -> LoginResult.NeedAccountChoice(attempt.accounts)
            is LoginAttempt.Failed -> LoginResult.Failed(attempt.message, attempt.errorCode)
            is LoginAttempt.LocalFailure -> LoginResult.LocalRetry
        }
    }

    /**
     * 多账号选择后登录（对位 lite loginByPhoneWithAccount:1394-1422 的 native 简化）。
     *
     * native 契约的 [LoginAccount] 携带 token（KugouAuthApi 契约增补），故直接以
     * 该账号凭证完成登录；账号缺 token 时显式失败（不重发登录请求——仓库不保留
     * 手机号/验证码，避免敏感数据驻留内存）。
     */
    suspend fun chooseAccount(account: LoginAccount): LoginResult = sessionMutex.withLock {
        val token = account.token?.takeIf { it.isNotBlank() }
            ?: return@withLock LoginResult.Failed("账号缺少登录凭证，无法直接登录")
        val credentials = KugouCredentials(
            userid = account.userid,
            token = token,
            vipToken = account.vipToken?.takeIf { it.isNotBlank() },
        )
        applySessionLocked(credentials, account.nickname?.takeIf { it.isNotBlank() })
        LoginResult.Success
    }

    /** 发送手机验证码（不触碰登录态）。 */
    suspend fun loginByCaptcha(mobile: String): LoginResult =
        when (val attempt = authApi.sendCaptcha(mobile)) {
            is LoginAttempt.Success -> LoginResult.Success
            is LoginAttempt.AccountChoiceRequired -> LoginResult.Failed("验证码发送响应异常")
            is LoginAttempt.Failed -> LoginResult.Failed(attempt.message, attempt.errorCode)
            is LoginAttempt.LocalFailure -> LoginResult.LocalRetry
        }

    // ------------------------------------------------------------------
    // 扫码登录（酷狗二维码，对位 lite generateQrCode/checkQrCode:1294-1336）
    // ------------------------------------------------------------------

    /**
     * 发起扫码登录：生成二维码。
     *
     * key 由仓库以 `System.currentTimeMillis()` 生成（对位 KugouAuthApi
     * .createQrLogin KDoc 的 native 契约决定；lite 的服务端签发 key 见
     * KugouAuthApi.qrKey，native 默认不需要）。创建失败返回 null。
     */
    suspend fun beginQrLogin(): QrLoginSession? {
        val key = System.currentTimeMillis().toString()
        return when (val attempt = authApi.createQrLogin(key)) {
            is LoginAttempt.Success -> QrLoginSession(
                key = key,
                qrImage = attempt.data.qrImage,
                handle = attempt.data.handle,
            )
            else -> null
        }
    }

    /**
     * 轮询扫码状态（对位 lite checkQrCode:1316-1336，status==4 已确认）。
     *
     * 三相映射（对位 OkHttpKugouAuthApi 三态契约）：
     * - Success（status==4，带 token）→ 完成登录；
     * - Failed(errorCode=null)（未确认/等待）→ [LoginResult.LocalRetry] 继续轮询；
     * - Failed(errorCode!=null)（二维码过期等终态）→ [LoginResult.Failed]；
     * - LocalFailure → [LoginResult.LocalRetry]。
     */
    suspend fun pollQrLogin(key: String): LoginResult = sessionMutex.withLock {
        when (val attempt = authApi.checkQrLogin(key)) {
            is LoginAttempt.Success -> completeLoginLocked(attempt.data, nickname = null)
            is LoginAttempt.AccountChoiceRequired -> LoginResult.NeedAccountChoice(attempt.accounts)
            is LoginAttempt.Failed -> pollFailureToResult(attempt)
            is LoginAttempt.LocalFailure -> LoginResult.LocalRetry
        }
    }

    // ------------------------------------------------------------------
    // 微信扫码登录（对位 lite login_page.dart:87-160）
    // ------------------------------------------------------------------

    /**
     * 发起微信扫码登录。uuid 取自 [LoginData.handle]（KugouAuthApi 契约：
     * createWxLogin 抽取 data.uuid → handle）。创建失败返回 null。
     */
    suspend fun beginWxLogin(): WxLoginSession? =
        when (val attempt = authApi.createWxLogin()) {
            is LoginAttempt.Success -> {
                val uuid = attempt.data.handle?.takeIf { it.isNotBlank() }
                if (uuid == null) null else WxLoginSession(uuid = uuid, qrImage = attempt.data.qrImage)
            }
            else -> null
        }

    /**
     * 轮询微信扫码状态（对位 lite checkLoginWx 三态 :114-146）。
     *
     * 映射同 [pollQrLogin]：确认时 OkHttpKugouAuthApi 的 Success 直带
     * token/userid（KugouAuthApi.checkWxLogin KDoc「与 checkQrLogin 同构」），
     * 故直接完成登录，无需再走 [completeWxLogin]。
     */
    suspend fun pollWxLogin(uuid: String): LoginResult = sessionMutex.withLock {
        when (val attempt = authApi.checkWxLogin(uuid)) {
            is LoginAttempt.Success -> completeLoginLocked(attempt.data, nickname = null)
            is LoginAttempt.AccountChoiceRequired -> LoginResult.NeedAccountChoice(attempt.accounts)
            is LoginAttempt.Failed -> pollFailureToResult(attempt)
            is LoginAttempt.LocalFailure -> LoginResult.LocalRetry
        }
    }

    /**
     * 微信 code 换 token（对位 lite loginByOpenplat:3390-3395）。
     *
     * 供调用方已持有 code 的场景（如微信 SDK 回调）；[pollWxLogin] 确认路径
     * 内部不经过本方法。
     */
    suspend fun completeWxLogin(code: String): LoginResult = sessionMutex.withLock {
        when (val attempt = authApi.loginByOpenplat(code)) {
            is LoginAttempt.Success -> completeLoginLocked(attempt.data, nickname = null)
            is LoginAttempt.AccountChoiceRequired -> LoginResult.NeedAccountChoice(attempt.accounts)
            is LoginAttempt.Failed -> LoginResult.Failed(attempt.message, attempt.errorCode)
            is LoginAttempt.LocalFailure -> LoginResult.LocalRetry
        }
    }

    // ------------------------------------------------------------------
    // 会话生命周期
    // ------------------------------------------------------------------

    /**
     * 注销：清凭证 + 清当前账号 + 清鉴权头（**保留 dfid**）+ LoggedOut。
     * 幂等：未登录时再调无副作用（不清空已不存在的凭证）。
     */
    suspend fun logout() {
        sessionMutex.withLock { clearSessionLocked() }
    }

    /**
     * 冷启动恢复会话（对位 lite _autoConnect:113-115：先注册设备，再恢复登录态）。
     *
     * 顺序：先 [ensureDeviceRegistered]（无锁，避免注册 HTTP 阻塞登录编排），
     * 再在锁内读 `currentUserid()` → `load()` → 有凭证则恢复 LoggedIn 并
     * 刷新 headerProvider；无当前账号或凭证不存在 → LoggedOut。
     */
    suspend fun restoreSession() {
        ensureDeviceRegistered()
        sessionMutex.withLock {
            val userid = tokenStore.currentUserid()
            val credentials = if (userid.isNullOrEmpty()) null else tokenStore.load(userid)
            if (credentials == null) {
                _authState.value = AuthState.LoggedOut
            } else {
                applySessionLocked(credentials, nickname)
            }
        }
    }

    /**
     * 设备注册（dfid 兜底）：prefs 已有 dfid 则跳过（等价优化，见类 KDoc）；
     * 否则经 [DeviceRegistrar] 注册并写入 [AuthHeaderProvider.updateDfid]。
     * 失败保持 dfid=null，不阻断调用方。
     */
    suspend fun ensureDeviceRegistered() {
        if (headerProvider.dfid() != null) return
        val dfid = deviceRegistrar.registerDevice() ?: return
        headerProvider.updateDfid(dfid)
    }

    /**
     * 刷新登录态（对位 lite _tryRefreshToken:3413-3435）。
     *
     * 流程：读当前凭证 → Refreshing → refreshLogin → 成功则以新凭证整体
     * 覆盖（vipToken 以响应为准，可空即清除，对位 lite setLoginCookies 语义）
     * → LoggedIn；**失败（含响应缺 token）→ 清除凭证并登出**（策略见类 KDoc）。
     *
     * @return true=刷新成功（仍是登录态）；false=失败（已登出或本无凭证）。
     */
    suspend fun refresh(): Boolean = sessionMutex.withLock {
        val userid = tokenStore.currentUserid()
        val current = if (userid.isNullOrEmpty()) null else tokenStore.load(userid)
        if (current == null) return@withLock false

        _authState.value = AuthState.Refreshing
        when (val attempt = authApi.refreshLogin(current.token, current.userid)) {
            is LoginAttempt.Success -> {
                val data = attempt.data
                val newToken = data.token?.takeIf { it.isNotBlank() }
                if (newToken == null) {
                    clearSessionLocked()
                    false
                } else {
                    val refreshed = KugouCredentials(
                        userid = data.userid?.takeIf { it.isNotBlank() } ?: current.userid,
                        token = newToken,
                        vipToken = data.vipToken?.takeIf { it.isNotBlank() },
                    )
                    applySessionLocked(refreshed, nickname)
                    true
                }
            }
            else -> {
                // 刷新失败 = 凭证失效：显式登出（失败不静默、不保留失效凭证）
                clearSessionLocked()
                false
            }
        }
    }

    // ------------------------------------------------------------------
    // 内部（均在 sessionMutex 内调用）
    // ------------------------------------------------------------------

    /** 完成登录：抽取凭证 → 应用会话。响应缺 token/userid 显式判失败。 */
    private suspend fun completeLoginLocked(data: LoginData, nickname: String?): LoginResult {
        val credentials = data.credentialsOrNull()
            ?: return LoginResult.Failed("登录响应缺少凭证")
        applySessionLocked(credentials, nickname)
        return LoginResult.Success
    }

    /**
     * 应用会话（副作用顺序契约）：
     * save → setCurrentUserid → headerProvider.update → 发布 LoggedIn。
     */
    private suspend fun applySessionLocked(credentials: KugouCredentials, nickname: String?) {
        tokenStore.save(credentials)
        tokenStore.setCurrentUserid(credentials.userid)
        headerProvider.update(credentials)
        this.nickname = nickname
        _authState.value = AuthState.LoggedIn(credentials.userid, nickname)
    }

    /** 清除会话：clear（有当前账号时）→ setCurrentUserid(null) → 清头 → LoggedOut。 */
    private suspend fun clearSessionLocked() {
        val userid = tokenStore.currentUserid()
        if (!userid.isNullOrEmpty()) tokenStore.clear(userid)
        tokenStore.setCurrentUserid(null)
        headerProvider.update(null)
        nickname = null
        _authState.value = AuthState.LoggedOut
    }

    /** 轮询失败二相映射：errorCode=null 等待（继续轮询）；非空即终态（过期/拒绝）。 */
    private fun pollFailureToResult(failed: LoginAttempt.Failed): LoginResult =
        if (failed.errorCode == null) {
            LoginResult.LocalRetry
        } else {
            LoginResult.Failed(failed.message, failed.errorCode)
        }

    /** 从登录响应抽取凭证；token/userid 任一缺失 → null（显式失败，不猜默认值）。 */
    private fun LoginData.credentialsOrNull(): KugouCredentials? {
        val token = this.token?.takeIf { it.isNotBlank() } ?: return null
        val userid = this.userid?.takeIf { it.isNotBlank() } ?: return null
        return KugouCredentials(
            userid = userid,
            token = token,
            vipToken = this.vipToken?.takeIf { it.isNotBlank() },
        )
    }
}
