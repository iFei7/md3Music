package com.gracemusic.data.net

import com.gracemusic.data.secure.KugouCredentials
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * [AuthorizationInterceptor] MockWebServer + Robolectric 单测（不依赖 DI）。
 *
 * 断言对象是**最终到达服务器的请求**（RecordedRequest），而非中间态；
 * [AuthHeaderProvider] 用真实实例（Robolectric 提供 prefs 环境），仅
 * dfid 经 [AuthHeaderProvider.updateDfid] 预置，不触网。
 *
 * 逐条对位 lite `kugou_api_client.dart` 的 `_onRequest` 拦截器：
 * `/images` 特判 :259、Authorization 拼接 :260-267、apicache 绕过
 * :268-272、未登录移除 :274-275、dfid query 注入 :278-280。
 */
@RunWith(RobolectricTestRunner::class)
class AuthorizationInterceptorTest {

    private lateinit var server: MockWebServer
    private lateinit var provider: AuthHeaderProvider
    private lateinit var client: OkHttpClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        provider = AuthHeaderProvider(RuntimeEnvironment.getApplication())
        client = OkHttpClient.Builder()
            .addInterceptor(AuthorizationInterceptor(provider))
            .build()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private fun respond(): MockResponse = MockResponse().setResponseCode(200).setBody("{}")

    /** 发起一次 GET 并返回服务器录得的请求（每次自动入队一个 200 空响应）。 */
    private fun get(path: String, presetAuthorization: String? = null): okhttp3.mockwebserver.RecordedRequest {
        server.enqueue(respond())
        val builder = Request.Builder().url(server.url(path)).get()
        if (presetAuthorization != null) builder.header("Authorization", presetAuthorization)
        client.newCall(builder.build()).execute().use { }
        return server.takeRequest()
    }

    private fun header(request: okhttp3.mockwebserver.RecordedRequest, name: String): String? =
        request.getHeader(name)

    private fun queryValues(request: okhttp3.mockwebserver.RecordedRequest, key: String): List<String> =
        request.requestUrl?.queryParameterValues(key)?.filterNotNull().orEmpty()

    private val loggedIn = KugouCredentials(userid = "U10086", token = "T-secret-1", vipToken = null)

    // ------------------------------------------------------------------
    // F-NET-003：已登录注入（对位 lite :260-272）
    // ------------------------------------------------------------------

    @Test
    fun `已登录非images_注入Authorization与apicache绕过头与dfid`() {
        provider.update(loggedIn)
        provider.updateDfid("DFID-abc123")

        val request = get("/song/url")

        assertEquals("token=T-secret-1;userid=U10086", header(request, "Authorization"))
        assertEquals("1", header(request, "x-apicache-bypass"))
        assertEquals("no-cache", header(request, "Cache-Control"))
        assertEquals(listOf("DFID-abc123"), queryValues(request, "dfid"))
    }

    @Test
    fun `已登录带vipToken_Authorization追加第三段`() {
        provider.update(loggedIn.copy(vipToken = "V-secret-2"))

        val request = get("/user/cloud/url")

        assertEquals("token=T-secret-1;userid=U10086;vip_token=V-secret-2", header(request, "Authorization"))
    }

    @Test
    fun `已登录但vipToken为空串_不追加第三段`() {
        provider.update(loggedIn.copy(vipToken = ""))

        val request = get("/song/url")

        assertEquals("token=T-secret-1;userid=U10086", header(request, "Authorization"))
    }

    // ------------------------------------------------------------------
    // /images 特判（对位 lite :259,274-280）
    // ------------------------------------------------------------------

    @Test
    fun `images路径_移除预设Authorization且不注入dfid`() {
        provider.update(loggedIn)
        provider.updateDfid("DFID-abc123")

        val request = get("/images/cover.jpg", presetAuthorization = "token=stale;userid=stale")

        assertNull("images 不得带 Authorization", header(request, "Authorization"))
        assertTrue("images 不得注入 dfid", queryValues(request, "dfid").isEmpty())
    }

    @Test
    fun `路径含images子串_同样跳过鉴权与dfid`() {
        provider.update(loggedIn)
        provider.updateDfid("DFID-abc123")

        val request = get("/singer/images/avatar.jpg")

        assertNull(header(request, "Authorization"))
        assertTrue(queryValues(request, "dfid").isEmpty())
    }

    // ------------------------------------------------------------------
    // 未登录（对位 lite :274-275：仅移除 Authorization；dfid 照注 :279）
    // ------------------------------------------------------------------

    @Test
    fun `未登录_移除预设Authorization但仍注入dfid`() {
        provider.update(null)
        provider.updateDfid("DFID-abc123")

        val request = get("/song/url", presetAuthorization = "token=stale;userid=stale")

        assertNull("未登录不得带 Authorization", header(request, "Authorization"))
        assertEquals(listOf("DFID-abc123"), queryValues(request, "dfid"))
    }

    @Test
    fun `dfid未设置_不注入dfid参数`() {
        provider.update(loggedIn)
        provider.updateDfid(null)

        val request = get("/song/url")

        assertTrue(queryValues(request, "dfid").isEmpty())
    }

    @Test
    fun `dfid为空白串_不注入dfid参数`() {
        provider.update(loggedIn)
        provider.updateDfid("   ")

        val request = get("/song/url")

        assertTrue(queryValues(request, "dfid").isEmpty())
    }

    // ------------------------------------------------------------------
    // dfid 去重（removeAllQueryParameters 后重加）
    // ------------------------------------------------------------------

    @Test
    fun `url已带dfid_替换为最新值且不重复`() {
        provider.update(loggedIn)
        provider.updateDfid("DFID-new")

        val request = get("/song/url?dfid=DFID-old&quality=320")

        assertEquals(listOf("DFID-new"), queryValues(request, "dfid"))
        assertEquals("320", request.requestUrl?.queryParameter("quality"))
    }

    // ------------------------------------------------------------------
    // 安全：token 只走 header，不进 query / URL（对位 lite 既有决定）
    // ------------------------------------------------------------------

    @Test
    fun `token不泄露到query参数`() {
        provider.update(loggedIn.copy(vipToken = "V-secret-2"))
        provider.updateDfid("DFID-abc123")

        val request = get("/song/url?quality=320")

        val path = request.path.orEmpty()
        assertFalse("token 不得进 URL: $path", path.contains("T-secret-1"))
        assertFalse("vipToken 不得进 URL: $path", path.contains("V-secret-2"))
        assertTrue("query 不得含 token 参数", request.requestUrl?.queryParameterNames?.none {
            it == "token" || it == "vip_token"
        } == true)
        // dfid 走 query 是 lite 既有决定（:279-280），此处仅断言其存在性与取值
        assertEquals(listOf("DFID-abc123"), queryValues(request, "dfid"))
    }

    // ------------------------------------------------------------------
    // 外部输入校验：含分隔符/控制字符的凭证拒绝注入（防污染 cookieToJson 语义）
    // ------------------------------------------------------------------

    @Test
    fun `凭证含非法分隔符_拒绝注入Authorization`() {
        // userid 含 ';' 会破坏服务端 cookieToJson 的 ';' 切分语义
        provider.update(KugouCredentials(userid = "U;10086", token = "T-secret-1"))

        val request = get("/song/url")

        assertNull("非法凭证不得注入 Authorization", header(request, "Authorization"))
    }

    @Test
    fun `凭证含控制字符_拒绝注入Authorization`() {
        provider.update(KugouCredentials(userid = "U10086", token = "T-secret-1\r\nX-Evil: 1"))

        val request = get("/song/url")

        assertNull("含 CR/LF 的凭证不得注入 Authorization", header(request, "Authorization"))
    }

    // ------------------------------------------------------------------
    // 状态面：update(null) 清空后恢复未登录形态
    // ------------------------------------------------------------------

    @Test
    fun `updateNull清空凭证_重回未登录形态且保留dfid`() {
        provider.update(loggedIn)
        provider.updateDfid("DFID-abc123")
        provider.update(null)

        val request = get("/song/url", presetAuthorization = "token=stale;userid=stale")

        assertNull(header(request, "Authorization"))
        assertEquals(listOf("DFID-abc123"), queryValues(request, "dfid"))
    }
}
