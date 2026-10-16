package com.gracemusic.feature.login

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.gracemusic.data.account.AccountRepository
import com.gracemusic.data.account.LoginResult
import com.gracemusic.data.net.LoginAccount
import com.gracemusic.data.account.QrLoginSession
import com.gracemusic.data.account.WxLoginSession
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 登录页 UI 状态（T-P4-11 / F-ACC-001）。
 *
 * 与 [com.gracemusic.data.account.AuthState] 的分界：本状态只描述**登录页本身**
 * （tab、二维码、输入框、倒计时、状态文本）；「是否已登录」的权威在
 * [com.gracemusic.data.account.AccountRepository.authState]，UI 另订阅它做跳转。
 */
data class LoginUiState(
    /** 当前 tab：0 = 扫码、1 = 手机验证码、2 = 微信（对位 lite `_tabIndex`）。 */
    val tabIndex: Int = 0,
    /** 酷狗扫码二维码 base64 data URL（`data:image/png;base64,...`）。 */
    val qrImage: String? = null,
    /** 微信扫码二维码 base64 data URL。 */
    val wxImage: String? = null,
    /** 状态提示文本（对位 lite `_statusText`）。 */
    val statusText: String? = null,
    /** 登录/发验证码在途。 */
    val isBusy: Boolean = false,
    val phone: String = "",
    val code: String = "",
    /** 验证码重发倒计时（秒）；0 = 可发送。 */
    val countdown: Int = 0,
    /** 一次性提示（错误 / 成功）；UI 消费后调 [LoginViewModel.consumeMessage]。 */
    val message: String? = null,
    /** 登录成功（UI 据此关闭页面）。 */
    val loginSucceeded: Boolean = false,
) {
    val isQrTab: Boolean get() = tabIndex == 0
    val isPhoneTab: Boolean get() = tabIndex == 1
    val isWxTab: Boolean get() = tabIndex == 2
}

/**
 * 登录页 ViewModel（T-P4-11 / F-ACC-001）。
 *
 * ## 对位 lite `lib/modules/login/login_page.dart`（607 行）
 * | lite | native |
 * |---|---|
 * | `_switchTab(int)` | [onTabSelected] |
 * | `_initLogin()` | [startCurrentTab] |
 * | `generateQrCode()` + `_startCheck()` | [onRefreshQr] + [startQrPolling] |
 * | `_initWxLogin()` + `_startWxCheck()` | [onInitWx] + [startWxPolling] |
 * | `_onSendCode` / 倒计时 | [onSendCode] |
 * | `_onLoginPhone` | [onLoginPhone] |
 * | `_checkTimer` / `_countdownTimer` | [pollJob] / [countdownJob] |
 *
 * ## 轮询间隔
 * 2 秒，与 lite `Timer.periodic(Duration(seconds: 2))` 一致。
 *
 * ## 生命周期
 * [pollJob] / [countdownJob] 绑 `viewModelScope`（页面销毁即取消）；
 * 切 tab 时先取消再重启（对位 lite `_switchTab` 的 `_checkTimer?.cancel()`）。
 */
@HiltViewModel
class LoginViewModel @Inject constructor(
    private val accountRepository: AccountRepository,
) : ViewModel() {

    private val _uiState = MutableStateFlow(LoginUiState())

    /** 登录页 UI 状态。 */
    val uiState: StateFlow<LoginUiState> = _uiState.asStateFlow()

    /** 扫码 / 微信轮询 Job（同时只有一个）。 */
    private var pollJob: Job? = null

    /** 验证码倒计时 Job。 */
    private var countdownJob: Job? = null

    init {
        // 对位 lite `initState` 的 `addPostFrameCallback(_initLogin)`。
        startCurrentTab()
    }

    /** 切 tab（对位 lite `_switchTab`：取消轮询与倒计时、清空输入、重启 init）。 */
    fun onTabSelected(index: Int) {
        if (_uiState.value.tabIndex == index) return
        pollJob?.cancel()
        countdownJob?.cancel()
        _uiState.value = _uiState.value.copy(
            tabIndex = index,
            qrImage = null,
            wxImage = null,
            statusText = null,
            message = null,
            phone = "",
            code = "",
            countdown = 0,
            isBusy = false,
        )
        startCurrentTab()
    }

    /** 刷新二维码（扫码 tab）。 */
    fun onRefreshQr() {
        pollJob?.cancel()
        _uiState.value = _uiState.value.copy(
            qrImage = null,
            statusText = "请使用酷狗音乐 App 扫码登录",
        )
        startQrLogin()
    }

    /** 手机号输入。 */
    fun onPhoneChange(value: String) {
        _uiState.value = _uiState.value.copy(phone = value.filter { it.isDigit() }.take(11))
    }

    /** 验证码输入。 */
    fun onCodeChange(value: String) {
        _uiState.value = _uiState.value.copy(code = value.filter { it.isDigit() }.take(6))
    }

    /** 发送验证码（对位 lite `_onSendCode`：校验 → 发码 → 60s 倒计时）。 */
    fun onSendCode() {
        val state = _uiState.value
        if (state.isBusy || state.countdown > 0) return
        val phone = state.phone
        if (phone.length != 11) {
            _uiState.value = state.copy(message = "请输入 11 位手机号")
            return
        }
        _uiState.value = state.copy(isBusy = true)
        viewModelScope.launch {
            when (val result = accountRepository.loginByCaptcha(phone)) {
                is LoginResult.Success -> {
                    _uiState.value = _uiState.value.copy(
                        isBusy = false,
                        statusText = "验证码已发送",
                        countdown = RESEND_COUNTDOWN_SECONDS,
                    )
                    startCountdown()
                }

                is LoginResult.Failed ->
                    _uiState.value = _uiState.value.copy(isBusy = false, message = result.message)

                // 本地服务器不可用：可重试，不算错误文案。
                LoginResult.LocalRetry ->
                    _uiState.value = _uiState.value.copy(
                        isBusy = false,
                        statusText = "网络不稳定，请稍后重试",
                    )

                is LoginResult.NeedAccountChoice -> Unit // 发验证码不会返回
            }
        }
    }

    /** 手机验证码登录（对位 lite `_onLoginPhone`）。 */
    fun onLoginPhone() {
        val state = _uiState.value
        if (state.isBusy) return
        val phone = state.phone
        val code = state.code
        if (phone.length != 11) {
            _uiState.value = state.copy(message = "请输入 11 位手机号")
            return
        }
        if (code.isBlank()) {
            _uiState.value = state.copy(message = "请输入验证码")
            return
        }
        _uiState.value = state.copy(isBusy = true)
        viewModelScope.launch {
            handleLoginResult(accountRepository.loginByCellphone(phone, code))
        }
    }

    /** 多账号选择（对位 lite `error_code=34175` 的 info_list 分支）。 */
    fun onChooseAccount(account: LoginAccount) {
        _uiState.value = _uiState.value.copy(isBusy = true)
        viewModelScope.launch {
            handleLoginResult(accountRepository.chooseAccount(account))
        }
    }

    /** 关闭页面前调用：取消全部轮询/定时器。 */
    fun onDismiss() {
        pollJob?.cancel()
        countdownJob?.cancel()
        pollJob = null
        countdownJob = null
    }

    /** 消费一次性提示（UI 展示后调用，防止旋转屏幕重复弹出）。 */
    fun consumeMessage() {
        _uiState.value = _uiState.value.copy(message = null)
    }

    // ─────────────────────────── 内部 ───────────────────────────

    private fun startCurrentTab() {
        when (_uiState.value.tabIndex) {
            0 -> {
                _uiState.value = _uiState.value.copy(
                    statusText = "请使用酷狗音乐 App 扫码登录",
                )
                startQrLogin()
            }

            2 -> startWxLogin()

            // 手机 tab：仅提示，不自动请求。
            else -> _uiState.value = _uiState.value.copy(
                statusText = "请输入手机号获取验证码",
            )
        }
    }

    private fun startQrLogin() {
        pollJob = viewModelScope.launch {
            val session = accountRepository.beginQrLogin() ?: run {
                _uiState.value = _uiState.value.copy(
                    isBusy = false,
                    statusText = "生成二维码失败，请重试",
                )
                return@launch
            }
            _uiState.value = _uiState.value.copy(
                isBusy = false,
                qrImage = session.qrImage,
                statusText = "请使用酷狗音乐 App 扫码登录",
            )
            startQrPolling(session)
        }
    }

    /** 扫码轮询（对位 lite `_startCheck`：2s 周期）。 */
    private fun startQrPolling(session: QrLoginSession) {
        pollJob = viewModelScope.launch {
            while (isActive) {
                delay(POLL_INTERVAL)
                if (!isActive) break
                when (val result = accountRepository.pollQrLogin(session.key)) {
                    is LoginResult.Success -> {
                        handleLoginResult(result)
                        return@launch
                    }

                    // 尚未扫码 / 已扫码待确认 → 继续轮询（对位 lite 的 statusText）。
                    LoginResult.LocalRetry ->
                        _uiState.value = _uiState.value.copy(
                            statusText = session.handle ?: "等待扫描...",
                        )

                    is LoginResult.Failed -> {
                        // 二维码过期/被拒：终态，需用户点刷新。
                        _uiState.value = _uiState.value.copy(message = result.message)
                        return@launch
                    }

                    is LoginResult.NeedAccountChoice -> {
                        handleLoginResult(result)
                        return@launch
                    }
                }
            }
        }
    }

    private fun startWxLogin() {
        pollJob = viewModelScope.launch {
            _uiState.value = _uiState.value.copy(
                isBusy = true,
                statusText = "正在生成微信二维码...",
            )
            val session = accountRepository.beginWxLogin() ?: run {
                _uiState.value = _uiState.value.copy(
                    isBusy = false,
                    statusText = "生成微信二维码失败",
                )
                return@launch
            }
            _uiState.value = _uiState.value.copy(
                isBusy = false,
                wxImage = session.qrImage,
                statusText = "请使用微信扫码登录",
            )
            // 微信轮询：确认即完成（其 Success 直带 token）。
            while (isActive) {
                delay(POLL_INTERVAL)
                if (!isActive) break
                when (val result = accountRepository.pollWxLogin(session.uuid)) {
                    is LoginResult.Success -> {
                        handleLoginResult(result)
                        return@launch
                    }

                    LoginResult.LocalRetry ->
                        _uiState.value = _uiState.value.copy(statusText = "等待扫描...")

                    is LoginResult.Failed -> {
                        _uiState.value = _uiState.value.copy(message = result.message)
                        return@launch
                    }

                    is LoginResult.NeedAccountChoice -> {
                        handleLoginResult(result)
                        return@launch
                    }
                }
            }
        }
    }

    /** 60s 验证码重发倒计时（对位 lite `_countdownTimer`）。 */
    private fun startCountdown() {
        countdownJob?.cancel()
        countdownJob = viewModelScope.launch {
            var remaining = RESEND_COUNTDOWN_SECONDS
            while (remaining > 0 && isActive) {
                delay(1.seconds)
                remaining -= 1
                _uiState.value = _uiState.value.copy(countdown = remaining)
            }
        }
    }

    private suspend fun handleLoginResult(result: LoginResult) {
        when (result) {
            is LoginResult.Success -> {
                pollJob?.cancel()
                countdownJob?.cancel()
                _uiState.value = _uiState.value.copy(
                    isBusy = false,
                    statusText = "登录成功！",
                    loginSucceeded = true,
                )
            }

            is LoginResult.Failed ->
                _uiState.value = _uiState.value.copy(isBusy = false, message = result.message)

            LoginResult.LocalRetry ->
                _uiState.value = _uiState.value.copy(isBusy = false, statusText = "网络不稳定，请稍后重试")

            // 多账号：UI 侧展示选择列表（本阶段仅提示，见文档未完成项）。
            is LoginResult.NeedAccountChoice ->
                _uiState.value = _uiState.value.copy(
                    isBusy = false,
                    message = "检测到多个账号，请选择要登录的账号",
                )
        }
    }

    private companion object {
        /** 轮询间隔：与 lite `Timer.periodic(Duration(seconds: 2))` 一致。 */
        val POLL_INTERVAL = 2.seconds

        /** 验证码重发倒计时秒数（对位 lite 的 60s）。 */
        const val RESEND_COUNTDOWN_SECONDS = 60
    }
}
