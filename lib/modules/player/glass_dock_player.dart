import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/services/player_frame_driver.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/widgets/liquid_glass_container.dart';
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
  'favorites': _DockTab('favorites', Icons.favorite_outline, Icons.favorite, '收藏'),
  'library': _DockTab('library', Icons.library_music_outlined, Icons.library_music, '本地音乐'),
  'user': _DockTab('user', Icons.person_outlined, Icons.person, '我的'),
  'fm': _DockTab('fm', Icons.radio_outlined, Icons.radio, '私人FM'),
  'search': _DockTab('search', Icons.search_outlined, Icons.search, '搜索'),
  'recognition': _DockTab('recognition', Icons.mic_none_outlined, Icons.mic, '听歌识曲'),
  'audiobook': _DockTab('audiobook', Icons.auto_stories_outlined, Icons.auto_stories, '听书'),
  'settings': _DockTab('settings', Icons.settings_outlined, Icons.settings, '设置'),
};

_DockTab _dockTabFor(String id) => _kDockTabById[id] ??
    const _DockTab('unknown', Icons.circle_outlined, Icons.circle, '标签页');

/// 底部悬浮玻璃 Dock：导航胶囊 + 常驻播放器圆钮。
///
/// 状态机（全部收敛型动画，无 repeat 连续动画）：
/// - **单展开不变量**：导航与播放器工具**恰好一个展开**，仅两种合法组合：
///   [导航胶囊 + 播放器球]（默认）与 [导航球 + 播放器胶囊]。折叠状态唯一
///   驱动是用户点击，滚动不参与：
///   · 点坍缩导航圆 / 切 tab / 播放器工具收起 → 导航展开；
///   · 播放器工具展开（点播放器圆钮）→ 导航坍缩让位；
///   · 导航展开 → 播放器工具收起（listener 双向闭环，无双坍缩驻留）。
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
/// - **播放器圆钮**：点击在「圆钮 ↔ 控制小胶囊」间收敛形变（AnimatedSize）；
///   圆钮外周进度环订阅 [PlayerProvider.positionNotifier]（~200ms 高频通道，
///   禁 context.watch），中央为当前歌曲的**圆形封面缩略图**：播放中叠加
///   [PlayingSpectrumIndicator] 律动图标（挂共享 60fps 节拍、仅播放中
///   运行）；暂停时叠静态 pause 图标（均不加蒙版，图标直接叠在封面上）；
///   无歌 / 封面缺失时回退音符占位；整钮 [RepaintBoundary] 隔离高频重绘；
/// - **完整播放页往返**：openFullPlayer / close 不触碰折叠状态；关闭播放页
///   后 Dock 恢复「打开前的那个唯一展开组件」——状态只由用户点击驱动，
///   关闭后即为打开前状态，符合单展开不变量，无额外恢复路径。
/// - **布局固定**：行恒为 [导航部分, 8, 播放器(Flexible)]——左侧悬浮导航、
///   右侧悬浮播放器，位置恒定不互换；单展开不变量保证「导航胶囊 +
///   播放器球」「导航球 + 播放器胶囊」两种组合均不超宽；已移除向上按钮——
///   点封面 / 歌名进入完整播放页（胶囊内左侧含 36dp 圆形封面缩略图，
///   同源可点击）；
/// - **隐藏**：完整播放页展开（playerExpansion > 0.5）时整体移除，不产帧。
class GlassDockPlayer extends StatefulWidget {
  const GlassDockPlayer({
    super.key,
    required this.selectedTabId,
    required this.onSelectTab,
    required this.navExpanded,
    required this.onNavExpandedChanged,
  });

  /// 当前选中的 tab id（discover / favorites / user / search 等）。
  final String selectedTabId;

  /// 点击导航项回调（tabId）。
  final ValueChanged<String> onSelectTab;

  /// 导航展开态（由 _MainLayout 持有的 ValueNotifier，用户点击驱动，
  /// 滚动不参与）。
  final ValueListenable<bool> navExpanded;

  /// 请求导航展开/坍缩（双向闭环）：true = 点坍缩圆或播放器工具收起时
  /// 恢复展开；false = 播放器工具展开时请求导航让位坍缩。
  final ValueChanged<bool> onNavExpandedChanged;

  @override
  State<GlassDockPlayer> createState() => _GlassDockPlayerState();
}

class _GlassDockPlayerState extends State<GlassDockPlayer> {
  /// 播放器圆钮 → 控制小胶囊的展开态（收敛型 AnimatedSize 驱动）。
  bool _controlsExpanded = false;

  static const double _kButtonSize = 52.0;
  static const Duration _kMorphDuration = Duration(milliseconds: 260);

  /// 展开态控制胶囊内 3 个紧凑 IconButton 的总宽（40dp/个），
  /// 用于小屏下计算歌名 marquee 的可压缩宽度。
  static const double _kControlsButtonsWidth = 120.0;

  /// 坍缩圆中央的圆形封面直径（52dp 圆钮内、进度环内圈）。
  static const double _kCircleCoverSize = 40.0;

  /// 展开胶囊内左侧的圆形封面缩略图直径。
  static const double _kCapsuleCoverSize = 36.0;

  /// 进度环线宽（坍缩球与展开胶囊共用，环内缘紧贴封面外缘）。
  static const double _kRingStroke = 1.5;

  /// 展开胶囊内封面与歌名 marquee 之间的间距。
  static const double _kCapsuleCoverGap = 8.0;

  @override
  void initState() {
    super.initState();
    // 状态联动（单展开不变量的反向闭环）：导航展开 ⇒ 播放器工具强制收起。
    // 正向闭环（播放器工具展开 ⇒ 导航坍缩；收起 ⇒ 导航恢复展开）在
    // [_toggleControls] 中经 onNavExpandedChanged 回调完成。两个展开态
    // 不得同时存在，否则总宽超出屏宽。
    widget.navExpanded.addListener(_onNavExpandedChanged);
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
    super.dispose();
  }

  /// 反向闭环：导航展开 ⇒ 播放器工具强制收起（维持单展开不变量）。
  /// 两种驱动路径的命中情况：
  /// - 点播放器圆钮展开（[_toggleControls] 置 _controlsExpanded = true 后
  ///   回调 onNavExpandedChanged(false)）：_collapseNav() 使 nav 变为
  ///   false，本 listener 触发时 navExpanded.value 为 false，条件不成立，
  ///   走 no-op，播放器胶囊得以保留 ✓；
  /// - 点导航坍缩圆展开导航（onNavExpandedChanged(true)）：nav 变为 true，
  ///   若播放器胶囊仍展开则强制收起，恢复「恰好一个展开」——这是期望
  ///   行为，不可删除。
  /// 两条路径均不会反向再改导航值，故无乒乓竞态。
  void _onNavExpandedChanged() {
    if (widget.navExpanded.value && _controlsExpanded) {
      setState(() => _controlsExpanded = false);
    }
  }

  /// 播放器工具展开/收起（单展开不变量的正向驱动，双向闭环）：
  /// - 展开：先置 _controlsExpanded = true，再回调 onNavExpandedChanged(false)
  ///   请求导航坍缩让位；
  /// - 收起：先置 _controlsExpanded = false，再回调 onNavExpandedChanged(true)
  ///   请求导航恢复展开。时序保证：回调触发 _onNavExpandedChanged 时
  ///   _controlsExpanded 已为 false，命中 no-op 分支，不会反向收起导航，
  ///   无乒乓竞态。
  void _toggleControls() {
    AppHaptics.click();
    final next = !_controlsExpanded;
    setState(() => _controlsExpanded = next);
    // 回调语义是「导航是否展开」，与播放器自身状态相反：
    // 播放器展开 → 导航让位坍缩；播放器收起 → 导航恢复展开。
    widget.onNavExpandedChanged(!next);
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
    return ValueListenableBuilder<double>(
      valueListenable: playerExpansion,
      builder: (context, exp, child) {
        if (exp > 0.5) return const SizedBox.shrink();
        return IgnorePointer(
          ignoring: exp > 0.2,
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
                _buildNavPart(tabConfig),
                const SizedBox(width: 8),
                Flexible(
                  child: _buildPlayerButton(
                    player,
                    song,
                    isPlaying,
                    duration,
                  ),
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
      onTap: song == null ? null : _toggleControls,
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
                        // 环中心线 = 20 + 0.75 = 20.75：环内缘 20 恰贴
                        // 40dp 封面外缘（无间隙）。
                        ringRadius:
                            _kCircleCoverSize / 2 + _kRingStroke / 2,
                        trackColor: cs.onSurface.withValues(alpha: 0.15),
                        progressColor: cs.primary,
                      ),
                    );
                  },
                ),
              ),
              // 中央标识：有歌→圆形封面（播放中叠律动图标；暂停叠静态
              // pause 图标，均不加蒙版）；无歌→音符占位。
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
  /// 静态 pause 图标（均不加蒙版，图标直接叠在封面上）。
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
          // 40dp 圆钮按 128px 解码，避免全尺寸封面（RGBA 4MB+）解码浪费
          decodeCap: 128,
        ),
      ),
    );
    if (isPlaying) {
      // 播放中：封面 + 律动图标（不加蒙版——用户反馈半透明底像一层白色
      // 蒙版、遮挡封面，去掉后图标直接叠在封面上）。PlayingSpectrumIndicator
      // 挂 PlayerFrameDriver 共享 60fps 节拍、ValueNotifier 驱动 painter
      // 重绘（不 setState）、仅播放中运行，功耗合规。
      cover = Stack(
        alignment: Alignment.center,
        children: [
          cover,
          SizedBox(
            width: _kCircleCoverSize,
            height: _kCircleCoverSize,
            child: Center(
              child: PlayingSpectrumIndicator(
                color: cs.primary,
                size: 14,
                isPlaying: true,
              ),
            ),
          ),
        ],
      );
    } else {
      // 暂停：封面 + 静态 pause 图标（不加蒙版——与播放中一致，
      // 用户反馈半透明底像白色蒙版遮挡封面）。
      cover = Stack(
        alignment: Alignment.center,
        children: [
          cover,
          SizedBox(
            width: _kCircleCoverSize,
            height: _kCircleCoverSize,
            child: Center(
              child: Icon(Icons.pause, size: 16, color: cs.primary),
            ),
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
    return GestureDetector(
      onTap: _toggleControls,
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
              final fixedWidth = _kControlsButtonsWidth +
                  _kCapsuleCoverSize +
                  _kRingStroke * 2 +
                  _kCapsuleCoverGap +
                  10; // 水平 padding（6 + 4）
              final marqueeWidth =
                  (constraints.maxWidth - fixedWidth).clamp(0.0, 120.0);
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
                                    ringRadius: _kCapsuleCoverSize / 2 +
                                        _kRingStroke / 2,
                                    trackColor:
                                        cs.onSurface.withValues(alpha: 0.15),
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
                  // 歌名 marquee：点击打开播放页。
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: song == null ? null : () => openFullPlayer(context),
                    child: _MarqueeText(
                      text: song?.displayName ?? '未在播放',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: song == null ? cs.onSurfaceVariant : cs.onSurface,
                      ),
                      width: marqueeWidth,
                      playing: player.isPlaying,
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
              ? ShapeDecoration(color: cs.secondaryContainer, shape: const StadiumBorder())
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
/// [ringRadius] 由调用方计算：封面半径 + [stroke] / 2，
/// 使环内缘恰好紧贴封面外缘（无间隙）。
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

  /// 环中心线半径（封面半径 + stroke/2 → 环内缘贴封面外缘）。
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
      canvas.drawArc(rect, -3.1415926535897932 / 2, 2 * 3.1415926535897932 * progress, false, progressPaint);
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
