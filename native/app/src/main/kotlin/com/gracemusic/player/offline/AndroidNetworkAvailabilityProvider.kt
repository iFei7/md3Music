package com.gracemusic.player.offline

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/**
 * [NetworkAvailabilityProvider] 的生产实现：`ConnectivityManager` **同步按需查询**。
 *
 * ## 为什么是「同步查询」而不是 `NetworkCallback`
 * 端口契约（[NetworkAvailabilityProvider]）要求**同步、无阻塞、绝不抛异常**。
 * `NetworkCallback` 方案需要注册/注销、持有回调引用、并绑定生命周期
 * （注册后不注销就是泄漏；注销时机错误会导致状态永远陈旧），
 * 而本端口的全部调用点都是「此刻是否有网」的一次性判断。
 * 故按需查询是更小、更少泄漏面的选择。
 *
 * ## 判定规则
 * ```
 * 取不到 ConnectivityManager            → true   （无法判定，保守判有网）
 * activeNetwork == null                 → false  （无活动网络 = 离线）
 * getNetworkCapabilities(activeNetwork) == null → true （无法判定，保守判有网）
 * hasCapability(NET_CAPABILITY_INTERNET) → true  （有网）
 * 其它                                   → false
 * ```
 *
 * ### 关于 `NET_CAPABILITY_VALIDATED`（**决策登记**）
 * 任务提示「有条件时用 `NET_CAPABILITY_VALIDATED` 更准确」。本实现**不要求**
 * VALIDATED，原因：VALIDATED 由系统的连通性探测（captive portal 检测）异步置位，
 * 刚连上 Wi-Fi 的数百毫秒内通常**尚未**置位。若要求 VALIDATED，这段时间会被判为
 * 「离线」，从而触发 R-3「停止播放」——违反端口契约的硬约束
 * 「保守，避免误判离线而错误停播」。宁可「有网但解析失败」（走既有失败恢复链），
 * 也不可「明明有网却主动停播」。此偏离已登记在交付报告。
 *
 * ## 「绝不抛异常」
 * 任何 [Exception]（系统服务缺失、OEM 定制收紧权限、`RemoteException`、
 * 内部状态不一致等）一律吞掉并返回 `true`——保守方向（判「有网」不会触发停播；
 * 判「离线」会）。这是**有意的**保守兜底，不是「吞异常伪装成功」：
 * 本方法没有「成功」语义，只有「有网 / 离线」二值，兜底值选风险更小的一侧。
 *
 * 权限：`android.permission.ACCESS_NETWORK_STATE` 已在 `AndroidManifest.xml:6` 声明。
 *
 * @param connectivityManagerProvider 系统服务获取函数（构造期不调用、每次查询调用）。
 *   独立成参数是为了给「取服务/查询抛异常」这条路径一个可注入的接缝（单测用），
 *   生产走 [AndroidNetworkAvailabilityProvider] 的 `Context` 构造器。
 */
class AndroidNetworkAvailabilityProvider internal constructor(
    private val connectivityManagerProvider: () -> ConnectivityManager?,
) : NetworkAvailabilityProvider {

    /** 生产构造器：从应用 [Context] 取 `ConnectivityManager`。 */
    constructor(context: Context) : this({
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    })

    override fun isNetworkAvailable(): Boolean = try {
        when (val manager = connectivityManagerProvider()) {
            // 取不到系统服务：无法判定 → 保守判有网。
            null -> true
            else -> {
                val activeNetwork = manager.activeNetwork
                if (activeNetwork == null) {
                    // 无活动网络：明确离线。
                    false
                } else {
                    val capabilities = manager.getNetworkCapabilities(activeNetwork)
                    when {
                        // 拿不到能力集：无法判定 → 保守判有网。
                        capabilities == null -> true
                        // 有 INTERNET 能力即视为有网（不要求 VALIDATED，见类 KDoc）。
                        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) -> true
                        else -> false
                    }
                }
            }
        }
    } catch (e: Exception) {
        // 绝不抛出：任何异常都按「有网」兜底（保守，避免误判离线而错误停播）。
        true
    }
}
