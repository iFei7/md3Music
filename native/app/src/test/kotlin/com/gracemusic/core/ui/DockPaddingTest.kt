package com.gracemusic.core.ui

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Dock 避让计算的 JVM 单测（lite app.dart:1180-1189 注入语义）。
 */
class DockPaddingTest {

    @Test
    fun dock可见时避让为导航栏加72dp() {
        assertEquals(72.dp + 24.dp, dockAvoidanceBottom(24.dp, true))
    }

    @Test
    fun dock不可见时仅保留导航栏insets() {
        assertEquals(24.dp, dockAvoidanceBottom(24.dp, false))
    }

    @Test
    fun 手势条为0时避让即Dock高度() {
        assertEquals(DockHeight, dockAvoidanceBottom(0.dp, true))
    }

    @Test
    fun 自定义dock高度参与叠加() {
        assertEquals(16.dp + 52.dp, dockAvoidanceBottom(16.dp, true, 52.dp))
    }
}
