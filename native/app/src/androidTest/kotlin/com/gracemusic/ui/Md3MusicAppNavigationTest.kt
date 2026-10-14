package com.gracemusic.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.feature.discover.DiscoverScreenTestTag
import com.gracemusic.feature.home.MainScaffoldContent
import com.gracemusic.feature.user.FavoritesScreenTestTag
import com.gracemusic.feature.user.UserCenterScreenTestTag
import com.gracemusic.player.state.PlaybackState
import kotlin.time.Duration
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Compose UI 测试：主壳导航（P3-A1 重写，替代 P0-C 占位断言）。
 *
 * 覆盖台本 §3.2 要求的四类断言：
 * 1. 启动后三 tab 可见 + Dock 存在（Dock 为 icon-only，lite :661-664 语义，
 *    tab 项经 `contentDescription = tab.label` 暴露，按 contentDescription 断言）；
 * 2. 点 tab 切换后内容变化（按各页 testTag）；
 * 3. Dock 存在性（Dock 导航三项的 contentDescription 全部可见）；
 * 4. navigate 到 `/player` 后 PlayerScreen 占位可见。
 *
 * 说明：测试 1-3 走 [MainScaffoldContent]（state hoisting 渲染层，无 Hilt
 * 依赖，可真实运行）；测试 4 走 [Md3MusicApp] 全量组合（HOME 路由经
 * `hiltViewModel()` 取 PlaybackStore，真实运行需 Hilt 测试基建——
 * HiltTestRunner + hilt-android-testing，本轮 androidTest 仅作
 * `:app:assembleDebugAndroidTest` 编译门禁，登记遗留）。
 */
@RunWith(AndroidJUnit4::class)
class Md3MusicAppNavigationTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    // ==================== 1/3：三 tab 可见 + Dock 存在 ====================

    @Test
    fun 启动后三个tab可见且Dock存在() {
        composeTestRule.setContent {
            Md3MusicTheme {
                MainScaffoldContent(
                    state = PlaybackState(),
                    position = Duration.ZERO,
                    onTogglePlayPause = {},
                    onNext = {},
                    onPrevious = {},
                    onOpenFullPlayer = {},
                )
            }
        }
        // Dock 导航三项（icon-only，经 contentDescription 暴露 label）
        composeTestRule.onNodeWithContentDescription("发现").assertIsDisplayed()
        composeTestRule.onNodeWithContentDescription("收藏").assertIsDisplayed()
        composeTestRule.onNodeWithContentDescription("我的").assertIsDisplayed()
        // 默认 tab 是 discover
        composeTestRule.onNodeWithTag(DiscoverScreenTestTag).assertIsDisplayed()
    }

    // ==================== 2：tab 切换内容变化 ====================

    @Test
    fun 点击收藏tab切换到收藏页() {
        composeTestRule.setContent {
            Md3MusicTheme {
                MainScaffoldContent(
                    state = PlaybackState(),
                    position = Duration.ZERO,
                    onTogglePlayPause = {},
                    onNext = {},
                    onPrevious = {},
                    onOpenFullPlayer = {},
                )
            }
        }
        composeTestRule.onNodeWithTag(FavoritesScreenTestTag).assertDoesNotExist()

        composeTestRule.onNodeWithContentDescription("收藏").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag(FavoritesScreenTestTag).assertIsDisplayed()
        composeTestRule.onNodeWithText("还没有收藏").assertIsDisplayed()
        composeTestRule.onNodeWithTag(DiscoverScreenTestTag).assertDoesNotExist()
    }

    @Test
    fun 点击我的tab切换到用户中心页() {
        composeTestRule.setContent {
            Md3MusicTheme {
                MainScaffoldContent(
                    state = PlaybackState(),
                    position = Duration.ZERO,
                    onTogglePlayPause = {},
                    onNext = {},
                    onPrevious = {},
                    onOpenFullPlayer = {},
                )
            }
        }
        composeTestRule.onNodeWithTag(UserCenterScreenTestTag).assertDoesNotExist()

        composeTestRule.onNodeWithContentDescription("我的").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag(UserCenterScreenTestTag).assertIsDisplayed()
        composeTestRule.onNodeWithText("登录后同步收藏").assertIsDisplayed()
    }

    // ==================== 4：/player 路由导航 ====================

    @Test
    fun 导航到播放器页显示占位() {
        // 提升 navController 出组合，便于测试直接驱动导航
        // （真实入口 = Dock 的 onOpenFullPlayer，P3-C 换用户点击驱动）。
        lateinit var navController: NavHostController
        composeTestRule.setContent {
            Md3MusicTheme {
                navController = rememberNavController()
                Md3MusicApp(navController = navController)
            }
        }
        composeTestRule.onNodeWithText("/player").assertDoesNotExist()

        composeTestRule.runOnUiThread { navController.navigate(Routes.PLAYER) }
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithText("/player").assertIsDisplayed()
    }
}
