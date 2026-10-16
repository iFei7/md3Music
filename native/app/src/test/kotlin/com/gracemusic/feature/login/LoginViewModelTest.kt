package com.gracemusic.feature.login

import android.content.Context
import com.gracemusic.data.account.AccountRepository
import com.gracemusic.data.account.DeviceRegistrar
import com.gracemusic.data.net.AuthHeaderProvider
import com.gracemusic.data.net.KugouAuthApi
import com.gracemusic.data.net.LoginAccount
import com.gracemusic.data.net.LoginAttempt
import com.gracemusic.data.net.LoginData
import com.gracemusic.data.net.LocalFailureKind
import com.gracemusic.data.secure.KugouCredentials
import com.gracemusic.data.secure.TokenStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * [LoginViewModel] 测试（T-P4-11 / F-ACC-001）。
 *
 * ## 策略：真实 `AccountRepository` + 两个假接口
 * `AccountRepository` 是 final class（未抽接口），为**不改动生产代码**，
 * 这里用「真实 AccountRepository + 假 `KugouAuthApi` + 假 `TokenStore` + 假
 * `DeviceRegistrar` + 真 `AuthHeaderProvider`」组装，从而覆盖
 * 「ViewModel → AccountRepository → 结果类型」的完整链路，而不是只验证 ViewModel 转发。
 *
 * `viewModelScope` 绑 `Dispatchers.Main`，故用 [setMain] 装
 * `UnconfinedTestDispatcher`（launch 立即执行，无需推进虚拟时间）。
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class LoginViewModelTest {

    private val mainDispatcher = UnconfinedTestDispatcher()

    private lateinit var api: FakeKugouAuthApi
    private lateinit var tokenStore: FakeTokenStore
    private lateinit var deviceRegistrar: DeviceRegistrar
    private lateinit var headerProvider: AuthHeaderProvider

    @Before
    fun setUp() {
        Dispatchers.setMain(mainDispatcher)
        api = FakeKugouAuthApi()
        tokenStore = FakeTokenStore()
        deviceRegistrar = DeviceRegistrar { null }
        val context = RuntimeEnvironment.getApplication() as Context
        headerProvider = AuthHeaderProvider(context)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun newViewModel(): LoginViewModel {
        val repository = AccountRepository(
            authApi = api,
            tokenStore = tokenStore,
            headerProvider = headerProvider,
            deviceRegistrar = deviceRegistrar,
        )
        return LoginViewModel(repository)
    }

    // ─────────────────────── 初始化与 tab ───────────────────────

    @Test
    fun `初始化进入扫码tab_生成二维码并提示扫码`() {
        api.createQrResult = LoginAttempt.Success(
            LoginData(handle = "KEY123", qrImage = QR_IMAGE),
        )

        val vm = newViewModel()
        val state = vm.uiState.value

        assertEquals(0, state.tabIndex)
        assertEquals(QR_IMAGE, state.qrImage)
        assertEquals("请使用酷狗音乐 App 扫码登录", state.statusText)
    }

    @Test
    fun `生成二维码失败_提示失败且不崩溃`() {
        api.createQrResult = LoginAttempt.Failed(errorCode = null, message = "上游忙")

        val vm = newViewModel()

        assertEquals("生成二维码失败，请重试", vm.uiState.value.statusText)
        assertFalse(vm.uiState.value.loginSucceeded)
    }

    @Test
    fun `切到手机tab_清空输入与二维码并提示`() {
        val vm = newViewModel()
        vm.onPhoneChange("13800138000")

        vm.onTabSelected(1)

        val state = vm.uiState.value
        assertEquals(1, state.tabIndex)
        assertEquals("请输入手机号获取验证码", state.statusText)
        assertEquals("", state.phone)
        assertNull(state.qrImage)
    }

    @Test
    fun `切到微信tab_生成微信二维码`() {
        api.createWxResult = LoginAttempt.Success(
            LoginData(handle = "UUID-1", qrImage = WX_IMAGE),
        )

        val vm = newViewModel()
        vm.onTabSelected(2)

        assertEquals(WX_IMAGE, vm.uiState.value.wxImage)
        assertEquals("请使用微信扫码登录", vm.uiState.value.statusText)
    }

    // ─────────────────────── 手机验证码 ───────────────────────

    @Test
    fun `手机号不足11位_提示错误且不请求`() {
        val vm = newViewModel()
        vm.onTabSelected(1)

        vm.onSendCode()

        assertEquals("请输入 11 位手机号", vm.uiState.value.message)
        assertEquals(0, api.sendCaptchaCalls)
    }

    @Test
    fun `手机号输入过滤非数字并截断到11位`() {
        val vm = newViewModel()
        vm.onTabSelected(1)

        vm.onPhoneChange("138abc00138000123456")

        assertEquals("13800138000", vm.uiState.value.phone)
    }

    @Test
    fun `发送验证码成功_进入60秒倒计时`() {
        api.sendCaptchaResult = LoginAttempt.Success(LoginData())

        val vm = newViewModel()
        vm.onTabSelected(1)
        vm.onPhoneChange("13800138000")

        vm.onSendCode()

        val state = vm.uiState.value
        assertEquals("验证码已发送", state.statusText)
        assertEquals(60, state.countdown)
        assertEquals(1, api.sendCaptchaCalls)
    }

    @Test
    fun `倒计时期间不可再次发送`() {
        api.sendCaptchaResult = LoginAttempt.Success(LoginData())
        val vm = newViewModel()
        vm.onTabSelected(1)
        vm.onPhoneChange("13800138000")
        vm.onSendCode()

        vm.onSendCode()

        assertEquals(1, api.sendCaptchaCalls)
    }

    @Test
    fun `验证码为空_提示且不请求登录`() {
        val vm = newViewModel()
        vm.onTabSelected(1)
        vm.onPhoneChange("13800138000")

        vm.onLoginPhone()

        assertEquals("请输入验证码", vm.uiState.value.message)
        assertEquals(0, api.loginCalls)
    }

    @Test
    fun `手机登录成功_置成功态并收敛`() {
        api.loginResult = LoginAttempt.Success(
            LoginData(token = "TOKEN-1", userid = "123", vipToken = "VIP-1"),
        )

        val vm = newViewModel()
        vm.onTabSelected(1)
        vm.onPhoneChange("13800138000")
        vm.onCodeChange("123456")

        vm.onLoginPhone()

        val state = vm.uiState.value
        assertTrue(state.loginSucceeded)
        assertEquals("登录成功！", state.statusText)
        assertFalse(state.isBusy)
    }

    @Test
    fun `手机登录失败_展示收敛文案`() {
        api.loginResult = LoginAttempt.Failed(errorCode = 20010, message = "登录已过期")

        val vm = newViewModel()
        vm.onTabSelected(1)
        vm.onPhoneChange("13800138000")
        vm.onCodeChange("123456")

        vm.onLoginPhone()

        assertEquals("登录已过期", vm.uiState.value.message)
        assertFalse(vm.uiState.value.loginSucceeded)
    }

    @Test
    fun `本地服务器不可用_提示稍后重试非错误`() {
        api.loginResult = LoginAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE)

        val vm = newViewModel()
        vm.onTabSelected(1)
        vm.onPhoneChange("13800138000")
        vm.onCodeChange("123456")

        vm.onLoginPhone()

        assertEquals("网络不稳定，请稍后重试", vm.uiState.value.statusText)
    }

    // ─────────────────────── 扫码轮询 ───────────────────────

    @Test
    fun `扫码轮询_等待状态不打断_确认后成功`() {
        // 不用 runTest：viewModelScope 的轮询协程挂在虚拟 delay 上，
        // runTest 会因「同 scheduler 上的泄漏任务」一直推进虚拟时间而挂死。
        // 改为直接驱动主调度器的虚拟时钟，末尾 onDismiss 取消轮询。
        api.createQrResult = LoginAttempt.Success(LoginData(handle = "K1", qrImage = QR_IMAGE))
        // 第一次轮询：还在等；第二次：成功。
        api.qrCheckResults = ArrayDeque(
            listOf(
                LoginAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE),
                LoginAttempt.Success(LoginData(token = "T", userid = "U")),
            ),
        )

        val vm = newViewModel()
        // 推进两个轮询周期（2s 间隔）。
        mainDispatcher.scheduler.advanceTimeBy(4_100)

        assertTrue(vm.uiState.value.loginSucceeded)
        vm.onDismiss()
    }

    @Test
    fun `扫码被拒_展示文案且不自动成功`() {
        api.createQrResult = LoginAttempt.Success(LoginData(handle = "K1", qrImage = QR_IMAGE))
        // errorCode 非空 → AccountRepository 判为终态（过期/拒绝），映射为 Failed。
        api.qrCheckResults = ArrayDeque(
            listOf(LoginAttempt.Failed(errorCode = 4001, message = "二维码已过期")),
        )

        val vm = newViewModel()
        mainDispatcher.scheduler.advanceTimeBy(2_100)

        assertEquals("二维码已过期", vm.uiState.value.message)
        assertFalse(vm.uiState.value.loginSucceeded)
        vm.onDismiss()
    }

    // ─────────────────────── 消息与关闭 ───────────────────────

    @Test
    fun `consumeMessage_清空一次性提示`() {
        val vm = newViewModel()
        vm.onTabSelected(1)
        vm.onSendCode() // 手机号为空 → message
        assertNotNull(vm.uiState.value.message)

        vm.consumeMessage()

        assertNull(vm.uiState.value.message)
    }

    @Test
    fun `onDismiss_取消轮询_不崩溃`() {
        api.createQrResult = LoginAttempt.Success(LoginData(handle = "K1", qrImage = QR_IMAGE))
        val vm = newViewModel()

        vm.onDismiss()

        // 轮询已取消：不应再调用 check。
        val before = api.qrCheckCalls
        vm.onDismiss()
        assertEquals(before, api.qrCheckCalls)
    }

    @Test
    fun `多账号选择_返回需选择`() {
        api.loginResult = LoginAttempt.AccountChoiceRequired(
            listOf(
                LoginAccount(userid = "1", token = "t1", nickname = "账号一"),
                LoginAccount(userid = "2", token = "t2", nickname = "账号二"),
            ),
        )

        val vm = newViewModel()
        vm.onTabSelected(1)
        vm.onPhoneChange("13800138000")
        vm.onCodeChange("123456")

        vm.onLoginPhone()

        assertTrue(vm.uiState.value.message!!.contains("多个账号"))
    }

    // ─────────────────────── fakes ───────────────────────

    private class FakeTokenStore : TokenStore {
        val saved = LinkedHashMap<String, KugouCredentials>()
        var current: String? = null

        override suspend fun load(userid: String): KugouCredentials? = saved[userid]

        override suspend fun save(credentials: KugouCredentials) {
            saved[credentials.userid] = credentials
        }

        override suspend fun clear(userid: String) {
            saved.remove(userid)
        }

        override suspend fun currentUserid(): String? = current

        override suspend fun setCurrentUserid(userid: String?) {
            current = userid
        }
    }

    private class FakeKugouAuthApi : KugouAuthApi {
        var createQrResult: LoginAttempt? = null
        var createWxResult: LoginAttempt? = null
        var sendCaptchaResult: LoginAttempt? = null
        var loginResult: LoginAttempt? = null
        var qrCheckResults: ArrayDeque<LoginAttempt> = ArrayDeque()
        var sendCaptchaCalls = 0
        var loginCalls = 0
        var qrCheckCalls = 0

        override suspend fun loginByCellphone(
            mobile: String,
            code: String,
            userid: String?,
        ): LoginAttempt {
            loginCalls++
            return loginResult ?: LoginAttempt.Failed(null, "未设置")
        }

        override suspend fun sendCaptcha(mobile: String): LoginAttempt {
            sendCaptchaCalls++
            return sendCaptchaResult ?: LoginAttempt.Failed(null, "未设置")
        }

        override suspend fun createQrLogin(key: String): LoginAttempt =
            createQrResult ?: LoginAttempt.Failed(null, "未设置")

        override suspend fun checkQrLogin(key: String): LoginAttempt {
            qrCheckCalls++
            return if (qrCheckResults.isNotEmpty()) {
                qrCheckResults.removeFirst()
            } else {
                LoginAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE)
            }
        }

        override suspend fun qrKey(): LoginAttempt = LoginAttempt.Success(LoginData(handle = "K"))

        override suspend fun createWxLogin(): LoginAttempt =
            createWxResult ?: LoginAttempt.Failed(null, "未设置")

        override suspend fun checkWxLogin(uuid: String): LoginAttempt = LoginAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE)

        override suspend fun loginByOpenplat(code: String): LoginAttempt =
            loginResult ?: LoginAttempt.Failed(null, "未设置")

        override suspend fun refreshLogin(token: String, userid: String): LoginAttempt =
            LoginAttempt.Failed(null, "未设置")

        override suspend fun fetchUserDetail(): LoginAttempt = LoginAttempt.Failed(null, "未设置")
    }

    private companion object {
        const val QR_IMAGE = "data:image/png;base64,iVBORw0KGgo="
        const val WX_IMAGE = "data:image/png;base64,QW55IGNhcm5hbCBwbGVhc3VyZS4="
    }
}
