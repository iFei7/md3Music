package com.gracemusic.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.gracemusic.core.theme.Md3MusicTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Compose UI 测试：导航骨架（P0-C）。
 *
 * 断言首页占位可见、导航到 /settings 显示对应占位。
 * 无真机环境下由 `:app:assembleDebugAndroidTest` 保证编译通过。
 */
@RunWith(AndroidJUnit4::class)
class Md3MusicAppNavigationTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun 首页占位可见() {
        composeTestRule.setContent {
            Md3MusicTheme {
                Md3MusicApp()
            }
        }
        composeTestRule.onNodeWithText("/").assertIsDisplayed()
        composeTestRule.onNodeWithText("/settings").assertDoesNotExist()
    }

    @Test
    fun 导航到设置页显示对应占位() {
        // 提升 navController 出组合，便于测试直接驱动导航
        // （占位屏本身无交互元素，P3 feature 落地后改由真实入口点击驱动）
        lateinit var navController: NavHostController
        composeTestRule.setContent {
            Md3MusicTheme {
                navController = rememberNavController()
                Md3MusicApp(navController = navController)
            }
        }
        composeTestRule.onNodeWithText("/").assertIsDisplayed()
        composeTestRule.onNodeWithText("/settings").assertDoesNotExist()

        composeTestRule.runOnUiThread { navController.navigate(Routes.SETTINGS) }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithText("/").assertDoesNotExist()
        composeTestRule.onNodeWithText("/settings").assertIsDisplayed()
    }
}
