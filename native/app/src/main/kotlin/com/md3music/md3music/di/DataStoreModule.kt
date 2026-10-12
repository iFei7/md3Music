package com.md3music.md3music.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * DataStore 层 DI 骨架（P0-C 仅结构，无绑定）。
 *
 * TODO(P1): 提供 `DataStore<Preferences>` 实例（`preferencesDataStore` 委托，
 *   文件名对齐 lite 的 SharedPreferences 键：theme_mode / use_dynamic_color /
 *   use_oled_black / use_background_image / background_image_path 等），
 *   承载 ThemeProvider 状态面的 native 对应（见 `SeedColors` 优先级链注释）。
 */
@Module
@InstallIn(SingletonComponent::class)
object DataStoreModule
