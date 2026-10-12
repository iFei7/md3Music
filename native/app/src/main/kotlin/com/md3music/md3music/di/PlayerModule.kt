package com.md3music.md3music.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * 播放层 DI 骨架（P0-C 仅结构，无绑定）。
 *
 * TODO(P1): 提供 Media3 ExoPlayer / MediaSession / MediaController
 *   （media3 锁定 1.4.1，与 lite 的 just_audio fork 内嵌源码版本对齐）
 *   与 `MediaSessionService`；音频属性、缓存、音频焦点处理对齐 lite 播放器行为。
 */
@Module
@InstallIn(SingletonComponent::class)
object PlayerModule
