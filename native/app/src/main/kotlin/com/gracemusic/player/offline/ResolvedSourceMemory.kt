package com.gracemusic.player.offline

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/**
 * 「`songId|quality` → 上次成功解析到的音源」的记忆端口。
 *
 * ## 为什么需要它
 * Media3 `CacheDataSource` 只缓存**字节流**（以缓存键为索引），它**不知道**
 * 「这段字节属于哪首歌」。离线时要重建一个可播放的播放项，必须知道
 * 「这首歌上次是用哪个 URL 解析成功的」——否则即使字节还在磁盘上，
 * 也没有可用的 URI 去打开它（`CacheDataSource` 是透明读缓存：命中时仍按原
 * URI 打开，只是内部改读缓存文件）。
 *
 * ## 语义基准
 * 对位 Dart `PlayerProvider.resolveLocalAudioPath` 的**反向**写入侧：Dart 私有构建
 * 在解析成功后直接落本地路径；native 无该钩子，故单独持久化
 * 「键 → 源」（见 [PlaybackCacheResolver.rememberResolvedSource] 的偏离登记）。
 *
 * ## 安全纪律（**强制**）
 * - 存的是**可能含鉴权参数的签名 URL**：**绝不允许写日志**（任何级别），
 *   不得回显到 UI、不得进入崩溃上报的附加信息；
 * - 只允许写入**应用私有存储**（本工程为 `Context.MODE_PRIVATE` 的
 *   SharedPreferences，位于 `/data/data/<pkg>/shared_prefs/`，其他应用不可读）。
 *
 * 实现必须是线程安全的（写入路径在播放线程、读取路径在 IO 线程）。
 */
interface ResolvedSourceMemory {

    /** 读取键对应的源；未记住时返回 `null`。 */
    fun read(key: String): String?

    /** 记住（或覆盖）键对应的源。 */
    fun write(key: String, source: String)
}

/**
 * [ResolvedSourceMemory] 的持久化实现：应用私有 [SharedPreferences]。
 *
 * ## 持久化选择与偏离登记
 * - 任务允许「优先复用仓库已有持久化设施」：`di/DataStoreModule.kt` 目前是**空骨架**
 *   （无任何绑定），引入 DataStore 需要新建 `DataStore<Preferences>` 实例、文件与
 *   异步 API 面，成本高于本阶段所需。故按任务许可回退到 `SharedPreferences`
 *   （应用私有、进程重启后仍在、无额外依赖）。
 * - **后续收敛任务（登记）**：设置层（F-CACHE-009 缓存大小设置）落地时会引入
 *   DataStore；届时把本实现迁移为 DataStore 后端，并保持 [ResolvedSourceMemory]
 *   接口不变（调用方零改动）。
 * - **未加密**：`MODE_PRIVATE` 提供的是「应用隔离」而非「静态加密」。
 *   仓库已有 `androidx.security.crypto`（EncryptedSharedPreferences）可用，
 *   本阶段不引入（该库的 master key 生命周期与备份策略需要单独评审）；
 *   登记为后续加固项。
 *
 * 写入用 `apply()`（异步落盘、不阻塞调用线程）；读取由调用方（
 * [SimplePlaybackCacheResolver]）置于 `Dispatchers.IO`。
 */
class SharedPreferencesResolvedSourceMemory(context: Context) : ResolvedSourceMemory {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun read(key: String): String? = prefs.getString(key, null)

    override fun write(key: String, source: String) {
        // 不得记录 key/source 到任何日志（source 可能含鉴权参数）。
        // 用 core-ktx 的 `edit {}`（默认 commit=false，内部即 apply()：异步落盘、
        // 不阻塞调用线程）——与 `prefs.edit().putString(..).apply()` 语义一致，
        // 且不新增 lint UseKtx 告警。
        prefs.edit { putString(key, source) }
    }

    private companion object {
        /** 专用文件名，避免与设置层的偏好项混用（也便于将来整体迁移/清理）。 */
        const val PREFS_NAME = "gracemusic_playback_cache_sources"
    }
}
