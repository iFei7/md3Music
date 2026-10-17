import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';

/// iOS 大标题骨架（sonify `Title.kt` 的 Flutter 等价物，方案 §1.4/§0.3）。
///
/// 结构约定（与 sonify 一级页骨架同构，Title.kt:402-466）：
/// - 列表首 item = 状态栏占位 + 大标题占位（[SonifyTextStyles.largeTitle]
///   20sp Bold、行高 36dp——与右上角 36dp 用户头像等高；水平边距
///   20dp，距顶 8dp）+ 底部留白；
/// - **大标题固定悬浮**（[_PinnedLargeTitle]）：位置 = 状态栏 + 8dp 起、
///   水平 20dp，滚动过程中**不位移、不缩放、不溶解**（用户反馈①：
///   "上滑时标题位置会变，不想要"）。列表首项只保留同尺寸占位
///  （[_TitlePlaceholderItem]，含高度实测），业务内容从标题下方滚过；
/// - 顶栏悬浮叠加在列表之上：背景为**单层渐变模糊带**（材质对齐
///   `LiquidGlassSurface` dock 配方：blur 18dp + cs.surface 系叠色——
///   状态栏区域全强度 [kSonifyBarTopAlpha]，自状态栏下缘起线性淡出至
///   带底缘严格 α0）随滚动 120ms 淡入出（Title.kt:952-953），
///   保证滚过内容时固定标题仍清晰可读；
/// - 顶栏右侧内容（如固定用户头像）**常驻渲染**；[actions] 动作钮随
///   栏体 120ms 淡入（滚动即出现，展开态隐藏不挡内容）。
///
/// **去掉的机制**（批次 8 起）：大标题随滚动折叠为小标题（位置/尺寸
/// 变化）及 180ms 端点吸附——与"标题位置固定"的诉求直接冲突，且小标题
/// 与固定大标题同时可见会造成双标题，故整条折叠链路移除；短内容页的
/// minHeight 兜底保留（保证可滚动/下拉刷新，见 [_titleZone]）。
class SonifyTitleScaffold extends StatefulWidget {
  const SonifyTitleScaffold({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.trailing,
    this.actions,
    this.titleBottomPadding = 8,
  });

  /// 页面大标题文本（固定悬浮，不折叠）。
  final String title;

  /// 业务列表 item 数量（大标题占位 item 由本组件内部追加，不计入）。
  /// [itemBuilder] 的 index 从 0 开始对应业务 item。
  final int itemCount;

  /// 业务 item 构建器。
  final IndexedWidgetBuilder itemBuilder;

  /// 外部滚动控制器（可选）。不传时内部创建并管理生命周期；
  /// 测试与需要监听滚动位置的页面可传入共享实例。
  final ScrollController? controller;

  /// 顶栏右侧内容（如固定用户头像），批次 1 首页接入。
  /// **常驻渲染**，不随滚动淡入出。
  final Widget? trailing;

  /// [trailing] 左侧的动作按钮组（如搜索/识曲圆钮）。
  /// 仅在滚动后（栏体浮现时）随栏体 120ms 淡入，展开态隐藏（不挡内容）。
  final List<Widget>? actions;

  /// 大标题 item 底部留白（内容区与大标题的间距）。
  final double titleBottomPadding;

  @override
  State<SonifyTitleScaffold> createState() => _SonifyTitleScaffoldState();
}

class _SonifyTitleScaffoldState extends State<SonifyTitleScaffold> {
  ScrollController? _internalController;
  ScrollController get _controller =>
      widget.controller ?? (_internalController ??= ScrollController());

  /// 大标题占位 item 实测高度（状态栏占位 + 标题 + 底部留白），布局后回填。
  double _titleItemHeight = 0;

  /// 顶栏背景（渐变带组）可见性：列表发生任何滚动即出现，回到顶部消失
  /// （Title.kt:640-653）。
  final ValueNotifier<bool> _showBarBackground = ValueNotifier(false);

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _showBarBackground.dispose();
    _internalController?.dispose();
    super.dispose();
  }

  void _updateFromScroll() {
    if (_disposed || !_controller.hasClients) return;
    // 任何滚动（offset > 0）即出栏背景，回到顶部隐藏
    final showBar = _controller.offset > 0;
    if (_showBarBackground.value != showBar) {
      _showBarBackground.value = showBar;
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      body: Stack(
        children: [
          // 滚动列表：顶到屏幕顶（首项为大标题占位，自带状态栏占位）
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // 拖拽/惯性/程序滚动统一走 End + Update 两条路更新状态
              if (notification is ScrollEndNotification ||
                  notification is ScrollUpdateNotification) {
                _updateFromScroll();
              }
              return false;
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomScrollView(
                  controller: _controller,
                  // 内容不足一屏时也必须能拖拽（配合下方 minHeight 兜底）：
                  // 否则冷启动/分区未就绪时整页 maxScrollExtent == 0，
                  // 上滑零位移（下拉刷新/回弹随之失效）。
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: ConstrainedBox(
                        // 内容不足一屏时把列表撑到「视口 + 标题区」：
                        // 保证 maxScrollExtent > 0，短内容页也能拖拽
                        // （对齐 iOS 大标题在短内容页的可滚行为）。
                        // 内容超过该高度时 minHeight 不生效（无额外留白）。
                        constraints: BoxConstraints(
                          minHeight:
                              constraints.maxHeight + _titleZone(media),
                        ),
                        // stretch 对齐 ListView 的整宽 item 语义（子项缺省
                        // 会收缩到内在宽度，导致搜索框/分区塌缩）。
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _TitlePlaceholderItem(
                              title: widget.title,
                              bottomPadding: widget.titleBottomPadding,
                              onHeightChanged: (h) {
                                if (h != _titleItemHeight) {
                                  // 实测高度回来后要重建一次：minHeight 兜底
                                  // 依赖该值（首帧为 0，次帧起生效）。
                                  setState(() => _titleItemHeight = h);
                                  // 高度首测/变化后立即校正一次状态
                                  _updateFromScroll();
                                }
                              },
                            ),
                            for (var i = 0; i < widget.itemCount; i++)
                              widget.itemBuilder(context, i),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          // 顶栏：单层渐变模糊带 + 右侧动作区，悬浮叠加
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              showBarBackground: _showBarBackground,
              statusBarHeight: media.padding.top,
              trailing: widget.trailing,
              actions: widget.actions,
            ),
          ),
          // 固定悬浮大标题：不随滚动位移/缩放/溶解（反馈①）
          _PinnedLargeTitle(
            title: widget.title,
            statusBarHeight: media.padding.top,
          ),
        ],
      ),
    );
  }

  /// 标题区高度 = 首 item 高度 − 状态栏（与占位 item 的标题段同口径）。
  /// 首帧实测值未回传时为 0，次帧起生效。
  double _titleZone(MediaQueryData media) =>
      (_titleItemHeight - media.padding.top).clamp(0.0, double.infinity);
}

/// 大标题占位 item：状态栏占位 + 8dp 顶距 + 20sp Bold 标题（行高 36dp，
/// 与顶栏 36dp 头像等高）+ 底部留白——与旧 _LargeTitleItem 同构同尺寸，
/// 但标题**不可见**（visible=false + maintainSize + 无语义）：可见标题已
/// 改为固定悬浮的 [_PinnedLargeTitle]，本项仅提供占位高度与实测
/// （字体缩放/文本变化自适应，供 [_SonifyTitleScaffoldState._titleZone]
/// 兜底滚动区使用）。
class _TitlePlaceholderItem extends StatelessWidget {
  const _TitlePlaceholderItem({
    required this.title,
    required this.bottomPadding,
    required this.onHeightChanged,
  });

  final String title;
  final double bottomPadding;
  final ValueChanged<double> onHeightChanged;

  @override
  Widget build(BuildContext context) {
    final statusBarHeight = MediaQuery.of(context).padding.top;
    final cs = Theme.of(context).colorScheme;
    return _MeasureSize(
      onSizeChanged: (size) => onHeightChanged(size.height),
      child: Visibility(
        // 不可见但保持布局尺寸（占位）与关闭语义（读屏不双报）；
        // Visibility flag 依赖链：maintainSemantics → maintainSize →
        // maintainAnimation → maintainState，四者需显式配齐
        visible: false,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        maintainSemantics: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: statusBarHeight),
            Padding(
              // 距顶 8dp / 水平边距 20dp：Title.kt:1125, 1137
              padding: const EdgeInsets.fromLTRB(
                  SonifySpacing.titleMargin, 8, SonifySpacing.titleMargin, 0),
              child: Text(
                title,
                style: SonifyTextStyles.largeTitle.copyWith(
                  color: cs.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(height: bottomPadding),
          ],
        ),
      ),
    );
  }
}

/// 固定悬浮大标题：位置 = 状态栏 + 8dp 顶距、水平 20dp（与占位 item 的
/// 标题文本坐标一致），**滚动中不位移、不缩放、不溶解**（反馈①）。
///
/// 方案取舍：完全静止（而非透明度微调）——标题是页面的定位锚，任何
/// 淡出都会让用户在滚动中"找不到标题"；可读性由顶栏渐变带（滚动即
/// 浮现）保证，无需标题自身变化。
class _PinnedLargeTitle extends StatelessWidget {
  const _PinnedLargeTitle({
    required this.title,
    required this.statusBarHeight,
  });

  final String title;
  final double statusBarHeight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Positioned(
      top: statusBarHeight + 8,
      left: SonifySpacing.titleMargin,
      right: SonifySpacing.titleMargin,
      // IgnorePointer：RenderParagraph.hitTestSelf 恒为 true，裸 Text 会
      // 吸收命中测试——不包的话标题盒区（通宽、与 36dp 头像同竖向带）
      // 会挡住顶栏头像/动作钮的点按（真机复现：点头像无响应）。
      child: IgnorePointer(
        child: Text(
          title,
          style: SonifyTextStyles.largeTitle.copyWith(color: cs.onSurface),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// 顶栏：状态栏区域 + 54dp 栏体（Title.kt:989）。
///
/// - 背景：**单层渐变模糊带**（磨砂带 + 加深带双带合并，用户反馈③：
///   "偏实、渐变位置不对、两层叠加"），Positioned.fill 覆盖「状态栏 +
///   栏体」全带（y=0 起），随滚动 120ms 淡入出；内容在带下可滚动
///   （悬浮语义）：blur 18dp + cs.surface 系叠色，竖向 LinearGradient
///   **状态栏锚定**——状态栏区域（stops 0 → sb/(sb+[SonifySpacing.topBar])）
///   全强度 [kSonifyBarTopAlpha]，自状态栏下缘起对栏体线性淡出，至带
///   底缘严格 α0；sb<=0 时退化为 stops [0, 1]、colors [α, 0]。
///   覆盖状态栏是既有修正项：曾只覆盖 54dp 栏体，上滑时页面内容从状态栏透出。
/// - 栏体内容：右侧动作区（[actions] 滚动后淡入 + [trailing] 常驻）；
///   大标题已固定悬浮，栏内不再放标题（避免双标题）。
///
/// **图层纪律（批次 9 修复，勿回退）**：[BackdropFilter] 直接位于
/// Positioned.fill → ClipRect 之内，**不得**包进 ShaderMask / Opacity /
/// ColorFiltered 等图层边界 widget——它们创建 saveLayer，内嵌
/// BackdropFilter 模糊完全失效（flutter/flutter#164079、#175537；批次 8
/// 的 ShaderMask(dstIn) 结构即因此真机全无模糊）。渐变衰减改由叠色层
/// 自身 LinearGradient 承担（DecoratedBox/BoxDecoration.gradient）。
/// 带叠色走 cs.surface 系：亮色主题浅色带、暗色主题深色带，跟随
/// 主题；深浅层级由叠色 alpha 承担，不用黑白蒙层（scrim 语义
/// 是次级文字色，亮=黑/暗=白，用在顶栏会导致主题色翻转——构建号 104
/// 真机反馈的回归根源）。
///
/// **材质来源（对齐 dock 配方）**：带 blur sigma 统一 18
/// （[kSonifyBarBlurSigma]）、叠色统一 cs.surface 系，均取自
/// `LiquidGlassSurface`（lib/widgets/common/liquid_glass_surface.dart，
/// 默认参数 = 悬浮 Dock 玻璃配方：blurSigma 18 + surface α0.12 叠色）。
/// 批次 11/12：叠色 alpha 逐步下调（0.7 → 0.40 → 0.32）、实心平台压短，
/// 均因用户反馈"偏实/遮罩感"；本次合并单带后收敛为状态栏区域单值
/// α0.42（[kSonifyBarTopAlpha]）+ 自状态栏下缘起线性淡出。仍高于 dock 的
/// 0.12：顶栏是全宽可读性带、固定大标题直接叠在其上，需保证文字对比度
/// ——结构（顶部浓→底部渐隐）与色系与 dock 一致，仅浓度按可读性上调。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.showBarBackground,
    required this.statusBarHeight,
    required this.trailing,
    this.actions,
  });

  final ValueListenable<bool> showBarBackground;
  final double statusBarHeight;
  final Widget? trailing;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: statusBarHeight + SonifySpacing.topBar,
      child: Stack(
        children: [
          // 渐变模糊带：Positioned.fill 覆盖「状态栏 + 栏体」全带（y=0 起），
          // 滚动即整体淡入（120ms）；单层磨砂带（双带合并，反馈③）。
          // 注意：AnimatedOpacity 全显（opacity=1）时不产生 saveLayer，
          // BackdropFilter 模糊不受影响（见类文档图层纪律）。
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
              // 磨砂带（唯一 BackdropFilter）：blur 18 + surface 叠色，
              // 状态栏锚定竖向渐变 stops [0, sb/(sb+54), 1]——状态栏条
              // 全强度，自状态栏下缘线性淡出，底缘严格全透明
              child: ClipRect(
                child: BackdropFilter(
                  // 对齐 LiquidGlassSurface dock 配方 blurSigma 18
                  //（原 sonify 回退磨砂 14，材质统一，见类文档）
                  filter: ImageFilter.blur(
                    sigmaX: kSonifyBarBlurSigma,
                    sigmaY: kSonifyBarBlurSigma,
                  ),
                  child: DecoratedBox(
                    // surface 系叠色：状态栏区域全强度
                    // （[kSonifyBarTopAlpha]），自状态栏下缘线性淡出到
                    // 底缘 α0；亮=浅带/暗=深带，跟随主题（禁改回
                    // scrim 黑白蒙层——会主题色翻转，见类文档）
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // 状态栏条全强度、栏体段线性淡出到底缘全透明；
                        // sb<=0 退化：stops [0, 1]（避免 stops 重复）
                        colors: statusBarHeight > 0
                            ? [
                                cs.surface
                                    .withValues(alpha: kSonifyBarTopAlpha),
                                cs.surface
                                    .withValues(alpha: kSonifyBarTopAlpha),
                                cs.surface.withValues(alpha: 0),
                              ]
                            : [
                                cs.surface
                                    .withValues(alpha: kSonifyBarTopAlpha),
                                cs.surface.withValues(alpha: 0),
                              ],
                        stops: statusBarHeight > 0
                            ? [
                                0.0,
                                statusBarHeight /
                                    (statusBarHeight + SonifySpacing.topBar),
                                1.0,
                              ]
                            : const [0.0, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 栏体内容：状态栏占位 + 54dp 栏体（右侧动作区）
          Column(
            children: [
              SizedBox(height: statusBarHeight),
              SizedBox(
                height: SonifySpacing.topBar,
                child: Stack(
                  children: [
                    // 右侧动作区：actions（滚动后淡入）+ trailing（常驻）
                    if (trailing != null ||
                        (actions != null && actions!.isNotEmpty))
                      PositionedDirectional(
                        end: SonifySpacing.titleMargin,
                        top: 0,
                        bottom: 0,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // actions 与栏体同拍：滚动即浮现
                            if (actions != null && actions!.isNotEmpty)
                              ValueListenableBuilder<bool>(
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
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: actions!,
                                ),
                              ),
                            if (trailing != null) ...[
                              const SizedBox(width: 8),
                              Center(child: trailing!),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 顶栏单层渐变模糊带（磨砂带）的背景模糊 sigma：对齐 `LiquidGlassSurface`
/// dock 配方（默认 blurSigma 18）——原磨砂 14 / 加深 22 的双强度早已取消，
/// "浓淡"层级完全由叠色 alpha 承担。
/// 非私有：供 widget 测试断言（见 test/widgets/sonify_title_scaffold_test.dart）。
const double kSonifyBarBlurSigma = 18;

/// 顶栏渐变模糊带在状态栏区域的叠色 alpha：状态栏条全强度覆盖，
/// 自状态栏下缘起对栏体线性淡出，至带底缘严格 alpha 0（渐变语义见
/// [_TopBar] 背景段与类文档「材质来源」）。
/// 双带合并后的单值（反馈③：偏实/两层叠加/渐变位置不对），风格值：
/// 介于 dock 透明档 0.12 与批次 12 磨砂带 0.32 之间——偏 0.32 一侧是
/// 为了补回加深带撤掉后文字区的可读性余量。
/// 非私有：供 widget 测试断言（见 test/widgets/sonify_title_scaffold_test.dart）。
const double kSonifyBarTopAlpha = 0.42;

/// 子树尺寸实测（一帧延迟回传），用于大标题占位 item 高度自适应。
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
