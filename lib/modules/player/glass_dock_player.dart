import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/services/player_frame_driver.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/widgets/liquid_glass_container.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/player_provider.dart';
import '../../providers/tab_config_provider.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/playing_spectrum_indicator.dart';
import 'full_player_route.dart';

/// Dock 导航项图标 / 回退文案定义（按 tab id 查表）。
///
/// 图标映射与 app.dart `_buildDestination`、home_tab_manager.dart
/// `homeTabIcon` 保持一致；label 以 [TabConfigProvider] 为准，
/// [fallbackLabel] 仅在未知 tab id 时兜底。
class _DockTab {
  final String id;
  final IconData outlined;
  final IconData filled;
  final String fallbackLabel;

  const _DockTab(this.id, this.outlined, this.filled, this.fallbackLabel);
}

const Map<String, _DockTab> _kDockTabById = {
  'discover': _DockTab('discover', Icons.home_outlined, Icons.home, '主页'),
  'favorites': _DockTab(
    'favorites',
    Icons.favorite_outline,
    Icons.favorite,
    '收藏',
  ),
  'library': _DockTab(
    'library',
    Icons.library_music_outlined,
    Icons.library_music,
    '本地音乐',
  ),
  'fm': _DockTab('fm', Icons.radio_outlined, Icons.radio, '私人FM'),
  'search': _DockTab('search', Icons.search_outlined, Icons.search, '搜索'),
  'recognition': _DockTab(
    'recognition',
    Icons.mic_none_outlined,
    Icons.mic,
    '听歌识曲',
  ),
  'audiobook': _DockTab(
    'audiobook',
    Icons.auto_stories_outlined,
    Icons.auto_stories,
    '听书',
  ),
  'settings': _DockTab(
    'settings',
    Icons.settings_outlined,
    Icons.settings,
    '设置',
  ),
  'recent': _DockTab('recent', Icons.history_outlined, Icons.history, '最近播放'),
  'scan': _DockTab('scan', Icons.radar_outlined, Icons.radar, '扫描状态'),
};

_DockTab _dockTabFor(String id) =>
    _kDockTabById[id] ??
    const _DockTab('unknown', Icons.circle_outlined, Icons.circle, '标签页');

/// 底部悬浮玻璃 Dock：导航胶囊 + 常驻播放器圆钮。
///
/// 状态机（全部收敛型动画，无 repeat 连续动画）：
/// - **单展开不变量**：导航与播放器工具**恰好一个展开**，仅两种合法组合：
///   [导航胶囊 + 播放器球]（默认）与 [导航球 + 播放器胶囊]。折叠状态唯一
///   驱动是用户点击，滚动不参与：
///   · 播放器工具展开（点播放器圆钮）→ 导航坍缩让位；
///   · 点坍缩导航圆 / 切 tab → 导航展开；
///   · 导航展开 → 播放器工具收起（listener 双向闭环，无双坍缩驻留）。
///   **播放器工具的收起只由「点坍缩导航圆 / 切 tab」经 listener 闭环驱动**，
///   胶囊自身不响应 tap 收起：用户反馈「未点中悬浮导航条的触摸也误触导致
///   播放器坍缩」——根因是玻璃叠色层（[LiquidGlassSurface] 内的 ColoredBox）
///   以 HitTestBehavior.opaque 命中，整个胶囊矩形（含 padding / 边缘）均可
///   点，原胶囊外层 onTap 在背景区域即生效。语义收紧后仅命中导航条本体的
///   点击才坍缩播放器；封面 / 歌名点击进播放页、三个控制钮、左右滑切歌、
///   上滑展开均不受影响。
///   合法组合仅 [导航胶囊 + 播放器球] 与 [导航球 + 播放器胶囊] 两种；
///   现为纯点击驱动（点导航坍缩圆 / 切 tab / 点播放器圆钮），无滚动驱动。
/// - **导航**：展开（玻璃胶囊导航项）↔ 坍缩（单个当前 tab 玻璃圆）。
///   导航项完全跟随 [TabConfigProvider.visibleTabs]（顺序 + 显隐 + label，
///   即设置→主页管理的配置实时生效，低频 watch 不进 positionNotifier
///   高频通道）；图标按 id 查 `_kDockTabById`（与 app.dart 一致）；
///   坍缩圆显示当前选中且可见 tab 的图标（选中 filled / 回退 outlined），
///   selectedTabId 不在 visibleTabs 时回退第一个可见 tab；
///   展开态由外部（`_MainLayout`）持有并通过 [navExpanded] 注入；
///   项宽随项数自适应（≤4 项 44dp，更多时按 320dp 最小屏预算压缩，
///   见 `_buildNavPill`），保证「导航胶囊 + 播放器球」组合不超宽；
/// - **播放器圆钮**：点击展开为控制小胶囊（AnimatedSize 收敛形变；收起只
///   经点坍缩导航圆 / 切 tab，见单展开不变量——胶囊自身不再响应 tap 收起）；
///   圆钮外周进度环订阅 [PlayerProvider.positionNotifier]（~200ms 高频通道，
///   禁 context.watch），中央为当前歌曲的**圆形封面缩略图**（46dp 充满
///   圆内）：播放中叠加 [PlayingSpectrumIndicator] 律动图标（挂共享 60fps
///   节拍、仅播放中运行）；暂停时叠静态 pause 图标（均垫一层略暗圆形
///   遮罩，保证图标在亮色封面上可读）；
///   无歌 / 封面缺失时回退音符占位；整钮 [RepaintBoundary] 隔离高频重绘；
/// - **完整播放页往返**：openFullPlayer / close 不触碰折叠状态；关闭播放页
///   后 Dock 恢复「打开前的那个唯一展开组件」——状态只由用户点击驱动，
///   关闭后即为打开前状态，符合单展开不变量，无额外恢复路径。
/// - **布局固定**：行恒为 [导航部分, 8, 播放器(Flexible)]——左侧悬浮导航、
///   右侧悬浮播放器，位置恒定不互换；单展开不变量保证「导航胶囊 +
///   播放器球」「导航球 + 播放器胶囊」两种组合均不超宽；已移除向上按钮——
///   点封面 / 歌名进入完整播放页（胶囊内左侧含 36dp 圆形封面缩略图，
///   同源可点击）；
/// - **上滑展开（P0-1 接通）**：播放器圆钮 / 胶囊加 `onVerticalDragStart/
///   Update/End`——start 记 [playerDragOriginTop]（= 播放器按钮顶端全局 Y）
///   并激活 [playerDragActive]（跟手覆盖层显示真实 FullPlayer）；update 按
///   「拖拽距离 / 按钮顶端」1:1 映射 [playerExpansion]（复用 PlayerDragOverlay
///   与 DraggablePlayerRoute 既有映射口径）；end 按 [shouldExpandPlayer]
///   三阈值（屏高 20% / 900px/s / 6000px/s²）判定：达标则 push
///   [fullPlayerRoute]（dragOriginTop 模式）并从当前拖拽进度 settleToFull，
///   未达标 / 取消则覆盖层经 200ms easeOutCubic 回归收敛归位
///   （[_startDragReturn]，从松手进度连续收敛，无瞬跳）。song == null 时
///   不注册拖拽回调（不抢手势，
///   tap 行为不变）；「播放页已在栈中」在 start 运行时拦截——build 期判定
///   会随 Dock 子树移除/重挂载产生过期快照（收起后无法再展开的回归根因，
///   见 [_buildPlayerButton] 内注释）；
/// - **左右滑切歌（P1，默认开）**：展开胶囊 `onHorizontalDrag*` 歌名跟手
///   位移、露出相邻方向歌名预览，松手按距离/速度阈值判定调 previous()/next()
///   （iOS 迷你条惯例），开关 `SettingsRepository.dockSwipeToSwitchTrack`
///   （默认开，设置→播放行为）；
/// - **隐藏**：完整播放页展开（playerExpansion > 0.5）时整体移除，不产帧；
///   Dock 自身上滑拖拽期间豁免（拖拽会把 expansion 推过 0.5，此时 Dock
///   必须保持在树中维持手势事件流，视觉上由 Opacity(1-exp) 淡出）。
class GlassDockPlayer extends StatefulWidget {
  const GlassDockPlayer({
    super.key,
    required this.selectedTabId,
    required this.onSelectTab,
    required this.navExpanded,
    required this.onNavExpandedChanged,
    this.showNav = true,
  });

  /// 当前选中的 tab id（discover / library / fm / search 等）。
  final String selectedTabId;

  /// 点击导航项回调（tabId）。
  final ValueChanged<String> onSelectTab;

  /// 导航展开态（由 _MainLayout 持有的 ValueNotifier，用户点击驱动，
  /// 滚动不参与）。
  final ValueListenable<bool> navExpanded;

  /// 请求导航展开/坍缩（双向闭环）：true = 点坍缩圆或切 tab 时恢复展开
  /// （播放器工具若仍展开，经 listener 强制收起）；false = 播放器工具
  /// 展开时请求导航让位坍缩。
  final ValueChanged<bool> onNavExpandedChanged;

  /// 是否渲染导航部分（默认 true，一级 tab 页「导航 + 播放器」）。
  ///
  /// 批次 24：二级 push 路由页只挂悬浮播放器（用户口径「二级页面不
  /// 显示悬浮导航但显示悬浮播放器」）——路由页盖在主布局之上，主布局
  /// 的 Dock 被完全遮住，故由 app.dart 在 Navigator 之上单独渲染一份
  /// `showNav: false` 的实例；此时导航相关参数均不参与布局。
  final bool showNav;

  @override
  State<GlassDockPlayer> createState() => _GlassDockPlayerState();
}

class _GlassDockPlayerState extends State<GlassDockPlayer>
    with TickerProviderStateMixin {
  /// 播放器圆钮 → 控制小胶囊的展开态（收敛型 AnimatedSize 驱动）。
  ///
  /// 仅播放器形态（[GlassDockPlayer.showNav] == false，二级 push 路由页）
  /// **恒展开**（用户口径「仅显示悬浮播放器时恒展开」）：初始即展开，且
  /// 不参与「导航展开 ⇒ 播放器收起」的单展开闭环（见 initState 与
  /// [_onNavExpandedChanged] 守卫）。
  bool _controlsExpanded = false;

  static const double _kButtonSize = 52.0;
  static const Duration _kMorphDuration = Duration(milliseconds: 260);

  /// 展开态控制胶囊内 3 个紧凑 IconButton 的总宽（40dp/个），
  /// 用于小屏下计算歌名 marquee 的可压缩宽度。
  static const double _kControlsButtonsWidth = 120.0;

  /// 坍缩圆中央的圆形封面直径（52dp 圆钮内，充满进度环内圈，
  /// 距按钮外缘各留 3dp）。
  static const double _kCircleCoverSize = 46.0;

  /// 展开胶囊内左侧的圆形封面缩略图直径。
  static const double _kCapsuleCoverSize = 36.0;

  /// 进度环线宽（坍缩球与展开胶囊共用；坍缩球环贴按钮外缘、
  /// 展开胶囊环贴封面外缘）。
  static const double _kRingStroke = 1.5;

  /// 展开胶囊内封面与歌名 marquee 之间的间距。
  static const double _kCapsuleCoverGap = 8.0;

  /// 左右滑切歌的最低松手速度（px/s，|primaryVelocity| 达标才切）。
  static const double _kSwipeSwitchVelocity = 400.0;

  // ── 上滑展开拖拽状态（与 FullPlayer 顶栏下滑收起镜像的判定口径） ──

  /// 向上累计拖拽距离（px，≥0）。
  double _dragDistance = 0.0;

  /// 上次事件 Y / 时间戳（速度、加速度差分估计用）。
  double? _dragLastY;
  Duration? _dragLastTime;

  /// 上次事件向上速度（px/s，向上为正）。
  double _dragVelocity = 0.0;

  /// 当前向上加速度估计（px/s²，允许为负 = 末端减速）。
  double _dragAcceleration = 0.0;

  /// 松手未达三阈值（/ 手势被取消）时的回归收敛动画：把 [playerExpansion]
  /// 从松手进度 easeOutCubic 收敛回 0（200ms），期间保持 [playerDragActive]
  /// （跟手覆盖层继续渲染回归过程），正常结束后释放。
  ///
  /// 修复此前的瞬跳：旧实现直接 `playerExpansion.value = 0.0`，跟手覆盖层
  /// （[PlayerDragOverlay]）瞬间消失、Dock 透明度瞬跳回 1，与
  /// [DraggablePlayerRoute.settleToFull] / dismiss 的收敛口径不一致。
  late final AnimationController _dragReturnSettle;

  /// 回归收敛起点（松手瞬间的 playerExpansion 快照，由 [_startDragReturn]
  /// 记录）。
  double _dragReturnFrom = 0.0;

  // ── 左右滑切歌：歌名跟手位移 / 相邻曲目预览（ValueNotifier 局部驱动，
  //    拖拽期不 setState、不重建整个 Dock）──

  /// 歌名区水平位移（px，向左为负 = 预览下一曲；向右为正 = 预览上一曲）。
  final ValueNotifier<double> _switchDx = ValueNotifier<double>(0.0);

  /// 跟手位移收敛动画（松手切歌滑出 / 未达阈值回弹归位）。
  late final AnimationController _switchSettle;

  /// 收敛动画起止位移（由 [_settleSwitchTo] 记录）。
  double _switchAnimFrom = 0.0;
  double _switchAnimTo = 0.0;

  /// 最近一次布局得到的歌名区宽度（跟手位移上限与切歌距离阈值用）。
  double _marqueeWidth = 0.0;

  @override
  void initState() {
    super.initState();
    // 仅播放器形态恒展开（二级 push 路由页，用户口径），见字段注释。
    if (!widget.showNav) _controlsExpanded = true;
    // 状态联动（单展开不变量的反向闭环）：导航展开 ⇒ 播放器工具强制收起。
    // 正向闭环（播放器工具展开 ⇒ 导航坍缩）在 [_expandControls] 中经
    // onNavExpandedChanged 回调完成。两个展开态不得同时存在，否则总宽
    // 超出屏宽。
    widget.navExpanded.addListener(_onNavExpandedChanged);
    // 预热「左右滑切歌」开关内存缓存（设置页修改经 ValueNotifier 即时生效）
    // ignore: discarded_futures
    SettingsRepository().getDockSwipeToSwitchTrack();
    _switchSettle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _switchSettle.addListener(() {
      final t = Curves.easeOutCubic.transform(_switchSettle.value);
      _switchDx.value = _switchAnimFrom + (_switchAnimTo - _switchAnimFrom) * t;
    });
    // 上滑拖拽松手未达阈值时的回归收敛（200ms easeOutCubic）：帧回调只写
    // 局部 ValueNotifier（playerExpansion），不 setState、不重建 Dock。
    _dragReturnSettle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _dragReturnSettle.addListener(_onDragReturnTick);
  }

  @override
  void didUpdateWidget(covariant GlassDockPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navExpanded != widget.navExpanded) {
      oldWidget.navExpanded.removeListener(_onNavExpandedChanged);
      widget.navExpanded.addListener(_onNavExpandedChanged);
    }
  }

  @override
  void dispose() {
    widget.navExpanded.removeListener(_onNavExpandedChanged);
    _switchSettle.dispose();
    _switchDx.dispose();
    _dragReturnSettle.dispose();
    super.dispose();
  }

  /// 反向闭环：导航展开 ⇒ 播放器工具强制收起（维持单展开不变量）。
  /// 两种驱动路径的命中情况：
  /// - 点播放器圆钮展开（[_expandControls] 置 _controlsExpanded = true 后
  ///   回调 onNavExpandedChanged(false)）：_collapseNav() 使 nav 变为
  ///   false，本 listener 触发时 navExpanded.value 为 false，条件不成立，
  ///   走 no-op，播放器胶囊得以保留 ✓；
  /// - 点导航坍缩圆展开导航（onNavExpandedChanged(true)）：nav 变为 true，
  ///   若播放器胶囊仍展开则强制收起，恢复「恰好一个展开」——这是期望
  ///   行为，不可删除；也是**播放器工具收起的唯一点击路径**（语义收紧，
  ///   见类文档：胶囊自身不再响应 tap 收起）。
  /// 两条路径均不会反向再改导航值，故无乒乓竞态。
  void _onNavExpandedChanged() {
    // 仅播放器形态没有导航可展开，恒展开（见字段注释）。
    if (!widget.showNav) return;
    if (widget.navExpanded.value && _controlsExpanded) {
      setState(() => _controlsExpanded = false);
    }
  }

  /// 播放器工具展开（单展开不变量的正向驱动，双向闭环）：先置
  /// _controlsExpanded = true，再回调 onNavExpandedChanged(false) 请求
  /// 导航坍缩让位。时序保证：回调触发 _onNavExpandedChanged 时
  /// navExpanded.value 已为 false，条件不成立，走 no-op，播放器胶囊
  /// 得以保留，无乒乓竞态。
  ///
  /// 语义收紧（用户反馈「未点中悬浮导航条的触摸误触导致播放器坍缩」）：
  /// 本方法只负责展开——原「点胶囊收起」分支随胶囊 onTap 一并移除
  /// （根因见类文档与 [_buildControlsCapsule] 注释），播放器工具的收起
  /// 只经「点坍缩导航圆 / 切 tab → 导航展开 → [_onNavExpandedChanged]
  /// 强制收起」闭环。
  void _expandControls() {
    AppHaptics.click();
    setState(() => _controlsExpanded = true);
    // 回调语义是「导航是否展开」，与播放器自身状态相反：
    // 播放器展开 → 导航让位坍缩。
    widget.onNavExpandedChanged(false);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    final isPlaying = player.isPlaying;
    final duration = player.duration;

    // 主页管理配置（显隐/排序/label）：低频 watch——设置页改动即时反映
    // 到 Dock；不进 positionNotifier 高频通道。
    final tabConfig = context.watch<TabConfigProvider>();

    // 完整播放页展开时整体隐藏（>0.5 直接移除，不产帧）。
    // 豁免：Dock 自身上滑拖拽期间（playerDragActive）exp 会被推过 0.5，
    // 此时必须保持在树中维持手势事件流（视觉由下方 Opacity 淡出）。
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, exp, child) {
        if (exp > 0.5 && !playerDragActive.value) {
          return const SizedBox.shrink();
        }
        return IgnorePointer(
          ignoring: exp > 0.2 && !playerDragActive.value,
          child: Opacity(opacity: (1.0 - exp).clamp(0.0, 1.0), child: child),
        );
      },
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            // 布局防御：播放器按钮用 Flexible（loose）吃剩余宽度，
            // 极限屏宽下歌名区先压缩，整体任何状态不超屏宽。
            // 布局恒定：左 = 悬浮导航、右 = 悬浮播放器；单展开不变量
            // 保证「导航胶囊 + 播放器球」「导航球 + 播放器胶囊」
            // 两种组合在 320dp 屏均不超宽。
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 仅播放器形态（二级 push 路由页）不渲染导航部分，
                // 播放器球改为整行居中（单展开不变量在此形态下退化）。
                if (widget.showNav) ...[
                  _buildNavPart(tabConfig),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: _buildPlayerButton(player, song, isPlaying, duration),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // —— 导航部分 ——

  Widget _buildNavPart(TabConfigProvider tabConfig) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.navExpanded,
      builder: (context, expanded, _) => AnimatedSize(
        duration: _kMorphDuration,
        curve: Curves.easeOutCubic,
        // 左缘锚定：导航恒在行首（屏左），坍缩 ↔ 展开时左缘不动、
        // 向右生长，不会顶出屏幕左缘。
        alignment: Alignment.centerLeft,
        // 注意：不要在此包 AnimatedSwitcher 做内容交叉淡化——淡出中的旧
        // 形态会以非定位子元素参与 Stack 布局，容器尺寸被钉在 max(旧, 新)
        // 上直到旧形态移除，尺寸动画被推迟成「先等待后收缩」的两段式，
        // 观感跳变（b70a19b 的纯 AnimatedSize 单动画节奏反而干脆）。
        child: expanded
            ? _buildNavPill(tabConfig)
            : _buildNavCollapsed(tabConfig),
      ),
    );
  }

  /// 展开态：玻璃胶囊内的导航项（渲染 [TabConfigProvider.visibleTabs]，
  /// 顺序 / 显隐 / label 全跟随主页管理配置）。
  ///
  /// 项宽自适应（溢出复核，320dp 最小屏）：可用宽 320 − 左右外边距 32
  /// = 288；预留播放器球 52 + 间距 8 → 导航胶囊预算 228；再扣胶囊水平
  /// padding 8 → 导航项总预算 220。导航项本身 icon-only（44×44 图标块 +
  /// 左右各 1dp 外边距 = 46dp 足额占用）：
  /// - ≤4 项：4×46=184 ≤ 220，项宽足额 44dp；
  /// - 5 项：项宽 42（footprint 44）→ 5×44+8=228，228+8+52=288 恰好满宽；
  /// - 6 项：项宽 34（footprint 36）→ 6×36+8=224，224+8+52=284 < 288。
  /// 宽于 320dp 的屏幕项宽不受影响（仍 44dp）。
  Widget _buildNavPill(TabConfigProvider tabConfig) {
    final tabs = tabConfig.visibleTabs;
    final count = tabs.length;
    final itemWidth = count <= 4
        ? 44.0
        : ((220.0 / count) - 2).floorToDouble().clamp(28.0, 44.0);
    return LiquidGlassContainer(
      shape: GlassShape.pill,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tab in tabs)
            _DockNavItem(
              tab: _dockTabFor(tab.id),
              label: tab.label,
              selected: widget.selectedTabId == tab.id,
              width: itemWidth,
              onTap: () {
                AppHaptics.tick();
                widget.onSelectTab(tab.id);
              },
            ),
        ],
      ),
    );
  }

  /// 坍缩态：单个当前 tab 玻璃圆（点击展开导航，展开逻辑不变）。
  ///
  /// **播放器工具收起的唯一点击路径**（语义收紧，见类文档）：点此圆展开
  /// 导航，[_onNavExpandedChanged] listener 闭环同步强制收起播放器胶囊。
  ///
  /// 显示「当前选中且可见」的 tab 图标（选中 filled + primary）；
  /// selectedTabId 不在 visibleTabs 中时回退第一个可见 tab（outlined +
  /// onSurfaceVariant，该 tab 并非选中态）。
  Widget _buildNavCollapsed(TabConfigProvider tabConfig) {
    final visible = tabConfig.visibleTabs;
    final selectedVisible = visible.any((t) => t.id == widget.selectedTabId);
    final dockTab = _dockTabFor(
      selectedVisible
          ? widget.selectedTabId
          : (visible.firstOrNull?.id ?? 'discover'),
    );
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        AppHaptics.click();
        widget.onNavExpandedChanged(true);
      },
      child: LiquidGlassContainer(
        shape: GlassShape.circle,
        child: SizedBox(
          width: _kButtonSize,
          height: _kButtonSize,
          child: Icon(
            selectedVisible ? dockTab.filled : dockTab.outlined,
            size: 24,
            color: selectedVisible ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  // —— 播放器部分 ——

  Widget _buildPlayerButton(
    PlayerProvider player,
    dynamic song,
    bool isPlaying,
    Duration? duration,
  ) {
    // RepaintBoundary 隔离：进度环 ~200ms 重绘不外溢。
    return RepaintBoundary(
      child: Builder(
        builder: (buttonContext) {
          // 上滑展开（P0-1）：song == null 不注册拖拽回调（不抢手势）。
          // 注意：**播放页已在栈中**这一条不能在 build 期判定——回归教训：
          // 播放页展开期间 Dock 子树被移除（exp > 0.5 → SizedBox.shrink），
          // 收起动画中段（exp 回落 ≤ 0.5、路由仍在栈中）子树重挂载时，
          // build 期快照判定 canDrag=false 注册了空回调；收起完成后若暂停态
          // 无 position tick 通知重建，回调永久缺失 → 无法再次上滑展开。
          // 因此注册只看 song；「播放页已在栈中」由 [_onPlayerDragStart]
          // 运行时守卫拦截（拖拽期 Dock 未隐藏时仍不抢播放页手势）。
          final canDrag = song != null;
          return GestureDetector(
            key: const ValueKey('glass_dock_player_button'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: canDrag
                ? (d) => _onPlayerDragStart(buttonContext, d)
                : null,
            onVerticalDragUpdate: canDrag ? _onPlayerDragUpdate : null,
            onVerticalDragEnd: canDrag ? _onPlayerDragEnd : null,
            onVerticalDragCancel: canDrag ? _onPlayerDragCancel : null,
            child: AnimatedSize(
              duration: _kMorphDuration,
              curve: Curves.easeOutCubic,
              // 右缘锚定：播放器恒在行尾（屏右），坍缩 ↔ 展开时右缘不动、
              // 向左生长，不会顶出屏幕右缘。
              // 同导航部分：不包 AnimatedSwitcher（理由见 _buildNavPart 注释）。
              alignment: Alignment.centerRight,
              child: _controlsExpanded
                  ? _buildControlsCapsule(player, song, duration)
                  : _buildCircle(song, isPlaying, duration, player),
            ),
          );
        },
      ),
    );
  }

  // —— 上滑展开拖拽（P0-1：start 记 origin / update 跟手 / end 三阈值判定）——

  /// 拖拽开始：记录播放器按钮顶端全局 Y（= FullPlayer 展开起点），
  /// 激活跟手覆盖层（真实 FullPlayer，随 playerExpansion 位移/淡入）。
  void _onPlayerDragStart(BuildContext boxContext, DragStartDetails details) {
    // 运行时守卫（含「播放页已在栈中」检查——不放在 build 期注册判定，
    // 否则 Dock 子树重挂载后会拿到过期快照，见 _buildPlayerButton 注释）：
    // 无歌 / 播放页已在栈中时不启动拖拽。
    if (context.read<PlayerProvider>().currentSong == null) return;
    if (activePlayerRoute != null && activePlayerRoute!.isActive) return;
    // 停掉可能正在进行的回归收敛（松手未达阈值后立刻重新上滑的场景）：
    // 新拖拽接管，[playerDragActive] 本就保持 true，无需重置。
    _dragReturnSettle.stop();
    _dragVelocity = 0.0;
    _dragAcceleration = 0.0;
    _dragLastY = details.globalPosition.dy;
    _dragLastTime = details.sourceTimeStamp;
    final box = boxContext.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      playerDragOriginTop = box.localToGlobal(Offset.zero).dy;
    }
    // 从当前 expansion 续接累计距离：回归收敛被新拖拽接管时的无缝起点
    // （常态 expansion 为 0，与旧的 _dragDistance = 0.0 等价）。
    _dragDistance = playerExpansion.value * playerDragOriginTop;
    playerDragActive.value = true;
  }

  /// 拖拽更新：1:1 跟手映射 playerExpansion（距离 / 按钮顶端），
  /// 同时差分估计向上速度与加速度（供松手三阈值判定）。
  void _onPlayerDragUpdate(DragUpdateDetails details) {
    if (!playerDragActive.value) return;
    _dragDistance = (_dragDistance - details.delta.dy).clamp(
      0.0,
      double.infinity,
    );
    final ts = details.sourceTimeStamp;
    if (ts != null && _dragLastTime != null && _dragLastY != null) {
      final dt = (ts - _dragLastTime!).inMicroseconds / 1e6;
      if (dt > 0) {
        // 向上为正（全局 Y 向下为正，取负）
        final v = -(details.globalPosition.dy - _dragLastY!) / dt;
        _dragAcceleration = (v - _dragVelocity) / dt;
        _dragVelocity = v;
      }
    }
    _dragLastY = details.globalPosition.dy;
    _dragLastTime = ts;
    final origin = playerDragOriginTop;
    if (origin > 0) {
      playerExpansion.value = (_dragDistance / origin).clamp(0.0, 1.0);
    }
  }

  /// 拖拽松手：按 [shouldExpandPlayer] 三阈值判定（屏高 20% / 900px/s /
  /// 6000px/s²，任一达标即展开；松手瞬间向下回拉则否决）。
  /// 达标 → push dragOriginTop 模式路由并从当前拖拽进度 settleToFull
  /// （覆盖层最后位置与路由首帧无缝衔接）；未达标 → 覆盖层经回归收敛
  /// 动画归位（[_startDragReturn]，替代此前的瞬跳置 0）。
  void _onPlayerDragEnd(DragEndDetails details) {
    if (!playerDragActive.value) return;
    final distance = _dragDistance;
    _dragDistance = 0.0;
    // primaryVelocity 向下为正，换算为「向上为正」
    final velocity = -(details.primaryVelocity ?? 0.0);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final progress = playerExpansion.value;
    if (shouldExpandPlayer(
      dragDistance: distance,
      screenHeight: screenHeight,
      velocity: velocity,
      acceleration: _dragAcceleration,
    )) {
      // 路由接管显示权，拖拽激活即刻释放（覆盖层交棒）。
      playerDragActive.value = false;
      final route = fullPlayerRoute(
        context,
        dragOriginTop: playerDragOriginTop,
        screenHeight: screenHeight,
      );
      Navigator.of(context, rootNavigator: true).push(route);
      // 拖拽模式 didPush 将 controller 归零等待手势接管；此处无后续手势，
      // 从覆盖层最后进度收敛到全屏（300ms easeOutCubic，起点连续不跳变）。
      route.controller.value = progress.clamp(0.0, 1.0);
      route.settleToFull();
    } else {
      // 未达标：跟手覆盖层从当前进度收敛归位，[playerDragActive] 保持
      // true 直到动画正常结束（被新拖拽接管则不释放，见 [_startDragReturn]）。
      _startDragReturn();
    }
    _dragVelocity = 0.0;
    _dragAcceleration = 0.0;
  }

  /// 启动回归收敛（松手未达三阈值 / 手势被系统取消）：从当前
  /// [playerExpansion] easeOutCubic 收敛回 0（200ms），期间
  /// [playerDragActive] 保持 true 让跟手覆盖层渲染回归过程；动画正常
  /// 结束后释放，被新拖拽（[_onPlayerDragStart] stop 接管，status 非
  /// completed）则不释放、交给新拖拽管理。已在起点（expansion ≤ 0）时
  /// 无需动画，直接释放。
  void _startDragReturn() {
    final from = playerExpansion.value;
    if (from <= 0.0) {
      playerDragActive.value = false;
      return;
    }
    _dragReturnFrom = from;
    _dragReturnSettle.forward(from: 0).whenCompleteOrCancel(() {
      if (!mounted) return;
      // stop 接管后 status 为 dismissed（不释放）；自然收敛完成才释放。
      if (_dragReturnSettle.status == AnimationStatus.completed) {
        playerDragActive.value = false;
      }
    });
  }

  /// 回归收敛帧回调：easeOutCubic 插值写回 [playerExpansion]（局部
  /// ValueNotifier 驱动覆盖层位置 / 透明度与 Dock 淡入，不 setState、
  /// 不重建整个 Dock；动画结束 controller 自动停止，无残留 ticker）。
  void _onDragReturnTick() {
    // 收敛期间被外部释放（如系统返回键置 playerDragActive = false 并清零
    // expansion）：即刻停止收敛并不再写回，避免 Dock 亮度二次闪烁。
    if (!playerDragActive.value) {
      _dragReturnSettle.stop();
      return;
    }
    final t = Curves.easeOutCubic.transform(_dragReturnSettle.value);
    playerExpansion.value = _dragReturnFrom * (1.0 - t);
  }

  /// 拖拽被系统取消（来电 / 手势竞争仲裁）：覆盖层收敛归位，状态清零。
  void _onPlayerDragCancel() {
    if (!playerDragActive.value) return;
    _dragDistance = 0.0;
    _dragVelocity = 0.0;
    _dragAcceleration = 0.0;
    // 与松手未达阈值同一口径：收敛归位而非瞬跳。
    _startDragReturn();
  }

  // ── 左右滑切歌（P1，默认开）：歌名跟手位移 + 相邻曲目预览 ──
  //
  // 手势注册在展开胶囊（开关关闭或无歌时不注册，不进手势竞技场）。
  // 拖拽期 [_switchDx] 驱动歌名区双层交叉位移/透明度（局部 ValueNotifier，
  // 不 setState 不重建 Dock）；松手按「距离 ≥ 歌名区宽一半 或
  // |primaryVelocity| ≥ _kSwipeSwitchVelocity」判定：达标 → 收敛动画滑出
  // 完整露出相邻歌名后执行切歌并归位；未达标 → 回弹归位。

  /// 拖拽开始：停掉进行中的收敛动画，从当前位置接续跟手。
  void _onCapsuleHorizontalDragStart(DragStartDetails details) {
    _switchSettle.stop();
  }

  /// 拖拽更新：位移跟手（上限 = 歌名区宽度，防止拖出胶囊视口）。
  void _onCapsuleHorizontalDragUpdate(DragUpdateDetails details) {
    if (_switchSettle.isAnimating) return;
    final max = _marqueeWidth;
    if (max <= 0) return;
    _switchDx.value = (_switchDx.value + details.delta.dx).clamp(-max, max);
  }

  /// 拖拽松手：按距离 / 速度阈值判定切歌方向，或回弹归位。
  void _onCapsuleHorizontalDragEnd(DragEndDetails details) {
    final dx = _switchDx.value;
    final velocity = details.primaryVelocity ?? 0.0;
    final width = _marqueeWidth;
    final distanceThreshold = width * 0.5;
    if (dx < 0 &&
        (-dx >= distanceThreshold || velocity < -_kSwipeSwitchVelocity)) {
      _commitTrackSwitch(-1); // 向左甩 → 下一曲
    } else if (dx > 0 &&
        (dx >= distanceThreshold || velocity > _kSwipeSwitchVelocity)) {
      _commitTrackSwitch(1); // 向右甩 → 上一曲
    } else {
      _settleSwitchTo(0);
    }
  }

  /// 拖拽被系统取消（来电 / 手势竞争仲裁）：回弹归位。
  void _onCapsuleHorizontalDragCancel() {
    _settleSwitchTo(0);
  }

  /// 切歌收敛动画：从当前位移滑到 ±歌名区宽（完整露出相邻歌名），
  /// 动画结束后执行切歌并瞬移归位（此刻当前歌名即为刚预览的那首，
  /// 视觉上无缝衔接）。切歌走 provider 既有 previous()/next()。
  void _commitTrackSwitch(int direction) {
    AppHaptics.tick();
    final player = context.read<PlayerProvider>();
    if (player.currentSong == null) {
      _settleSwitchTo(0);
      return;
    }
    _switchAnimFrom = _switchDx.value;
    _switchAnimTo = direction < 0 ? -_marqueeWidth : _marqueeWidth;
    _switchSettle.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      if (direction < 0) {
        player.next();
      } else {
        player.previous();
      }
      _switchDx.value = 0.0;
    });
  }

  /// 位移收敛到 [target]（未达阈值回弹归位 / 取消恢复）。
  void _settleSwitchTo(double target) {
    _switchAnimFrom = _switchDx.value;
    _switchAnimTo = target;
    _switchSettle.forward(from: 0);
  }

  /// 相邻方向曲目的展示名（预览层用）；无相邻曲目（列表边界）返回 null。
  /// 简化处理：不做循环播放方向的绕回预览（loop 模式下边界由 provider
  /// 既有 next()/previous() 语义决定，预览层宁缺毋假）。
  String? _neighborTrackTitle(PlayerProvider player, int offset) {
    final songs = player.playlist;
    final index = player.currentIndex;
    if (songs.isEmpty || index < 0) return null;
    final neighbor = index + offset;
    if (neighbor < 0 || neighbor >= songs.length) return null;
    return songs[neighbor].displayName;
  }

  /// 播放器圆钮：外周进度环 + 中央播放标识。
  Widget _buildCircle(
    dynamic song,
    bool isPlaying,
    Duration? duration,
    PlayerProvider player,
  ) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: song == null ? null : _expandControls,
      child: LiquidGlassContainer(
        shape: GlassShape.circle,
        child: SizedBox(
          width: _kButtonSize,
          height: _kButtonSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 进度环：只订阅 positionNotifier（~200ms），禁 context.watch。
              Positioned.fill(
                child: ValueListenableBuilder<Duration>(
                  valueListenable: player.positionNotifier,
                  builder: (context, position, _) {
                    final progress =
                        (duration != null && duration > Duration.zero)
                        ? (position.inMilliseconds / duration.inMilliseconds)
                              .clamp(0.0, 1.0)
                        : 0.0;
                    return CustomPaint(
                      size: const Size.square(_kButtonSize),
                      painter: _ProgressRingPainter(
                        progress: progress,
                        stroke: _kRingStroke,
                        // 环贴按钮外缘：环中心线 = 26 − 0.75 − 0.5 =
                        // 24.75，环外缘 25.5 < 26 不出界，环内缘 24.0
                        // 距 46dp 封面外缘 1dp（封面充满圆内）。
                        ringRadius: _kButtonSize / 2 - _kRingStroke / 2 - 0.5,
                        trackColor: cs.onSurface.withValues(alpha: 0.15),
                        progressColor: cs.primary,
                      ),
                    );
                  },
                ),
              ),
              // 中央标识：有歌→圆形封面（播放中叠律动图标；暂停叠静态
              // pause 图标，均垫略暗遮罩）；无歌→音符占位。
              if (song == null)
                Icon(
                  Icons.music_note,
                  size: 22,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                )
              else
                _buildCircleArtwork(song, isPlaying, cs),
            ],
          ),
        ),
      ),
    );
  }

  /// 圆形歌曲封面：复用 [PlayerArtworkImage]（http(s):// 走 CachedNetworkImage、
  /// content:// / local:// / file:// 走内嵌封面懒加载、null / 失败回退音符占位），
  /// 外层 [ClipOval] 裁圆。仅随 song 变化重建（封面低频，不进 positionNotifier
  /// 高频通道）。播放中叠加 [PlayingSpectrumIndicator] 律动图标；暂停时叠
  /// 静态 pause 图标（两分支均垫一层略暗圆形遮罩——用户复验：直接叠图标
  /// 在亮封面上不可读，加略暗底）。
  Widget _buildCircleArtwork(dynamic song, bool isPlaying, ColorScheme cs) {
    Widget cover = ClipOval(
      child: SizedBox(
        width: _kCircleCoverSize,
        height: _kCircleCoverSize,
        // PlayerArtworkImage 未指定 width/height 时流式布局，由 SizedBox 约束。
        child: PlayerArtworkImage(
          artworkUri: song.artworkUri as String?,
          fallbackFilePath: song.localPath as String?,
          fit: BoxFit.cover,
          iconSize: 20,
          backgroundColor: cs.surfaceContainerHighest,
          iconColor: cs.onSurfaceVariant,
          // 46dp 圆钮按 128px 解码，避免全尺寸封面（RGBA 4MB+）解码浪费
          decodeCap: 128,
        ),
      ),
    );
    if (isPlaying) {
      // 播放中：封面 → 略暗遮罩 + 律动图标。用户复验：直接叠图标在亮
      // 封面上不可读，加略暗底（比此前 45% surface 更暗且中性）保证
      // 图标可读。PlayingSpectrumIndicator 挂 PlayerFrameDriver 共享
      // 60fps 节拍、ValueNotifier 驱动 painter 重绘（不 setState）、仅
      // 播放中运行，功耗合规。
      cover = Stack(
        alignment: Alignment.center,
        children: [
          cover,
          Container(
            width: _kCircleCoverSize,
            height: _kCircleCoverSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 略暗遮罩：亮色封面上保证图标可读；比此前 45% surface
              // 更暗且中性。
              color: Colors.black.withValues(alpha: 0.28),
            ),
            child: PlayingSpectrumIndicator(
              color: cs.primary,
              size: 14,
              isPlaying: true,
            ),
          ),
        ],
      );
    } else {
      // 暂停：封面 → 略暗遮罩 + 静态 pause 图标（用户复验：直接叠图标
      // 在亮封面上不可读，加略暗底，与播放中分支一致）。
      cover = Stack(
        alignment: Alignment.center,
        children: [
          cover,
          Container(
            width: _kCircleCoverSize,
            height: _kCircleCoverSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 略暗遮罩：亮色封面上保证图标可读；比此前 45% surface
              // 更暗且中性。
              color: Colors.black.withValues(alpha: 0.28),
            ),
            child: Icon(Icons.pause, size: 16, color: cs.primary),
          ),
        ],
      );
    }
    return cover;
  }

  /// 展开态控制小胶囊：圆形封面缩略图（外周进度环，与坍缩球同一 painter）
  /// + 歌名 marquee + 上一曲 / 播放暂停 / 下一曲。
  /// 封面与歌名点击均进入完整播放页（原「向上按钮」职责由二者承担）。
  Widget _buildControlsCapsule(
    PlayerProvider player,
    dynamic song,
    Duration? duration,
  ) {
    final cs = Theme.of(context).colorScheme;
    // 左右滑切歌（P1）：开关关闭或无歌时不注册 onHorizontalDrag*，
    // 不进手势竞技场（默认开，见 SettingsRepository.dockSwipeToSwitchTrack）。
    final swipeEnabled =
        SettingsRepository.dockSwipeToSwitchTrack.value && song != null;
    // 语义收紧（用户反馈「未点中悬浮导航条的触摸也误触导致播放器坍缩」）：
    // 胶囊自身**不**响应 tap 收起——原 onTap: _toggleControls 已移除。
    // 根因：玻璃叠色层（[LiquidGlassSurface] 内 Positioned.fill 的
    // ColoredBox）以 HitTestBehavior.opaque 命中，整个胶囊矩形（含
    // padding / 边缘）均可点，点背景即触发收起。收紧后播放器工具的收起
    // 只由「点坍缩导航圆 / 切 tab → 导航展开 → [_onNavExpandedChanged]
    // 强制收起」驱动（见类文档）；封面 / 歌名点击进播放页、三个控制钮、
    // 左右滑切歌（下方 onHorizontalDrag*，开关关闭或无歌时不注册）均不变。
    return GestureDetector(
      onHorizontalDragStart: swipeEnabled
          ? _onCapsuleHorizontalDragStart
          : null,
      onHorizontalDragUpdate: swipeEnabled
          ? _onCapsuleHorizontalDragUpdate
          : null,
      onHorizontalDragEnd: swipeEnabled ? _onCapsuleHorizontalDragEnd : null,
      onHorizontalDragCancel: swipeEnabled
          ? _onCapsuleHorizontalDragCancel
          : null,
      child: LiquidGlassContainer(
        shape: GlassShape.pill,
        padding: const EdgeInsets.fromLTRB(6, 0, 4, 0),
        child: SizedBox(
          height: _kButtonSize,
          // 宽度防御：歌名 marquee 区随可用宽度压缩（上限 120，下限 0），
          // 固定区 = 水平 padding(10) + 封面含环(36 + 2×1.5) + 间距(8)
          // + 3 个按钮(120)，保证小屏（含 320dp）下胶囊自身也不超宽。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fixedWidth =
                  _kControlsButtonsWidth +
                  _kCapsuleCoverSize +
                  _kRingStroke * 2 +
                  _kCapsuleCoverGap +
                  10; // 水平 padding（6 + 4）
              final marqueeWidth = (constraints.maxWidth - fixedWidth).clamp(
                0.0,
                120.0,
              );
              _marqueeWidth = marqueeWidth;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 圆形封面缩略图：点击进入播放页。外周进度环只订阅
                  // positionNotifier（~200ms），禁 context.watch。
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: song == null ? null : () => openFullPlayer(context),
                    child: SizedBox(
                      width: _kCapsuleCoverSize + _kRingStroke * 2,
                      height: _kCapsuleCoverSize + _kRingStroke * 2,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // 进度环：与坍缩球同一 painter，紧贴 36dp 封面外缘。
                          Positioned.fill(
                            child: ValueListenableBuilder<Duration>(
                              valueListenable: player.positionNotifier,
                              builder: (context, position, _) {
                                final progress =
                                    (duration != null &&
                                        duration > Duration.zero)
                                    ? (position.inMilliseconds /
                                              duration.inMilliseconds)
                                          .clamp(0.0, 1.0)
                                    : 0.0;
                                return CustomPaint(
                                  size: Size.square(
                                    _kCapsuleCoverSize + _kRingStroke * 2,
                                  ),
                                  painter: _ProgressRingPainter(
                                    progress: progress,
                                    stroke: _kRingStroke,
                                    // 环中心线 = 18 + 0.75 = 18.75：
                                    // 环内缘 18 恰贴 36dp 封面外缘（无间隙）。
                                    ringRadius:
                                        _kCapsuleCoverSize / 2 +
                                        _kRingStroke / 2,
                                    trackColor: cs.onSurface.withValues(
                                      alpha: 0.15,
                                    ),
                                    progressColor: cs.primary,
                                  ),
                                );
                              },
                            ),
                          ),
                          ClipOval(
                            child: SizedBox(
                              width: _kCapsuleCoverSize,
                              height: _kCapsuleCoverSize,
                              child: PlayerArtworkImage(
                                artworkUri: song?.artworkUri as String?,
                                fallbackFilePath: song?.localPath as String?,
                                fit: BoxFit.cover,
                                iconSize: 16,
                                backgroundColor: cs.surfaceContainerHighest,
                                iconColor: cs.onSurfaceVariant,
                                // 36dp 胶囊缩略图按 128px 解码
                                decodeCap: 128,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: _kCapsuleCoverGap),
                  // 歌名 marquee：点击打开播放页；左右滑跟手位移并露出
                  // 相邻方向歌名预览（双层交叉位移/透明度，局部
                  // ValueListenableBuilder 驱动，不重建整个 Dock）。
                  GestureDetector(
                    key: const ValueKey('glass_dock_track_title'),
                    behavior: HitTestBehavior.opaque,
                    onTap: song == null ? null : () => openFullPlayer(context),
                    child: ClipRect(
                      child: SizedBox(
                        width: marqueeWidth,
                        child: ValueListenableBuilder<double>(
                          valueListenable: _switchDx,
                          builder: (context, dx, _) {
                            final titleStyle = Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: song == null
                                      ? cs.onSurfaceVariant
                                      : cs.onSurface,
                                );
                            final current = _MarqueeText(
                              text: song?.displayName ?? '未在播放',
                              style: titleStyle,
                              width: marqueeWidth,
                              playing: player.isPlaying,
                            );
                            // 未拖拽 / 无可用宽度：仅当前歌名（零开销路径）。
                            if (dx == 0 || marqueeWidth <= 0) return current;
                            final progress = (dx.abs() / marqueeWidth).clamp(
                              0.0,
                              1.0,
                            );
                            final toNext = dx < 0;
                            final incomingText = _neighborTrackTitle(
                              player,
                              toNext ? 1 : -1,
                            );
                            return Stack(
                              children: [
                                // 当前歌名：跟手位移 + 随进度淡出。
                                Opacity(
                                  opacity: 1.0 - progress,
                                  child: Transform.translate(
                                    offset: Offset(dx, 0),
                                    child: current,
                                  ),
                                ),
                                // 相邻方向歌名：从拖拽方向对侧滑入 + 淡入。
                                if (incomingText != null)
                                  Opacity(
                                    opacity: progress,
                                    child: Transform.translate(
                                      offset: Offset(
                                        toNext
                                            ? dx + marqueeWidth
                                            : dx - marqueeWidth,
                                        0,
                                      ),
                                      child: SizedBox(
                                        width: marqueeWidth,
                                        child: Text(
                                          incomingText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          softWrap: false,
                                          style: titleStyle,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  _DockIconButton(
                    icon: Icons.skip_previous,
                    tooltip: '上一曲',
                    onTap: song == null ? null : player.previous,
                  ),
                  _DockIconButton(
                    icon: player.isPlaying ? Icons.pause : Icons.play_arrow,
                    tooltip: player.isPlaying ? '暂停' : '播放',
                    onTap: song == null
                        ? null
                        : () => player.isPlaying
                              ? player.pause()
                              : player.resume(),
                  ),
                  _DockIconButton(
                    icon: Icons.skip_next,
                    tooltip: '下一曲',
                    onTap: song == null ? null : player.next,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Dock 导航项：icon-only（label 仅用于无障碍朗读），激活时 filled 图标 +
/// secondaryContainer 圆形底（AnimatedContainer 收敛动画）。
/// [width] 随可见 tab 数自适应（见 `_buildNavPill` 的溢出复核）。
class _DockNavItem extends StatelessWidget {
  const _DockNavItem({
    required this.tab,
    required this.label,
    required this.selected,
    required this.width,
    required this.onTap,
  });

  final _DockTab tab;
  final String label;
  final bool selected;

  /// 图标块宽度（dp），左右各另有 1dp 外边距。
  final double width;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: width,
          height: 44,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: selected
              ? ShapeDecoration(
                  color: cs.secondaryContainer,
                  shape: const StadiumBorder(),
                )
              : null,
          child: Icon(
            selected ? tab.filled : tab.outlined,
            size: 22,
            color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Dock 内的紧凑图标按钮。
class _DockIconButton extends StatelessWidget {
  const _DockIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      icon: Icon(icon, size: 22, color: cs.onSurface),
      onPressed: onTap,
    );
  }
}

/// 进度环绘制器：细轨道整环 + 主色进度弧（从 12 点方向起）。
///
/// [ringRadius] 由调用方按布局计算：展开胶囊 = 封面半径 + [stroke] / 2
/// （环内缘贴封面外缘）；坍缩球 = 按钮半径 − [stroke] / 2 − 0.5
/// （环贴按钮外缘，封面充满圆内）。
class _ProgressRingPainter extends CustomPainter {
  _ProgressRingPainter({
    required this.progress,
    required this.stroke,
    required this.ringRadius,
    required this.trackColor,
    required this.progressColor,
  });

  final double progress;

  /// 环线宽。
  final double stroke;

  /// 环中心线半径（由调用方按布局计算，见类注释）。
  final double ringRadius;
  final Color trackColor;
  final Color progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: ringRadius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = trackColor;
    canvas.drawCircle(center, ringRadius, trackPaint);

    if (progress > 0) {
      final progressPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = progressColor;
      canvas.drawArc(
        rect,
        -3.1415926535897932 / 2,
        2 * 3.1415926535897932 * progress,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ProgressRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.stroke != stroke ||
        oldDelegate.ringRadius != ringRadius ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.progressColor != progressColor;
  }
}

/// 单行跑马灯文字：溢出且播放中时经共享 60fps 节拍
///（[PlayerFrameDriver]，与频谱/歌词同源，整页保持 60fps）缓慢滚动；
/// 未溢出 / 暂停时静态显示（保留当前偏移）。
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    required this.width,
    this.playing = true,
  });

  final String text;
  final TextStyle? style;

  /// 视口宽度（dp）。
  final double width;

  /// 仅播放中滚动；暂停时停在当前位置。
  final bool playing;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> {
  /// 滚动偏移（px），ValueNotifier 驱动 Transform.translate，不 setState。
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  /// 两份文本之间的间隔（px）。
  static const double _gap = 32;

  /// 滚动速度（px/s）。
  static const double _speed = 24;

  /// 是否已挂到共享 60fps 节拍上。
  bool _boundToDriver = false;

  /// 文本像素宽（build 时测量，供滚动循环计算）。
  double _textWidth = 0;

  @override
  void dispose() {
    _unbindDriver();
    _offset.dispose();
    super.dispose();
  }

  void _bindDriver() {
    if (_boundToDriver) return;
    PlayerFrameDriver.instance.addListener(_onSharedTick);
    _boundToDriver = true;
  }

  void _unbindDriver() {
    if (!_boundToDriver) return;
    PlayerFrameDriver.instance.removeListener(_onSharedTick);
    _boundToDriver = false;
  }

  /// 共享节拍回调：步进偏移，超出「文本宽 + 间隔」后回卷（无缝循环）。
  void _onSharedTick() {
    final total = _textWidth + _gap;
    if (total <= 0) return;
    _offset.value =
        (_offset.value + PlayerFrameDriver.step.inMicroseconds / 1e6 * _speed) %
        total;
  }

  @override
  Widget build(BuildContext context) {
    // 测量文本宽度判断是否溢出（dock 低频 rebuild，TextPainter 开销可忽略）。
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textWidth = tp.width;

    final overflow = _textWidth > widget.width;
    // 滚动条件：溢出且播放中；否则解绑（偏移保留/归零）。
    if (overflow && widget.playing) {
      _bindDriver();
    } else {
      _unbindDriver();
      if (!widget.playing && _offset.value != 0) _offset.value = 0;
    }

    final body = overflow
        ? ClipRect(
            child: SizedBox(
              width: widget.width,
              child: ValueListenableBuilder<double>(
                valueListenable: _offset,
                builder: (context, offset, _) => Transform.translate(
                  offset: Offset(-offset, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.text,
                        maxLines: 1,
                        style: widget.style,
                        overflow: TextOverflow.visible,
                        softWrap: false,
                      ),
                      SizedBox(width: _gap),
                      Text(
                        widget.text,
                        maxLines: 1,
                        style: widget.style,
                        overflow: TextOverflow.visible,
                        softWrap: false,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        : SizedBox(
            width: widget.width,
            child: Text(
              widget.text,
              maxLines: 1,
              style: widget.style,
              overflow: TextOverflow.ellipsis,
            ),
          );

    return body;
  }
}
