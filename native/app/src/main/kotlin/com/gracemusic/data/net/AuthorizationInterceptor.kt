package com.gracemusic.data.net

import okhttp3.Interceptor
import okhttp3.Response
import javax.inject.Inject

/**
 * 鉴权注入拦截器（F-NET-003 核心）。
 *
 * 逐条对位 lite `kugou_api_client.dart` 的 `_onRequest`（Dio 拦截器）：
 *
 * 1. **`/images` 特判**（lite :259, :274-275, :278-280）：路径含 `/images`
 *    → 不注入 Authorization、不注入 dfid，并**移除**请求上已有的
 *    Authorization 头。依据 lite 注释：「`/images` 接口不需要登录态，带
 *    token 会导致上游返回不同响应（缺少 imgs 字段）」；
 * 2. **已登录**（token + userid 均非空）：`Authorization =
 *    token=<t>;userid=<u>[;vip_token=<v>]`（分号连接；vip_token 仅当非空，
 *    lite :263-267），同时加 `x-apicache-bypass: 1` 与
 *    `Cache-Control: no-cache`（lite :268-272）——Rust apicache 的缓存 key
 *    不含 token，切账号后会命中旧账号缓存（昵称/头像/VIP/歌单串号）；
 * 3. **未登录**：`removeHeader("Authorization")`（lite :274-275）；
 * 4. **dfid**：非 `/images` 且 dfid 非空 → 作为 **query 参数**
 *    `dfid=<v>` 加入（lite :278-280）——dfid 走 query 是 lite 既有决定；
 *    **token 只走 header，绝不进 query/URL**。已存在同名参数时先去重再
 *    加（`removeAllQueryParameters`），避免 URL 出现重复 dfid。
 *
 * ## 线程/性能
 * 拦截器在 OkHttp IO 线程同步执行：本类只做**内存读**（[AuthHeaderProvider]
 * 的 `@Volatile` 字段）+ 字符串拼接，**无 I/O、无锁、无日志**。
 *
 * ## 未实现对位 lite :282-297 的 noCache 分支
 * lite 的 `extra['noCache']`（调用方显式绕 apicache + `t=` 时间戳）在
 * native 尚无调用方；待「我的收藏」等写后刷新需求落地时再补，当前不预造。
 *
 * @param headerProvider 内存凭证缓存（由 AccountRepository 刷新）。
 */
class AuthorizationInterceptor @Inject constructor(
    private val headerProvider: AuthHeaderProvider,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        // 对位 lite :259：/images 不需要登录态（子串匹配，与 lite contains 一致）
        val skipAuth = request.url.encodedPath.contains(IMAGES_MARKER)
        val builder = request.newBuilder()

        if (skipAuth) {
            // 对位 lite :274-275：移除已有 Authorization，避免上游按 token 返回不同响应
            builder.removeHeader(HEADER_AUTHORIZATION)
        } else {
            val authHeader = headerProvider.currentHeader()
            if (authHeader != null) {
                builder.header(HEADER_AUTHORIZATION, authHeader)
                // 对位 lite :268-272：绕 Rust apicache，防切账号串号
                builder.header(HEADER_APICACHE_BYPASS, APICACHE_BYPASS_VALUE)
                builder.header(HEADER_CACHE_CONTROL, CACHE_CONTROL_VALUE)
            } else {
                // 对位 lite :274-275：未登录移除 Authorization
                builder.removeHeader(HEADER_AUTHORIZATION)
            }
            // 对位 lite :278-280：dfid 走 query（/images 不注入）
            val dfid = headerProvider.dfid()
            if (!dfid.isNullOrBlank()) {
                val url = request.url.newBuilder()
                    .removeAllQueryParameters(QUERY_DFID)
                    .addQueryParameter(QUERY_DFID, dfid)
                    .build()
                builder.url(url)
            }
        }

        return chain.proceed(builder.build())
    }

    private companion object {
        /** `/images` 路径标记（对位 lite :259 `path.contains('/images')`）。 */
        const val IMAGES_MARKER: String = "/images"

        const val HEADER_AUTHORIZATION: String = "Authorization"
        const val HEADER_APICACHE_BYPASS: String = "x-apicache-bypass"
        const val HEADER_CACHE_CONTROL: String = "Cache-Control"
        const val APICACHE_BYPASS_VALUE: String = "1"
        const val CACHE_CONTROL_VALUE: String = "no-cache"
        const val QUERY_DFID: String = "dfid"
    }
}
