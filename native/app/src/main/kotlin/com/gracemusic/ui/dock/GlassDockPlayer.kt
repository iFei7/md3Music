package com.gracemusic.ui.dock

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import coil3.compose.SubcomposeAsyncImage
import com.gracemusic.core.theme.Md3Motion
import com.gracemusic.core.theme.Md3MusicTheme
import com.gracemusic.data.model.Song
import com.gracemusic.player.queue.PlaybackQueue
import com.gracemusic.player.state.PlaybackState
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 底部悬浮玻璃 Dock：导航胶囊 + 常驻播放器钮，1:1 移植 lite
 * `lib/modules/player/glass_dock_player.dart`。
 *
 * ## 单展开不变量（lite :44-53）
 *
 * 导航与播放器**恰好一个展开**，合法组合仅两种：
 * [导航胶囊 + 播放器球]（默认）与 [导航球 + 播放器胶囊]。折叠状态唯一驱动
 * 是用户点击，滚动不参与：
 * - 点坍缩导航圆 / 切 tab / 播放器胶囊收起 → 导航展开；
 * - 点播放器球 → 播放器胶囊展开、导航坍缩让位。
 * 迁移逻辑收敛在 [DockLogic] 纯函数（`onNavCircleClicked` / `onTabSelected` /
 * `onPlayerButtonToggled`，双向闭环「先置位后回调」的时序在纯函数模型下
 * 天然无乒乓竞态，对位 lite :166-186），本组件只做壳。
 *
 * ## FullPlayer 门控（lite :199-207）
 *
 * `fullPlayerVisibleFraction > 0.5` → 整体零渲染（不产帧；组件保留在组合中
 * 以免内部展开状态丢失——lite 的 `navExpanded` 由 `_MainLayout` 外部持有，
 * native 侧内聚在组件内，故用「空占位」等价 `SizedBox.shrink`）；
 * `0.2 < fraction ≤ 0.5` → `IgnorePointer + alpha = 1 − fraction`
 * （Compose 无 IgnorePointer，以禁用全部交互等价实现）。
 *
 * ## 高频纪律（lite :380-404）
 *
 * 进度环画在独立 `Canvas` 的 draw 块内、通过 `rememberUpdatedState` 以
 * State 形式读取 [position]：position 高频更新只失效该 draw 块（Canvas
 * lambda 读 State 仅触发 draw 阶段失效），不重组、不重布局；整钮外层
 * `graphicsLayer()` 建立独立绘制层（RepaintBoundary 等价）隔离重绘外溢。
 *
 * ## 偏离登记（台本 §2）
 *
 * - **频谱律动简化**：lite `PlayingSpectrumIndicator`（ObserverRenderer 频谱）
 *   不移植 → 播放态中央标识用封面 + 黑 α0.28 遮罩 + 脉动 PlayArrow
 *   （α 0.45↔1.0、600ms 反向循环，draw 层读值零重组）替代。
 * - **图标自绘**：工程无 material-icons 依赖且 ECC 禁新增依赖，控制键与
 *   Preview 图标为 Material Symbols path 自绘（见 [DockIcons]）。
 *
 * @param tabs 可见 tab 项（顺序即渲染顺序）。
 * @param selectedTabId 当前选中 tab id。
 * @param onTabSelected tab 点击回调。
 * @param state 播放状态快照（只读消费：currentSong / isPlaying / queue /
 *   duration；不含 position 高频通道）。
 * @param position 播放位置高频值（调用方 collectAsState 注入，组件内不重复
 *   订阅；仅进度环 draw 块消费）。
 * @param fullPlayerVisibleFraction 全屏播放器展开度 0..1。
 * @param onOpenFullPlayer 打开全屏播放页（点封面 / 歌名，lite :75-77——
 *   已移除「向上按钮」，二者是唯一入口）。
 * @param onTogglePlayPause 播放/暂停切换（调用方按 state.isPlaying 映射
 *   Resume / Pause）。
 * @param onNext 下一曲。
 * @param onPrevious 上一曲。
 */
@Composable
public fun GlassDockPlayer(
    tabs: List<DockTab>,
    selectedTabId: String,
    onTabSelected: (String) -> Unit,
    state: PlaybackState,
    position: Duration,
    fullPlayerVisibleFraction: Float,
    onOpenFullPlayer: () -> Unit,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // FullPlayer 门控三段判定（lite :199-207，纯函数见 DockLogic）
    val visibility = DockLogic.dockVisibility(fullPlayerVisibleFraction)

    // 单展开状态机（内部自持；冷启动默认「导航胶囊 + 播放器球」，lite app.dart:603-607）。
    // 先 remember 再门控：REMOVED 分支零渲染时状态仍存活，恢复后回到打开前形态
    //（lite :70-72「关闭播放页恢复打开前的唯一展开组件」）。
    var navExpanded by rememberSaveable { mutableStateOf(true) }

    if (visibility == DockLogic.DockVisibility.REMOVED) {
        // >0.5：整体零渲染、不产帧（lite :203 SizedBox.shrink 等价）
        Box(modifier = modifier)
        return
    }

    // 0.2 < fraction ≤ 0.5：等价 IgnorePointer + 淡出（lite :204-206）
    val interactionEnabled = visibility == DockLogic.DockVisibility.VISIBLE
    val dockAlpha = DockLogic.dockAlpha(fullPlayerVisibleFraction)
    val fadeModifier: Modifier =
        if (dockAlpha < 1f) Modifier.graphicsLayer { this.alpha = dockAlpha } else Modifier

    // position → State：进度环 draw 块以 State 读取（高频纪律，见类 KDoc）
    val positionState: State<Duration> = rememberUpdatedState(position)

    Box(
        modifier = modifier
            .then(fadeModifier)
            .testTag(GlassDockPlayerTestTag)
            // SafeArea(top: false)（lite :209-211）：仅吃底部安全区
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom))
            // 外层内边距 (16, 0, 16, 12)（lite :214）
            .padding(start = 16.dp, top = 0.dp, end = 16.dp, bottom = 12.dp),
    ) {
        // 布局恒定 Row(min) [导航, 8, 播放器(Flexible loose)]（lite :220-234）：
        // 左悬浮导航、右悬浮播放器，位置恒定不互换；播放器 weight(1f, fill=false)
        // 是 loose 约束，极限屏宽下歌名区先压缩、任何形态不超屏宽。
        Row(verticalAlignment = Alignment.CenterVertically) {
            DockNavPart(
                tabs = tabs,
                selectedTabId = selectedTabId,
                expanded = navExpanded,
                interactionEnabled = interactionEnabled,
                onSelectTab = { tabId ->
                    // 切 tab → 导航保持展开（状态机语义，DockLogic.onTabSelected）
                    navExpanded = DockLogic.onTabSelected(
                        DockLogic.DockExpansion(navExpanded = navExpanded),
                    ).navExpanded
                    onTabSelected(tabId)
                },
                onExpandNav = {
                    // 点坍缩导航圆 → 导航展开（反向闭环，lite :166-170）
                    navExpanded = DockLogic.onNavCircleClicked(
                        DockLogic.DockExpansion(navExpanded = navExpanded),
                    ).navExpanded
                },
                modifier = Modifier,
            )
            Spacer(modifier = Modifier.width(8.dp))
            Row(modifier = Modifier.weight(weight = 1f, fill = false)) {
                DockPlayerPart(
                    state = state,
                    positionState = positionState,
                    controlsExpanded = !navExpanded,
                    interactionEnabled = interactionEnabled,
                    onOpenFullPlayer = onOpenFullPlayer,
                    onTogglePlayPause = onTogglePlayPause,
                    onNext = onNext,
                    onPrevious = onPrevious,
                    onToggleControls = {
                        // 点播放器球 / 胶囊背景 → 播放器展开态翻转、导航让位/恢复
                        //（正向闭环，lite :179-186）
                        navExpanded = DockLogic.onPlayerButtonToggled(
                            DockLogic.DockExpansion(navExpanded = navExpanded),
                        ).navExpanded
                    },
                    modifier = Modifier,
                )
            }
        }
    }
}

/**
 * Dock 导航项定义（冻结契约，台本 §3.1）。
 *
 * @param id tab 标识（discover / favorites / user 等）。
 * @param label 展示与无障碍文案（lite :661-664：icon-only，label 仅朗读）。
 * @param iconSelected 选中态图标（filled）。
 * @param iconUnselected 未选中态图标（outlined）。
 */
public data class DockTab(
    val id: String,
    val label: String,
    val iconSelected: androidx.compose.ui.graphics.vector.ImageVector,
    val iconUnselected: androidx.compose.ui.graphics.vector.ImageVector,
)

/**
 * Dock 测试标签（androidTest 断言 Dock 存在性用）。
 *
 * 承接自 A1 临时 stub（`GlassDockPlayerStub.kt`，其 KDoc 注明合并时删除、
 * 以本文件为准）；真实现主容器挂同一 testTag，A1 的导航测试调用点无需改动。
 */
@androidx.annotation.VisibleForTesting
internal const val GlassDockPlayerTestTag: String = "glass_dock_player"

// ─────────────────────────── 导航部分 ───────────────────────────

/**
 * 导航部分：展开（玻璃胶囊导航项）↔ 坍缩（单玻璃圆）。
 *
 * morph 260ms easeOutCubic、**左缘锚定**（导航恒在行首，坍缩↔展开时左缘
 * 不动、向右生长；lite :243-260 `alignment: centerLeft`）。刻意不包
 * AnimatedContent 交叉淡化——淡出中的旧形态会钉住容器尺寸造成「先等待后
 * 收缩」两段式跳变（lite :251-255 实测坑；`animateContentSize` 单动画节奏
 * 干脆）。
 */
@Composable
private fun DockNavPart(
    tabs: List<DockTab>,
    selectedTabId: String,
    expanded: Boolean,
    interactionEnabled: Boolean,
    onSelectTab: (String) -> Unit,
    onExpandNav: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier.animateContentSize(
            animationSpec = tween(durationMillis = Md3Motion.DockMorphDurationMillis, easing = EaseOutCubic),
            alignment = Alignment.CenterStart,
        ),
    ) {
        if (expanded) {
            DockNavPill(
                tabs = tabs,
                selectedTabId = selectedTabId,
                interactionEnabled = interactionEnabled,
                onSelectTab = onSelectTab,
            )
        } else {
            DockNavCollapsed(
                tabs = tabs,
                selectedTabId = selectedTabId,
                interactionEnabled = interactionEnabled,
                onExpandNav = onExpandNav,
            )
        }
    }
}

/**
 * 展开态导航胶囊：icon-only 项，项宽随项数自适应
 * （≤4 项 44dp，更多时 `floor(220/count) − 2` 夹 [28, 44]，
 * lite :266-279 的 320dp 最小屏溢出复核；公式见 [DockLogic.navItemWidthDp]）。
 */
@Composable
private fun DockNavPill(
    tabs: List<DockTab>,
    selectedTabId: String,
    interactionEnabled: Boolean,
    onSelectTab: (String) -> Unit,
) {
    LiquidGlassContainer(
        // 胶囊形内边距 symmetric(horizontal: 4, vertical: 4)（lite :282）
        padding = PaddingValues(horizontal = 4.dp, vertical = 4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val itemWidth = DockLogic.navItemWidthDp(tabs.size).dp
            for (tab in tabs) {
                DockNavItem(
                    tab = tab,
                    selected = selectedTabId == tab.id,
                    width = itemWidth,
                    enabled = interactionEnabled,
                    onTap = { onSelectTab(tab.id) },
                )
            }
        }
    }
}

/**
 * Dock 导航项：icon-only 44×44（lite :666-685 `_DockNavItem`），左右各 1dp
 * 外边距；选中 secondaryContainer Stadium 底 220ms easeOutCubic（lite
 * :668-681 AnimatedContainer）；图标 22（lite :679）；语义 selected + role
 * Tab（lite :661-664 Semantics）。
 */
@Composable
private fun DockNavItem(
    tab: DockTab,
    selected: Boolean,
    width: androidx.compose.ui.unit.Dp,
    enabled: Boolean,
    onTap: () -> Unit,
) {
    val colorScheme: ColorScheme = MaterialTheme.colorScheme
    val backgroundColor by animateColorAsState(
        targetValue = if (selected) colorScheme.secondaryContainer else Color.Transparent,
        animationSpec = tween(
            durationMillis = DockLogic.NAV_SELECT_DURATION_MILLIS,
            easing = EaseOutCubic,
        ),
        label = "dockNavItemBackground",
    )
    Box(
        modifier = Modifier
            // 左右各 1dp 外边距（lite :673 margin symmetric(horizontal: 1)）
            .padding(horizontal = 1.dp)
            .size(width = width, height = 44.dp)
            .semantics { this.selected = selected }
            // Stadium 选中底：44dp 方块下 percent 50 即正圆（规范 §二.212）
            .clip(RoundedCornerShape(percent = 50))
            .background(backgroundColor)
            .clickable(enabled = enabled, role = Role.Tab, onClick = onTap),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = if (selected) tab.iconSelected else tab.iconUnselected,
            contentDescription = tab.label,
            modifier = Modifier.size(22.dp),
            tint = if (selected) colorScheme.onSecondaryContainer else colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * 坍缩态导航：单个当前 tab 玻璃圆（点击展开导航，lite :302-335）。
 * 显示「当前选中且可见」的 tab 图标（选中 primary）；selectedTabId 不在
 * 可见集合时回退第一个可见 tab（[DockLogic.collapsedNavTabId]，lite :307-314）。
 */
@Composable
private fun DockNavCollapsed(
    tabs: List<DockTab>,
    selectedTabId: String,
    interactionEnabled: Boolean,
    onExpandNav: () -> Unit,
) {
    val colorScheme: ColorScheme = MaterialTheme.colorScheme
    val displayTabId = DockLogic.collapsedNavTabId(
        selectedTabId = selectedTabId,
        visibleTabIds = tabs.map { it.id },
    )
    val displayTab = tabs.firstOrNull { it.id == displayTabId }
    val isSelectedVisible = displayTabId != null && displayTabId == selectedTabId
    Box(
        modifier = Modifier.clickable(enabled = interactionEnabled, onClick = onExpandNav),
    ) {
        LiquidGlassContainer(shape = GlassShape.CIRCLE) {
            Box(
                modifier = Modifier.size(DockLogic.BUTTON_SIZE_DP.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (displayTab != null) {
                    Icon(
                        imageVector = if (isSelectedVisible) displayTab.iconSelected else displayTab.iconUnselected,
                        contentDescription = displayTab.label,
                        modifier = Modifier.size(24.dp), // lite :329 坍缩圆图标 24
                        tint = if (isSelectedVisible) colorScheme.primary else colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

// ─────────────────────────── 播放器部分 ───────────────────────────

/**
 * 播放器部分：球 ↔ 控制胶囊收敛形变。
 *
 * morph 260ms easeOutCubic、**右缘锚定**（播放器恒在行尾，坍缩↔展开时右缘
 * 不动、向左生长；lite :346-358 `alignment: centerRight`）；外层
 * `graphicsLayer()` 建立独立绘制层 = RepaintBoundary（lite :345-346），
 * 隔离进度环 ~200ms 高频重绘外溢。
 */
@Composable
private fun DockPlayerPart(
    state: PlaybackState,
    positionState: State<Duration>,
    controlsExpanded: Boolean,
    interactionEnabled: Boolean,
    onOpenFullPlayer: () -> Unit,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    onToggleControls: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            // RepaintBoundary 等价：独立绘制层（高频纪律）
            .graphicsLayer()
            .animateContentSize(
                animationSpec = tween(durationMillis = Md3Motion.DockMorphDurationMillis, easing = EaseOutCubic),
                alignment = Alignment.CenterEnd,
            ),
    ) {
        if (controlsExpanded) {
            DockControlsCapsule(
                state = state,
                positionState = positionState,
                interactionEnabled = interactionEnabled,
                onOpenFullPlayer = onOpenFullPlayer,
                onTogglePlayPause = onTogglePlayPause,
                onNext = onNext,
                onPrevious = onPrevious,
                onCollapse = onToggleControls,
            )
        } else {
            DockPlayerCircle(
                state = state,
                positionState = positionState,
                interactionEnabled = interactionEnabled,
                onExpand = onToggleControls,
            )
        }
    }
}

/**
 * 播放器圆钮：52dp 玻璃圆 + 外周进度环 + 中央播放标识（lite :361-422）。
 *
 * 无歌 → 音符 22 占位（onSurfaceVariant α0.6，lite :409-414）且**点击不响应**
 * （lite :371 `onTap: song == null ? null : _toggleControls`）。
 *
 * **高频纪律实现**：进度环画在独立 `Canvas`（`matchParentSize`）的 draw 块，
 * 内部以 `positionState.value`（State）读取 position——position 高频更新
 * 只失效本 draw 块，不重组外层任何 composable、不重布局；duration 为
 * null / 0 时 progress 为 0 → 只画轨道不画进度弧（lite :385-389, :747）。
 */
@Composable
private fun DockPlayerCircle(
    state: PlaybackState,
    positionState: State<Duration>,
    interactionEnabled: Boolean,
    onExpand: () -> Unit,
) {
    val colorScheme: ColorScheme = MaterialTheme.colorScheme
    val song = state.currentSong
    val hasSong = song != null
    Box(
        modifier = Modifier.clickable(
            enabled = hasSong && interactionEnabled,
            onClick = onExpand,
        ),
    ) {
        LiquidGlassContainer(shape = GlassShape.CIRCLE) {
            Box(
                modifier = Modifier.size(DockLogic.BUTTON_SIZE_DP.dp),
                contentAlignment = Alignment.Center,
            ) {
                Canvas(modifier = Modifier.matchParentSize()) {
                    val position: Duration = positionState.value
                    val progress = DockLogic.progressRatio(
                        positionMs = position.inWholeMilliseconds,
                        durationMs = state.duration?.inWholeMilliseconds,
                    )
                    drawDockProgressRing(
                        progress = progress,
                        strokePx = DockLogic.RING_STROKE_DP.dp.toPx(),
                        // 环贴按钮外缘：26 − 0.75 − 0.5 = 24.75（lite :395-399）
                        ringRadiusPx = DockLogic.collapsedRingRadiusDp().dp.toPx(),
                        trackColor = colorScheme.onSurface.copy(alpha = 0.15f),
                        progressColor = colorScheme.primary,
                    )
                }
                if (song == null) {
                    Icon(
                        imageVector = DockIcons.MusicNote,
                        contentDescription = null,
                        modifier = Modifier.size(22.dp),
                        tint = colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    )
                } else {
                    DockCircleArtwork(song = song, isPlaying = state.isPlaying)
                }
            }
        }
    }
}

/**
 * 坍缩圆中央圆形封面（46dp，lite :430-499）：播放中叠黑 α0.28 遮罩 +
 * 脉动播放标识；暂停叠遮罩 + 静态 pause 图标（均垫遮罩保证亮封面可读，
 * lite :454-498 用户复验结论）。
 *
 * **偏离登记（频谱简化，台本 §2）**：lite 的 PlayingSpectrumIndicator 依赖
 * ObserverRenderer 频谱数据，native 决议不移植 → 播放态用 α 0.45↔1.0、
 * 600ms 反向循环的脉动 PlayArrow（Compose 无 Interval 错峰原语，600ms
 * Reverse 即 lite 频谱律动的收敛型近似；alpha 读在 graphicsLayer draw 阶段，
 * 零重组）。
 */
@Composable
private fun DockCircleArtwork(song: Song, isPlaying: Boolean) {
    Box(
        modifier = Modifier
            .size(DockLogic.CIRCLE_COVER_SIZE_DP.dp)
            .clip(CircleShape),
    ) {
        DockArtworkImage(uri = song.artworkUri ?: song.localPath, modifier = Modifier.fillMaxSize())
        Box(
            modifier = Modifier
                .fillMaxSize()
                // 略暗遮罩：亮色封面上保证图标可读（lite :466, :491）
                .background(Color.Black.copy(alpha = 0.28f)),
            contentAlignment = Alignment.Center,
        ) {
            if (isPlaying) {
                val pulseAlpha by rememberInfiniteTransition(label = "dockSpectrumPulse")
                    .animateFloat(
                        initialValue = 0.45f,
                        targetValue = 1f,
                        animationSpec = infiniteRepeatable(
                            animation = tween(durationMillis = 600),
                            repeatMode = RepeatMode.Reverse,
                        ),
                        label = "dockSpectrumPulseAlpha",
                    )
                Icon(
                    imageVector = DockIcons.PlayArrow,
                    contentDescription = "正在播放",
                    modifier = Modifier
                        .graphicsLayer { this.alpha = pulseAlpha } // draw 阶段读值，零重组
                        .size(14.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
            } else {
                Icon(
                    imageVector = DockIcons.Pause,
                    contentDescription = "已暂停",
                    modifier = Modifier.size(16.dp), // lite :493
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

/**
 * 封面图片：Coil [SubcomposeAsyncImage]，加载中 / 失败 / 无 URI 一律回退
 * 音符占位（lite `PlayerArtworkImage` 的回退语义 :424-429；artworkUri 与
 * localPath 双源，lite :436-439）。
 */
@Composable
private fun DockArtworkImage(uri: String?, modifier: Modifier = Modifier) {
    val colorScheme: ColorScheme = MaterialTheme.colorScheme
    SubcomposeAsyncImage(
        model = uri,
        contentDescription = null, // 装饰性：曲目信息由歌名 / 无障碍文案承担
        modifier = modifier,
        contentScale = ContentScale.Crop,
        loading = { DockArtworkFallback(colorScheme = colorScheme) },
        error = { DockArtworkFallback(colorScheme = colorScheme) },
    )
}

@Composable
private fun DockArtworkFallback(colorScheme: ColorScheme) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colorScheme.surfaceContainerHighest),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = DockIcons.MusicNote,
            contentDescription = null,
            modifier = Modifier.size(20.dp),
            tint = colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * 展开态控制小胶囊（lite :501-634）：圆形封面缩略图（外周进度环，与坍缩球
 * 同一绘制函数）→ 8dp → 歌名 marquee（宽度上限 120 下限 0，溢出防御）→
 * prev / play / next 三钮（40×40，总宽 120）。封面与歌名点击均进全屏播放页
 * （lite :75-77：原「向上按钮」职责由二者承担）；胶囊背景点击收起回球
 * （lite :510-511）。
 *
 * 宽度防御（lite :517-528）：固定区 = 水平 padding 10 + 封面含环
 * (36 + 2×1.5) + 间距 8 + 三钮 120 = 177（[DockLogic.CAPSULE_FIXED_WIDTH_DP]），
 * 歌名区 = 可用宽 − 固定区夹 [0, 120]，320dp 最小屏下胶囊自身不超宽。
 */
@Composable
private fun DockControlsCapsule(
    state: PlaybackState,
    positionState: State<Duration>,
    interactionEnabled: Boolean,
    onOpenFullPlayer: () -> Unit,
    onTogglePlayPause: () -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    onCollapse: () -> Unit,
) {
    val colorScheme: ColorScheme = MaterialTheme.colorScheme
    val song = state.currentSong
    val hasSong = song != null
    Box(
        modifier = Modifier.clickable(
            enabled = interactionEnabled,
            onClick = onCollapse, // lite :511 胶囊背景点击 → 收起回球
        ),
    ) {
        LiquidGlassContainer(
            // 控制胶囊内边距 fromLTRB(6, 0, 4, 0)（lite :514）
            padding = PaddingValues(start = 6.dp, top = 0.dp, end = 4.dp, bottom = 0.dp),
        ) {
            // BoxWithConstraints（Compose 无 Flutter LayoutBuilder 同名原语）：
            // 读父约束计算歌名区可压缩宽度（lite :520-528 的等价实现）
            BoxWithConstraints(modifier = Modifier.height(DockLogic.BUTTON_SIZE_DP.dp)) {
                val marqueeWidth = DockLogic.capsuleMarqueeWidthDp(maxWidth.value).dp
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        // 封面缩略图 + 外周进度环（39dp = 36 + 2×1.5）：点击进播放页
                        Box(
                            modifier = Modifier
                                .size(
                                    DockLogic.CAPSULE_COVER_SIZE_DP.dp +
                                        DockLogic.RING_STROKE_DP.dp * 2,
                                )
                                .clickable(
                                    enabled = hasSong && interactionEnabled,
                                    onClick = onOpenFullPlayer,
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Canvas(modifier = Modifier.matchParentSize()) {
                                val position: Duration = positionState.value
                                val progress = DockLogic.progressRatio(
                                    positionMs = position.inWholeMilliseconds,
                                    durationMs = state.duration?.inWholeMilliseconds,
                                )
                                drawDockProgressRing(
                                    progress = progress,
                                    strokePx = DockLogic.RING_STROKE_DP.dp.toPx(),
                                    // 环贴封面外缘：18 + 0.75 = 18.75（lite :562-565）
                                    ringRadiusPx = DockLogic.capsuleRingRadiusDp().dp.toPx(),
                                    trackColor = colorScheme.onSurface.copy(alpha = 0.15f),
                                    progressColor = colorScheme.primary,
                                )
                            }
                            if (song != null) {
                                DockArtworkImage(
                                    uri = song.artworkUri ?: song.localPath,
                                    modifier = Modifier
                                        .size(DockLogic.CAPSULE_COVER_SIZE_DP.dp)
                                        .clip(CircleShape),
                                )
                            }
                        }
                        Spacer(modifier = Modifier.width(DockLogic.CAPSULE_COVER_GAP_DP.dp))
                        // 歌名 marquee：点击进播放页（lite :595-607）
                        Box(
                            modifier = Modifier
                                .width(marqueeWidth)
                                .clickable(
                                    enabled = hasSong && interactionEnabled,
                                    onClick = onOpenFullPlayer,
                                ),
                        ) {
                            MarqueeText(
                                text = song?.displayName ?: "未在播放", // lite :600
                                style = MaterialTheme.typography.bodyMedium.copy(
                                    color = if (hasSong) colorScheme.onSurface else colorScheme.onSurfaceVariant,
                                ),
                                width = marqueeWidth,
                                playing = state.isPlaying,
                            )
                        }
                        DockIconButton(
                            icon = DockIcons.SkipPrevious,
                            contentDescription = "上一曲",
                            enabled = hasSong && interactionEnabled,
                            onClick = onPrevious,
                        )
                        DockIconButton(
                            icon = if (state.isPlaying) DockIcons.Pause else DockIcons.PlayArrow,
                            contentDescription = if (state.isPlaying) "暂停" else "播放",
                            enabled = hasSong && interactionEnabled,
                            onClick = onTogglePlayPause,
                        )
                        DockIconButton(
                            icon = DockIcons.SkipNext,
                            contentDescription = "下一曲",
                            enabled = hasSong && interactionEnabled,
                            onClick = onNext,
                        )
                }
            }
        }
    }
}

/**
 * Dock 内的紧凑图标按钮（lite :688-710 `_DockIconButton`）：图标 22、
 * 命中区 40×40（lite `visualDensity: compact` 的实际命中尺寸；规范 §九
 * 要求 ≥48，lite 自身即 40——保持 1:1，登记为待无障碍复核项），三钮总宽
 * 120（[DockLogic.CONTROLS_BUTTONS_WIDTH_DP]）。
 */
@Composable
private fun DockIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.size(40.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription, // lite tooltip 的无障碍等价
            modifier = Modifier.size(22.dp), // lite :706
            tint = MaterialTheme.colorScheme.onSurface,
        )
    }
}

/**
 * 进度环绘制（坍缩球与展开胶囊共用，1:1 移植 lite `_ProgressRingPainter`
 * :717-765）：细轨道整环 + 主色进度弧（12 点方向起、round cap）。
 *
 * @param progress 0..1（duration null / 0 → 0 → 不画进度弧，只画轨道）。
 * @param strokePx 环线宽。
 * @param ringRadiusPx 环中心线半径（调用方按 [DockLogic] 常量换算）。
 */
private fun DrawScope.drawDockProgressRing(
    progress: Float,
    strokePx: Float,
    ringRadiusPx: Float,
    trackColor: Color,
    progressColor: Color,
) {
    val center = Offset(size.width / 2f, size.height / 2f)
    // 轨道整环（lite :741-745）
    drawCircle(
        color = trackColor,
        radius = ringRadiusPx,
        center = center,
        style = Stroke(width = strokePx),
    )
    // 进度弧：progress > 0 才画（lite :747）
    if (progress > 0f) {
        drawArc(
            color = progressColor,
            startAngle = -90f, // 12 点方向起（lite :753 −π/2）
            sweepAngle = 360f * progress, // 顺时针
            useCenter = false,
            topLeft = Offset(center.x - ringRadiusPx, center.y - ringRadiusPx),
            size = androidx.compose.ui.geometry.Size(ringRadiusPx * 2f, ringRadiusPx * 2f),
            style = Stroke(width = strokePx, cap = StrokeCap.Round), // lite :751
        )
    }
}

// ─────────────────────────── Preview ───────────────────────────

private fun previewPlaybackState(withSong: Boolean, isPlaying: Boolean): PlaybackState {
    if (!withSong) return PlaybackState()
    val song = Song(
        id = "preview-1",
        title = "夜空中最亮的星.mp3",
        artist = "逃跑计划",
        album = "世界",
        duration = 200.seconds,
        isOnline = false,
        localPath = null,
    )
    return PlaybackState(
        queue = PlaybackQueue(playlist = listOf(song), currentIndex = 0),
        isPlaying = isPlaying,
        position = 75.seconds,
        duration = 200.seconds,
    )
}

private val previewTabs3: List<DockTab> = listOf(
    DockTab("discover", "主页", DockIcons.Home, DockIcons.Home),
    DockTab("favorites", "收藏", DockIcons.Favorite, DockIcons.Favorite),
    DockTab("user", "我的", DockIcons.Person, DockIcons.Person),
)

private val previewTabs9: List<DockTab> = listOf(
    DockTab("discover", "主页", DockIcons.Home, DockIcons.Home),
    DockTab("favorites", "收藏", DockIcons.Favorite, DockIcons.Favorite),
    DockTab("library", "本地音乐", DockIcons.LibraryMusic, DockIcons.LibraryMusic),
    DockTab("fm", "私人FM", DockIcons.Radio, DockIcons.Radio),
    DockTab("search", "搜索", DockIcons.Search, DockIcons.Search),
    DockTab("recognition", "听歌识曲", DockIcons.Mic, DockIcons.Mic),
    DockTab("audiobook", "听书", DockIcons.AutoStories, DockIcons.AutoStories),
    DockTab("settings", "设置", DockIcons.Settings, DockIcons.Settings),
    DockTab("user", "我的", DockIcons.Person, DockIcons.Person),
)

/** Preview：空队列球态（导航展开，播放器球显示音符占位且不响应）。 */
@Preview(name = "Dock·空队列球态", showBackground = true, widthDp = 360, heightDp = 96)
@Composable
private fun GlassDockPlayerEmptyQueuePreview() {
    Md3MusicTheme {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.BottomCenter,
        ) {
            GlassDockPlayer(
                tabs = previewTabs3,
                selectedTabId = "discover",
                onTabSelected = {},
                state = previewPlaybackState(withSong = false, isPlaying = false),
                position = Duration.ZERO,
                fullPlayerVisibleFraction = 0f,
                onOpenFullPlayer = {},
                onTogglePlayPause = {},
                onNext = {},
                onPrevious = {},
            )
        }
    }
}

/** Preview：播放中球态（导航展开，播放器球封面 + 遮罩 + 脉动播放标识）。 */
@Preview(name = "Dock·播放中球态", showBackground = true, widthDp = 360, heightDp = 96)
@Composable
private fun GlassDockPlayerPlayingCirclePreview() {
    Md3MusicTheme {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.BottomCenter,
        ) {
            GlassDockPlayer(
                tabs = previewTabs3,
                selectedTabId = "favorites",
                onTabSelected = {},
                state = previewPlaybackState(withSong = true, isPlaying = true),
                position = 75.seconds,
                fullPlayerVisibleFraction = 0f,
                onOpenFullPlayer = {},
                onTogglePlayPause = {},
                onNext = {},
                onPrevious = {},
            )
        }
    }
}

/** Preview：胶囊态（播放器展开：环 + 歌名 marquee + 三钮；导航侧对应坍缩）。 */
@Preview(name = "Dock·播放器胶囊态", showBackground = true, widthDp = 360, heightDp = 96)
@Composable
private fun GlassDockPlayerCapsulePreview() {
    Md3MusicTheme {
        val state = previewPlaybackState(withSong = true, isPlaying = true)
        val positionState = remember { mutableStateOf(75.seconds) }
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Column {
                Spacer(modifier = Modifier.height(8.dp))
                DockControlsCapsule(
                    state = state,
                    positionState = positionState,
                    interactionEnabled = true,
                    onOpenFullPlayer = {},
                    onTogglePlayPause = {},
                    onNext = {},
                    onPrevious = {},
                    onCollapse = {},
                )
            }
        }
    }
}

/** Preview：3 tab 导航胶囊（默认可见 discover/favorites/user，项宽 44）。 */
@Preview(name = "Dock·导航胶囊 3 tab", showBackground = true, widthDp = 280, heightDp = 96)
@Composable
private fun GlassDockNavPill3TabsPreview() {
    Md3MusicTheme {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.Center,
        ) {
            DockNavPart(
                tabs = previewTabs3,
                selectedTabId = "favorites",
                expanded = true,
                interactionEnabled = true,
                onSelectTab = {},
                onExpandNav = {},
            )
        }
    }
}

/** Preview：9 tab 导航胶囊（全 tab 序，项宽压缩至下限 28）。 */
@Preview(name = "Dock·导航胶囊 9 tab", showBackground = true, widthDp = 360, heightDp = 96)
@Composable
private fun GlassDockNavPill9TabsPreview() {
    Md3MusicTheme {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface),
            contentAlignment = Alignment.Center,
        ) {
            DockNavPart(
                tabs = previewTabs9,
                selectedTabId = "search",
                expanded = true,
                interactionEnabled = true,
                onSelectTab = {},
                onExpandNav = {},
            )
        }
    }
}
