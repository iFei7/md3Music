package com.gracemusic.player.offline

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetworkCapabilities

/**
 * [AndroidNetworkAvailabilityProvider] 行为测试（Robolectric `ShadowConnectivityManager`）。
 *
 * **不依赖真实网络**：全部用例通过 `ShadowConnectivityManager` 摆布活动网络与
 * 能力集，或经注入的 `ConnectivityManager` 提供函数模拟异常。
 *
 * ## Robolectric 默认状态（本测试依赖的事实，来自 shadows-framework:4.17 字节码）
 * `ShadowConnectivityManager` 的静态初始化把活动网络设为 **mobile**（netId 0），
 * 且该网络的能力集**只有 TRANSPORT_CELLULAR、没有 `NET_CAPABILITY_INTERNET`**。
 * 因此「有网」用例必须显式给活动网络加上 INTERNET 能力。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class AndroidNetworkAvailabilityProviderTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    private fun connectivityManager(): ConnectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private fun provider(): AndroidNetworkAvailabilityProvider =
        AndroidNetworkAvailabilityProvider(context)

    /**
     * 构造带指定能力集的 `NetworkCapabilities`。
     *
     * 用 Robolectric 的 [ShadowNetworkCapabilities]（`addCapability`/`addTransportType`
     * 在公开 SDK 中是 `@SystemApi`，普通代码不可直接调用）。
     */
    private fun capabilitiesOf(vararg capabilities: Int): NetworkCapabilities {
        val caps = ShadowNetworkCapabilities.newInstance()
        val shadow = shadowOf(caps)
        shadow.addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        capabilities.forEach { shadow.addCapability(it) }
        return caps
    }

    private fun capabilitiesWithInternet(): NetworkCapabilities =
        capabilitiesOf(NetworkCapabilities.NET_CAPABILITY_INTERNET)

    // ------------------------------------------------------------------
    // 有网 / 无网
    // ------------------------------------------------------------------

    @Test
    fun `活动网络具备 INTERNET 能力时返回 true`() {
        val manager = connectivityManager()
        val active = manager.activeNetwork!!
        shadowOf(manager).setNetworkCapabilities(active, capabilitiesWithInternet())

        assertTrue(provider().isNetworkAvailable())
    }

    @Test
    fun `无活动网络时返回 false`() {
        // defaultNetworkActive=false → ShadowConnectivityManager.getActiveNetwork() 返回 null。
        shadowOf(connectivityManager()).setDefaultNetworkActive(false)

        assertFalse(provider().isNetworkAvailable())
    }

    @Test
    fun `活动网络缺少 INTERNET 能力时返回 false`() {
        val manager = connectivityManager()
        val active = manager.activeNetwork!!
        // 只有传输类型、没有 INTERNET 能力（Robolectric 默认形态）。
        shadowOf(manager).setNetworkCapabilities(
            active,
            capabilitiesOf(), // 无任何能力，仅 TRANSPORT_WIFI
        )

        assertFalse(provider().isNetworkAvailable())
    }

    @Test
    fun `只有 INTERNET 没有 VALIDATED 时仍返回 true_保守不误判离线`() {
        // 决策登记：不要求 NET_CAPABILITY_VALIDATED（刚连上 Wi-Fi 时它尚未置位，
        // 要求它会把「有网」误判为离线 → 触发错误停播）。见类 KDoc。
        val manager = connectivityManager()
        val active = manager.activeNetwork!!
        val caps = capabilitiesWithInternet()
        assertFalse("前提：该能力集不含 VALIDATED", caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
        shadowOf(manager).setNetworkCapabilities(active, caps)

        assertTrue(provider().isNetworkAvailable())
    }

    // ------------------------------------------------------------------
    // 「绝不抛异常」兜底
    // ------------------------------------------------------------------

    @Test
    fun `getNetworkCapabilities 返回 null 时返回 true`() {
        val manager = connectivityManager()
        val active = manager.activeNetwork!!
        shadowOf(manager).setNetworkCapabilities(active, null)

        assertTrue("无法判定必须保守判有网", provider().isNetworkAvailable())
    }

    @Test
    fun `ConnectivityManager 查询抛异常时返回 true`() {
        val throwing = AndroidNetworkAvailabilityProvider {
            throw IllegalStateException("模拟 ConnectivityManager 不可用")
        }
        assertTrue("任何异常都必须兜底为有网，绝不外抛", throwing.isNetworkAvailable())
    }

    @Test
    fun `取不到 ConnectivityManager 时返回 true`() {
        assertTrue(AndroidNetworkAvailabilityProvider { null }.isNetworkAvailable())
    }

    // ------------------------------------------------------------------
    // 端口默认实现
    // ------------------------------------------------------------------

    @Test
    fun `AlwaysOnline 默认实现恒为有网`() {
        assertTrue(AlwaysOnlineNetworkAvailabilityProvider.isNetworkAvailable())
    }
}
