package com.md3music.md3music.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * 数据库层 DI 骨架（P0-C 仅结构，无绑定）。
 *
 * TODO(P1): 提供 RoomDatabase 实例（`Room.databaseBuilder`，含
 *   fallbackToDestructiveMigration 策略与 schema 导出路径）及各 DAO；
 *   表结构对齐 lite 的本地库（歌曲 / 歌单 / 收藏 / 播放历史 / 设置）。
 */
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule
