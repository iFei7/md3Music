package com.gracemusic.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * 仓库层 DI 骨架（P0-C 仅结构，无绑定）。
 *
 * TODO(P1): `@Binds` 绑定仓库接口到实现（播放 / 歌单 / 收藏 / 搜索历史 /
 *   设置等），对应 lite 的 data/repositories 目录；绑定走抽象函数，
 *   需将本 object 改为 `abstract class`（Hilt @Binds 要求）。
 */
@Module
@InstallIn(SingletonComponent::class)
object RepositoryModule
