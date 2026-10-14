package com.gracemusic.feature.home

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.gracemusic.core.responsive.LocalWindowSizeClass
import com.gracemusic.core.responsive.WindowSizeClass
import com.gracemusic.core.theme.Md3Motion
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.core.ui.ContentEntrance
import com.gracemusic.core.ui.dockPadding
import com.gracemusic.feature.discover.DiscoverScreen
import com.gracemusic.feature.user.FavoritesScreen
import com.gracemusic.feature.user.UserCenterScreen
import com.gracemusic.player.state.PlaybackIntent
import com.gracemusic.player.state.PlaybackState
import com.gracemusic.ui.dock.DockTab
import com.gracemusic.ui.dock.GlassDockPlayer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Person
import androidx.compose.ui.unit.IntOffset
import androidx.hilt.navigation.compose.hiltViewModel
import kotlin.math.roundToInt
import kotlin.time.Duration

/**
 * 主壳默认 tab 集（台本 §1 红线 9：P3-A 固定 3 个，P3-D 再落 TabConfig 持久化）。
 *
 * 对位 lite `lib/app.dart:640-674` `_buildPageForTab` 的 tab 语义：
 * - `discover`（发现，lite 图标 home/home_outlined）；
 * - `favorites`（收藏，lite 独立页 favorites_page.dart）；
 * - `user`（我的，lite 语义为不可隐藏 tab）。
 *
 * 图标偏离：lite 用 material-icons-extended 成对图标，native 无该依赖，
 * 取 material-icons **默认集**近似（Home/Favorite/Person 成对 filled/outlined，
 * 语义一致）；待补依赖后逐一对位（登记遗留）。
 */
internal val MainTabs: List<DockTab> = listOf(
    DockTab(
        id = "discover",
        label = "发现",
        iconSelected = Icons.Filled.Home,
        iconUnselected = Icons.Outlined.Home,
    ),
    DockTab(
        id = "favorites",
        label = "收藏",
        iconSelected = Icons.Filled.Favorite,
        iconUnselected = Icons.Outlined.Favorite,
    ),
    DockTab(
        id = "user",
        label = "我的",
        iconSelected = Icons.Filled.Person,
        iconUnselected = Icons.Outlined.Person,
    ),
)

/** tab id 在默认序中的下标（未知 id 视为最后，避免越界）。 */
internal fun tabIndex(id: String): Int =
    MainTabs.indexOfFirst { it.id == id }.let { if (it < 0) MainTabs.lastIndex else it }

/**
 * 主壳（路由 `/`）：底部 tab + 玻璃 Dock 播放器（P3-A1，替换 P0-C 占位）。
 *
 * 对位 lite `lib/app.dart:591-1270` 的 `_MainLayout`：
 * - tab 状态 `selectedTabId`（rememberSaveable，进程重建恢复）；
 * - `AnimatedContent` tab 切换转场：竖屏左右位移 ±0.12 + Fade 400ms
 *   （Expressive easing，台本 §1 红线 5；横屏侧边导航语义收敛为上下 ±0.1，
 *   以 [LocalWindowSizeClass] ≠ Compact 判定）；
 * - 每页包 [ContentEntrance] 上浮入场（app_animation.dart:73-102 对位）；
 * - 底部悬浮 [GlassDockPlayer]（A2 契约，当前为 stub），内容经
 *   [dockPadding] 注入 navigationBars + 72dp 避让；
 * - 播放控制：只读 `store.state` / `store.position`（高频流）+ 发意图
 *   （MVI，不经手引擎），dispatch 主线程铁律由 UI 回调天然满足。
 */
@Composable
fun MainScaffold(
    modifier: Modifier = Modifier,
    onOpenFullPlayer: () -> Unit = {},
    viewModel: MainScaffoldViewModel = hiltViewModel(),
) {
    val playbackState: PlaybackState by viewModel.store.state.collectAsState()
    val position: Duration by viewModel.store.position.collectAsState()
    MainScaffoldContent(
        state = playbackState,
        position = position,
        onTogglePlayPause = {
            // 按 state.isPlaying 映射 Resume/Pause（A2 契约注释，权威收敛值）。
            if (playbackState.isPlaying) {
                viewModel.store.dispatch(PlaybackIntent.Pause)
            } else {
                viewModel.store.dispatch(PlaybackIntent.Resume)
            }
        },
        onNext = { viewModel.store.dispatch(PlaybackIntent.Next()) },
        onPrevious = { viewModel.store.dispatch(PlaybackIntent.Previous()) },
        onOpenFullPlayer = onOpenFullPlayer,
        modifier = modifier,
    )
}

/**
 * 主壳的无依赖渲染层（state hoisting）：供 Preview 与 androidTest 在
 * 无 Hilt 环境下直接组合；生产入口 [MainScaffold] 负责从 ViewModel 取流。
 */
@Composable
internal fun MainScaffoldContent(
    state: PlaybackState,
    position: Duration,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    onOpenFullPlayer: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var selectedTabId by rememberSaveable { mutableStateOf(value = MainTabs.first().id) }
    val useVerticalTransition = LocalWindowSizeClass.current != WindowSizeClass.Compact

    Box(modifier = modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = selectedTabId,
            transitionSpec = {
                val goingForward = tabIndex(targetState) > tabIndex(initialState)
                // 竖屏 ±0.12 水平 / 横屏 ±0.1 竖直（lite app.dart:1172-1191 语义）；
                // 方向按 tab 序号：前进则新页自右（下）入、旧页向左（上）出。
                val slideSpec = Md3Motion.expressiveTween<IntOffset>()
                val fadeSpec = Md3Motion.expressiveTween<Float>()
                val enter = if (useVerticalTransition) {
                    slideInVertically(slideSpec) { full: Int ->
                        (full * 0.1f).roundToInt() * (if (goingForward) 1 else -1)
                    }
                } else {
                    slideInHorizontally(slideSpec) { full: Int ->
                        (full * 0.12f).roundToInt() * (if (goingForward) 1 else -1)
                    }
                } + fadeIn(fadeSpec)
                val exit = if (useVerticalTransition) {
                    slideOutVertically(slideSpec) { full: Int ->
                        (full * 0.1f).roundToInt() * (if (goingForward) -1 else 1)
                    }
                } else {
                    slideOutHorizontally(slideSpec) { full: Int ->
                        (full * 0.12f).roundToInt() * (if (goingForward) -1 else 1)
                    }
                } + fadeOut(fadeSpec)
                enter togetherWith exit
            },
            label = "mainTabSwitch",
        ) { tabId: String ->
            // 底部避让：navigationBars + 72dp（Dock 恒可见，红线 8「空队列
            // Dock 不隐藏」→ visible 恒 true；条件化留给 FullPlayer 覆盖态）。
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .dockPadding(visible = true),
            ) {
                ContentEntrance(modifier = Modifier.fillMaxSize()) {
                    when (tabId) {
                        "discover" -> DiscoverScreen()
                        "favorites" -> FavoritesScreen()
                        "user" -> UserCenterScreen()
                    }
                }
            }
        }
        GlassDockPlayer(
            tabs = MainTabs,
            selectedTabId = selectedTabId,
            onTabSelected = { id: String -> selectedTabId = id },
            state = state,
            position = position,
            fullPlayerVisibleFraction = 0f, // P3-A1 无拖拽，恒 0（登记偏离台本 §2）
            onOpenFullPlayer = onOpenFullPlayer,
            onTogglePlayPause = onTogglePlayPause,
            onNext = onNext,
            onPrevious = onPrevious,
            modifier = Modifier.align(alignment = Alignment.BottomCenter),
        )
    }
}

@Preview(name = "主壳", showBackground = true)
@Composable
private fun MainScaffoldContentPreview() {
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
