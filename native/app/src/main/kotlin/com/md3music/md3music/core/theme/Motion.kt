package com.md3music.md3music.core.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween

/**
 * M3 Expressive Motion 常量（native 端口）。
 *
 * 移植来源（逐值忠实译，不拍脑袋）：
 * 1. `lib/core/theme/motion_constants.dart`：核心弹簧 / 时长 / 缓动；
 * 2. `m3e_core` 包 `M3EMotion` 预设（lite 通过 material_ui + m3e_core 引用）：
 *    14 个弹簧预设，被 NavigationBar 胶囊回弹（responsive_layout.dart）与
 *    下拉刷新（md3_pull_to_refresh.dart）等直接使用；
 * 3. 各核心 Widget 的固定时长常量（responsive_layout / md3_pull_to_refresh /
 *    md3e_transport_row / glass_dock_player / keyboard_expand_sheet /
 *    playlist_comments_view）。
 *
 * M3 Expressive 强调「直觉性物理动效」——弹簧物理优先于固定 cubic 曲线，
 * 让动画带有自然的过冲和回弹感。
 */
object Md3Motion {

    // ==================== 核心弹簧 / 时长 / 缓动 ====================
    // 移植自 lib/core/theme/motion_constants.dart

    /**
     * 默认弹簧描述的质量分量。
     *
     * Flutter 端 `SpringDescription.withDampingRatio(mass: 1.0, stiffness: 180, ratio: 0.825)`。
     * Compose 的 `spring()` 内部模拟质量固定为 1（SpringSimulation 以 mass=1 积分），
     * 与 Flutter 端 mass=1.0 一致，故无需移植该值；仅移植刚度与阻尼比。
     */
    const val DefaultSpringMass = 1.0f

    /** 默认弹簧刚度 180（对应 Flutter defaultSpring.stiffness）。 */
    const val DefaultSpringStiffness = 180f

    /**
     * 默认弹簧阻尼比 0.825。
     * 0.825 < 1.0 产生轻微过冲，符合 M3 Expressive「有生命感」的动效。
     */
    const val DefaultSpringDampingRatio = 0.825f

    /** 默认动画时长 400ms（M3 标准时长，对应 medium duration）。 */
    const val DefaultDurationMillis = 400

    /** 强调动画时长 600ms（对应 long duration，用于 FullPlayer 入场等）。 */
    const val EmphasisDurationMillis = 600

    /**
     * Expressive easing：略带过冲的减速曲线 `Cubic(0.05, 0.7, 0.1, 1.0)`。
     * 用于 tab 切换、卡片入场。
     */
    val ExpressiveEasing: Easing = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1.0f)

    /**
     * Emphasized easing：M3 标准 emphasized 缓动 `Cubic(0.2, 0.0, 0, 1.0)`。
     * 用于大型状态转换（FullPlayer 展开、对话框入场）。
     */
    val EmphasizedEasing: Easing = CubicBezierEasing(0.2f, 0.0f, 0f, 1.0f)

    /** 默认弹簧（dampingRatio 0.825 / stiffness 180），对应 Flutter defaultSpring。 */
    fun <T> defaultSpring(): SpringSpec<T> =
        spring(dampingRatio = DefaultSpringDampingRatio, stiffness = DefaultSpringStiffness)

    /** expressiveEasing + defaultDuration(400ms) 的 tween，用于 tab 切换、卡片入场。 */
    fun <T> expressiveTween(durationMillis: Int = DefaultDurationMillis) =
        tween<T>(durationMillis = durationMillis, easing = ExpressiveEasing)

    /** emphasizedEasing + emphasisDuration(600ms) 的 tween，用于大型状态转换。 */
    fun <T> emphasizedTween(durationMillis: Int = EmphasisDurationMillis) =
        tween<T>(durationMillis = durationMillis, easing = EmphasizedEasing)

    // ==================== M3E 弹簧预设 ====================
    // 移植自 m3e_core 的 M3EMotion（stiffness / damping 逐值对应）。
    // Compose 的 spring() 只有刚度与阻尼比两个参数，damping 即 dampingRatio。

    /** 弹簧预设：刚度 + 阻尼比。[spec] 产出可直接传入动画 API 的 SpringSpec。 */
    data class SpringProfile(
        val stiffness: Float,
        val dampingRatio: Float,
    ) {
        fun <T> spec(): SpringSpec<T> =
            spring(dampingRatio = dampingRatio, stiffness = stiffness)
    }

    /** Fast spatial motion（stiffness 1400 / damping 0.9）。 */
    val StandardSpatialFast = SpringProfile(stiffness = 1400f, dampingRatio = 0.9f)

    /** Default spatial motion（stiffness 700 / damping 0.9）。 */
    val StandardSpatialDefault = SpringProfile(stiffness = 700f, dampingRatio = 0.9f)

    /** Slow spatial motion（stiffness 300 / damping 0.9）。 */
    val StandardSpatialSlow = SpringProfile(stiffness = 300f, dampingRatio = 0.9f)

    /** Fast expressive spatial motion（stiffness 800 / damping 0.6）。 */
    val ExpressiveSpatialFast = SpringProfile(stiffness = 800f, dampingRatio = 0.6f)

    /** Default expressive spatial motion（stiffness 380 / damping 0.8）。 */
    val ExpressiveSpatialDefault = SpringProfile(stiffness = 380f, dampingRatio = 0.8f)

    /** Slow expressive spatial motion（stiffness 200 / damping 0.8）。 */
    val ExpressiveSpatialSlow = SpringProfile(stiffness = 200f, dampingRatio = 0.8f)

    /** Fast effects motion（stiffness 3800 / damping 1，临界阻尼无振荡）。 */
    val StandardEffectsFast = SpringProfile(stiffness = 3800f, dampingRatio = 1.0f)

    /** Default effects motion（stiffness 1600 / damping 1）。 */
    val StandardEffectsDefault = SpringProfile(stiffness = 1600f, dampingRatio = 1.0f)

    /** Slow effects motion（stiffness 800 / damping 1）。 */
    val StandardEffectsSlow = SpringProfile(stiffness = 800f, dampingRatio = 1.0f)

    /** Fast expressive effects motion（stiffness 3800 / damping 1）。 */
    val ExpressiveEffectsFast = SpringProfile(stiffness = 3800f, dampingRatio = 1.0f)

    /** Default expressive effects motion（stiffness 1600 / damping 1，约 200ms 到位）。 */
    val ExpressiveEffectsDefault = SpringProfile(stiffness = 1600f, dampingRatio = 1.0f)

    /** Slow expressive effects motion（stiffness 800 / damping 1）。 */
    val ExpressiveEffectsSlow = SpringProfile(stiffness = 800f, dampingRatio = 1.0f)

    /** Standard overflow animation（stiffness 1600 / damping 0.85）。 */
    val StandardOverflow = SpringProfile(stiffness = 1600f, dampingRatio = 0.85f)

    /**
     * Standard popup animation（stiffness 1000 / damping 0.6，bouncy 回弹）。
     *
     * lite 的 NavigationBar 选中胶囊点击回弹即用此预设
     * （responsive_layout.dart 的 `_CapsuleBounce`）。
     */
    val StandardPopup = SpringProfile(stiffness = 1000f, dampingRatio = 0.6f)

    // ==================== 组件级固定时长 ====================
    // 移植自各核心 Widget 的私有常量（lite 侧散落，native 收敛到本对象统一管理）。

    /**
     * NavigationBar 胶囊回弹的拉伸段时长 80ms。
     * spring 无固定时长，拉伸用短 tween 保证节奏可控（responsive_layout.dart）。
     */
    const val CapsuleStretchDurationMillis = 80

    /**
     * 下拉刷新指示器最短展示时间 500ms：回弹约 200ms + 停留约 300ms，
     * 视觉上「自然到位 → 短暂转圈 → 平滑收回」（md3_pull_to_refresh.dart）。
     */
    const val PullToRefreshMinDisplayMillis = 500

    /** 播放控制行（播放/暂停等）状态切换时长 350ms（md3e_transport_row.dart）。 */
    const val TransportTransitionDurationMillis = 350

    /** 播放控制行按压缩放时长 120ms（md3e_transport_row.dart）。 */
    const val TransportPressDurationMillis = 120

    /** 玻璃 Dock 形态切换（迷你/展开互变）时长 260ms（glass_dock_player.dart）。 */
    const val DockMorphDurationMillis = 260

    /** 输入法展开时面板高度过渡时长 220ms（keyboard_expand_sheet.dart）。 */
    const val SheetResizeDurationMillis = 220

    /** 评论列表排序切换的淡入淡出时长 200ms（playlist_comments_view.dart）。 */
    const val SortFadeDurationMillis = 200
}
