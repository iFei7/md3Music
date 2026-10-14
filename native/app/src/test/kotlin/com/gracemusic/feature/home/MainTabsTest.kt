package com.gracemusic.feature.home

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 主壳 tab 模型的 JVM 单测（台本 §1 红线 9：P3-A 固定默认 3 tab）。
 */
class MainTabsTest {

    @Test
    fun 默认tab集恰为三个且顺序固定() {
        assertEquals(
            listOf("discover", "favorites", "user"),
            MainTabs.map { it.id },
        )
    }

    @Test
    fun tab标签为中文且唯一() {
        assertEquals(listOf("发现", "收藏", "我的"), MainTabs.map { it.label })
        assertEquals(MainTabs.size, MainTabs.map { it.label }.toSet().size)
    }

    @Test
    fun tab图标成对且selected与unselected不同实例() {
        MainTabs.forEach { tab ->
            assertTrue(
                "tab ${tab.id} 的选中/未选中图标必须成对且不同",
                tab.iconSelected != tab.iconUnselected,
            )
        }
    }

    @Test
    fun tabIndex对已知id返回序号对未知id兜底为末尾() {
        assertEquals(0, tabIndex("discover"))
        assertEquals(1, tabIndex("favorites"))
        assertEquals(2, tabIndex("user"))
        assertEquals(MainTabs.lastIndex, tabIndex("unknown"))
    }
}
