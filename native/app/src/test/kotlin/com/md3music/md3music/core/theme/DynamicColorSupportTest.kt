package com.md3music.md3music.core.theme

import android.app.Application
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 动态取色门槛测试（API 31+）。
 *
 * `supportsDynamicColor()` 读取 `android.os.Build.VERSION.SDK_INT`，
 * 需 Robolectric 提供桩化的 Build 字段。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class DynamicColorSupportTest {

    @Test
    @Config(sdk = [31])
    fun `API 31 支持系统动态取色`() {
        assertTrue(supportsDynamicColor())
    }

    @Test
    @Config(sdk = [30])
    fun `API 30 不支持系统动态取色`() {
        assertFalse(supportsDynamicColor())
    }
}
