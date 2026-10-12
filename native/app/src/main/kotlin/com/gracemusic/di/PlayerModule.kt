package com.gracemusic.di

import android.content.Context
import androidx.annotation.MainThread
import androidx.media3.common.Player
import com.gracemusic.player.engine.AudioEngine
import com.gracemusic.player.engine.AudioEngineConfig
import com.gracemusic.player.engine.AudioEngineFactory
import com.gracemusic.player.engine.EngineRole
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * 播放层 DI。
 *
 * 提供的三件东西各有明确边界：
 * - [AudioEngineFactory]：构建器，无状态，只为让上层能在需要时再建辅引擎（交叉淡化）；
 * - [AudioEngine]（主）：**进程内唯一的播放引擎**。单例而非"每次播放新建"，
 *   是原生化相对 lite 的关键简化：lite 的 `AudioPlayer` 随 Dart 侧 `PlayerProvider`
 *   生命周期反复创建/销毁，导致媒体卡片经常残留旧歌会话（fork 为此写了
 *   `ensureActiveSessionHosted` 一整套收敛逻辑）。引擎单例后，`MediaSession`
 *   可以在服务重建时重建而播放状态不动。
 * - [Player]：把引擎里的 `ExoPlayer` 以 `Player` 接口暴露给系统层
 *   （`MediaSessionService` 建会话只需要 `Player`）。用接口而非 `ExoPlayer`
 *   是有意的收窄：会话/通知代码不应该能拿到 `setWakeMode`、`setAudioSink` 这类
 *   引擎构建期配置入口。
 */
@Module
@InstallIn(SingletonComponent::class)
object PlayerModule {

    @Provides
    @Singleton
    fun provideAudioEngineFactory(@ApplicationContext context: Context): AudioEngineFactory =
        AudioEngineFactory(context)

    /**
     * 主播放引擎。
     *
     * `@MainThread`：`AudioEngineFactory.create` 内部会调用 `ExoPlayer.Builder.build()`
     * 与 `AudioManager.generateAudioSessionId()`，两者都要求主线程（详见工厂类注释）。
     * 标注出来是为了让"从后台线程首次注入本单例"这类错误在代码审查阶段就暴露，
     * 而不是在真机上表现为 `IllegalStateException: Player is accessed on the wrong thread`。
     *
     * 配置当前取默认值（蝰蛇母带开、flac 扩展开、60s 缓冲、`WAKE_MODE_NETWORK`）。
     * TODO(P1)：待设置层（DataStore）落地后改为读用户设置构建；
     *   届时需保证"引擎单例已创建后切换设置"走 `player.set*` 增量路径而非重建引擎。
     */
    @Provides
    @Singleton
    @MainThread
    fun provideMainAudioEngine(factory: AudioEngineFactory): AudioEngine =
        factory.create(AudioEngineConfig(role = EngineRole.MAIN))

    @Provides
    @Singleton
    fun provideMainPlayer(engine: AudioEngine): Player = engine.player
}
