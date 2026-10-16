package com.gracemusic.di

import android.content.Context
import com.gracemusic.data.net.KugouAuthApi
import com.gracemusic.data.net.ManagerKugouServerEndpoint
import com.gracemusic.data.net.OkHttpKugouAuthApi
import com.gracemusic.data.secure.EncryptedSharedPreferencesTokenStore
import com.gracemusic.data.secure.TokenStore
import com.gracemusic.kugou.KugouServerManager
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import okhttp3.OkHttpClient

/**
 * 账号 / 登录 / 凭证 DI（S4a：F-ACC-005 登录链路生产装配的收口模块）。
 *
 * 职责边界：只装配账号域的**接口 → 实现**绑定，不承载任何业务逻辑：
 * - [TokenStore]：凭证加密存储（Keystore + EncryptedSharedPreferences，按
 *   userid 隔离），[com.gracemusic.data.account.AccountRepository] 的凭证
 *   落盘 / 读取端口；
 * - [KugouAuthApi]：登录系列网络接口（本机 Rust 服务器 `/login` 系列、
 *   `/captcha/sent`、`/user/detail`），OkHttp 实现，端口来源复用
 *   [ManagerKugouServerEndpoint]——与 [KugouServerModule] 的
 *   [com.gracemusic.data.net.KugouApi] / DeviceRegistrar 同一个真 Manager，
 *   懒启动语义（不预热、就绪等待 ≤8s）不变。
 *
 * ## OkHttpClient 唯一提供约定（固化 S3 提出的重复绑定风险）
 * [OkHttpClient] **唯一**由 [NetworkModule] 以**非限定符**
 * `@Provides @Singleton` 提供（含
 * [com.gracemusic.data.net.AuthorizationInterceptor] 鉴权注入、connect 10s /
 * read 15s 超时）。本模块**不重复提供** OkHttpClient，也不引入限定符另造
 * 第二份——登录链路与既有链路共享同一客户端实例，鉴权拦截器统一生效
 * （refreshLogin / fetchUserDetail 等登录态请求同样携带 Authorization，
 * 不绕过）。若未来确需专用客户端（不同超时 / 不带拦截器），必须显式引入
 * 限定符并在此登记，**禁止**新增第二个非限定符 OkHttpClient 绑定。
 *
 * ## 不在本模块提供（依赖均有既有绑定，无需重复声明）
 * - [com.gracemusic.data.account.AccountRepository]：已有 `@Singleton` +
 *   `@Inject constructor`，其四个依赖（[KugouAuthApi]、[TokenStore]、
 *   [com.gracemusic.data.net.AuthHeaderProvider]、
 *   [com.gracemusic.data.account.DeviceRegistrar]）分别由本模块、
 *   Hilt 自动构造、[KugouServerModule] 提供；
 * - [com.gracemusic.data.net.AuthHeaderProvider]：已有 `@Singleton` +
 *   `@Inject constructor`，自动构造；
 * - [com.gracemusic.data.account.DeviceRegistrar]：由 [KugouServerModule]
 *   provideDeviceRegistrar 提供（与登录链路共享同一 OkHttpClient）。
 *
 * ## 安全纪律
 * 本模块**只做装配**：不硬编码任何密钥 / token，不读取、不打印、不记录
 * 凭证。token 的签发、落盘与鉴权头注入全部发生在
 * [com.gracemusic.data.account.AccountRepository]、[TokenStore] 实现与
 * [com.gracemusic.data.net.AuthorizationInterceptor] 内部（各自 KDoc 均有
 * 安全约定）——DI 层没有可观测凭证的挂点。
 */
@Module
@InstallIn(SingletonComponent::class)
object AccountModule {

    /**
     * [TokenStore] 绑定：加密凭证存储（F-ACC-005 凭证面，S3 缺口之一）。
     *
     * 单例：凭证状态进程内唯一（多实例会出现「保存后读不到」的竞态）。
     * 实现 [EncryptedSharedPreferencesTokenStore] 自带
     * `@Inject constructor(@ApplicationContext Context)`（供无 DI 场景如
     * 单元测试直接构造）；生产装配经本 @Provides 显式绑定到接口，收敛
     * 「接口是唯一注入点」的约定。
     */
    @Provides
    @Singleton
    fun provideTokenStore(@ApplicationContext context: Context): TokenStore =
        EncryptedSharedPreferencesTokenStore(context)

    /**
     * [KugouAuthApi] 绑定：登录系列网络接口（S3 缺口之二）。
     *
     * 端口来源 [ManagerKugouServerEndpoint]（真 Manager，懒启动语义同
     * [KugouServerModule] 的 KugouApi 绑定）；client 为 [NetworkModule]
     * 唯一提供的共享客户端（带 AuthorizationInterceptor）——登录态请求
     * （refreshLogin / fetchUserDetail）与普通请求同样携带鉴权头。
     * 不使用 [OkHttpKugouAuthApi] 的默认 client（无鉴权拦截器），避免
     * 登录请求绕过统一鉴权面。
     */
    @Provides
    @Singleton
    fun provideKugouAuthApi(manager: KugouServerManager, client: OkHttpClient): KugouAuthApi =
        OkHttpKugouAuthApi(ManagerKugouServerEndpoint(manager), client)
}
