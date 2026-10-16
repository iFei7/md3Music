package com.gracemusic.di

import com.gracemusic.data.net.AuthHeaderProvider
import com.gracemusic.data.net.AuthorizationInterceptor
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.Provides
import java.util.concurrent.TimeUnit
import javax.inject.Singleton
import okhttp3.OkHttpClient

/**
 * 网络层 DI（F-NET-003 装配）。
 *
 * 当前仅提供与本任务相关的绑定：
 * - [OkHttpClient]：酷狗本机 Rust 服务器链路的共享客户端，装配
 *   [AuthorizationInterceptor]（/images 特判、Authorization 拼接、apicache
 *   绕过、dfid query 注入，对位 lite kugou_api_client.dart:259-280），供
 *   [com.gracemusic.data.net.OkHttpKugouApi] 与
 *   [com.gracemusic.data.net.OkHttpKugouAuthApi] 及设备注册 seam 消费；
 *   超时（connect 10s / read 15s）与 [com.gracemusic.data.net.OkHttpKugouApi]
 *   既有默认客户端逐字一致，加拦截器不改变超时行为。
 *
 * 骨架 TODO 中与本任务无关的项**不预造**：UA 拦截、日志拦截（仅 debug）、
 * Retrofit（kotlinx.serialization converter）——native 请求均为手工 OkHttp
 * GET + query，无 Retrofit 需求；日志拦截天然违背「URL/token 不进日志」
 * 的安全纪律，故不排期。
 */
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun provideOkHttpClient(headerProvider: AuthHeaderProvider): OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(READ_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .addInterceptor(AuthorizationInterceptor(headerProvider))
            .build()

    /** connect 超时（对位 OkHttpKugouApi.DEFAULT_CLIENT：10s）。 */
    private const val CONNECT_TIMEOUT_SECONDS: Long = 10L

    /** read 超时（对位 OkHttpKugouApi.DEFAULT_CLIENT：15s）。 */
    private const val READ_TIMEOUT_SECONDS: Long = 15L
}
