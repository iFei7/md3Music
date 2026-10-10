import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/services/player_frame_driver.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/widgets/liquid_glass_container.dart';
import '../../providers/car_mode_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/tab_config_provider.dart';
import '../../widgets/playing_spectrum_indicator.dart';
import 'full_player_route.dart';

/// Dock 导航项定义（lite 版固定三项：主页 / 收藏 / 我的）。
class _DockTab {
  final String id;
  final IconData outlined;
  final IconData filled;
  final String fallbackLabel;

  const _DockTab(this.id, this.outlined, this.filled, this.fallbackLabel);
}

const List<_DockTab> _kDockTabs = [
  _DockTab('discover', Icons.home_outlined, Icons.home, '主页'),
  _DockTab('favorites', Icons.favorite_outline, Icons.favorite, '收藏'),
  _DockTab('user', Icons.person_outlined, Icons.person, '我的'),
];

/// 底部悬浮玻璃 Dock：导航胶囊 + 常驻播放器圆钮。
///
/// 状态机（全部收敛型动画，无 repeat 连续动画）：
/// - **导航**：展开（玻璃胶囊三导航项）↔ 坍缩（单个 home 玻璃圆）。
///   展开态由外部（`_MainLayout`）持有并通过 [navExpanded] 注入——
///   页面滚动超过滞回阈值坍缩、切 tab / 点坍缩圆展开；
/// - **播放器圆钮**：点击在「圆钮 ↔ 控制小胶囊」间收敛形变（AnimatedSize）；
///   圆钮外周进度环订阅 [PlayerProvider.positionNotifier]（~200ms 高频通道，
///   禁 context.watch），中央为播放标识（PlayingSpectrumIndicator / 暂停图标 /
///   无歌音符）；整钮 [RepaintBoundary] 隔离高频重绘；
/// - **隐藏**：完整播放页展开（playerExpansion > 0.5）或车机模式时整体移除，
///   不产帧。
///
/// 宽屏（NavigationRail 布局）传 [playerOnly] = true：只渲染播放器圆钮，
/// 浮于右下，导航交给侧栏。
class GlassDockPlayer extends StatefulWidget {
  const GlassDockPlayer({
    super.key,
    required this.selectedTabId,
    required this.onSelectTab,
    required this.navExpanded,
    required this.onNavExpandedChanged,
    this.playerOnly = false,
  });

  /// 当前选中的 tab id（discover / favorites / user 等）。
  final String selectedTabId;

  /// 点击导航项回调（tabId）。
  final ValueChanged<String> onSelectTab;

  /// 导航展开态（由 _MainLayout 持有的 ValueNotifier，滚动滞回驱动）。
  final ValueListenable<bool> navExpanded;

  /// 用户点击坍缩态 home 圆请求展开导航。
  final ValueChanged<bool> onNavExpandedChanged;

  /// 宽屏模式：只渲染播放器圆钮（浮于右下）。
  final bool playerOnly;

  @override
  State<GlassDockPlayer> createState() => _GlassDockPlayerState();
}

class _GlassDockPlayerState extends State<GlassDockPlayer> {
  /// 播放器圆钮 → 控制小胶囊的展开态（收敛型 AnimatedSize 驱动）。
  bool _controlsExpanded = false;

  static const double _kButtonSize = 52.0;
  static const Duration _kMorphDuration = Duration(milliseconds: 260);

  /// 展开态控制胶囊内 4 个紧凑 IconButton 的总宽（40dp/个），
  /// 用于小屏下计算歌名 marquee 的可压缩宽度。
  static const double _kControlsButtonsWidth = 160.0;

  @override
  void initState() {
    super.initState();
    // 状态联动：导航展开 ⇒ 播放器工具强制收起（两个展开态不得同时存在，
    // 否则总宽超出屏宽）。收起播放器工具后导航保持坍缩，由滚动 /
    // 手势 / 切 tab 自然恢复，避免乒乓。
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

  void _onNavExpandedChanged() {
    if (widget.navExpanded.value && _controlsExpanded) {
      setState(() => _controlsExpanded = false);
    }
  }

  void _toggleControls() {
    AppHaptics.click();
    setState(() => _controlsExpanded = !_controlsExpanded);
    // 播放器工具展开时请求导航坍缩（_MainLayout 侧置 _navExpanded = false）。
    if (_controlsExpanded) widget.onNavExpandedChanged(false);
  }

  @override
  Widget build(BuildContext context) {
    // 车机模式：播放器常驻侧边面板，任何界面都不显示 Dock（沿用既有规则）。
    if (context.watch<CarModeProvider>().enabled) {
      return const SizedBox.shrink();
    }

    final player = context.watch<PlayerProvider>();
    final song = player.currentSong;
    final isPlaying = player.isPlaying;
    final duration = player.duration;

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
        child: widget.playerOnly
            ? Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 16, 16),
                  child: _buildPlayerButton(player, song, isPlaying, duration),
                ),
              )
            : Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  // 宽度防御：播放器按钮用 Flexible（loose）吃剩余宽度，
                  // 极限屏宽下歌名区先压缩，整体任何状态不超屏宽。
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildNavPart(),
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

  Widget _buildNavPart() {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.navExpanded,
      builder: (context, expanded, _) => AnimatedSize(
        duration: _kMorphDuration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.centerRight,
        child: expanded ? _buildNavPill() : _buildNavCollapsed(),
      ),
    );
  }

  /// 展开态：玻璃胶囊内的导航项。
  Widget _buildNavPill() {
    final tabConfig = context.read<TabConfigProvider>();
    return LiquidGlassContainer(
      shape: GlassShape.pill,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tab in _kDockTabs)
            _DockNavItem(
              tab: tab,
              label: tabConfig
                      .allTabs
                      .where((t) => t.id == tab.id)
                      .firstOrNull
                      ?.label ??
                  tab.fallbackLabel,
              selected: widget.selectedTabId == tab.id,
              onTap: () {
                AppHaptics.tick();
                widget.onSelectTab(tab.id);
              },
            ),
        ],
      ),
    );
  }

  /// 坍缩态：单个 home 玻璃圆（点击展开导航）。
  Widget _buildNavCollapsed() {
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
            widget.selectedTabId == 'discover' ? Icons.home : Icons.home_outlined,
            size: 24,
            color: widget.selectedTabId == 'discover'
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
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
        alignment: Alignment.centerLeft,
        child: _controlsExpanded
            ? _buildControlsCapsule(player, song)
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
                        trackColor: cs.onSurface.withValues(alpha: 0.15),
                        progressColor: cs.primary,
                      ),
                    );
                  },
                ),
              ),
              // 中央标识：播放中→频谱；暂停→pause；无歌→音符。
              if (song == null)
                Icon(
                  Icons.music_note,
                  size: 22,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                )
              else if (isPlaying)
                PlayingSpectrumIndicator(color: cs.primary, size: 18)
              else
                Icon(Icons.pause, size: 22, color: cs.primary),
            ],
          ),
        ),
      ),
    );
  }

  /// 展开态控制小胶囊：歌名 marquee + 上一曲 / 播放暂停 / 下一曲 / 展开播放页。
  Widget _buildControlsCapsule(PlayerProvider player, dynamic song) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _toggleControls,
      child: LiquidGlassContainer(
        shape: GlassShape.pill,
        padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
        child: SizedBox(
          height: _kButtonSize,
          // 宽度防御：歌名 marquee 区随可用宽度压缩（上限 120，下限 0），
          // 4 个按钮区固定，保证小屏（含 320dp）下胶囊自身也不超宽。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final marqueeWidth = (constraints.maxWidth - _kControlsButtonsWidth)
                  .clamp(0.0, 120.0);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                  _DockIconButton(
                    icon: Icons.keyboard_arrow_up,
                    tooltip: '展开播放页',
                    onTap: song == null ? null : () => openFullPlayer(context),
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

/// Dock 导航项：激活时 filled 图标 + secondaryContainer 圆形底
///（AnimatedContainer 收敛动画）。
class _DockNavItem extends StatelessWidget {
  const _DockNavItem({
    required this.tab,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final _DockTab tab;
  final String label;
  final bool selected;
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
          width: 44,
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
class _ProgressRingPainter extends CustomPainter {
  _ProgressRingPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - stroke / 2 - 1;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = trackColor;
    canvas.drawCircle(center, radius, trackPaint);

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
