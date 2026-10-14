package com.gracemusic.ui.dock

/**
 * 玻璃 Dock 的纯逻辑函数集合（无 Android / Compose 依赖，JVM 可测）。
 *
 * 从 `GlassDockPlayer` 的布局与状态语义中抽出「可单测的算术与迁移」，
 * Composable 只做渲染壳；全部常量逐值对齐 lite
 * `lib/modules/player/glass_dock_player.dart`（行号见各声明 KDoc）。
 */
object DockLogic {

    // ─────────────────────────── 尺寸常量（对位表） ───────────────────────────

    /** 圆钮 / 展开胶囊高（lite `_kButtonSize`，glass_dock_player.dart:110）。 */
    const val BUTTON_SIZE_DP: Float = 52f

    /** 坍缩圆中央圆形封面直径（lite `_kCircleCoverSize`，:119）。 */
    const val CIRCLE_COVER_SIZE_DP: Float = 46f

    /** 展开胶囊左侧圆形封面直径（lite `_kCapsuleCoverSize`，:122）。 */
    const val CAPSULE_COVER_SIZE_DP: Float = 36f

    /** 进度环线宽（lite `_kRingStroke`，:126；坍缩球与展开胶囊共用）。 */
    const val RING_STROKE_DP: Float = 1.5f

    /** 展开胶囊内封面与歌名 marquee 的间距（lite `_kCapsuleCoverGap`，:129）。 */
    const val CAPSULE_COVER_GAP_DP: Float = 8f

    /** 展开胶囊内 prev/play/next 三钮总宽（lite `_kControlsButtonsWidth`，:115）。 */
    const val CONTROLS_BUTTONS_WIDTH_DP: Float = 120f

    /**
     * 展开胶囊的固定宽度预算 = 三钮 120 + 封面 36 + 环 2×1.5 + 间距 8 +
     * 水平 padding 10（lite `_buildControlsCapsule` 内 `fixedWidth`，
     * glass_dock_player.dart:522-526）。
     */
    const val CAPSULE_FIXED_WIDTH_DP: Float =
        CONTROLS_BUTTONS_WIDTH_DP + CAPSULE_COVER_SIZE_DP + RING_STROKE_DP * 2 + CAPSULE_COVER_GAP_DP + 10f

    /** 歌名 marquee 区宽度上限（lite :528 `clamp(0.0, 120.0)` 的上限）。 */
    const val MARQUEE_MAX_WIDTH_DP: Float = 120f

    /**
     * 导航项图标块宽度预算（lite :266-279：320dp 最小屏 − 外边距 32 −
     * 播放器球 52 − 间距 8 − 胶囊水平 padding 8 = 220）。
     */
    const val NAV_ITEM_BUDGET_DP: Float = 220f

    /** 导航项图标块最大宽度（lite :277，≤4 项时 44）。 */
    const val NAV_ITEM_MAX_WIDTH_DP: Float = 44f

    /** 导航项图标块最小宽度（lite :279 `clamp(28.0, 44.0)` 下限）。 */
    const val NAV_ITEM_MIN_WIDTH_DP: Float = 28f

    /** 导航项压缩时每项扣除的边距量（lite :279 `- 2`）。 */
    const val NAV_ITEM_COMPACT_GAP_DP: Float = 2f

    /** 导航项选中底过渡时长（lite :669 `Duration(milliseconds: 220)`）。 */
    const val NAV_SELECT_DURATION_MILLIS: Int = 220

    /** 两份 marquee 文本之间的间隔（lite `_gap`，:796）。 */
    const val MARQUEE_GAP_PX: Float = 32f

    /** marquee 滚动速度（lite `_speed`，:799；lite 逻辑像素 ≈ Compose dp，见 MarqueeText KDoc）。 */
    const val MARQUEE_SPEED_DP_PER_SEC: Float = 24f

    // ─────────────────────────── 导航项宽 ───────────────────────────

    /**
     * 导航项图标块宽度（dp），1:1 移植 lite glass_dock_player.dart:277-279：
     *
     * ```dart
     * final itemWidth = count <= 4
     *     ? 44.0
     *     : ((220.0 / count) - 2).floorToDouble().clamp(28.0, 44.0);
     * ```
     *
     * 防御：count ≤ 0（空 tab 序 / 非法输入）与 ≤ 4 一样命中足额 44。
     */
    fun navItemWidthDp(count: Int): Float {
        if (count <= 4) return NAV_ITEM_MAX_WIDTH_DP
        val raw = kotlin.math.floor(NAV_ITEM_BUDGET_DP / count - NAV_ITEM_COMPACT_GAP_DP)
        return raw.coerceIn(NAV_ITEM_MIN_WIDTH_DP, NAV_ITEM_MAX_WIDTH_DP)
    }

    // ─────────────────────────── 单展开状态机 ───────────────────────────

    /**
     * Dock 的展开形态值对象。
     *
     * **单展开不变量**（lite glass_dock_player.dart:44-53）：导航与播放器
     * **恰好一个展开**，合法组合仅 [导航胶囊 + 播放器球] 与 [导航球 +
     * 播放器胶囊] 两种，无双坍缩驻留。导航与播放器互斥，故内表示取
     * 单一布尔（`controlsExpanded = !navExpanded` 恒成立，无法表达非法态）。
     */
    data class DockExpansion(val navExpanded: Boolean) {
        /** 播放器工具是否展开（恒与 [navExpanded] 相反）。 */
        val controlsExpanded: Boolean get() = !navExpanded

        companion object {
            /** 冷启动默认「导航胶囊 + 播放器球」（lite app.dart:603-607）。 */
            fun initial(): DockExpansion = DockExpansion(navExpanded = true)
        }
    }

    /**
     * 点坍缩导航圆 → 导航展开、播放器强制收起（lite 反向闭环
     * glass_dock_player.dart:166-170）。
     */
    fun onNavCircleClicked(state: DockExpansion): DockExpansion = DockExpansion(navExpanded = true)

    /**
     * 切 tab → 导航保持展开（lite `_DockNavItem.onTap` 只上报选中、不改折叠态；
     * 导航本就展开，此处以纯函数形式固定「切 tab 不收起导航」的语义）。
     */
    fun onTabSelected(state: DockExpansion): DockExpansion = DockExpansion(navExpanded = true)

    /**
     * 点播放器钮 / 胶囊背景 → 播放器展开态翻转，导航随之让位 / 恢复
     * （lite 正向闭环 `_toggleControls` glass_dock_player.dart:179-186：
     * `next = !_controlsExpanded; setState(controls = next); onNavExpandedChanged(!next)`
     * ——先置位后回调，时序保证无乒乓竞态。纯函数模型下新导航态 =
     * 旧 controlsExpanded（即 `!next`），展开态天然翻转）。
     */
    fun onPlayerButtonToggled(state: DockExpansion): DockExpansion =
        DockExpansion(navExpanded = state.controlsExpanded)

    // ─────────────────────────── 进度钳位 ───────────────────────────

    /**
     * 进度环进度 = position / duration，1:1 移植 lite glass_dock_player.dart:385-389
     * （坍缩球）与 :548-554（展开胶囊）：
     * duration 为 null 或 0 → 0（只画轨道不画进度弧）；负值钳 0、超长钳 1。
     *
     * @param positionMs 当前位置毫秒。
     * @param durationMs 时长毫秒；null 表示未知。
     */
    fun progressRatio(positionMs: Long, durationMs: Long?): Float {
        if (durationMs == null || durationMs <= 0L) return 0f
        if (positionMs <= 0L) return 0f
        val ratio = positionMs.toDouble() / durationMs.toDouble()
        return ratio.coerceIn(0.0, 1.0).toFloat()
    }

    // ─────────────────────────── 歌名区宽度防御 ───────────────────────────

    /**
     * 展开胶囊内歌名 marquee 区的宽度（dp），1:1 移植 lite
     * glass_dock_player.dart:522-528：`(constraints.maxWidth - fixedWidth).clamp(0, 120)`。
     * 小屏下歌名区先压缩到 0，保证胶囊自身不超屏宽。
     *
     * @param availableWidthDp 胶囊可用总宽（dp）。
     */
    fun capsuleMarqueeWidthDp(availableWidthDp: Float): Float =
        (availableWidthDp - CAPSULE_FIXED_WIDTH_DP).coerceIn(0f, MARQUEE_MAX_WIDTH_DP)

    // ─────────────────────────── marquee 回卷 ───────────────────────────

    /**
     * marquee 偏移步进（纯算术），1:1 移植 lite glass_dock_player.dart:827-833：
     * `offset = (offset + delta) % (textWidth + gap)`，双文本间隔 32px 无缝循环。
     *
     * 与 Dart `%` 的差异：Dart 对正被除数返回非负，Kotlin `%` 对负被除数返回负；
     * 此处用 floorMod 语义（`((x % m) + m) % m`）保证偏移恒非负，防御负 delta。
     * total ≤ 0（文本未测量 / 空文本）时原样返回当前偏移，不前进。
     *
     * @param currentOffsetPx 当前偏移（px）。
     * @param deltaPx 本帧步进量（px，恒正）。
     * @param textWidthPx 单份文本像素宽。
     */
    fun marqueeLoopOffset(currentOffsetPx: Float, deltaPx: Float, textWidthPx: Float): Float {
        val total = textWidthPx + MARQUEE_GAP_PX
        if (total <= 0f) return currentOffsetPx
        val next = currentOffsetPx + deltaPx
        return ((next % total) + total) % total
    }

    // ─────────────────────────── FullPlayer 门控 ───────────────────────────

    /** Dock 对 FullPlayer 展开度的响应三态（lite glass_dock_player.dart:199-207）。 */
    enum class DockVisibility {
        /** fraction > 0.5：整体移除，不产帧。 */
        REMOVED,

        /** 0.2 < fraction ≤ 0.5：IgnorePointer + alpha = 1 − fraction。 */
        FADED,

        /** fraction ≤ 0.2：正常显示与交互。 */
        VISIBLE,
    }

    /**
     * FullPlayer 展开度 → Dock 可见性三态，1:1 移植 lite
     * glass_dock_player.dart:199-207（`exp > 0.5` 移除；`exp > 0.2` 半透明 +
     * IgnorePointer；其余正常）。
     */
    fun dockVisibility(fullPlayerVisibleFraction: Float): DockVisibility = when {
        fullPlayerVisibleFraction > 0.5f -> DockVisibility.REMOVED
        fullPlayerVisibleFraction > 0.2f -> DockVisibility.FADED
        else -> DockVisibility.VISIBLE
    }

    /**
     * FullPlayer 展开度 → Dock 透明度，1:1 移植 lite :206
     * `Opacity(opacity: (1.0 - exp).clamp(0.0, 1.0))`。越界 fraction 钳位防御。
     */
    fun dockAlpha(fullPlayerVisibleFraction: Float): Float =
        (1f - fullPlayerVisibleFraction).coerceIn(0f, 1f)

    // ─────────────────────────── 坍缩圆 tab 回退 ───────────────────────────

    /**
     * 坍缩导航圆应显示的 tab id，1:1 移植 lite glass_dock_player.dart:307-314：
     * 选中 tab 在可见集合内用之；否则回退第一个可见 tab；可见集为空回退 null
     * （上层坍缩圆不画图标——lite 的 `visible.firstOrNull` 在空集时回退
     * 'discover' 字面量，但该情形仅出现于配置异常，native 侧以 null 显式表达，
     * 由调用方决定占位渲染，避免魔法字符串）。
     */
    fun collapsedNavTabId(selectedTabId: String?, visibleTabIds: List<String>): String? {
        if (visibleTabIds.isEmpty()) return null
        return if (selectedTabId != null && selectedTabId in visibleTabIds) {
            selectedTabId
        } else {
            visibleTabIds.first()
        }
    }

    // ─────────────────────────── 进度环几何 ───────────────────────────

    /**
     * 坍缩球进度环中心线半径（dp），1:1 移植 lite glass_dock_player.dart:395-399：
     * 26 − 0.75 − 0.5 = 24.75——环贴按钮外缘，外缘 25.5 < 26 不出界，
     * 内缘 24 距 46dp 封面外缘 1dp。
     */
    fun collapsedRingRadiusDp(): Float = BUTTON_SIZE_DP / 2f - RING_STROKE_DP / 2f - 0.5f

    /**
     * 展开胶囊进度环中心线半径（dp），1:1 移植 lite glass_dock_player.dart:562-565：
     * 18 + 0.75 = 18.75——环内缘恰贴 36dp 封面外缘（无间隙）。
     */
    fun capsuleRingRadiusDp(): Float = CAPSULE_COVER_SIZE_DP / 2f + RING_STROKE_DP / 2f
}
