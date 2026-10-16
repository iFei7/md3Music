package com.gracemusic.data.net

import android.content.Context
import androidx.core.content.edit
import com.gracemusic.data.secure.KugouCredentials
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 鉴权头的内存缓存面（F-NET-003 的读取侧，供 [AuthorizationInterceptor] 同步读取）。
 *
 * ## 为什么是内存缓存而非每次读盘
 * OkHttp 拦截器在 **IO 线程同步执行**（`Interceptor.intercept` 非挂起函数），
 * 既不能调用 suspend 的 [com.gracemusic.data.secure.TokenStore]（Keystore
 * 解密 + 磁盘 I/O），也不应在拦截器热路径上做阻塞磁盘读。因此凭证在内存
 * 维护一份**预拼接好的 Authorization 头字符串**，由 [com.gracemusic.data.account.AccountRepository]
 * 在登录成功 / 冷启动恢复 / 刷新时经 [update] 刷新；拦截器只做 `@Volatile`
 * 引用读取 + 字符串拼接，**无 I/O、无锁**。
 *
 * ## dfid（设备标识）
 * dfid **非敏感**（对位 lite `kugou_api_client.dart:598` 注释「保留 kugou_dfid，
 * 非机密」），故用普通 SharedPreferences 持久化，键 `kugou_dfid` 与 lite
 * 逐字一致（lite :624 `prefs.getString('kugou_dfid')`）。来源为
 * `/register/dev` 响应（对位 lite `registerDevice` :836-847），由
 * AccountRepository.ensureDeviceRegistered 经 [updateDfid] 写入；**登出不清
 * dfid**（对位 lite 活跃路径：setLoginCookies :598 保留；clearCookies :818
 * 虽清除但全库无调用方，属死代码）。
 *
 * ## 安全
 * - 类内**无任何日志调用**，token/vipToken 不进日志、不进异常消息；
 * - [update] 对凭证做字符校验（见 [isValidHeaderValue]）：含 `;` 或控制
 *   字符的凭证**拒绝注入**（`;` 会破坏 Rust 服务端 cookieToJson 的 `;`
 *   切分语义，CR/LF 属头部注入），失败时按未登录处理而非拼接脏头。
 */
@Singleton
class AuthHeaderProvider @Inject constructor(
    @ApplicationContext context: Context,
) {

    private val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /** 预拼接的 Authorization 头值（`token=<t>;userid=<u>[;vip_token=<v>]`）；未登录为 null。 */
    @Volatile
    private var header: String? = null

    /** dfid 内存缓存（构造时从 prefs 读一次，之后只走内存；拦截器不触盘）。 */
    @Volatile
    private var dfidValue: String? = prefs.getString(KEY_DFID, null)?.takeIf { it.isNotBlank() }

    /** 当前 Authorization 头值；未登录 / 凭证非法返回 null。 */
    fun currentHeader(): String? = header

    /** 当前 dfid；未注册返回 null。 */
    fun dfid(): String? = dfidValue

    /**
     * 刷新凭证（登录成功 / 冷启动恢复 / token 刷新后调用）。
     *
     * 传 null 表示未登录：清空内存头（**不动 dfid**，对位 lite）。
     * 凭证含非法字符时拒绝注入（头保持 null），调用方状态仍可为 LoggedIn，
     * 但请求不会带上脏 Authorization。
     */
    fun update(credentials: KugouCredentials?) {
        header = if (credentials == null) null else buildHeader(credentials)
    }

    /**
     * 更新 dfid 并持久化（设备注册成功后调用）。
     *
     * 传 null 或空白表示清除（对位 lite clearCookies 的死代码路径与
     * setBaseUrl :312 的 `_dfid = null` 语义，native 预留）。
     */
    fun updateDfid(dfid: String?) {
        val normalized = dfid?.takeIf { it.isNotBlank() }
        dfidValue = normalized
        prefs.edit { putString(KEY_DFID, normalized) }
    }

    /**
     * 拼接 Authorization（对位 lite kugou_api_client.dart:263-267）：
     * `token=<t>;userid=<u>`，vipToken 非空才追加 `;vip_token=<v>`。
     *
     * 校验失败返回 null（拒绝注入），绝不抛异常、绝不静默放行脏值。
     */
    private fun buildHeader(credentials: KugouCredentials): String? {
        if (!isValidHeaderValue(credentials.token) || !isValidHeaderValue(credentials.userid)) return null
        val vipToken = credentials.vipToken
        if (vipToken != null && vipToken.isNotEmpty() && !isValidHeaderValue(vipToken)) return null
        return buildString {
            append("token=").append(credentials.token)
            append(";userid=").append(credentials.userid)
            if (!vipToken.isNullOrEmpty()) append(";vip_token=").append(vipToken)
        }
    }

    /**
     * 头值字符白名单校验（外部输入必须校验，安全纪律）：
     * 非空、仅可打印 ASCII（0x20-0x7E）、不含 `;`。
     *
     * - `;` 会破坏 Rust 服务端 cookieToJson 的 `;` 切分（lite :261 注释）；
     * - CR/LF 等控制字符属 HTTP 头注入，OkHttp 亦会拒绝；
     * - token/userid 为上游签发值，正常情况下均为字母数字，本校验只兜底。
     */
    private fun isValidHeaderValue(value: String): Boolean =
        value.isNotEmpty() && value.all { it.code in 0x20..0x7E && it != ';' }

    private companion object {
        /** dfid prefs 文件名（专用，避免与 LoudnessStorePrefs 等混用）。 */
        const val PREFS_FILE: String = "kugou_auth"

        /** dfid 键名（对位 lite `kugou_dfid`，kugou_api_client.dart:624）。 */
        const val KEY_DFID: String = "kugou_dfid"
    }
}
