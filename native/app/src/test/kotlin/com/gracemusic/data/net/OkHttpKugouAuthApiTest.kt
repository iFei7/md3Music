package com.gracemusic.data.net

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.net.ServerSocket

/**
 * [OkHttpKugouAuthApi] MockWebServer + Robolectric 单测。
 *
 * 服务器端口注入经 [KugouServerEndpoint] seam（MockWebServer 端口冒充
 * Rust 服务器监听端口，模式同 OkHttpKugouApiTest）；`_getAllowNonOk`
 * 等价语义（任何 HTTP 响应都尝试解析 body）用 HTTP 502 + 业务 body 覆盖。
 *
 * 方法名即断言；响应体均为登录接口真实结构的裁剪版（对位 lite
 * kugou_api_client.dart 与 kugou_api_server/rust 各模块）。
 */
@RunWith(RobolectricTestRunner::class)
class OkHttpKugouAuthApiTest {

    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    /** 默认 API：端口 seam 直接指向 MockWebServer。 */
    private fun api(endpoint: KugouServerEndpoint = KugouServerEndpoint { server.port }): OkHttpKugouAuthApi =
        OkHttpKugouAuthApi(endpoint)

    private fun respond(body: String, status: Int = 200): MockResponse =
        MockResponse().setResponseCode(status).setBody(body)

    private fun query(request: RecordedRequest, key: String): String? =
        request.requestUrl?.queryParameter(key)

    /**
     * 失败路径安全断言：文案不得含 mock 主机名 / URL / token 明文
     * （任务安全约束：绝不外泄 URL / token / 上游原始报文）。
     */
    private fun assertSafeFailureMessage(failed: LoginAttempt.Failed, token: String? = null) {
        val message = failed.message
        assertFalse("文案不得含 mock 主机名: $message", message.contains(server.hostName))
        assertFalse("文案不得含 URL: $message", message.contains("http://") || message.contains("https://"))
        token?.let {
            assertFalse("文案不得含 token 明文: $message", message.contains(it))
        }
    }

    // ------------------------------------------------------------------
    // loginByCellphone（对位 lite kugou_api_client.dart:3296-3309，
    // Rust login.rs:139 handle_cellphone）
    // ------------------------------------------------------------------

    @Test
    fun `手机验证码登录成功_抽取 token_userid_vipToken`() = runTest {
        server.enqueue(
            respond("""{"status":1,"data":{"token":"tok-alpha-1","userid":"10086","vip_token":"vip-alpha-1"}}"""),
        )

        val result = api().loginByCellphone("22644212509", "246810")

        val success = result as LoginAttempt.Success
        assertEquals("tok-alpha-1", success.data.token)
        assertEquals("10086", success.data.userid)
        assertEquals("vip-alpha-1", success.data.vipToken)
    }

    @Test
    fun `手机验证码登录 502 带 info_list_返回多账号待选择`() = runTest {
        // 对位 lite kugou_provider.dart:1373-1381：Rust 把多账号响应
        // （error_code=34175）包装成 HTTP 502，但 body 带 data.info_list。
        server.enqueue(
            respond(
                """{"status":0,"error_code":34175,"data":{"info_list":[
                    {"userid":"10086","nickname":"用户甲","token":"tok-alpha-1","vip_token":"vip-alpha-1"},
                    {"userid":"10087","nickname":"用户乙","token":"tok-beta-2"},
                    {"userid":"","nickname":"无ID条目应被过滤"}
                ]}}""",
                status = 502,
            ),
        )

        val result = api().loginByCellphone("22644212509", "246810")

        val choice = result as LoginAttempt.AccountChoiceRequired
        assertEquals("空 userid 条目必须被过滤", 2, choice.accounts.size)
        val first = choice.accounts[0]
        assertEquals("10086", first.userid)
        assertEquals("用户甲", first.nickname)
        assertEquals("tok-alpha-1", first.token)
        assertEquals("vip-alpha-1", first.vipToken)
        val second = choice.accounts[1]
        assertEquals("10087", second.userid)
        assertEquals("用户乙", second.nickname)
        assertEquals("tok-beta-2", second.token)
        assertNull(second.vipToken)
    }

    @Test
    fun `手机验证码登录 error_code 34175 且 info_list 为空_仍判多账号`() = runTest {
        // 34175 特判优先于列表解析：空列表同样返回 AccountChoiceRequired，
        // 不得退化为 Failed（任务判据 §五.3）。
        server.enqueue(
            respond("""{"status":0,"error_code":34175,"data":{"info_list":[]}}""", status = 502),
        )

        val result = api().loginByCellphone("22644212509", "246810")

        val choice = result as LoginAttempt.AccountChoiceRequired
        assertTrue(choice.accounts.isEmpty())
    }

    @Test
    fun `手机验证码登录 error_code 20010_返回 Failed 且文案收敛`() = runTest {
        server.enqueue(
            respond("""{"status":0,"error_code":20010,"error_msg":"登录已过期，请重新登录"}"""),
        )

        val result = api().loginByCellphone("22644212509", "246810")

        val failed = result as LoginAttempt.Failed
        assertEquals(20010, failed.errorCode)
        assertSafeFailureMessage(failed, token = "tok-alpha-1")
    }

    @Test
    fun `手机验证码登录 query 带 mobile_code_选中账号时带 userid`() = runTest {
        server.enqueue(respond("""{"status":1,"data":{"token":"tok-alpha-1","userid":"10086"}}"""))
        api().loginByCellphone("22644212509", "246810", userid = "10087")

        val request = server.takeRequest()
        assertTrue(request.path.orEmpty().startsWith("/login/cellphone?"))
        assertEquals("22644212509", query(request, "mobile"))
        assertEquals("246810", query(request, "code"))
        assertEquals("10087", query(request, "userid"))
    }

    @Test
    fun `手机验证码登录 未指定 userid 时 query 不带 userid`() = runTest {
        server.enqueue(respond("""{"status":1,"data":{"token":"tok-alpha-1","userid":"10086"}}"""))
        api().loginByCellphone("22644212509", "246810")

        val request = server.takeRequest()
        assertNull(query(request, "userid"))
    }

    // ------------------------------------------------------------------
    // sendCaptcha（对位 lite kugou_api_client.dart:3437-3442，
    // Rust misc.rs:136 handle_captcha_sent）
    // ------------------------------------------------------------------

    @Test
    fun `发送验证码成功`() = runTest {
        server.enqueue(respond("""{"status":1}"""))

        val result = api().sendCaptcha("22644212509")

        assertTrue(result is LoginAttempt.Success)
        val request = server.takeRequest()
        assertTrue(request.path.orEmpty().startsWith("/captcha/sent?"))
        assertEquals("22644212509", query(request, "mobile"))
    }

    @Test
    fun `发送验证码失败_返回 Failed`() = runTest {
        server.enqueue(
            respond("""{"status":0,"error_code":40010,"error_msg":"验证码发送失败"}"""),
        )

        val result = api().sendCaptcha("22644212509")

        val failed = result as LoginAttempt.Failed
        assertEquals(40010, failed.errorCode)
        assertSafeFailureMessage(failed)
    }

    // ------------------------------------------------------------------
    // createQrLogin（对位 lite kugou_api_client.dart:3337-3353，
    // Rust login.rs:484 handle_qr_create）
    // ------------------------------------------------------------------

    @Test
    fun `创建二维码 query 含 qrimg_true 与 timestamp_返回 qrImage`() = runTest {
        server.enqueue(
            respond(
                """{"code":200,"data":{"url":"https://h5.kugou.com/loginQRCode","base64":"data:image/png;base64,AAAA"}}""",
            ),
        )

        val result = api().createQrLogin("qr-key-abc")

        val success = result as LoginAttempt.Success
        assertEquals("data:image/png;base64,AAAA", success.data.qrImage)
        val request = server.takeRequest()
        assertTrue(request.path.orEmpty().startsWith("/login/qr/create?"))
        assertEquals("qr-key-abc", query(request, "key"))
        assertEquals("true", query(request, "qrimg"))
        assertNotNullNumeric(query(request, "timestamp"))
    }

    @Test
    fun `创建二维码失败_返回 Failed`() = runTest {
        server.enqueue(respond("""{"status":0,"error_code":40010,"error_msg":"二维码生成失败"}"""))

        val result = api().createQrLogin("qr-key-abc")

        val failed = result as LoginAttempt.Failed
        assertEquals(40010, failed.errorCode)
        assertSafeFailureMessage(failed)
    }

    // ------------------------------------------------------------------
    // checkQrLogin（对位 lite kugou_api_client.dart:3355-3369，
    // Rust login.rs:439 handle_qr_check，status==4 已确认）
    // ------------------------------------------------------------------

    @Test
    fun `扫码三态_等待返回 Failed 无错误码`() = runTest {
        server.enqueue(respond("""{"data":{"status":0}}"""))

        val result = api().checkQrLogin("qr-key-abc")

        val failed = result as LoginAttempt.Failed
        assertNull("扫码前无错误码", failed.errorCode)
        assertSafeFailureMessage(failed)
        val request = server.takeRequest()
        assertTrue(request.path.orEmpty().startsWith("/login/qr/check?"))
        assertEquals("qr-key-abc", query(request, "key"))
        assertNotNullNumeric(query(request, "timestamp"))
    }

    @Test
    fun `扫码三态_已确认返回 Success 带 token`() = runTest {
        server.enqueue(
            respond(
                """{"data":{"status":4,"token":"qr-tok-1","userid":"10086","vip_token":"qr-vip-1"}}""",
            ),
        )

        val result = api().checkQrLogin("qr-key-abc")

        val success = result as LoginAttempt.Success
        assertEquals("qr-tok-1", success.data.token)
        assertEquals("10086", success.data.userid)
        assertEquals("qr-vip-1", success.data.vipToken)
    }

    @Test
    fun `扫码三态_已过期返回 Failed 带错误码`() = runTest {
        server.enqueue(
            respond("""{"status":0,"error_code":40010,"error_msg":"二维码已过期"}"""),
        )

        val result = api().checkQrLogin("qr-key-abc")

        val failed = result as LoginAttempt.Failed
        assertEquals(40010, failed.errorCode)
        assertSafeFailureMessage(failed, token = "qr-tok-1")
    }

    // ------------------------------------------------------------------
    // qrKey（对位 lite kugou_api_client.dart:3321-3335 getLoginQrKey，
    // Rust login.rs:506 handle_qr_key；lite 确有独立端点，故保留本方法）
    // ------------------------------------------------------------------

    @Test
    fun `二维码 key 生成成功_返回 key 句柄`() = runTest {
        server.enqueue(respond("""{"data":{"qrcode":"qr-key-abc","qrcode_img":"data:image/png;base64,BBBB"}}"""))

        val result = api().qrKey()

        val success = result as LoginAttempt.Success
        assertEquals("qr-key-abc", success.data.handle)
        val request = server.takeRequest()
        assertTrue(request.path.orEmpty().startsWith("/login/qr/key?"))
        assertNotNullNumeric(query(request, "timestamp"))
    }

    @Test
    fun `二维码 key 生成失败_返回 Failed`() = runTest {
        server.enqueue(respond("""{"status":0,"error_code":40010}"""))

        val result = api().qrKey()

        val failed = result as LoginAttempt.Failed
        assertEquals(40010, failed.errorCode)
        assertSafeFailureMessage(failed)
    }

    // ------------------------------------------------------------------
    // createWxLogin / checkWxLogin（对位 lite kugou_api_client.dart:3398-3411，
    // Rust login.rs:649 handle_wx_create / :623 handle_wx_check）
    // ------------------------------------------------------------------

    @Test
    fun `微信二维码创建成功_返回 uuid 句柄`() = runTest {
        server.enqueue(respond("""{"data":{"uuid":"wx-uuid-1"}}"""))

        val result = api().createWxLogin()

        val success = result as LoginAttempt.Success
        assertEquals("wx-uuid-1", success.data.handle)
        val request = server.takeRequest()
        assertEquals("/login/wx/create", request.path)
    }

    @Test
    fun `微信二维码创建失败_返回 Failed`() = runTest {
        // 对位 Rust login.rs:665-675：上游失败包装为 502 + {"status":0,"msg":...}
        server.enqueue(respond("""{"status":0,"msg":"获取 ticket 失败"}""", status = 502))

        val result = api().createWxLogin()

        assertTrue(result is LoginAttempt.Failed)
        assertSafeFailureMessage(result as LoginAttempt.Failed)
    }

    @Test
    fun `微信扫码已确认_返回 Success`() = runTest {
        server.enqueue(respond("""{"status":1,"token":"wx-tok-1","userid":"20001"}"""))

        val result = api().checkWxLogin("wx-uuid-1")

        val success = result as LoginAttempt.Success
        assertEquals("wx-tok-1", success.data.token)
        assertEquals("20001", success.data.userid)
        val request = server.takeRequest()
        assertTrue(request.path.orEmpty().startsWith("/login/wx/check?"))
        assertEquals("wx-uuid-1", query(request, "uuid"))
        assertNotNullNumeric(query(request, "timestamp"))
    }

    @Test
    fun `微信扫码失败_返回 Failed`() = runTest {
        server.enqueue(respond("""{"status":0,"error_code":40010,"msg":"二维码已过期"}"""))

        val result = api().checkWxLogin("wx-uuid-1")

        val failed = result as LoginAttempt.Failed
        assertEquals(40010, failed.errorCode)
        assertSafeFailureMessage(failed, token = "wx-tok-1")
    }

    // ------------------------------------------------------------------
    // loginByOpenplat（对位 lite kugou_api_client.dart:3390-3395，
    // Rust login.rs:332 handle_openplat）
    // ------------------------------------------------------------------

    @Test
    fun `开放平台登录成功`() = runTest {
        server.enqueue(respond("""{"status":1,"data":{"token":"op-tok-1","userid":"30001"}}"""))

        val result = api().loginByOpenplat("wx-code-xyz")

        val success = result as LoginAttempt.Success
        assertEquals("op-tok-1", success.data.token)
        assertEquals("30001", success.data.userid)
        val request = server.takeRequest()
        assertTrue(request.path.orEmpty().startsWith("/login/openplat?"))
        assertEquals("wx-code-xyz", query(request, "code"))
    }

    @Test
    fun `开放平台登录失败_返回 Failed`() = runTest {
        server.enqueue(respond("""{"status":0,"error_code":20010,"error_msg":"code 已失效"}"""))

        val result = api().loginByOpenplat("wx-code-xyz")

        val failed = result as LoginAttempt.Failed
        assertEquals(20010, failed.errorCode)
        assertSafeFailureMessage(failed, token = "op-tok-1")
    }

    // ------------------------------------------------------------------
    // refreshLogin（对位 lite kugou_api_client.dart:3371-3379，
    // Rust login.rs:523 handle_token）
    // ------------------------------------------------------------------

    @Test
    fun `刷新登录成功_返回新 token`() = runTest {
        server.enqueue(
            respond("""{"status":1,"data":{"token":"new-tok-1","userid":"10086","vip_token":"new-vip-1"}}"""),
        )

        val result = api().refreshLogin("old-tok-1", "10086")

        val success = result as LoginAttempt.Success
        assertEquals("new-tok-1", success.data.token)
        assertEquals("10086", success.data.userid)
        assertEquals("new-vip-1", success.data.vipToken)
        val request = server.takeRequest()
        assertTrue(request.path.orEmpty().startsWith("/login/token?"))
        assertEquals("old-tok-1", query(request, "token"))
        assertEquals("10086", query(request, "userid"))
    }

    @Test
    fun `刷新登录失败_返回 Failed`() = runTest {
        server.enqueue(respond("""{"status":0,"error_code":20010,"error_msg":"token 已失效"}"""))

        val result = api().refreshLogin("old-tok-1", "10086")

        val failed = result as LoginAttempt.Failed
        assertEquals(20010, failed.errorCode)
        assertSafeFailureMessage(failed, token = "old-tok-1")
    }

    // ------------------------------------------------------------------
    // fetchUserDetail（对位 lite kugou_api_client.dart:3446-3468，
    // Rust user.rs:499 handle_detail，路由 /user/detail mod.rs:122）
    // ------------------------------------------------------------------

    @Test
    fun `用户资料成功_抽取 userid`() = runTest {
        server.enqueue(
            respond("""{"status":1,"data":{"userid":"10086","nickname":"昵称甲","username":"u86"}}"""),
        )

        val result = api().fetchUserDetail()

        val success = result as LoginAttempt.Success
        assertEquals("10086", success.data.userid)
        val request = server.takeRequest()
        assertEquals("/user/detail", request.path)
    }

    @Test
    fun `用户资料 502 业务包装仍解析成功 body`() = runTest {
        // 对位 lite kugou_api_client.dart:3449-3450：Rust 偶发把上游业务错误
        // 包装为 HTTP 502，但 body 仍带 data 用户信息 → 必须读 body 判成功。
        server.enqueue(
            respond("""{"status":1,"data":{"userid":"10086","nickname":"昵称甲"}}""", status = 502),
        )

        val result = api().fetchUserDetail()

        val success = result as LoginAttempt.Success
        assertEquals("10086", success.data.userid)
    }

    @Test
    fun `用户资料失败_token 失效返回 Failed`() = runTest {
        server.enqueue(respond("""{"status":0,"error_code":20010,"error_msg":"token 已失效"}"""))

        val result = api().fetchUserDetail()

        val failed = result as LoginAttempt.Failed
        assertEquals(20010, failed.errorCode)
        assertSafeFailureMessage(failed, token = "old-tok-1")
    }

    // ------------------------------------------------------------------
    // 脱敏 toString（任务安全约束 §五.5）
    // ------------------------------------------------------------------

    @Test
    fun `LoginData toString 脱敏_token 与 vipToken 打码`() {
        val data = LoginData(
            token = "tok-alpha-1",
            userid = "10086",
            vipToken = "vip-alpha-1",
            qrImage = "data:image/png;base64,AAAA",
            handle = "qr-key-abc",
        )

        val rendered = data.toString()

        assertFalse("token 不得明文: $rendered", rendered.contains("tok-alpha-1"))
        assertFalse("vipToken 不得明文: $rendered", rendered.contains("vip-alpha-1"))
        assertTrue(rendered.contains("token=***"))
        assertTrue(rendered.contains("vipToken=***"))
        assertTrue("userid 保留明文（非敏感标识）", rendered.contains("userid=10086"))
    }

    @Test
    fun `LoginData toString 可空字段显示占位符`() {
        val data = LoginData()

        val rendered = data.toString()

        assertTrue(rendered.contains("token=?"))
        assertTrue(rendered.contains("qrImage=?"))
        assertTrue(rendered.contains("handle=?"))
    }

    @Test
    fun `LoginAccount toString 脱敏_token 与 vipToken 打码`() {
        val account = LoginAccount(
            userid = "10086",
            token = "tok-alpha-1",
            vipToken = "vip-alpha-1",
            nickname = "用户甲",
        )

        val rendered = account.toString()

        assertFalse("token 不得明文: $rendered", rendered.contains("tok-alpha-1"))
        assertFalse("vipToken 不得明文: $rendered", rendered.contains("vip-alpha-1"))
        assertTrue(rendered.contains("token=***"))
        assertTrue(rendered.contains("vipToken=***"))
        assertTrue(rendered.contains("userid=10086"))
    }

    // ------------------------------------------------------------------
    // 协程取消（任务 §五.6）
    // ------------------------------------------------------------------

    @Test
    fun `挂起中被取消_CancellationException 继续抛出`() = runTest {
        var cancelObserved = false
        val endpoint = KugouServerEndpoint {
            try {
                delay(Long.MAX_VALUE)
            } catch (e: CancellationException) {
                cancelObserved = true
                throw e
            }
            server.port
        }

        val job = launch { OkHttpKugouAuthApi(endpoint).loginByCellphone("22644212509", "246810") }
        advanceTimeBy(50)
        job.cancelAndJoin()

        assertTrue("端口探测挂起点必须收到取消", cancelObserved)
        assertTrue("CancellationException 必须穿透实现传播给协程", job.isCancelled)
    }

    // ------------------------------------------------------------------
    // 本地服务器层失败（LocalFailureKind，对位 KugouApi.kt:94-101）
    // ------------------------------------------------------------------

    @Test
    fun `服务器未就绪_返回 SERVER_UNAVAILABLE`() = runTest {
        val result = api(KugouServerEndpoint { null }).loginByCellphone("22644212509", "246810")

        assertEquals(
            LoginAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE),
            result,
        )
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `连接被拒_返回 SERVER_UNAVAILABLE`() = runTest {
        val socket = ServerSocket(0)
        val deadPort = socket.localPort
        socket.close()

        val result = api(KugouServerEndpoint { deadPort }).loginByCellphone("22644212509", "246810")

        assertEquals(
            LoginAttempt.LocalFailure(LocalFailureKind.SERVER_UNAVAILABLE),
            result,
        )
    }

    @Test
    fun `503 忙_返回 SERVER_BUSY`() = runTest {
        // 对位 OkHttpKugouApi busyKind 判据（KugouApi.kt:96）：503 +
        // error=local_server_busy + retryable=true。
        server.enqueue(
            respond("""{"error":"local_server_busy","retryable":true}""", status = 503),
        )

        val result = api().loginByCellphone("22644212509", "246810")

        assertEquals(
            LoginAttempt.LocalFailure(LocalFailureKind.SERVER_BUSY),
            result,
        )
    }

    // ------------------------------------------------------------------
    // 畸形 body（_getAllowNonOk 等价语义的收敛路径）
    // ------------------------------------------------------------------

    @Test
    fun `畸形 body_返回 Failed 兜底文案`() = runTest {
        server.enqueue(respond("<html><body>502 Bad Gateway</body></html>", status = 502))

        val result = api().loginByCellphone("22644212509", "246810")

        val failed = result as LoginAttempt.Failed
        assertNull(failed.errorCode)
        assertSafeFailureMessage(failed)
    }

    /** timestamp query 参数必须是纯数字（System.currentTimeMillis 派生）。 */
    private fun assertNotNullNumeric(timestamp: String?) {
        assertNotNull(timestamp)
        assertTrue("timestamp 必须为纯数字: $timestamp", timestamp!!.all { it.isDigit() })
    }

    private fun assertNotNull(value: String?) {
        assertTrue("期望非 null", value != null)
    }
}
