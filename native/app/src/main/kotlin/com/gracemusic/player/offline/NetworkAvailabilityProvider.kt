package com.gracemusic.player.offline

/**
 * 网络可用性查询端口（**冻结契约，逐字实现，不得改名/改签名**）。
 *
 * ## 为什么需要它
 * 产品要求（2026-10-15）的「断网时在线歌单行为」以「当前是否断网」为**首要判据**，
 * 而 native 此前**没有任何连接可用性监测**：`PlaybackStore.StoreEngineListener`
 * 的 `isNetworkAvailable()` 硬编码返回 `true`，`RecoveryOrchestrator` 的
 * `NETWORK_UNAVAILABLE` 分类分支因此**不可达**（风险 **R4-02**，见
 * `docs/native/phase-4-risks.md`）。本接口即该判据的**唯一来源**。
 *
 * ## 语义基准
 * 对位 Dart `_lastHasNetwork`（`player_provider.dart:365`、`:1075-1079`、
 * `:1120`）：由 `connectivity_plus` 的 `onConnectivityChanged` 维护，判定
 * `!results.contains(ConnectivityResult.none)`。
 *
 * ## 偏离登记（相对 Dart）
 * - Dart 侧由 `connectivity_plus` 的**流式订阅**维护一个缓存的 `_lastHasNetwork`
 *   布尔；本端口刻意收窄为**同步按需查询**（`fun interface` 单方法），
 *   由实现方内部自行决定是否订阅。理由：端口契约要求「同步、无阻塞」，
 *   且调用点在恢复决策等高频路径上，流式订阅会引入生命周期与泄漏负担。
 *   见 [AndroidNetworkAvailabilityProvider] 的 KDoc。
 *
 * ## 实现约束
 * - 必须是**同步、无阻塞**的查询（可在高频路径与恢复决策路径上被调用）；
 * - **不得抛异常**：任何异常 / 无法判定一律返回 `true`（保守，避免误判为离线而错误停播）。
 */
fun interface NetworkAvailabilityProvider {

    /** 当前是否有可用网络（`true` = 有网）。 */
    fun isNetworkAvailable(): Boolean
}

/**
 * [NetworkAvailabilityProvider] 的默认实现：恒「有网」。
 *
 * 与 `PlaybackStore.StoreEngineListener.isNetworkAvailable()` 的硬编码 `true` 等价，
 * 仅把该隐式约定**显式化**为一个可替换端口。用于「不希望引入真实网络探测」的
 * 场景（例如无 `ConnectivityManager` 的纯 JVM 测试替身）。
 *
 * ⚠️ 生产接线（`di/PlayerModule.kt`）绑定的是 [AndroidNetworkAvailabilityProvider]，
 * 本对象只在测试 / 降级路径上使用。
 */
object AlwaysOnlineNetworkAvailabilityProvider : NetworkAvailabilityProvider {
    override fun isNetworkAvailable(): Boolean = true
}
