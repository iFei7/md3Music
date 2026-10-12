package com.gracemusic.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * 酷狗本地服务层 DI 骨架（P0-C 仅结构，无绑定）。
 *
 * TODO(P1): 提供 `libkugou_server.so` 的 JNI 封装（符号契约见 cpp/ 与
 *   kugou/ 目录，由其他任务维护，本模块只消费）；本地 HTTP 服务生命周期
 *   与 kugou API 转发（lite 的 `services/kugou_server.dart`）。
 */
@Module
@InstallIn(SingletonComponent::class)
object KugouServerModule
