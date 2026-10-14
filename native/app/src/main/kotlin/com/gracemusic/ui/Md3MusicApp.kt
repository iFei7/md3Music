package com.gracemusic.ui

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.gracemusic.core.responsive.LocalWindowSizeClass
import com.gracemusic.core.responsive.rememberWindowSizeClass
import com.gracemusic.core.theme.Md3Motion
import com.gracemusic.core.ui.AppBackground
import com.gracemusic.feature.home.MainScaffold
import com.gracemusic.feature.library.LibraryScreen
import com.gracemusic.feature.onboarding.OnboardingScreen
import com.gracemusic.feature.personalfm.PersonalFmScreen
import com.gracemusic.feature.player.PlayerScreen
import com.gracemusic.feature.playlist.PlaylistScreen
import com.gracemusic.feature.search.SearchScreen
import com.gracemusic.feature.settings.SettingsScreen
import com.gracemusic.feature.user.UserScreen
import androidx.compose.ui.unit.IntOffset
import kotlin.math.roundToInt

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
        // 转场对齐 lite（P3-A1 落地，替代 P0-C 默认淡入淡出）：
        //   - `/` ↔ `/player`：FullPlayer 300ms 淡入 + 从 15% 屏高上滑
        //     （lite _UpFadeMainRoute，playerExpansion > 0.5 生效的语义由
        //     路由转场近似——拖拽跟手 P3-D，登记偏离台本 §2）；
        //   - `/onboarding`：fade + emphasisDuration(600ms)；
        //   - `/playlist`：fade 400ms；
        //   - 二级页面内嵌 AppBackground 随页面位移入场（_BgSafeFadeForwardsBuilder）
        //     仍留 P3-D（背景系统未接线）。
        composable(
            Routes.HOME,
            enterTransition = { homeEnterTransition(initialState) },
            // 登记偏离：lite 仅在被 FullPlayer 覆盖时 up-fade（playerExpansion
            // 判定），Compose Navigation 无法在 exit 中取「即将覆盖的页」的
            // 展开度，简化为 HOME exit 恒 up-fade 300ms（-15% 位移 + 淡出）。
            exitTransition = { homeExitTransition() },
        ) {
            MainScaffold(
                onOpenFullPlayer = { navController.navigate(route = Routes.PLAYER) },
            )
        }
        composable(
            Routes.ONBOARDING,
            enterTransition = { fadeIn(animationSpec = Md3Motion.emphasizedTween()) },
            exitTransition = { fadeOut(animationSpec = Md3Motion.emphasizedTween()) },
        ) {
            OnboardingScreen()
        }
        composable(
            route = Routes.PLAYLIST_ROUTE,
            enterTransition = { fadeIn(animationSpec = Md3Motion.expressiveTween()) },
            exitTransition = { fadeOut(animationSpec = Md3Motion.expressiveTween()) },
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
        composable(
            Routes.PLAYER,
            enterTransition = { playerEnterTransition() },
            exitTransition = { playerExitTransition() },
        ) {
            PlayerScreen()
        }
        composable(Routes.PERSONAL_FM) {
            PersonalFmScreen()
        }
    }
}

// ==================== 主壳 / 播放器转场（P3-A1） ====================
// 常量与曲线取自 Md3Motion；300ms 为 lite FullPlayer 转场时长
// （Md3Motion 无对应常量，core/theme/Motion.kt 不在本任务改动范围，
// 收敛为本文件私有常量）。

private const val FullPlayerTransitionMillis = 300

/** FullPlayer 屏高位移比例 15%（lite `_UpFadeMainRoute`）。 */
private const val FullPlayerSlideFraction = 0.15f

private fun playerFadeSpec() = tween<Float>(
    durationMillis = FullPlayerTransitionMillis,
    easing = Md3Motion.EmphasizedEasing,
)

private fun playerSlideSpec() = tween<IntOffset>(
    durationMillis = FullPlayerTransitionMillis,
    easing = Md3Motion.EmphasizedEasing,
)

/** PLAYER enter：淡入 + 从 15% 屏高下方上滑（lite FullPlayer 打开）。 */
private fun playerEnterTransition(): EnterTransition =
    slideInVertically(animationSpec = playerSlideSpec()) { full: Int ->
        (full * FullPlayerSlideFraction).roundToInt()
    } + fadeIn(animationSpec = playerFadeSpec())

/** PLAYER exit：反向（淡出 + 滑回屏下方 15%）。 */
private fun playerExitTransition(): ExitTransition =
    slideOutVertically(animationSpec = playerSlideSpec()) { full: Int ->
        (full * FullPlayerSlideFraction).roundToInt()
    } + fadeOut(animationSpec = playerFadeSpec())

/**
 * HOME enter：从 PLAYER 返回时自上方 -15% 下滑 + 淡入（up-fade 的反向）；
 * 其余进入（冷启动 / onboarding 返回）保持默认淡入 400ms。
 */
private fun homeEnterTransition(initialState: NavBackStackEntry): EnterTransition =
    if (initialState.destination.route == Routes.PLAYER) {
        slideInVertically(animationSpec = playerSlideSpec()) { full: Int ->
            -(full * FullPlayerSlideFraction).roundToInt()
        } + fadeIn(animationSpec = playerFadeSpec())
    } else {
        fadeIn(animationSpec = Md3Motion.expressiveTween())
    }

/** HOME exit：恒 up-fade 300ms（-15% 上移 + 淡出，登记偏离见使用处注释）。 */
private fun homeExitTransition(): ExitTransition =
    slideOutVertically(animationSpec = playerSlideSpec()) { full: Int ->
        -(full * FullPlayerSlideFraction).roundToInt()
    } + fadeOut(animationSpec = playerFadeSpec())
