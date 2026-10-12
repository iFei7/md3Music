package com.gracemusic.player.model

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [AppLoopMode] 三态与行为迁移的移植锁测试。
 *
 * 场景对标 lib/providers/player_provider.dart：
 * - 54 行 enum 三值；
 * - 5143-5153 行 toggleLoopMode 的 off→all→one→off 切换循环；
 * - 1374-1377 行按名称恢复、无法识别回落 off。
 */
class AppLoopModeTest {

    @Test
    fun `三态及顺序与 Dart 一致`() {
        assertEquals(listOf("OFF", "ONE", "ALL"), AppLoopMode.entries.map { it.name })
    }

    @Test
    fun `模式按钮切换循环_不循环到列表循环到单曲循环`() {
        assertEquals(AppLoopMode.ALL, AppLoopMode.OFF.toggled())
        assertEquals(AppLoopMode.ONE, AppLoopMode.ALL.toggled())
        assertEquals(AppLoopMode.OFF, AppLoopMode.ONE.toggled())
    }

    @Test
    fun `切换三步回到原模式`() {
        var mode = AppLoopMode.OFF
        repeat(3) { mode = mode.toggled() }
        assertEquals(AppLoopMode.OFF, mode)
    }

    @Test
    fun `按持久化名称恢复_精确匹配`() {
        assertEquals(AppLoopMode.OFF, AppLoopMode.fromStoredName("OFF"))
        assertEquals(AppLoopMode.ONE, AppLoopMode.fromStoredName("ONE"))
        assertEquals(AppLoopMode.ALL, AppLoopMode.fromStoredName("ALL"))
    }

    @Test
    fun `按持久化名称恢复_无法识别回落不循环`() {
        assertEquals(AppLoopMode.OFF, AppLoopMode.fromStoredName(null))
        assertEquals(AppLoopMode.OFF, AppLoopMode.fromStoredName(""))
        assertEquals(AppLoopMode.OFF, AppLoopMode.fromStoredName("bogus"))
        // 大小写敏感（Dart name 精确匹配，无归一化）
        assertEquals(AppLoopMode.OFF, AppLoopMode.fromStoredName("off"))
    }
}
