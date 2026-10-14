import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';

/// iOS 大标题折叠骨架（sonify `Title.kt` 的 Flutter 等价物，方案 §1.4/§0.3）。
///
/// 结构约定（与 sonify 一级页骨架同构，Title.kt:402-466）：
/// - 列表首 item = 状态栏占位 + 大标题（[SonifyTextStyles.largeTitle]
///   35sp Bold，水平边距 20dp，距顶 8dp）；
/// - 顶栏悬浮叠加在列表之上：背景玻璃（回退磨砂档：blur 14dp + 页面色 α0.7，
///   Title.kt:976-977）随滚动 120ms 淡入出（Title.kt:952-953）；
/// - 大标题随滚动**在顶栏玻璃下溶解**：透明度 = `1 + offset/height × 1.8`
///   clamp 0~1（Title.kt:588-589）；完全没入（alpha ≤ 0）后小标题
///   （[SonifyTextStyles.barTitle] 18.5sp Bold）才浮现——两个标题从不同时可见
///   （Title.kt:640-653）；
/// - 松手停在过渡区（既没完全展开也没完全收起）时 180ms EaseOutCubic
///   吸附到更近的端点（Title.kt:745-788）：折叠比例 < 0.5 弹回展开，
///   否则收起；评估前等待 50ms 稳定检测（跳过惯性尾巴），手指按住时暂停。
///
/// **批次 0 仅交付组件本体**，不接线到任何页面（接线在批次 1/2/3）。
class SonifyTitleScaffold extends StatefulWidget {
  const SonifyTitleScaffold({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.trailing,
    this.titleBottomPadding = 8,
  });

  /// 页面大标题文本（同时是折叠后的顶栏小标题）。
  final String title;

  /// 业务列表 item 数量（大标题 item 由本组件内部追加，不计入）。
  /// [itemBuilder] 的 index 从 0 开始对应业务 item。
  final int itemCount;

  /// 业务 item 构建器。
  final IndexedWidgetBuilder itemBuilder;

  /// 外部滚动控制器（可选）。不传时内部创建并管理生命周期；
  /// 测试与需要监听滚动位置的页面可传入共享实例。
  final ScrollController? controller;

  /// 顶栏右侧内容（如搜索玻璃圆钮），批次 1 首页接入。
  final Widget? trailing;

  /// 大标题 item 底部留白（内容区与大标题的间距）。
  final double titleBottomPadding;

  @override
  State<SonifyTitleScaffold> createState() => _SonifyTitleScaffoldState();
}

class _SonifyTitleScaffoldState extends State<SonifyTitleScaffold> {
  ScrollController? _internalController;
  ScrollController get _controller =>
      widget.controller ?? (_internalController ??= ScrollController());

  /// 大标题 item 实测高度（状态栏占位 + 标题 + 底部留白），布局后回填。
  double _titleItemHeight = 0;

  /// 大标题透明度（绘制期直接读，scroll 通知里单点更新）。
  final ValueNotifier<double> _largeTitleAlpha = ValueNotifier(1);

  /// 小标题可见性：alpha ≤ 0 才出现（Title.kt:599-605）。
  final ValueNotifier<bool> _showSmallTitle = ValueNotifier(false);

  /// 顶栏背景可见性：列表发生任何滚动即出现，回到顶部消失（Title.kt:640-653）。
  final ValueNotifier<bool> _showBarBackground = ValueNotifier(false);

  /// 50ms 稳定检测定时器（吸附评估用，Title.kt:767-779）。
  Timer? _settleDebounce;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _settleDebounce?.cancel();
    _largeTitleAlpha.dispose();
    _showSmallTitle.dispose();
    _showBarBackground.dispose();
    _internalController?.dispose();
    super.dispose();
  }

  /// 折叠几何核心（逐行对齐 Title.kt:576-593 + 726-738）。
  ///
  /// - [offset]：首 item 在视口中的偏移（未滚动时 = 0，向上滚动为负）；
  /// - [height]：首 item 高度；
  /// - [statusBarHeight]：状态栏高度（sonify 的 statusPx，用于吸附区折算）；
  /// - 吸附端点（滚动位移）：0（完全展开）或 `zone`（首 item 完全没入顶栏下缘）。
  ({
    double alpha,
    bool showSmall,
    bool showBar,
    bool inSnapZone,
    double snapTargetScroll,
  }) _computeCollapse(double offset, double height, double statusBarHeight) {
    if (height <= 0) {
      return (
        alpha: 1,
        showSmall: false,
        showBar: false,
        inSnapZone: false,
        snapTargetScroll: 0,
      );
    }
    // Title.kt:587-589：offset + height <= 0（完全滚出）→ 0；
    // 否则 (1 + offset/height × 1.8).coerceAtLeast(0)，上界 clamp 1。
    final double alpha;
    if (offset + height <= 0) {
      alpha = 0;
    } else {
      alpha =
          (1 + (offset / height) * SonifyMotion.collapseAlphaGain)
              .clamp(0.0, 1.0);
    }
    // Title.kt:602：alpha <= 0 且列表非空 → 小标题
    final showSmall = alpha <= 0;
    // Title.kt:640-653：任何滚动即出栏背景，回到顶部隐藏
    final showBar = offset < 0;
    // 吸附区（Title.kt:732-738）：raw = -offset / zone，zone = itemHeight - statusPx；
    // raw ∈ (0.005, 1) 视为停在过渡区。
    final zone = (height - statusBarHeight).clamp(1.0, double.infinity);
    final raw = -offset / zone;
    final inSnapZone = raw > 0.005 && raw < 1;
    final snapTargetScroll = raw < 0.5 ? 0.0 : zone; // 展开端 0 / 收起端 zone
    return (
      alpha: alpha,
      showSmall: showSmall,
      showBar: showBar,
      inSnapZone: inSnapZone,
      snapTargetScroll: snapTargetScroll,
    );
  }

  void _updateFromScroll() {
    if (_disposed || !_controller.hasClients) return;
    final scrollOffset = _controller.offset;
    final state = _computeCollapse(
      -scrollOffset,
      _titleItemHeight,
      MediaQuery.of(context).padding.top,
    );
    if (_largeTitleAlpha.value != state.alpha) _largeTitleAlpha.value = state.alpha;
    if (_showSmallTitle.value != state.showSmall) {
      _showSmallTitle.value = state.showSmall;
    }
    if (_showBarBackground.value != state.showBar) {
      _showBarBackground.value = state.showBar;
    }
    if (state.inSnapZone) {
      _scheduleSnapEvaluate();
    } else {
      _settleDebounce?.cancel();
    }
  }

  /// 吸附评估：offset 稳定 50ms 后（≈惯性尾巴结束）且手指未按住时，
  /// 180ms EaseOutCubic 吸附到最近端点（Title.kt:715-788）。
  void _scheduleSnapEvaluate() {
    _settleDebounce?.cancel();
    _settleDebounce = Timer(const Duration(milliseconds: 50), () {
      if (_disposed || !_controller.hasClients) return;
      // 手指仍按住（拖拽中）：抬起后新的 End 通知会再次触发评估
      if (_controller.position.isScrollingNotifier.value) return;
      final scrollOffset = _controller.offset;
      final state = _computeCollapse(
        -scrollOffset,
        _titleItemHeight,
        MediaQuery.of(context).padding.top,
      );
      if (!state.inSnapZone) return;
      _controller.animateTo(
        state.snapTargetScroll,
        duration: SonifyMotion.collapseSnap,
        curve: SonifyMotion.collapseSnapCurve,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      body: Stack(
        children: [
          // 滚动列表：顶到屏幕顶（大标题 item 自带状态栏占位）
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // 拖拽/惯性/程序滚动统一走 End + Update 两条路更新状态；
              // 吸附只由 End 驱动（50ms 稳定检测天然跳过惯性尾巴）。
              if (notification is ScrollEndNotification ||
                  notification is ScrollUpdateNotification) {
                _updateFromScroll();
              }
              return false;
            },
            child: ListView.builder(
              controller: _controller,
              itemCount: widget.itemCount + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _LargeTitleItem(
                    title: widget.title,
                    bottomPadding: widget.titleBottomPadding,
                    onHeightChanged: (h) {
                      if (h != _titleItemHeight) {
                        _titleItemHeight = h;
                        // 高度首测/变化后立即校正一次状态（等价 sonify
                        // key 重建后 derivedStateOf 重估）
                        _updateFromScroll();
                      }
                    },
                    alpha: _largeTitleAlpha,
                  );
                }
                return widget.itemBuilder(context, index - 1);
              },
            ),
          ),
          // 顶栏：玻璃背景 + 小标题 + 右侧内容，悬浮叠加
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              title: widget.title,
              showBarBackground: _showBarBackground,
              showSmallTitle: _showSmallTitle,
              statusBarHeight: media.padding.top,
              trailing: widget.trailing,
            ),
          ),
        ],
      ),
    );
  }
}

/// 大标题 item：状态栏占位 + 8dp 顶距 + 35sp Bold 标题（透明度随滚动溶解）。
///
/// 高度实测通过 [onHeightChanged] 回传（字体缩放/文本变化自适应），
/// 供吸附几何计算使用（对应 sonify `state.layoutInfo` 读首 item size）。
class _LargeTitleItem extends StatelessWidget {
  const _LargeTitleItem({
    required this.title,
    required this.bottomPadding,
    required this.onHeightChanged,
    required this.alpha,
  });

  final String title;
  final double bottomPadding;
  final ValueChanged<double> onHeightChanged;
  final ValueListenable<double> alpha;

  @override
  Widget build(BuildContext context) {
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final cs = Theme.of(context).colorScheme;
    return _MeasureSize(
      onSizeChanged: (size) => onHeightChanged(size.height),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: statusBarHeight),
          Padding(
            // 距顶 8dp / 水平边距 20dp：Title.kt:1125, 1137
            padding: const EdgeInsets.fromLTRB(
                SonifySpacing.titleMargin, 8, SonifySpacing.titleMargin, 0),
            child: ValueListenableBuilder<double>(
              valueListenable: alpha,
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: child,
              ),
              // 文本只构建一次，滚动时仅改透明度
              child: Text(
                title,
                style: SonifyTextStyles.largeTitle.copyWith(
                  color: cs.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          SizedBox(height: bottomPadding),
        ],
      ),
    );
  }
}

/// 顶栏：状态栏区域 + 54dp 栏体（Title.kt:989）。
///
/// - 背景：回退磨砂档（blur 14dp + 页面色 α0.7，Title.kt:976-977），
///   120ms 淡入出；渐进模糊（12dp→0 + 40dp 淡出尾）作为增强项后续迭代
///   （方案 §9.4 先上回退档）。
/// - 小标题：18.5sp Bold，仅大标题完全没入后浮现，120ms 淡入出。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.showBarBackground,
    required this.showSmallTitle,
    required this.statusBarHeight,
    required this.trailing,
  });

  final String title;
  final ValueListenable<bool> showBarBackground;
  final ValueListenable<bool> showSmallTitle;
  final double statusBarHeight;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: statusBarHeight + SonifySpacing.topBar,
      child: Column(
        children: [
          SizedBox(height: statusBarHeight),
          SizedBox(
            height: SonifySpacing.topBar,
            child: Stack(
              children: [
                // 栏背景玻璃（覆盖状态栏 + 54dp 栏体，模糊列表内容）
                Positioned.fill(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: showBarBackground,
                    builder: (context, visible, child) {
                      return IgnorePointer(
                        ignoring: !visible,
                        child: AnimatedOpacity(
                          opacity: visible ? 1 : 0,
                          duration: SonifyMotion.barFade,
                          child: child,
                        ),
                      );
                    },
                    child: ClipRect(
                      child: BackdropFilter(
                        // sonify 回退磨砂：blur 14dp（Title.kt:976）
                        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: ColoredBox(
                          // 页面色 α0.7（Title.kt:977）
                          color: cs.surface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
                // 小标题 + 右侧内容
                Center(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: showSmallTitle,
                    builder: (context, visible, child) {
                      return IgnorePointer(
                        ignoring: !visible,
                        child: AnimatedOpacity(
                          opacity: visible ? 1 : 0,
                          duration: SonifyMotion.barFade,
                          child: child,
                        ),
                      );
                    },
                    child: Text(
                      title,
                      style: SonifyTextStyles.barTitle.copyWith(
                        color: cs.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (trailing != null)
                  PositionedDirectional(
                    end: SonifySpacing.titleMargin,
                    top: 0,
                    bottom: 0,
                    child: Center(child: trailing!),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 子树尺寸实测（一帧延迟回传），用于大标题 item 高度自适应。
class _MeasureSize extends StatefulWidget {
  const _MeasureSize({
    required this.child,
    required this.onSizeChanged,
  });

  final Widget child;
  final ValueChanged<Size> onSizeChanged;

  @override
  State<_MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  Size? _lastSize;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = (context.findRenderObject() as RenderBox?)?.size;
      if (size != null && size != _lastSize) {
        _lastSize = size;
        widget.onSizeChanged(size);
      }
    });
    return widget.child;
  }
}
