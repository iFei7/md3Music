// 批次43：TV 播放页 Z3 呼出控制条 + 进度 seek 步进器 + 音质/快捷玻璃弹层。
//
// 设计裁决（用户口径叠加）：TV 端空间 UI 与手机端同一设计语言——半透明模糊
// 玻璃。规范里的控制条实色 #14161D 被 [LiquidGlassSurface]（fillAlpha≈0.12、
// blur σ 经 tvBlurSigma 钳制）替代：正常构建满血 σ=18，TV 构建钳到 12
// （弱 GPU 防掉帧，见 lib/core/build_flags.dart）。
//
// 按键接线（与 dpad 宿主层的分工，见上游踩坑沉淀）：
// - 控制条整体包 [DpadRegion]（memoryKey），候选只在同 scope；
// - 进度条与各按钮是 [DpadFocusable]；进度条 onDirection 消费 ←/→ 做
//   seek 步进，被消费的方向键不会到页级连发层（避免双重响应）。
import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/common/liquid_glass_surface.dart';
import '../design/tv_design.dart';

/// 进度条 seek 步进状态机（批次43）。
///
/// ←/→ 每按一次步进 [stepAmount]（默认 10s），[debounce]（600ms）内再按
/// 则重置计时并累计步数；超时后一次性 seek 落定（onCommit）。
/// OK/Select 调 [commitNow] 立即落定。落定后状态清零。
///
/// 挂在页面 State 上（不随控制条重挂载丢状态）；ChangeNotifier 供
/// 时间文本/进度显示监听 pending 值。
class TvSeekStepper extends ChangeNotifier {
  TvSeekStepper({required this.onCommit, this.stepAmount = const Duration(seconds: 10), this.debounce = const Duration(milliseconds: 600)});

  /// 落定回调：参数为最终 seek 目标（已按上下界钳制）。
  final ValueChanged<Duration> onCommit;

  /// 单次步进量。
  final Duration stepAmount;

  /// 防抖窗口。
  final Duration debounce;

  Timer? _timer;
  Duration _base = Duration.zero;
  int _steps = 0;

  /// 是否有待落定的步进（显示层据此切换 pending 时间）。
  bool get isActive => _timer != null;

  /// 当前显示位置：待落定时为 base+累计步进（钳制后），否则回退 current。
  Duration displayPosition(Duration current) {
    if (!isActive) return current;
    return _pending;
  }

  Duration get _pending {
    var target = _base + stepAmount * _steps;
    if (target < Duration.zero) target = Duration.zero;
    if (_total != null && target > _total!) target = _total!;
    return target;
  }

  Duration? _total;

  /// 步进一步：[direction] 为 -1/1；[current] 是当前播放位置（首步锚点）；
  /// [total] 为歌曲总长（上界钳制，可空）。
  void step(int direction, Duration current, {Duration? total}) {
    _total = total;
    if (!isActive) {
      _base = current;
      _steps = 0;
    }
    _steps += direction;
    _timer?.cancel();
    _timer = Timer(debounce, _commit);
    notifyListeners();
  }

  /// OK/Select：立即落定。
  void commitNow() {
    _timer?.cancel();
    _commit();
  }

  void _commit() {
    _timer = null;
    final hadSteps = _steps != 0;
    final target = _pending;
    _steps = 0;
    _base = target;
    _total = null;
    notifyListeners();
    if (hadSteps) onCommit(target);
  }

  /// 控制条隐藏等场景：丢弃 pending 步进、不落定。
  void reset() {
    _timer?.cancel();
    _timer = null;
    _steps = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Z3 呼出控制条（批次43）。
///
/// 尺寸 1728×104 设计位（Y=880，即底部安全区上沿）；玻璃背板 +
/// 左→右：当前时长 / 进度轨道（总长 1020）/ 总时长 / 功能钮组
/// （喜欢、上一首、播放暂停、下一首、循环模式、音质切换，48×48 间距 36）。
class TvControlBar extends StatelessWidget {
  const TvControlBar({
    super.key,
    required this.player,
    required this.stepper,
    required this.onUserInteraction,
    required this.brandColor,
  });

  final PlayerProvider player;
  final TvSeekStepper stepper;

  /// 任意交互（按钮/步进/焦点进出）回调：页面用它重置 3.5s 隐藏计时。
  final VoidCallback onUserInteraction;

  /// 品牌色（ThemeProvider.effectiveSeedColor 动态取，不硬编码）。
  final Color brandColor;

  @override
  Widget build(BuildContext context) {
    final scale = TvLayoutScale.of(context);
    double px(double v) => v * scale;
    final song = player.currentSong;

    return LiquidGlassSurface(
      shape: GlassShape.roundedRect,
      borderRadius: px(28),
      blurSigma: tvBlurSigma(18),
      fillAlpha: 0.12,
      padding: EdgeInsets.symmetric(horizontal: px(40)),
      child: Row(
        children: [
          // 当前时长（20 Light；步进 pending 时显示步进目标）
          _TvClock(player: player, stepper: stepper, scale: scale),
          SizedBox(width: px(28)),
          // 进度轨道（总长 1020 设计位）
          Expanded(
            child: _TvProgressBar(
              key: const ValueKey('tv43_progress'),
              player: player,
              stepper: stepper,
              scale: scale,
              brandColor: brandColor,
              onUserInteraction: onUserInteraction,
            ),
          ),
          SizedBox(width: px(28)),
          // 总时长
          Text(
            _format(song?.duration ?? Duration.zero),
            style: TvType.duration(scale),
          ),
          SizedBox(width: px(36)),
          // 功能钮组：喜欢 / 上一首 / 播放暂停 / 下一首 / 循环 / 音质
          _TvBarButtons(
            player: player,
            scale: scale,
            brandColor: brandColor,
            onUserInteraction: onUserInteraction,
          ),
        ],
      ),
    );
  }

  static String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m$s' : '$m:$s';
  }
}

/// 当前时长文本：步进 pending 时显示步进目标，否则跟随 positionNotifier。
class _TvClock extends StatelessWidget {
  const _TvClock({required this.player, required this.stepper, required this.scale});

  final PlayerProvider player;
  final TvSeekStepper stepper;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: stepper,
      builder: (context, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: player.positionNotifier,
          builder: (context, position, _) {
            final shown = stepper.displayPosition(position);
            final m = shown.inMinutes.remainder(60).toString().padLeft(2, '0');
            final s = shown.inSeconds.remainder(60).toString().padLeft(2, '0');
            return Text('$m:$s', style: TvType.duration(scale));
          },
        );
      },
    );
  }
}

/// 进度轨道：设计总长 1020、常态高 6；获焦态高 10 + 16px 品牌色圆点滑块。
/// ←/→ 经 DpadFocusable.onDirection 消费为 seek 步进（600ms debounce 落定），
/// OK 立即落定。
class _TvProgressBar extends StatelessWidget {
  const _TvProgressBar({
    super.key,
    required this.player,
    required this.stepper,
    required this.scale,
    required this.brandColor,
    required this.onUserInteraction,
  });

  final PlayerProvider player;
  final TvSeekStepper stepper;
  final double scale;
  final Color brandColor;
  final VoidCallback onUserInteraction;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: stepper,
      builder: (context, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: player.positionNotifier,
          builder: (context, position, _) {
            final song = player.currentSong;
            final total = song?.duration ?? Duration.zero;
            final shown = stepper.displayPosition(position);
            final fraction = total <= Duration.zero
                ? 0.0
                : (shown.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);
            return DpadFocusable(
              child: const SizedBox.shrink(),
              onDirection: (direction) {
                switch (direction) {
                  case TraversalDirection.left:
                    stepper.step(-1, player.positionNotifier.value, total: total);
                    onUserInteraction();
                    return true;
                  case TraversalDirection.right:
                    stepper.step(1, player.positionNotifier.value, total: total);
                    onUserInteraction();
                    return true;
                  default:
                    return false; // ↑/↓ 交还焦点层
                }
              },
              onSelect: () {
                stepper.commitNow();
                onUserInteraction();
              },
              builder: (context, state, _) {
                final focused = state.focused;
                final trackH = (focused ? 10.0 : 6.0) * scale;
                final dotD = 16.0 * scale;
                return SizedBox(
                  height: (focused ? 16.0 : 6.0) * scale,
                  child: Center(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final w = constraints.maxWidth;
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // 轨道
                            Container(
                              height: trackH,
                              decoration: BoxDecoration(
                                color: TvColors.track,
                                borderRadius: BorderRadius.circular(trackH),
                              ),
                            ),
                            // 已播进度
                            FractionallySizedBox(
                              widthFactor: fraction,
                              child: Container(
                                height: trackH,
                                decoration: BoxDecoration(
                                  color: brandColor,
                                  borderRadius: BorderRadius.circular(trackH),
                                ),
                              ),
                            ),
                            // 获焦滑块圆点
                            if (focused)
                              Positioned(
                                left:
                                    (w * fraction - dotD / 2).clamp(0.0, w - dotD),
                                top: (trackH - dotD) / 2,
                                child: Container(
                                  width: dotD,
                                  height: dotD,
                                  decoration: BoxDecoration(
                                    color: brandColor,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: brandColor.withValues(alpha: 0.4),
                                        blurRadius: 8 * scale,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// 功能钮组：喜欢 / 上一首 / 播放暂停 / 下一首 / 循环模式 / 音质切换。
class _TvBarButtons extends StatelessWidget {
  const _TvBarButtons({
    required this.player,
    required this.scale,
    required this.brandColor,
    required this.onUserInteraction,
  });

  final PlayerProvider player;
  final double scale;
  final Color brandColor;
  final VoidCallback onUserInteraction;

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final songNow = player.currentSong ?? song;
        final favorites = context.watch<LocalFavoritesProvider>();
        final liked =
            songNow != null && favorites.isFavorite(songNow.id);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TvIconButton(
              buttonKey: const ValueKey('tv43_btn_like'),
              icon: liked ? Icons.favorite : Icons.favorite_border,
              active: liked,
              scale: scale,
              brandColor: brandColor,
              enabled: songNow != null,
              onSelect: songNow == null
                  ? null
                  : () => context.read<LocalFavoritesProvider>().toggleFavorite(songNow.id),
              onUserInteraction: onUserInteraction,
            ),
            _gap(),
            _TvIconButton(
              buttonKey: const ValueKey('tv43_btn_prev'),
              icon: Icons.skip_previous,
              scale: scale,
              brandColor: brandColor,
              onSelect: () => player.previous(),
              onUserInteraction: onUserInteraction,
            ),
            _gap(),
            _TvIconButton(
              buttonKey: const ValueKey('tv43_btn_play'),
              icon: player.isPlaying ? Icons.pause : Icons.play_arrow,
              scale: scale,
              brandColor: brandColor,
              onSelect: () => player.isPlaying ? player.pause() : player.resume(),
              onUserInteraction: onUserInteraction,
            ),
            _gap(),
            _TvIconButton(
              buttonKey: const ValueKey('tv43_btn_next'),
              icon: Icons.skip_next,
              scale: scale,
              brandColor: brandColor,
              onSelect: () => player.next(),
              onUserInteraction: onUserInteraction,
            ),
            _gap(),
            _TvIconButton(
              buttonKey: const ValueKey('tv43_btn_loop'),
              icon: player.loopMode == AppLoopMode.one
                  ? Icons.repeat_one
                  : Icons.repeat,
              active: player.loopMode != AppLoopMode.off,
              scale: scale,
              brandColor: brandColor,
              onSelect: () => player.cyclePlayMode(),
              onUserInteraction: onUserInteraction,
            ),
            _gap(),
            _TvIconButton(
              buttonKey: const ValueKey('tv43_btn_quality'),
              icon: Icons.graphic_eq,
              scale: scale,
              brandColor: brandColor,
              onSelect: () => TvQualitySheet.show(
                context,
                player: player,
                onUserInteraction: onUserInteraction,
              ),
              onUserInteraction: onUserInteraction,
            ),
          ],
        );
      },
    );
  }

  Widget _gap() => SizedBox(width: 36 * scale);
}

/// 48×48 线性图标钮（design px），获焦 150ms 放大 + 品牌色。
class _TvIconButton extends StatelessWidget {
  const _TvIconButton({
    required this.buttonKey,
    required this.icon,
    required this.scale,
    required this.brandColor,
    required this.onUserInteraction,
    this.onSelect,
    this.active = false,
    this.enabled = true,
  });

  final Key buttonKey;
  final IconData icon;
  final double scale;
  final Color brandColor;
  final VoidCallback onUserInteraction;
  final VoidCallback? onSelect;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      key: buttonKey,
      child: const SizedBox.shrink(),
      enabled: enabled && onSelect != null,
      onSelect: onSelect == null
          ? null
          : () {
              onUserInteraction();
              onSelect!();
            },
      onFocusChange: (focused) {
        if (focused) onUserInteraction(); // 焦点移入也算交互，重置隐藏计时
      },
      builder: (context, state, _) {
        final focused = state.focused;
        final color = !enabled
            ? TvColors.disabled
            : (focused || active)
            ? brandColor
            : TvColors.white;
        return AnimatedScale(
          scale: focused ? 1.15 : 1.0,
          duration: TvMotion.focus,
          child: SizedBox(
            width: 48 * scale,
            height: 48 * scale,
            child: Icon(icon, size: 40 * scale, color: color),
          ),
        );
      },
    );
  }
}

/// 音质切换弹层（批次43 简化版）：玻璃面板列 AudioQuality 五档 → setAudioQuality。
class TvQualitySheet {
  TvQualitySheet._();

  static Future<void> show(
    BuildContext context, {
    required PlayerProvider player,
    required VoidCallback onUserInteraction,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => _TvGlassMenuPanel(
        title: '音质',
        onUserInteraction: onUserInteraction,
        children: [
          for (final q in AudioQuality.values)
            _TvMenuItem(
              label: q.label,
              selected: player.audioQuality == q,
              onTap: () {
                player.setAudioQuality(q);
                Navigator.of(dialogContext).pop();
              },
            ),
        ],
      ),
    );
  }
}

/// Menu 键快捷浮窗（批次43 简化版）：定时关闭（SleepTimerMode 简化列表）+
/// 息屏听歌占位项（批次44）。面板自身 3.5s 无操作也淡出。
class TvQuickMenu {
  TvQuickMenu._();

  static bool _open = false;

  static Future<void> show(
    BuildContext context, {
    required PlayerProvider player,
    required VoidCallback onUserInteraction,
  }) async {
    if (_open) return;
    _open = true;
    try {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (dialogContext) => _TvGlassMenuPanel(
          title: '快捷',
          onUserInteraction: onUserInteraction,
          children: [
            _TvMenuItem(
              label: '定时关闭 · 关闭',
              selected: player.sleepTimerMode == SleepTimerMode.off,
              onTap: () {
                player.setSleepTimer(null);
                Navigator.of(dialogContext).pop();
              },
            ),
            _TvMenuItem(
              label: '定时关闭 · 30 分钟',
              selected: player.isSleepTimerActive &&
                  player.sleepTimerMode == SleepTimerMode.countdown,
              onTap: () {
                player.setSleepTimer(const Duration(minutes: 30));
                Navigator.of(dialogContext).pop();
              },
            ),
            _TvMenuItem(
              label: '定时关闭 · 播完当前曲',
              selected: player.sleepTimerMode == SleepTimerMode.endOfTrack,
              onTap: () {
                player.setStopAfterCurrentTrack(true);
                Navigator.of(dialogContext).pop();
              },
            ),
            // 息屏听歌：占位项，批次44 接入（禁用态，dpad 导航自动跳过）
            const _TvMenuItem(label: '息屏听歌（即将推出）', selected: false, enabled: false),
          ],
        ),
      );
    } finally {
      _open = false;
    }
  }
}

/// 玻璃菜单面板：LiquidGlassSurface 背板 + 菜单项列；3.5s 无操作自动关闭。
class _TvGlassMenuPanel extends StatefulWidget {
  const _TvGlassMenuPanel({
    required this.title,
    required this.children,
    required this.onUserInteraction,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback onUserInteraction;

  @override
  State<_TvGlassMenuPanel> createState() => _TvGlassMenuPanelState();
}

class _TvGlassMenuPanelState extends State<_TvGlassMenuPanel> {
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(TvMotion.controlBarAutoHide, () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = TvLayoutScale.of(context);
    double px(double v) => v * scale;
    return Center(
      child: DpadRegion(
        onFocusChange: (inside) {
          if (inside) {
            widget.onUserInteraction();
            if (mounted) _armHide(); // 焦点移动重置面板计时
          }
        },
        child: LiquidGlassSurface(
          shape: GlassShape.roundedRect,
          borderRadius: px(24),
          blurSigma: tvBlurSigma(18),
          fillAlpha: 0.16,
          padding: EdgeInsets.symmetric(horizontal: px(32), vertical: px(24)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: TvType.sectionTitle(scale)),
              SizedBox(height: px(16)),
              ...widget.children,
            ],
          ),
        ),
      ),
    );
  }
}

/// 菜单项（design px：26 号字、行高 ~72）。
class _TvMenuItem extends StatelessWidget {
  const _TvMenuItem({
    required this.label,
    required this.selected,
    this.enabled = true,
    this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scale = TvLayoutScale.of(context);
    double px(double v) => v * scale;
    final brand = Theme.of(context).colorScheme.primary;
    return DpadFocusable(
      child: const SizedBox.shrink(),
      enabled: enabled && onTap != null,
      onSelect: onTap,
      builder: (context, state, _) {
        final focused = state.focused;
        return AnimatedContainer(
          duration: TvMotion.focus,
          width: px(360),
          padding: EdgeInsets.symmetric(horizontal: px(16), vertical: px(14)),
          decoration: BoxDecoration(
            color: focused
                ? (enabled ? brand.withValues(alpha: 0.24) : Colors.transparent)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(px(12)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: (enabled ? TvType.body(scale) : TvType.body(scale).copyWith(color: TvColors.disabled)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (selected)
                Icon(Icons.check, size: px(28), color: enabled ? brand : TvColors.disabled),
            ],
          ),
        );
      },
    );
  }
}
