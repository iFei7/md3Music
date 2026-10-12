package com.md3music.md3music.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * 网络层 DI 骨架（P0-C 仅结构，无绑定）。
 *
 * TODO(P1): 提供 OkHttpClient（连接/读取超时、UA 拦截、日志拦截仅 debug）、
 *   Retrofit（kotlinx.serialization converter）与 API 接口实例；
 *   对应 lite 的网络客户端配置（kugou API 走本地 Rust 服务器转发，
 *   域名与证书固定见 network_security_config.xml）。
 */
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule
