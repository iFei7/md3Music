package com.gracemusic.di

import android.content.Context
import com.gracemusic.data.net.KugouApi
import com.gracemusic.data.net.OkHttpKugouApi
import com.gracemusic.data.source.LoudnessCache
import com.gracemusic.data.source.LoudnessStore
import com.gracemusic.data.source.LoudnessStorePrefs
import com.gracemusic.kugou.KugouServerGateway
import com.gracemusic.kugou.KugouServerManager
import com.gracemusic.kugou.NativeKugouServerGateway
import com.gracemusic.player.store.StoreScope
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope

/**
 * 酷狗本地服务层 DI（T-P1-05 网络链路）。
 *
 * 绑定各司其职：
 * - [KugouServerGateway]：native（libkugou_server.so）操作面，单例；
 * - [KugouServerManager]：启停状态机，dataDir 取应用 filesDir
 *   （Rust 侧持久化 device_info.json，重启后 dfid/mid 不变）；协程作用域
 *   复用 `@StoreScope`（进程级、不随 UI 重建，不新造限定符）；
 * - [KugouApi]：OkHttp 实现，构造经 [OkHttpKugouApi] 的 Manager 便捷构造
 *   绑定真 Manager——**懒启动语义**：不要求应用启动时预热（Md3MusicApp
 *   保持最小不动），首次 API 请求时才 `ensureStarted`（对位 lite
 *   `onServerNeeded`），就绪等待 ≤8s，见 ManagerKugouServerEndpoint KDoc；
 * - [LoudnessStore]：SharedPreferences 实现（独立 prefs 文件
 *   `kugou_loudness`，key 见 [LoudnessStorePrefs.KEY]），供 [LoudnessCache]
 *   持久化；
 * - [LoudnessCache]：@Provides 装配（data/source 冻结契约文件不补 @Inject，
 *   改动最小原则下绑定收敛在本模块）；[SongUrlResolver] 已有 @Inject 构造，
 *   经上述两绑定即可被 Hilt 解析。
 */
@Module
@InstallIn(SingletonComponent::class)
object KugouServerModule {

    @Provides
    @Singleton
    fun provideKugouServerGateway(): KugouServerGateway = NativeKugouServerGateway()

    @Provides
    @Singleton
    fun provideKugouServerManager(
        gateway: KugouServerGateway,
        @StoreScope scope: CoroutineScope,
        @ApplicationContext context: Context,
    ): KugouServerManager = KugouServerManager(
        gateway = gateway,
        scope = scope,
        dataDir = context.filesDir.absolutePath,
    )

    @Provides
    @Singleton
    fun provideKugouApi(manager: KugouServerManager): KugouApi = OkHttpKugouApi(manager)

    @Provides
    @Singleton
    fun provideLoudnessStore(@ApplicationContext context: Context): LoudnessStore =
        LoudnessStorePrefs(context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE))

    @Provides
    @Singleton
    fun provideLoudnessCache(store: LoudnessStore): LoudnessCache = LoudnessCache(store)

    /** 响度缓存专用 prefs 文件名（独立于设置页 SP，避免键空间冲突）。 */
    private const val PREFS_FILE: String = "kugou_loudness"
}
