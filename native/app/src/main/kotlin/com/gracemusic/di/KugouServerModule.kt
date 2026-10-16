package com.gracemusic.di

import android.content.Context
import com.gracemusic.data.account.DeviceRegistrar
import com.gracemusic.data.net.KugouApi
import com.gracemusic.data.net.KugouServerEndpoint
import com.gracemusic.data.net.ManagerKugouServerEndpoint
import com.gracemusic.data.net.OkHttpKugouApi
import com.gracemusic.data.source.LoudnessCache
import com.gracemusic.data.source.LoudnessStore
import com.gracemusic.data.source.LoudnessStorePrefs
import com.gracemusic.kugou.KugouServerGateway
import com.gracemusic.kugou.KugouServerManager
import com.gracemusic.kugou.NativeKugouServerGateway
import com.gracemusic.player.store.StoreScope
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import java.io.IOException
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * 酷狗本地服务层 DI（T-P1-05 网络链路 + F-NET-003 鉴权注入 + F-ACC-005 dfid 注册）。
 *
 * 绑定各司其职：
 * - [KugouServerGateway]：native（libkugou_server.so）操作面，单例；
 * - [KugouServerManager]：启停状态机，dataDir 取应用 filesDir
 *   （Rust 侧持久化 device_info.json，重启后 dfid/mid 不变）；协程作用域
 *   复用 `@StoreScope`（进程级、不随 UI 重建，不新造限定符）；
 * - [KugouApi]：OkHttp 实现，client 由 [NetworkModule] 提供（带
 *   [com.gracemusic.data.net.AuthorizationInterceptor] 鉴权注入），端口来源
 *   仍为 [ManagerKugouServerEndpoint] 包装的真 Manager——**懒启动语义**：
 *   不要求应用启动时预热（Md3MusicApp 保持最小不动），首次 API 请求时才
 *   `ensureStarted`（对位 lite `onServerNeeded`），就绪等待 ≤8s，见
 *   ManagerKugouServerEndpoint KDoc。client 注入不改变该语义与超时配置
 *   （10s/15s，与 OkHttpKugouApi.DEFAULT_CLIENT 一致）；
 * - [DeviceRegistrar]：设备注册 seam（GET /register/dev 取 dfid，对位 lite
 *   registerDevice:836-847），client 同样带鉴权拦截器（未登录时自然不含
 *   Authorization，与 lite registerDevice 走 Dio 拦截器的行为一致）；
 * - [LoudnessStore]：SharedPreferences 实现（独立 prefs 文件
 *   `kugou_loudness`，key 见 [LoudnessStorePrefs.KEY]），供 [LoudnessCache]
 *   持久化；
 * - [LoudnessCache]：@Provides 装配（data/source 冻结契约文件不补 @Inject，
 *   改动最小原则下绑定收敛在本模块）；[com.gracemusic.data.source.SongUrlResolver]
 *   已有 @Inject 构造，经上述两绑定即可被 Hilt 解析。
 */
@Module
@InstallIn(SingletonComponent::class)
object KugouServerModule {

    @Provides
    @Singleton
    fun provideKugouServerGateway(): KugouServerGateway = NativeKugouServerGateway()

    @Provides
    @Singleton
    fun provideKugouServerManager(
        gateway: KugouServerGateway,
        @StoreScope scope: CoroutineScope,
        @ApplicationContext context: Context,
    ): KugouServerManager = KugouServerManager(
        gateway = gateway,
        scope = scope,
        dataDir = context.filesDir.absolutePath,
    )

    /**
     * [KugouApi] 绑定：端口来源走真 Manager（懒启动），client 走 DI
     * （F-NET-003 鉴权拦截器）。
     */
    @Provides
    @Singleton
    fun provideKugouApi(manager: KugouServerManager, client: OkHttpClient): KugouApi =
        OkHttpKugouApi(ManagerKugouServerEndpoint(manager), client)

    /**
     * 设备注册绑定（F-ACC-005 dfid 来源）：GET /register/dev，与登录链路
     * 共享同一 OkHttpClient（鉴权拦截器 + 超时配置）。
     */
    @Provides
    @Singleton
    fun provideDeviceRegistrar(manager: KugouServerManager, client: OkHttpClient): DeviceRegistrar =
        OkHttpDeviceRegistrar(ManagerKugouServerEndpoint(manager), client)

    @Provides
    @Singleton
    fun provideLoudnessStore(@ApplicationContext context: Context): LoudnessStore =
        LoudnessStorePrefs(context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE))

    @Provides
    @Singleton
    fun provideLoudnessCache(store: LoudnessStore): LoudnessCache = LoudnessCache(store)

    /** 响度缓存专用 prefs 文件名（独立于设置页 SP，避免键空间冲突）。 */
    private const val PREFS_FILE: String = "kugou_loudness"
}

/**
 * [DeviceRegistrar] 的 OkHttp 实现：GET 本机 Rust 服务器 `/register/dev`，
 * 解析 `{"status":1,"data":{"dfid":"..."}}` 取 dfid。
 *
 * 对位：
 * - lite `registerDevice`（kugou_api_client.dart:836-847）：lite 只发
 *   **无参** GET（设备参数由 Rust 侧默认值填充，见 register_dev.rs:30-67），
 *   native 同样无参；
 * - Rust `/register/dev`（modules/register_dev.rs:20-28）：device_info.json
 *   命中时直接回缓存 dfid（幂等），故 AccountRepository 侧「prefs 有 dfid
 *   则跳过网络」是等价优化。
 *
 * 失败语义：服务器未就绪 / 非 200 / 畸形 body → null（**不臆造 dfid**，
 * 对位 lite catch 后保持 null；Rust login.rs:158-166 每请求随机兜底）。
 * CancellationException 原样重抛；token 不进日志（本类无日志调用）。
 */
private class OkHttpDeviceRegistrar(
    private val endpoint: KugouServerEndpoint,
    private val client: OkHttpClient,
) : DeviceRegistrar {

    override suspend fun registerDevice(): String? {
        val port = endpoint.portOrNull() ?: return null
        val url: HttpUrl = HttpUrl.Builder()
            .scheme("http")
            .host(LOOPBACK_HOST)
            .port(port)
            .addPathSegment("register")
            .addPathSegment("dev")
            .build()
        val request = Request.Builder().url(url).get().build()
        return try {
            withContext(Dispatchers.IO) {
                client.newCall(request).execute().use { response ->
                    if (response.code != HTTP_OK) return@use null
                    parseDfid(response.body?.string().orEmpty())
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            // 回环连接失败（服务器未就绪/被拒）与 lite catch 语义一致：保持 dfid=null
            null
        }
    }

    /** 解析 `data.dfid`（data 层缺失/非对象/dfid 空白或 JSON null → null，不崩溃）。 */
    private fun parseDfid(body: String): String? = try {
        val root = Json.parseToJsonElement(body) as? JsonObject ?: return null
        val data = root["data"] as? JsonObject ?: return null
        val primitive = data["dfid"]
        if (primitive == null || primitive is JsonNull) return null
        (primitive as? JsonPrimitive)?.content?.takeIf { it.isNotBlank() }
    } catch (e: SerializationException) {
        null
    } catch (e: IllegalArgumentException) {
        null
    }

    private companion object {
        const val LOOPBACK_HOST: String = "127.0.0.1"
        const val HTTP_OK: Int = 200
    }
}
