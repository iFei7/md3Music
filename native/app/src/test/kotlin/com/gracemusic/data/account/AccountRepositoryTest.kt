package com.gracemusic.data.account

import com.gracemusic.data.net.KugouAuthApi
import com.gracemusic.data.net.LoginAccount
import com.gracemusic.data.net.LoginAttempt
import com.gracemusic.data.net.LoginData
import com.gracemusic.data.net.AuthHeaderProvider
import com.gracemusic.data.secure.KugouCredentials
import com.gracemusic.data.secure.TokenStore
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowLog

/**
 * [AccountRepository] 单测（Robolectric + 假 TokenStore / 假 KugouAuthApi /
 * 假 DeviceRegistrar + runTest）。
 *
 * 断言**最终状态与副作用**（TokenStore 落盘内容、setCurrentUserid、
 * headerProvider 缓存、authState 迁移），不满足于「方法被调用」。
 *
 * 凭据流程副作用顺序契约（对位 lite setLoginCookies，kugou_api_client.dart
 * :625-660）：tokenStore.save → tokenStore.setCurrentUserid →
 * headerProvider.update → authState=LoggedIn。
 */
@RunWith(RobolectricTestRunner::class)
class AccountRepositoryTest {

    // ------------------------------------------------------------------
    // 假依赖（按冻结接口签名自实现，不 import 真实实现）
    // ------------------------------------------------------------------

    private class FakeTokenStore : TokenStore {
        val saved = mutableListOf<KugouCredentials>()
        val cleared = mutableListOf<String>()
        var current: String? = null
        val credentials = mutableMapOf<String, KugouCredentials>()

        override suspend fun load(userid: String): KugouCredentials? = credentials[userid]

        override suspend fun save(credentials: KugouCredentials) {
            saved += credentials
            this.credentials[credentials.userid] = credentials
        }

        override suspend fun clear(userid: String) {
            cleared += userid
            credentials.remove(userid)
        }

        override suspend fun currentUserid(): String? = current

        override suspend fun setCurrentUserid(userid: String?) {
            current = userid
        }
    }

    private class FakeAuthApi : KugouAuthApi {
        val calls = mutableListOf<String>()
        var cellphoneResult: LoginAttempt = LoginAttempt.Failed(0, "unset")
        var captchaResult: LoginAttempt = LoginAttempt.Success(LoginData())
        var qrCreateResult: LoginAttempt = LoginAttempt.Failed(0, "unset")
        var qrCheckResult: LoginAttempt = LoginAttempt.Failed(null, "unset")
        var wxCreateResult: LoginAttempt = LoginAttempt.Failed(0, "unset")
        var wxCheckResult: LoginAttempt = LoginAttempt.Failed(null, "unset")
        var openplatResult: LoginAttempt = LoginAttempt.Failed(0, "unset")
        var refreshResult: LoginAttempt = LoginAttempt.Failed(0, "unset")
        var lastQrKey: String? = null
        var lastWxUuid: String? = null
        var lastRefreshArgs: Pair<String, String>? = null

        /** 测试钩子：在 loginByCellphone 返回前挂起，用于制造交错。 */
        var onCellphone: (suspend () -> Unit)? = null

        /** 测试钩子：在 refreshLogin 返回前调用，用于观测中间态。 */
        var onRefreshObserve: (suspend () -> Unit)? = null

        override suspend fun loginByCellphone(mobile: String, code: String, userid: String?): LoginAttempt {
            calls += "cellphone"
            onCellphone?.invoke()
            return cellphoneResult
        }

        override suspend fun sendCaptcha(mobile: String): LoginAttempt {
            calls += "captcha"
            return captchaResult
        }

        override suspend fun createQrLogin(key: String): LoginAttempt {
            calls += "qrCreate"
            lastQrKey = key
            return qrCreateResult
        }

        override suspend fun checkQrLogin(key: String): LoginAttempt {
            calls += "qrCheck"
            lastQrKey = key
            return qrCheckResult
        }

        override suspend fun qrKey(): LoginAttempt {
            calls += "qrKey"
            return LoginAttempt.Failed(0, "unused")
        }

        override suspend fun createWxLogin(): LoginAttempt {
            calls += "wxCreate"
            return wxCreateResult
        }

        override suspend fun checkWxLogin(uuid: String): LoginAttempt {
            calls += "wxCheck"
            lastWxUuid = uuid
            return wxCheckResult
        }

        override suspend fun loginByOpenplat(code: String): LoginAttempt {
            calls += "openplat"
            return openplatResult
        }

        override suspend fun refreshLogin(token: String, userid: String): LoginAttempt {
            calls += "refresh"
            lastRefreshArgs = token to userid
            onRefreshObserve?.invoke()
            return refreshResult
        }

        override suspend fun fetchUserDetail(): LoginAttempt {
            calls += "userDetail"
            return LoginAttempt.Success(LoginData(userid = "U10086"))
        }
    }

    private class FakeDeviceRegistrar : DeviceRegistrar {
        var result: String? = "DFID-REG"
        var calls = 0

        override suspend fun registerDevice(): String? {
            calls++
            return result
        }
    }

    // ------------------------------------------------------------------
    // 夹具
    // ------------------------------------------------------------------

    private lateinit var store: FakeTokenStore
    private lateinit var authApi: FakeAuthApi
    private lateinit var registrar: FakeDeviceRegistrar
    private lateinit var provider: AuthHeaderProvider
    private lateinit var repository: AccountRepository

    private val mobile = "22644212509"
    private val code = "123456"
    private val token = "T-secret-1"
    private val vipToken = "V-secret-2"
    private val userid = "U10086"

    @Before
    fun setUp() {
        store = FakeTokenStore()
        authApi = FakeAuthApi()
        registrar = FakeDeviceRegistrar()
        provider = AuthHeaderProvider(RuntimeEnvironment.getApplication())
        repository = AccountRepository(authApi, store, provider, registrar)
    }

    private fun loggedInState(userid: String = this.userid, nickname: String? = null): AuthState.LoggedIn =
        AuthState.LoggedIn(userid, nickname)

    // ------------------------------------------------------------------
    // 手机验证码登录（对位 lite loginByPhone / _completePhoneLogin）
    // ------------------------------------------------------------------

    @Test
    fun `手机验证码登录成功_落盘并更新header与状态`() = runTest {
        authApi.cellphoneResult = LoginAttempt.Success(
            LoginData(token = token, userid = userid, vipToken = vipToken),
        )

        val result = repository.loginByCellphone(mobile, code)

        assertEquals(LoginResult.Success, result)
        assertEquals(loggedInState(), repository.authState.value)
        // 副作用顺序契约：save → setCurrentUserid → headerProvider.update
        assertEquals(listOf(KugouCredentials(userid, token, vipToken)), store.saved)
        assertEquals(userid, store.current)
        assertEquals("token=$token;userid=$userid;vip_token=$vipToken", provider.currentHeader())
    }

    @Test
    fun `手机验证码登录失败_保持登出且不落盘`() = runTest {
        authApi.cellphoneResult = LoginAttempt.Failed(20010, "验证码错误")

        val result = repository.loginByCellphone(mobile, code)

        assertEquals(LoginResult.Failed("验证码错误", 20010), result)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue("失败不得落盘", store.saved.isEmpty())
        assertNull("失败不得更新 header", provider.currentHeader())
        assertNull("失败不得写当前用户", store.current)
    }

    @Test
    fun `登录返回本地失败_映射LocalRetry且保持登出`() = runTest {
        authApi.cellphoneResult = LoginAttempt.LocalFailure(com.gracemusic.data.net.LocalFailureKind.SERVER_BUSY)

        val result = repository.loginByCellphone(mobile, code)

        assertEquals(LoginResult.LocalRetry, result)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue(store.saved.isEmpty())
    }

    @Test
    fun `登录成功但响应缺凭证_判失败不落盘`() = runTest {
        authApi.cellphoneResult = LoginAttempt.Success(LoginData(token = token, userid = null))

        val result = repository.loginByCellphone(mobile, code)

        assertTrue(result is LoginResult.Failed)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue(store.saved.isEmpty())
    }

    // ------------------------------------------------------------------
    // 验证码发送
    // ------------------------------------------------------------------

    @Test
    fun `发送验证码成功返回Success_失败返回Failed`() = runTest {
        authApi.captchaResult = LoginAttempt.Success(LoginData())
        assertEquals(LoginResult.Success, repository.loginByCaptcha(mobile))

        authApi.captchaResult = LoginAttempt.Failed(20010, "发送太频繁")
        assertEquals(LoginResult.Failed("发送太频繁", 20010), repository.loginByCaptcha(mobile))
        // 验证码发送不触碰登录态
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue(store.saved.isEmpty())
    }

    // ------------------------------------------------------------------
    // 多账号（对位 lite kugou_provider.dart:1376-1381 needChooseAccount）
    // ------------------------------------------------------------------

    @Test
    fun `登录返回多账号_需选择后chooseAccount成功`() = runTest {
        val account = LoginAccount(userid = "U20001", token = "T-two", vipToken = null, nickname = "二号")
        authApi.cellphoneResult = LoginAttempt.AccountChoiceRequired(listOf(account))

        val result = repository.loginByCellphone(mobile, code)

        assertEquals(LoginResult.NeedAccountChoice(listOf(account)), result)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue("待选择期间不得落盘", store.saved.isEmpty())

        val chosen = repository.chooseAccount(account)

        assertEquals(LoginResult.Success, chosen)
        assertEquals(loggedInState("U20001", "二号"), repository.authState.value)
        assertEquals(listOf(KugouCredentials("U20001", "T-two", null)), store.saved)
        assertEquals("U20001", store.current)
        assertEquals("token=T-two;userid=U20001", provider.currentHeader())
    }

    @Test
    fun `chooseAccount凭证缺失_返回Failed且不落盘`() = runTest {
        val account = LoginAccount(userid = "U20001", token = null, vipToken = null)

        val result = repository.chooseAccount(account)

        assertTrue(result is LoginResult.Failed)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue(store.saved.isEmpty())
    }

    // ------------------------------------------------------------------
    // 扫码登录（对位 lite generateQrCode / checkQrCode，status==4 确认）
    // ------------------------------------------------------------------

    @Test
    fun `扫码登录_未确认保持等待_确认后落盘`() = runTest {
        authApi.qrCreateResult = LoginAttempt.Success(
            LoginData(qrImage = "data:image/png;base64,AAAA", handle = "H-handle"),
        )
        val session = repository.beginQrLogin()
        requireNotNull(session)
        assertTrue("key 由仓库生成且非空", session.key.isNotBlank())
        assertEquals("data:image/png;base64,AAAA", session.qrImage)
        assertEquals("H-handle", session.handle)
        assertEquals(session.key, authApi.lastQrKey)

        // 等待态：Failed(errorCode=null)（对位 OkHttpKugouAuthApi 三态契约）
        authApi.qrCheckResult = LoginAttempt.Failed(null, "等待扫码")
        val waiting = repository.pollQrLogin(session.key)
        assertEquals(LoginResult.LocalRetry, waiting)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue(store.saved.isEmpty())
        assertEquals(session.key, authApi.lastQrKey)

        // 确认态：status==4，带 token/userid
        authApi.qrCheckResult = LoginAttempt.Success(
            LoginData(token = "T-qr", userid = "U30001", vipToken = "V-qr"),
        )
        val confirmed = repository.pollQrLogin(session.key)
        assertEquals(LoginResult.Success, confirmed)
        assertEquals(loggedInState("U30001"), repository.authState.value)
        assertEquals(listOf(KugouCredentials("U30001", "T-qr", "V-qr")), store.saved)
        assertEquals("token=T-qr;userid=U30001;vip_token=V-qr", provider.currentHeader())
    }

    @Test
    fun `扫码已过期_返回Failed终止轮询`() = runTest {
        authApi.qrCreateResult = LoginAttempt.Success(LoginData(qrImage = "img", handle = "H"))
        val session = requireNotNull(repository.beginQrLogin())
        authApi.qrCheckResult = LoginAttempt.Failed(40010, "二维码已过期")

        val result = repository.pollQrLogin(session.key)

        assertTrue(result is LoginResult.Failed)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue(store.saved.isEmpty())
    }

    @Test
    fun `beginQrLogin创建失败_返回null`() = runTest {
        authApi.qrCreateResult = LoginAttempt.Failed(40010, "二维码生成失败")

        assertNull(repository.beginQrLogin())
    }

    // ------------------------------------------------------------------
    // 微信登录（对位 lite login_page.dart:87-160）
    // ------------------------------------------------------------------

    @Test
    fun `微信登录_begin后poll等待_completeWxLogin成功后落盘`() = runTest {
        authApi.wxCreateResult = LoginAttempt.Success(
            LoginData(handle = "WX-UUID-1", qrImage = "data:image/png;base64,BBBB"),
        )
        val session = repository.beginWxLogin()
        requireNotNull(session)
        assertEquals("WX-UUID-1", session.uuid)
        assertEquals("data:image/png;base64,BBBB", session.qrImage)

        // 轮询等待态（Failed errorCode=null）
        authApi.wxCheckResult = LoginAttempt.Failed(null, "等待扫描")
        assertEquals(LoginResult.LocalRetry, repository.pollWxLogin(session.uuid))
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertEquals(session.uuid, authApi.lastWxUuid)

        // 直接以 code 走开放平台兑换
        authApi.openplatResult = LoginAttempt.Success(
            LoginData(token = "T-wx", userid = "U40001", vipToken = null),
        )
        val result = repository.completeWxLogin("WX-CODE-1")
        assertEquals(LoginResult.Success, result)
        assertEquals(loggedInState("U40001"), repository.authState.value)
        assertEquals(listOf(KugouCredentials("U40001", "T-wx", null)), store.saved)
        assertEquals("token=T-wx;userid=U40001", provider.currentHeader())
    }

    @Test
    fun `微信扫码轮询确认_直接落盘`() = runTest {
        authApi.wxCreateResult = LoginAttempt.Success(LoginData(handle = "WX-UUID-2"))
        val session = requireNotNull(repository.beginWxLogin())
        // 对位 OkHttpKugouAuthApi：checkWxLogin 确认时 Success 直带 token/userid
        authApi.wxCheckResult = LoginAttempt.Success(
            LoginData(token = "T-wx2", userid = "U40002", vipToken = "V-wx2"),
        )

        val result = repository.pollWxLogin(session.uuid)

        assertEquals(LoginResult.Success, result)
        assertEquals(loggedInState("U40002"), repository.authState.value)
        assertEquals(listOf(KugouCredentials("U40002", "T-wx2", "V-wx2")), store.saved)
    }

    @Test
    fun `微信扫码过期_返回Failed`() = runTest {
        authApi.wxCreateResult = LoginAttempt.Success(LoginData(handle = "WX-UUID-3"))
        val session = requireNotNull(repository.beginWxLogin())
        authApi.wxCheckResult = LoginAttempt.Failed(402, "二维码已过期")

        val result = repository.pollWxLogin(session.uuid)

        assertTrue(result is LoginResult.Failed)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
    }

    @Test
    fun `beginWxLogin创建失败_返回null`() = runTest {
        authApi.wxCreateResult = LoginAttempt.Failed(40010, "获取 ticket 失败")

        assertNull(repository.beginWxLogin())
    }

    // ------------------------------------------------------------------
    // 登出（对位 lite setLoginCookies:598：dfid 跨登录态保留）
    // ------------------------------------------------------------------

    @Test
    fun `登出_清凭证清header清当前用户_保留dfid`() = runTest {
        provider.updateDfid("DFID-keep")
        authApi.cellphoneResult = LoginAttempt.Success(LoginData(token = token, userid = userid))
        repository.loginByCellphone(mobile, code)
        require(repository.authState.value is AuthState.LoggedIn)

        repository.logout()

        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertEquals(listOf(userid), store.cleared)
        assertNull(store.current)
        assertNull("登出清 Authorization 头", provider.currentHeader())
        assertEquals("dfid 跨登录态保留", "DFID-keep", provider.dfid())
    }

    // ------------------------------------------------------------------
    // restoreSession（冷启动，对位 lite _autoConnect：先 registerDevice）
    // ------------------------------------------------------------------

    @Test
    fun `restoreSession_有当前用户与凭证_恢复登录态并更新header`() = runTest {
        store.current = userid
        store.credentials[userid] = KugouCredentials(userid, token, vipToken)

        repository.restoreSession()

        assertEquals(loggedInState(), repository.authState.value)
        assertEquals("token=$token;userid=$userid;vip_token=$vipToken", provider.currentHeader())
    }

    @Test
    fun `restoreSession_无当前用户_保持登出`() = runTest {
        store.current = null

        repository.restoreSession()

        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertNull(provider.currentHeader())
    }

    @Test
    fun `restoreSession_凭证不存在_保持登出`() = runTest {
        store.current = "U-missing"

        repository.restoreSession()

        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertNull(provider.currentHeader())
    }

    @Test
    fun `restoreSession_无dfid时注册设备`() = runTest {
        registrar.result = "DFID-REG"
        store.current = null

        repository.restoreSession()

        assertEquals(1, registrar.calls)
        assertEquals("DFID-REG", provider.dfid())
        assertEquals(AuthState.LoggedOut, repository.authState.value)
    }

    @Test
    fun `restoreSession_已有dfid不重复注册`() = runTest {
        provider.updateDfid("DFID-EXISTING")

        repository.restoreSession()

        assertEquals("已有 dfid 不得再注册", 0, registrar.calls)
        assertEquals("DFID-EXISTING", provider.dfid())
    }

    @Test
    fun `restoreSession_设备注册失败_dfid保持null不阻断恢复`() = runTest {
        registrar.result = null
        store.current = userid
        store.credentials[userid] = KugouCredentials(userid, token, null)

        repository.restoreSession()

        assertNull(provider.dfid())
        assertEquals(loggedInState(), repository.authState.value)
        assertEquals("token=$token;userid=$userid", provider.currentHeader())
    }

    // ------------------------------------------------------------------
    // refresh（对位 lite _tryRefreshToken:3413-3435；失败策略：登出）
    // ------------------------------------------------------------------

    @Test
    fun `refresh成功_新凭证覆盖旧凭证`() = runTest {
        authApi.cellphoneResult = LoginAttempt.Success(
            LoginData(token = token, userid = userid, vipToken = vipToken),
        )
        repository.loginByCellphone(mobile, code)
        authApi.refreshResult = LoginAttempt.Success(
            LoginData(token = "T-new", userid = userid, vipToken = "V-new"),
        )

        val ok = repository.refresh()

        assertTrue(ok)
        assertEquals(token to userid, authApi.lastRefreshArgs)
        assertEquals(KugouCredentials(userid, "T-new", "V-new"), store.saved.last())
        assertEquals(userid, store.current)
        assertEquals("token=T-new;userid=$userid;vip_token=V-new", provider.currentHeader())
        assertEquals(loggedInState(), repository.authState.value)
    }

    @Test
    fun `refresh失败_清凭证并登出`() = runTest {
        authApi.cellphoneResult = LoginAttempt.Success(LoginData(token = token, userid = userid))
        repository.loginByCellphone(mobile, code)
        authApi.refreshResult = LoginAttempt.Failed(20018, "token 已失效")

        val ok = repository.refresh()

        assertFalse(ok)
        assertEquals(listOf(userid), store.cleared)
        assertNull(store.current)
        assertNull(provider.currentHeader())
        assertEquals(AuthState.LoggedOut, repository.authState.value)
    }

    @Test
    fun `refresh无凭证_返回false且不动状态`() = runTest {
        store.current = null

        val ok = repository.refresh()

        assertFalse(ok)
        assertEquals(AuthState.LoggedOut, repository.authState.value)
        assertTrue(store.cleared.isEmpty())
    }

    @Test
    fun `刷新期间状态先Refreshing后收敛`() = runTest {
        authApi.cellphoneResult = LoginAttempt.Success(LoginData(token = token, userid = userid))
        repository.loginByCellphone(mobile, code)
        val observed = mutableListOf<AuthState>()
        authApi.refreshResult = LoginAttempt.Success(LoginData(token = "T-new2", userid = userid))
        // 在 refreshLogin 内部读取状态：此刻应已置 Refreshing
        authApi.onRefreshObserve = { observed += repository.authState.value }
        repository.refresh()
        assertEquals(listOf<AuthState>(AuthState.Refreshing), observed)
        assertEquals(loggedInState(), repository.authState.value)
    }

    // ------------------------------------------------------------------
    // 并发：连续两次登录（Mutex 串行化，不产生竞态）
    // ------------------------------------------------------------------

    @Test
    fun `并发连续登录_状态一致且save两次`() = runTest {
        authApi.cellphoneResult = LoginAttempt.Success(LoginData(token = token, userid = userid))
        // 强制交错：首次调用在返回前让出
        var first = true
        authApi.onCellphone = {
            if (first) {
                first = false
                yield()
            }
        }

        val results = listOf(
            async { repository.loginByCellphone(mobile, code) },
            async { repository.loginByCellphone(mobile, code) },
        ).awaitAll()

        assertTrue(results.all { it == LoginResult.Success })
        assertEquals(2, store.saved.size)
        assertEquals(userid, store.current)
        assertEquals(loggedInState(), repository.authState.value)
        assertEquals("token=$token;userid=$userid", provider.currentHeader())
    }

    // ------------------------------------------------------------------
    // 安全：全流程无日志输出 token / vipToken
    // ------------------------------------------------------------------

    @Test
    fun `全流程无日志输出token`() = runTest {
        ShadowLog.setCaptureLogsEnabled(true)
        ShadowLog.clear()
        authApi.cellphoneResult = LoginAttempt.Success(
            LoginData(token = token, userid = userid, vipToken = vipToken),
        )
        repository.loginByCellphone(mobile, code)
        repository.refresh()
        repository.logout()
        repository.restoreSession()

        val leaked = ShadowLog.getLogs().map { it.msg }.filter {
            it.contains(token) || it.contains(vipToken)
        }
        assertTrue("日志不得含 token/vipToken: $leaked", leaked.isEmpty())
    }
}
