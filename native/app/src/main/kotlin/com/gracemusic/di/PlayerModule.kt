package com.gracemusic.di

import android.content.Context
import androidx.annotation.MainThread
import androidx.media3.common.Player
import com.gracemusic.player.engine.AudioEngine
import com.gracemusic.player.engine.AudioEngineConfig
import com.gracemusic.player.engine.AudioEngineFactory
import com.gracemusic.player.engine.EngineRole
import com.gracemusic.player.engine.ExoPlayerPlaybackEngineAdapter
import com.gracemusic.player.offline.AndroidNetworkAvailabilityProvider
import com.gracemusic.player.offline.NetworkAvailabilityProvider
import com.gracemusic.player.offline.PlaybackCacheConfig
import com.gracemusic.player.offline.PlaybackCacheResolver
import com.gracemusic.player.offline.PlaybackCacheStore
import com.gracemusic.player.offline.ResolvedSourceMemory
import com.gracemusic.player.offline.SharedPreferencesResolvedSourceMemory
import com.gracemusic.player.offline.SimplePlaybackCacheResolver
import com.gracemusic.player.store.AndroidPlaybackKeepAlive
import com.gracemusic.player.store.PlaybackEngine
import com.gracemusic.player.store.PlaybackKeepAlive
import com.gracemusic.player.store.StoreScope
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

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
 *
 * ## 播放域归约入口三件套（T-P1-02 追加）
 * - [PlaybackEngine]：把 [AudioEngine] 适配成播放域最小接口（单曲时间线 +
 *   事件桥接），上层（`PlaybackStore`）只依赖该接口，测试用假引擎即可验证
 *   全部编排逻辑；
 * - [PlaybackKeepAlive]：保活控制器（决策在 Store，实现在前台服务）；
 * - `@StoreScope CoroutineScope`：应用级协程作用域（`SupervisorJob` +
 *   `Dispatchers.Main.immediate`），承载 Store 的位置收集协程——主线程
 *   immediate 与 media3 线程模型一致（采样写入与状态读取同线程，无锁）。
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
     *
     * ## 播放缓存层接线（T-P1-13 / S-A）
     * 注入 [PlaybackCacheStore.dataSourceFactory]，使播放经 `CacheDataSource`
     * （先查缓存、未命中回源、边播边写）。
     *
     * **主线程代价评估（重要）**：[PlaybackCacheStore] 的构造**不**触发磁盘 I/O
     * ——`SimpleCache` 是 `by lazy`，而 `dataSourceFactory` 是委托工厂，
     * 真正的 `CacheDataSource.Factory`/`SimpleCache` 在 `createDataSource()`
     * 时才构建，该调用由 ExoPlayer 在**加载线程**发起。故本 `@MainThread` 提供者
     * 只做一次廉价的 lambda 传递，不会阻塞主线程。详见
     * [PlaybackCacheStore] 类 KDoc 的「构造代价与线程」段。
     */
    @Provides
    @Singleton
    @MainThread
    fun provideMainAudioEngine(
        factory: AudioEngineFactory,
        playbackCacheStore: PlaybackCacheStore,
    ): AudioEngine = factory.create(
        AudioEngineConfig(
            role = EngineRole.MAIN,
            dataSourceFactory = playbackCacheStore.dataSourceFactory,
        ),
    )

    @Provides
    @Singleton
    fun provideMainPlayer(engine: AudioEngine): Player = engine.player

    /**
     * 播放域引擎接口（T-P1-02）。
     *
     * 适配器构造期 `player.addListener` 与媒体调用同受 media3 主线程约束，
     * 故与 [provideMainAudioEngine] 同样标注 `@MainThread`。
     */
    @Provides
    @Singleton
    @MainThread
    fun providePlaybackEngine(engine: AudioEngine): PlaybackEngine =
        ExoPlayerPlaybackEngineAdapter(engine)

    /** 播放保活控制器（T-P1-02）：Store 决策、服务执行。 */
    @Provides
    @Singleton
    fun providePlaybackKeepAlive(@ApplicationContext context: Context): PlaybackKeepAlive =
        AndroidPlaybackKeepAlive(context)

    /**
     * Store 持有的应用级协程作用域（T-P1-02）。
     *
     * `SupervisorJob`：位置收集协程独立失败不拖垮同Scope其他工作；
     * `Dispatchers.Main.immediate`：与引擎调用同线程，采样写入与状态读取无锁。
     * 进程级单例、不取消（Store/引擎进程存续，见 PlaybackStore 生命周期 KDoc）。
     */
    @Provides
    @Singleton
    @StoreScope
    fun provideStoreScope(): CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // ------------------------------------------------------------------
    // 离线播放端口（T-P1-13 / S-A）
    // ------------------------------------------------------------------

    /**
     * 播放缓存层构建参数（专用子目录 + 512 MiB 上限）。
     *
     * 生产固定取默认值；独立成提供者是为了让「缓存大小」设置（F-CACHE-009）
     * 接线时只改这一处（把默认值换成读设置）。
     */
    @Provides
    @Singleton
    fun providePlaybackCacheConfig(): PlaybackCacheConfig = PlaybackCacheConfig()

    /**
     * 「`songId|quality` → 上次解析到的源」的持久化记忆。
     *
     * 实现为应用私有 `SharedPreferences`（见 [SharedPreferencesResolvedSourceMemory]
     * 的持久化选择与后续收敛登记）。**不得**把其中的源 URL 写入任何日志。
     */
    @Provides
    @Singleton
    fun provideResolvedSourceMemory(
        @ApplicationContext context: Context,
    ): ResolvedSourceMemory = SharedPreferencesResolvedSourceMemory(context)

    /**
     * [PlaybackCacheResolver] 的生产实现（`NoOpPlaybackCacheResolver` 仅用于降级/测试）。
     *
     * 绑定后「离线时跳歌到下一首已缓存曲目」的判定才有真实数据源；
     * 若仍绑定 `NoOp`，离线时所有曲目都会被判为未缓存 → 立即停播
     * （见 [com.gracemusic.player.offline.PlaybackCacheResolver] KDoc 的接线顺序风险）。
     */
    @Provides
    @Singleton
    fun providePlaybackCacheResolver(store: PlaybackCacheStore): PlaybackCacheResolver =
        SimplePlaybackCacheResolver(store)

    /**
     * [NetworkAvailabilityProvider] 的生产实现：`ConnectivityManager` 同步按需查询。
     *
     * 绑定后 `PlaybackStore.StoreEngineListener.isNetworkAvailable()` 才能拿到真实值，
     * `RecoveryOrchestrator` 的 `NETWORK_UNAVAILABLE` 分类分支由此变为**可达**
     * （关闭风险 **R4-02**）。本提供者只做端口接线，不改任何恢复/跳歌策略。
     */
    @Provides
    @Singleton
    fun provideNetworkAvailabilityProvider(
        @ApplicationContext context: Context,
    ): NetworkAvailabilityProvider = AndroidNetworkAvailabilityProvider(context)
}
