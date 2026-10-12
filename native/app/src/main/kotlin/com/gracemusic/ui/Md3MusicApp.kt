package com.gracemusic.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.gracemusic.core.responsive.LocalWindowSizeClass
import com.gracemusic.core.responsive.rememberWindowSizeClass
import com.gracemusic.core.ui.AppBackground
import com.gracemusic.feature.home.HomeScreen
import com.gracemusic.feature.library.LibraryScreen
import com.gracemusic.feature.onboarding.OnboardingScreen
import com.gracemusic.feature.personalfm.PersonalFmScreen
import com.gracemusic.feature.player.PlayerScreen
import com.gracemusic.feature.playlist.PlaylistScreen
import com.gracemusic.feature.search.SearchScreen
import com.gracemusic.feature.settings.SettingsScreen
import com.gracemusic.feature.user.UserScreen

/**
 * 路由表（P0-C 骨架）。
 *
 * 移植自 lite `lib/app.dart` 的 routes / onGenerateRoute（9 条路由）：
 * `/`、`/onboarding`、`/playlist`、`/search`、`/library`、`/settings`、
 * `/user`、`/player`、`/personal_fm`。
 *
 * 说明：
 * - lite 的 `/playlist` 经 onGenerateRoute 接收 `Playlist` 对象参数；native 侧
 *   先用可空字符串 id 占位（query 参数），P3 接 DataSource 后按 id 加载歌单；
 * - lite 另有 `/user_agreement`（用户协议页），P0-C 路由表未含（协议流程属
 *   启动任务，P1 与 DataStore 的就绪判断一并落地）。
 */
object Routes {
    const val HOME = "/"
    const val ONBOARDING = "/onboarding"
    const val PLAYLIST = "/playlist"
    const val SEARCH = "/search"
    const val LIBRARY = "/library"
    const val SETTINGS = "/settings"
    const val USER = "/user"
    const val PLAYER = "/player"
    const val PERSONAL_FM = "/personal_fm"

    /** `/playlist` 的歌单 id 参数名（可空字符串）。 */
    const val ARG_PLAYLIST_ID = "playlistId"

    /** `/playlist` 完整路由模式（query 参数可选，id 为空时退化为无参入口）。 */
    const val PLAYLIST_ROUTE = "$PLAYLIST?$ARG_PLAYLIST_ID={$ARG_PLAYLIST_ID}"

    /** 跳转 `/playlist`：传 null 表示未指定歌单（占位屏不消费该参数）。 */
    fun playlist(playlistId: String?): String =
        if (playlistId.isNullOrEmpty()) PLAYLIST else "$PLAYLIST?$ARG_PLAYLIST_ID=$playlistId"
}

/**
 * md3Music 原生版应用根组合。
 *
 * 结构（对应 lite `MaterialApp(builder:)` 的层级）：
 * 1. 注入 [LocalWindowSizeClass]（响应式断层的 CompositionLocal 提供位）；
 * 2. [AppBackground] 全局背景占位（P0-C 纯色打底）；
 * 3. [Md3MusicNavHost] 导航图。
 *
 * 由 `MainActivity` 在 `Md3MusicTheme { Md3MusicApp() }` 中使用；
 * [navController] 暴露给测试与后续深链（notification / widget 跳转）场景。
 */
@Composable
fun Md3MusicApp(navController: NavHostController = rememberNavController()) {
    val windowSizeClass = rememberWindowSizeClass()
    // 尺寸分级在根层计算一次，页面侧经 LocalWindowSizeClass.current 读取
    CompositionLocalProvider(LocalWindowSizeClass provides windowSizeClass) {
        AppBackground {
            Md3MusicNavHost(navController = navController)
        }
    }
}

@Composable
internal fun Md3MusicNavHost(navController: NavHostController) {
    NavHost(
        navController = navController,
        startDestination = Routes.HOME,
    ) {
        // TODO(P3): 转场对齐 lite（当前用 NavHost 默认淡入淡出）：
        //   - `/` 主页用 _UpFadeMainRoute：FullPlayer(/player) push 时主页
        //     向上偏移 15% + 淡出（仅 FullPlayer 生效，playerExpansion > 0.5）；
        //   - `/onboarding`：fade + emphasisDuration(600ms)；
        //   - `/playlist`：fade；
        //   - 二级页面内嵌 AppBackground 随页面位移入场（_BgSafeFadeForwardsBuilder）。
        // TODO(P3): `/` 主页承载底部 tab（discover/favorites/library/fm/search/
        //   recognition/settings/user，见 lite _buildPageForTab 与 TabConfigProvider），
        //   P0-C 先以单占位屏呈现。
        composable(Routes.HOME) {
            HomeScreen()
        }
        composable(Routes.ONBOARDING) {
            OnboardingScreen()
        }
        composable(
            route = Routes.PLAYLIST_ROUTE,
            arguments = listOf(
                navArgument(Routes.ARG_PLAYLIST_ID) {
                    type = NavType.StringType
                    nullable = true
                    defaultValue = null
                },
            ),
        ) {
            PlaylistScreen()
        }
        composable(Routes.SEARCH) {
            SearchScreen()
        }
        composable(Routes.LIBRARY) {
            LibraryScreen()
        }
        composable(Routes.SETTINGS) {
            SettingsScreen()
        }
        composable(Routes.USER) {
            UserScreen()
        }
        composable(Routes.PLAYER) {
            PlayerScreen()
        }
        composable(Routes.PERSONAL_FM) {
            PersonalFmScreen()
        }
    }
}
