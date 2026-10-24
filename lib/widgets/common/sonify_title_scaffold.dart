import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';

/// iOS 大标题骨架（sonify `Title.kt` 的 Flutter 等价物，方案 §1.4/§0.3）。
///
/// 结构约定（与 sonify 一级页骨架同构，Title.kt:402-466）：
/// - 列表首 item = 状态栏占位 + 大标题占位（[SonifyTextStyles.largeTitle]
///   20sp Bold、行高 36dp——与右上角 36dp 用户头像等高；水平边距
///   20dp，距顶 8dp）+ 底部留白。占位 item 的高度按「展开/紧凑」两态
///   几何给出（竖屏恒展开态，见 [_TitlePlaceholderItem]）；
/// - **大标题固定悬浮**（[_PinnedLargeTitle]）：位置 = 状态栏 + 8dp 起、
///   水平 20dp，滚动过程中**不位移、不缩放、不溶解**（用户反馈①：
///   "上滑时标题位置会变，不想要"）。列表首项只保留同尺寸占位
///   （[_TitlePlaceholderItem]，两态解析高度），业务内容从标题下方滚过；
/// - 顶栏悬浮叠加在列表之上：背景为**单片均匀模糊 + tint 渐变带**
///   （材质对齐 `LiquidGlassSurface` dock 配方）：带内 [ClipRect] 包
///   **单个** [BackdropFilter]（`srcOver`，sigma [kSonifyBarBlurSigma]，
///   child `const SizedBox.expand()`），全带同一模糊强度；层次感由
///   tint 叠色层（cs.surface 系 [kSonifyBarTopAlpha] 同锚点渐变，
///   与模糊层同 Stack 的兄弟层）提供，随滚动 120ms 淡入出
///   （Title.kt:952-953），保证滚过内容时固定标题仍清晰可读；
/// - 顶栏右侧内容（如固定用户头像）**常驻渲染**；[actions] 动作钮随
///   栏体 120ms 淡入（滚动即出现，展开态隐藏不挡内容）。
///
/// **顶栏背景的双信号驱动（批次 24）**：栏体模糊带默认随本骨架自身的
/// 滚动（offset > 0）淡入；对外表现为「单固定高 item」的页面（音乐库
/// hub / 本地音乐 / 我的收藏 / FM / 识曲 / 播放历史 / 设置总览——业务
/// 区是固定高 item，滚动发生在**面板内层**列表），其外层骨架最大只
/// 能橡皮筋滚动一个标题区高度，内层列表滚动时骨架 offset 恒为 0，
/// 顶栏渐变带**永不浮现**——与首页「滚动即出带」不一致（用户反馈）。
/// 此类页面经 [barBackgroundVisible] 把内层列表的滚动信号注入本骨架，
/// 栏体背景改随「骨架滚动 **或** 外部信号」二者取或浮现，与
/// [actionsVisible] 同一套外置信号机制。
///
/// **横屏「收窄顶栏」（批次 36，取代批次 35 的「上滑隐藏」）**：
/// 横屏设备高度小，为尽可能减少页面纵向遮挡，横屏 + 内容滚动（离开
/// 顶部）时顶栏**不隐藏**，改为**收窄**：标题区从展开态收窄为紧凑态
/// ——标题区高度 52dp（8+36+8）→ 38dp（6+26+6）、大标题字号
/// 20sp → 14.5sp（行高 36 → 26dp），列表首项占位高度同步收缩
/// （内容区随之增高 14dp）；右上头像（36dp）、actions 钮、渐变
/// 模糊带（状态栏 + 54dp）**全部保留且保持原尺寸/原位置**（只收标题
/// 区，交互锚点不缩）。回顶（offset ≤ 0）恢复展开态；两态间以
/// [kSonifyTopBarCompactDuration]（180ms easeOut）插值（与
/// [SonifyMotion.barFade] 同族、时长更长——几何收窄比透明度淡入需要
/// 更多时长让位，见常量文档），经 Tween 插值驱动，无每帧 setState。
/// 竖屏完全维持现状（固定悬浮、滚动只出模糊带）。判定口径为壳层纯
/// 方向：[MediaQuery.orientationOf] == [Orientation.landscape]。
/// 驱动源与栏背景同源（骨架自身 offset > 0 或外部 [barBackgroundVisible]
/// 注入的内层列表滚动，二者取或）；搜索页（NestedScrollView 结构）由
/// 坍缩态信号驱动，见 [SonifyTitleOverlay.topBarCompact]。
///
/// **去掉的机制**（批次 8 起）：大标题随滚动折叠为小标题（位置/尺寸
/// 变化）及 180ms 端点吸附——与"标题位置固定"的诉求直接冲突，且小标题
/// 与固定大标题同时可见会造成双标题，故整条折叠链路移除；短内容页的
/// minHeight 兜底保留（保证可滚动/下拉刷新，见 [_titleZone]）。
///
/// 顶栏与大标题的悬浮叠加部分抽为公开组件 [SonifyTitleOverlay]：搜索页
/// （NestedScrollView + SliverAppBar 胶囊行结构）与其余三个 tab 页
/// （discover / library hub / fm）共用同一组件，四页顶栏几何与模糊
/// 由构造级保证一致（批次 20，见
/// test/modules/search/search_page_topbar_unification_test.dart）。
class SonifyTitleScaffold extends StatefulWidget {
  const SonifyTitleScaffold({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.trailing,
    this.actions,
    this.actionsVisible,
    this.barBackgroundVisible,
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
  ///
  /// 显隐信号默认随本骨架的滚动（offset > 0 即 [_showBarBackground]）；
  /// 外层骨架不可滚动、改由页面内层列表驱动显隐时，经
  /// [actionsVisible] 注入外部通知器覆盖（不传时行为不变）。
  final List<Widget>? actions;

  /// actions 显隐的外部信号（可选）：非空时 actions 的淡入改随该
  /// 通知器（true = 浮现），与栏体背景（[_showBarBackground]）解耦。
  ///
  /// 用途：页面外层为单个固定高 item、骨架本身不滚动（actions 的既有
  /// offset>0 条件永不满足），但面板内有可滚列表——由面板把内层列表
  /// 的滚动信号上传到此通知器（见 LibraryPage/LibraryMusicPanel 的
  /// listScrolled 链）。不传（null）时保持既有行为：actions 随骨架
  /// 滚动淡入（既有测试契约不变）。
  final ValueListenable<bool>? actionsVisible;

  /// 顶栏渐变模糊带可见性的外部信号（可选）：非空时栏体背景改随
  /// 「骨架自身滚动（offset > 0）**或** 该通知器」取或浮现。
  ///
  /// 用途与 [actionsVisible] 同源：业务区为固定高 item、滚动发生在
  /// 内层列表的页面（音乐库 hub / 本地音乐 / 我的收藏 / FM / 识曲 /
  /// 播放历史 / 设置总览），内层列表滚起来后顶栏应与首页一样出渐变
  /// 模糊带（用户反馈「tab 页顶栏背景不一致」）。通知器由页面持有
  /// 生命周期，面板内层可滚列表的 ScrollNotification 负责写入。
  /// 不传（null）时保持既有行为：仅随骨架滚动淡入。
  final ValueListenable<bool>? barBackgroundVisible;

  /// 大标题 item 底部留白（内容区与大标题的间距）。
  final double titleBottomPadding;

  @override
  State<SonifyTitleScaffold> createState() => _SonifyTitleScaffoldState();
}

class _SonifyTitleScaffoldState extends State<SonifyTitleScaffold> {
  ScrollController? _internalController;
  ScrollController get _controller =>
      widget.controller ?? (_internalController ??= ScrollController());

  /// 顶栏背景（渐变带组）可见性：列表发生任何滚动即出现，回到顶部消失
  /// （Title.kt:640-653）。
  final ValueNotifier<bool> _showBarBackground = ValueNotifier(false);

  /// 批次 36：横屏「收窄顶栏」信号（true = 标题区已收窄为紧凑态）。
  /// 与 [_showBarBackground] 同源（骨架自身 offset > 0 或外部
  /// barBackgroundVisible 注入的内层列表滚动，二者取或），横屏时二者
  /// 同真；**竖屏恒 false**（顶栏固定悬浮不收起，既有路径不变）。
  /// 横竖屏切换（MediaQuery 变化）经 [didChangeDependencies] 重算。
  final ValueNotifier<bool> _topBarCompact = ValueNotifier(false);

  /// 当前是否横屏的方向缓存（[didChangeDependencies] 刷新）：滚动通知
  /// 分发路径上只读缓存，不做 InheritedWidget 查找。另用于 build 期
  /// 决定占位 item / overlay 是否挂收窄动画壳（竖屏不挂，结构不变）。
  bool _landscape = false;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    // 外部滚动信号（内层列表）与骨架滚动共同驱动栏体背景，见
    // [SonifyTitleScaffold.barBackgroundVisible]。
    widget.barBackgroundVisible?.addListener(_updateFromScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 批次 36：横竖屏切换走这里（MediaQuery 依赖变化）——刷新方向缓存
    // 并按新方向重算顶栏收窄态（横屏 = 滚动信号，竖屏恒 false）。
    // 与滚动回调共用同一出口，等值防抖。
    _landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    _updateFromScroll();
  }

  @override
  void dispose() {
    _disposed = true;
    _showBarBackground.dispose();
    _topBarCompact.dispose();
    widget.barBackgroundVisible?.removeListener(_updateFromScroll);
    _internalController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SonifyTitleScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.barBackgroundVisible,
      widget.barBackgroundVisible,
    )) {
      oldWidget.barBackgroundVisible?.removeListener(_updateFromScroll);
      widget.barBackgroundVisible?.addListener(_updateFromScroll);
      _updateFromScroll();
    }
  }

  void _updateFromScroll() {
    if (_disposed) return;
    // 双信号取或：骨架自身滚动（offset > 0）或外部注入的内层列表滚动
    final showBar =
        (_controller.hasClients && _controller.offset > 0) ||
        (widget.barBackgroundVisible?.value ?? false);
    if (_showBarBackground.value != showBar) {
      _showBarBackground.value = showBar;
    }
    // 批次 36：横屏时顶栏随同一滚动信号收窄为紧凑态（竖屏恒 false，
    // 顶栏固定悬浮不收）。等值防抖，避免动画壳反复重启。
    final compactBar = _landscape && showBar;
    if (_topBarCompact.value != compactBar) {
      _topBarCompact.value = compactBar;
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
                          minHeight: constraints.maxHeight + _titleZone(media),
                        ),
                        // stretch 对齐 ListView 的整宽 item 语义（子项缺省
                        // 会收缩到内在宽度，导致搜索框/分区塌缩）。
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 大标题占位 item：竖屏恒展开态（无动画壳，
                            // 与批次 36 前同构）；横屏随 [_topBarCompact]
                            // 在展开/紧凑两态间动画收缩（占位同步收窄，
                            // 滚动态内容区随之增高——「减少遮挡」）。
                            _TitlePlaceholderItem(
                              compact: _landscape ? _topBarCompact : null,
                              statusBarHeight: media.padding.top,
                              textScaler: media.textScaler,
                              bottomPadding: widget.titleBottomPadding,
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
          // 顶栏 + 固定悬浮大标题：共享 overlay 组件（批次 20 抽出，
          // 搜索页 NestedScrollView 结构同款复用）。Positioned.fill 的
          // 全屏约束下 overlay 内部 Stack 与旧结构（_TopBar 的
          // Positioned(top/left/right) + _PinnedLargeTitle 的
          // Positioned）逐像素等价。
          Positioned.fill(
            child: SonifyTitleOverlay(
              title: widget.title,
              showBarBackground: _showBarBackground,
              // 批次 36：横屏「收窄顶栏」驱动信号（竖屏时 overlay 内
              // 的方向判定忽略它，顶栏结构逐字节维持既有悬浮形态）。
              topBarCompact: _topBarCompact,
              statusBarHeight: media.padding.top,
              trailing: widget.trailing,
              actions: widget.actions,
              actionsVisible: widget.actionsVisible,
            ),
          ),
        ],
      ),
    );
  }

  /// 标题区高度（首 item 高度 − 状态栏）：内容不足一屏时把列表撑到
  /// 「视口 + 标题区」的 minHeight 兜底口径。
  ///
  /// 批次 36 起改解析式计算（原为占位 item 实测回填）：展开态 =
  /// [_kTitleTopPad] + 20sp largeTitle 行高 36（随字体缩放）+ 底部
  /// 留白，首帧即精确可用（原实现首帧为 0、次帧才生效）。恒取展开态
  /// 口径——兜底只需保证 maxScrollExtent > 0，横屏紧凑态由占位 item
  /// 自身动画收紧（38dp），兜底保留 52dp 余量不影响可滚性（外层
  /// 橡皮筋上限略增 14dp，与既有「最大橡皮筋一个标题区高度」同族）。
  double _titleZone(MediaQueryData media) =>
      _kTitleTopPad +
      media.textScaler.scale(_kTitleFontSize) * (_kTitleLineHeight / _kTitleFontSize) +
      widget.titleBottomPadding;
}

/// 四页共用的顶栏悬浮 overlay：渐变模糊带（[_TopBar]）+ 固定悬浮大标题
/// （[_PinnedLargeTitle]）。
///
/// 批次 20 UI 统一：discover / library hub / fm 经 [SonifyTitleScaffold]
/// 使用，搜索页（NestedScrollView + SliverAppBar 胶囊行结构）直接以
/// `Positioned.fill` 叠在滚动区之上——同一组件即「标题 & 用户头像的
/// 位置和大小、模糊完全一致」的构造级保证（跨页几何回归见
/// test/modules/search/search_page_topbar_unification_test.dart）。
///
/// 用法约定：置于页面级 Stack 中、以 [Positioned.fill]（或等价全屏约束）
/// 包裹；`showBarBackground` 由宿主页的滚动信号驱动（offset > 0 即
/// 浮现，回顶消失）。
///
/// **横屏「收窄顶栏」（批次 36，取代批次 35 的「上滑隐藏」）**：注入
/// [topBarCompact] 且宿主为横屏时，整栏**不滑出**——渐变模糊带
/// （[_TopBar]）与右上头像 / actions 保持原尺寸原位置（交互锚点不缩），
/// 仅固定悬浮大标题（[_PinnedLargeTitle]）在展开/紧凑两态间以 180ms
/// easeOut 插值：标题区 52dp（8+36+8）→ 38dp（6+26+6）、字号 20sp →
/// 14.5sp（行高 36 → 26dp）；信号回落即恢复展开态。竖屏（或未注入
/// 信号）时本参数被方向判定忽略，返回原 Stack 结构（[_buildStack]），
/// 与批次 36 之前逐字节一致（回归锁
/// test/widgets/sonify_title_scaffold_test.dart）。
class SonifyTitleOverlay extends StatelessWidget {
  const SonifyTitleOverlay({
    super.key,
    required this.title,
    required this.showBarBackground,
    required this.statusBarHeight,
    this.trailing,
    this.actions,
    this.actionsVisible,
    this.topBarCompact,
  });

  /// 页面大标题文本（固定悬浮，不折叠）。
  final String title;

  /// 顶栏渐变模糊带可见性通知器（滚动即 true，回顶 false）。
  final ValueListenable<bool> showBarBackground;

  /// 状态栏高度（MediaQuery.padding.top；测试环境为 0）。
  final double statusBarHeight;

  /// 顶栏右侧常驻内容（如固定用户头像），不随滚动淡入出。
  final Widget? trailing;

  /// [trailing] 左侧的动作按钮组，随栏体 120ms 淡入（展开态隐藏）。
  final List<Widget>? actions;

  /// actions 显隐信号（可选）：非空时 actions 淡入改随该通知器，
  /// 与 [showBarBackground]（栏体背景）解耦；为空时沿用
  /// [showBarBackground]（默认行为）。见 [SonifyTitleScaffold.actionsVisible]。
  final ValueListenable<bool>? actionsVisible;

  /// 批次 36：横屏「收窄顶栏」信号（true = 标题区收窄为紧凑态）。
  ///
  /// 骨架页（SonifyTitleScaffold）传入 [_SonifyTitleScaffoldState] 的
  /// 同源滚动信号（横屏 = 骨架 offset > 0 或外部 barBackgroundVisible
  /// 注入的内层列表滚动；竖屏恒 false）；搜索页传入坍缩态通知器
  /// （outer offset ≥ 52 = 坍缩态 = 顶栏收窄，而非滑出）。**竖屏时
  /// 本参数被方向判定忽略**（顶栏固定悬浮不收窄），仅横屏生效。
  final ValueListenable<bool>? topBarCompact;

  @override
  Widget build(BuildContext context) {
    final compactSignal = topBarCompact;
    if (compactSignal != null &&
        MediaQuery.orientationOf(context) == Orientation.landscape) {
      // 横屏收窄路径（批次 36）：整栏不出屏，仅固定大标题在两态间
      // 插值收紧（_TopBar 渐变带与头像/actions 保持原样——只收标题
      // 区，交互锚点不缩）。信号监听只包 Stack 一层：180ms 插值由
      // _PinnedLargeTitle 内部 TweenAnimationBuilder 逐帧完成，
      // 不触发整页重建。
      return ValueListenableBuilder<bool>(
        valueListenable: compactSignal,
        builder: (context, compact, child) => _buildStack(compact: compact),
      );
    }
    // 竖屏（或未注入收窄信号）：固定悬浮顶栏，结构与批次 36 之前逐字节
    // 一致（回归锁 test/widgets/sonify_title_scaffold_test.dart）。
    return _buildStack();
  }

  /// 顶栏 Stack（渐变模糊带 [_TopBar] + 固定悬浮大标题）。
  ///
  /// [compact] 非空 = 横屏收窄路径：大标题随布尔值在展开/紧凑两态间
  /// 动画收紧；null = 竖屏原路径（[_PinnedLargeTitle] 不挂动画壳）。
  Widget _buildStack({bool? compact}) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _TopBar(
            showBarBackground: showBarBackground,
            statusBarHeight: statusBarHeight,
            trailing: trailing,
            actions: actions,
            actionsVisible: actionsVisible,
          ),
        ),
        // 固定悬浮大标题：不随滚动位移/缩放/溶解（反馈①）；
        // 横屏收窄路径下随 compact 信号做两态几何插值（批次 36）
        _PinnedLargeTitle(
          title: title,
          statusBarHeight: statusBarHeight,
          compact: compact,
        ),
      ],
    );
  }
}

/// 大标题占位 item：仅提供首项占位高度（状态栏占位 + 标题区），业务
/// 内容从标题下方滚过；可见标题为固定悬浮的 [_PinnedLargeTitle]。
///
/// **两态几何（批次 36）**：高度解析式计算，不再实测回填（原
/// [_MeasureSize] 机制）——展开态 = 状态栏 + 8 + 36（20sp largeTitle
/// 行高，随 textScaler 缩放）+ 底部留白；紧凑态 = 状态栏 + 6 + 26
/// （14.5sp 行高）+ 6。竖屏（[compact] 为 null）恒展开态、不挂动画
/// 壳，与批次 36 前同构同尺寸；横屏（[compact] 非空）随收窄信号在
/// 两态间 180ms easeOut 插值收缩——占位与悬浮标题同步收紧，滚动态
/// 业务内容起点随之上移 14dp（内容区增高 = 用户要的「减少遮挡」）。
/// 字体缩放自适应由 textScaler 代入两态公式保证（与原实测等价：
/// 行高 = scale(字号) × height）。
class _TitlePlaceholderItem extends StatelessWidget {
  const _TitlePlaceholderItem({
    required this.compact,
    required this.statusBarHeight,
    required this.textScaler,
    required this.bottomPadding,
  });

  /// 横屏收窄信号（null = 竖屏/无信号：恒展开态、无动画壳）。
  final ValueListenable<bool>? compact;

  final double statusBarHeight;
  final TextScaler textScaler;

  /// 大标题 item 底部留白（展开态口径；紧凑态收窄为定值 6dp）。
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    // 两态标题区高度（不含状态栏）：
    // 展开 = 8 + 36 + bottomPadding（52 @ ts=1）；紧凑 = 6 + 26 + 6（38）。
    final expandedZone = _kTitleTopPad +
        textScaler.scale(_kTitleFontSize) *
            (_kTitleLineHeight / _kTitleFontSize) +
        bottomPadding;
    final compactZone = _kCompactTitleTopPad +
        textScaler.scale(_kCompactTitleFontSize) *
            (_kCompactTitleLineHeight / _kCompactTitleFontSize) +
        _kCompactTitleBottomPad;
    final signal = compact;
    if (signal == null) {
      // 竖屏原路径：展开态定高盒，无动画壳（批次 36 前同构）
      return SizedBox(height: statusBarHeight + expandedZone);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: signal,
      builder: (context, compact, _) => TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: compact ? 1 : 0),
        duration: kSonifyTopBarCompactDuration,
        curve: Curves.easeOut,
        // 逐帧插值由 Tween 内部完成，不走 setState：仅本 SizedBox 的
        // 高度在动，业务 item 子树不被重建
        builder: (context, t, _) => SizedBox(
          height: statusBarHeight + expandedZone + (compactZone - expandedZone) * t,
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
///
/// **横屏收窄两态（批次 36）**：[compact] 非空（横屏收窄路径）时，
/// 标题在展开/紧凑两态间以 [kSonifyTopBarCompactDuration]（180ms
/// easeOut）插值：字号 20sp → 14.5sp、行高 36 → 26dp、顶距 8 → 6dp。
/// 竖屏（[compact] 为 null）走原静态路径，Positioned(top: sb+8) +
/// 20sp 原样，不挂任何动画壳（回归锁逐字节不动）。
///
/// 实现说明：Positioned.top 无法随动画插值（且 Positioned 必须是
/// Stack 直接子级、不能放进 Tween builder 里构造），故紧凑路径以
/// `top: 状态栏 + 6dp` 为常量锚点，展开态差的 2dp 顶距由内部
/// [Transform.translate] 补足（t=0 时 dy=2 → 视觉顶距恰为 8dp）。
/// 字号缩放不产生溢出：文本 maxLines 1 + ellipsis 横向截断、行高由
/// style height 精确给定（26dp < 36dp），无需 OverflowBox/ClipRect。
class _PinnedLargeTitle extends StatelessWidget {
  const _PinnedLargeTitle({
    required this.title,
    required this.statusBarHeight,
    this.compact,
  });

  final String title;
  final double statusBarHeight;

  /// 横屏收窄信号（null = 竖屏原路径：静态 20sp、顶距 8dp）；
  /// 非 null 时随布尔值在展开/紧凑两态间 180ms 插值。
  final bool? compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final compact = this.compact;
    if (compact == null) {
      // 竖屏原路径（批次 36 前逐字节一致）
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
    // 横屏收窄路径：常量锚点 6dp + Transform 补 2dp 展开差 + 字号/行高
    // 两态插值（t: 0=展开 1=紧凑）
    return Positioned(
      top: statusBarHeight + _kCompactTitleTopPad,
      left: SonifySpacing.titleMargin,
      right: SonifySpacing.titleMargin,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: compact ? 1 : 0),
        duration: kSonifyTopBarCompactDuration,
        curve: Curves.easeOut,
        builder: (context, t, child) {
          final fontSize = _kTitleFontSize +
              (_kCompactTitleFontSize - _kTitleFontSize) * t;
          return Transform.translate(
            // 展开态顶距 8dp = 锚点 6 + 2；紧凑态 6dp
            offset: Offset(0, (1 - t) * (_kTitleTopPad - _kCompactTitleTopPad)),
            child: IgnorePointer(
              child: Text(
                title,
                style: SonifyTextStyles.largeTitle.copyWith(
                  fontSize: fontSize,
                  // 行高随字号同拍插值（36 → 26dp）：height 为倍数，
                  // 换算成当前字号下的行高 dp
                  height: (_kTitleLineHeight +
                          (_kCompactTitleLineHeight - _kTitleLineHeight) * t) /
                      fontSize,
                  color: cs.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 顶栏：状态栏区域 + 54dp 栏体（Title.kt:989）。
///
/// - 背景：**单片均匀模糊 + tint 渐变带**（批次 17 由 3 切片退化为单片：
///   用户反馈三段分界线明显、非线性），Positioned.fill → ClipRect →
///   Stack 两层覆盖「状态栏 + 栏体」全带（y=0 起），随滚动 120ms
///   淡入出；内容在带下可滚动（悬浮语义）：
///   ① 单片模糊层：带内**单个** `srcOver` [BackdropFilter]
///      （filter = blur(sigma: [kSonifyBarBlurSigma])，child 必须非
///      null——`const SizedBox.expand()`，child 缺失时框架不生成滤镜
///      层，真机表现为完全无模糊），全带均匀同一强度；
///   ② tint 叠色层：与模糊层 **同 Stack 的兄弟层**
///      （Positioned.fill + DecoratedBox，普通 srcOver），cs.surface 系
///      竖向 LinearGradient **状态栏锚定**——stops [0, sb/(sb+54), 1]，
///      状态栏区域全强度 [kSonifyBarTopAlpha]，自状态栏下缘起对栏体
///      线性淡出，至带底缘严格 α0；sb<=0 时退化为 stops [0, 1]、
///      colors [满, 0]。层次感（顶部浓→底部渐隐）由本渐变提供，
///      不再靠切片 sigma 递减。
///   覆盖状态栏是既有修正项：曾只覆盖 54dp 栏体，上滑时页面内容从状态栏透出。
/// - 栏体内容：右侧动作区（[actions] 滚动后淡入 + [trailing] 常驻）；
///   大标题已固定悬浮，栏内不再放标题（避免双标题）。
///
/// **图层纪律（批次 9 修复，勿回退；批次 14/16/17 复核仍成立）**：
/// [BackdropFilter] 位于 Positioned.fill → ClipRect 之内，**不得**包进
/// ShaderMask / Opacity / ColorFiltered 等图层边界 widget——它们创建
/// saveLayer，内嵌 BackdropFilter 模糊完全失效（flutter/flutter#164079、
/// #175537；批次 8 的 ShaderMask(dstIn) 包 BackdropFilter 结构即因此真机
/// 全无模糊，禁止回退）。模糊强度**只有**在 [BackdropFilter] 不传
/// `blendMode`（即 `srcOver`）时全平台可靠（SDK basic.dart 内文档明确），
/// 故本组件直接用 BackdropFilter 构造、不传 blendMode；批次 14 的
/// `dstIn` 塑形在 Skia（本项目默认后端）与 Impeller 下真机均只剩 tint、
/// 无模糊，已废弃；批次 16 的切片 sigma 递减（18/9/3）亦因用户反馈
/// 分界线明显、非线性而退化为单片（批次 17）。动画透明度由外层
/// AnimatedOpacity 全显（opacity=1）免 saveLayer 的特性保证。
/// 带叠色走 cs.surface 系：亮色主题浅色带、暗色主题深色带，跟随
/// 主题；深浅层级由叠色 alpha 承担，不用黑白蒙层（scrim 语义
/// 是次级文字色，亮=黑/暗=白，用在顶栏会导致主题色翻转——构建号 104
/// 真机反馈的回归根源）。
///
/// **材质来源（对齐 dock 配方）**：blur sigma [kSonifyBarBlurSigma]、
/// 叠色统一 cs.surface 系，均取自 `LiquidGlassSurface`
/// （lib/widgets/common/liquid_glass_surface.dart，默认参数 = 悬浮 Dock
/// 玻璃配方：blurSigma 18 + surface α0.12 叠色）。批次 17 起：用户反馈
/// 3 切片（18/9/3）分界线明显、非线性，退化为**单片**；批次 25 起模糊
/// 强度回归 dock 同档 **sigma 18**（与 LiquidGlassSurface 完全同配方，
/// 无切片分界）——σ3 弱模糊在不透明白卡内容（搜索结果/音乐库/设置）
/// 滚过时糊不出磨砂结构，顶栏观感退化为一条实色（用户反馈「上滑后
/// 变实色条」）；σ18 让内容边缘/封面滚过时呈现明显磨砂玻璃感，与主页
/// （半透明玻璃卡内容）观感拉齐。层次感交给 tint 渐变（顶部浓 → 底缘
/// 渐隐）。需要调整模糊只改 [kSonifyBarBlurSigma] 一个常量。叠色 alpha
/// 历程：批次 11/12 逐步
/// 下调（0.7 → 0.40 → 0.32）均因用户反馈"偏实/遮罩感"；双带合并后
/// 收敛为状态栏区域单值 α0.42（[kSonifyBarTopAlpha]）+ 自状态栏下缘起
/// 线性淡出。仍高于 dock 的 0.12：顶栏是全宽可读性带、固定大标题直接
/// 叠在其上，需保证文字对比度。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.showBarBackground,
    required this.statusBarHeight,
    required this.trailing,
    this.actions,
    this.actionsVisible,
  });

  final ValueListenable<bool> showBarBackground;
  final double statusBarHeight;
  final Widget? trailing;
  final List<Widget>? actions;

  /// actions 显隐信号：非空时与栏体背景（[showBarBackground]）解耦，
  /// 随页面内层列表滚动浮现（本地音乐页）；为空时跟随栏体背景
  /// （默认，其余页面不变）。
  final ValueListenable<bool>? actionsVisible;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 带高：状态栏 + 54dp 栏体（单片模糊 + tint 覆盖全带）
    final bandHeight = statusBarHeight + SonifySpacing.topBar;
    return SizedBox(
      height: bandHeight,
      child: Stack(
        children: [
          // 渐变模糊带：Positioned.fill 覆盖「状态栏 + 栏体」全带（y=0 起），
          // 滚动即整体淡入（120ms）；单片均匀模糊（批次 25 起回归 dock
          // 配方 σ18，此前 3 切片/σ3 历程见常量文档）。
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
              // 单片均匀模糊带：带内单个 BackdropFilter（srcOver，不传
              // blendMode——仅 srcOver 全平台可靠，见类文档图层纪律），
              // child 必须非 null（const SizedBox.expand()，缺失时框架不
              // 生成滤镜层、真机无模糊）。
              // tint 叠色为同 Stack 兄弟层，提供顶部浓→底部渐隐的层次。
              child: ClipRect(
                child: Stack(
                  children: [
                    // ① 单片模糊层（全带同一 sigma，铺满整带）。
                    // key 'sonify_bar_blur'：σ 与 LiquidGlassSurface 玻璃
                    // 钮（GlassCircleButton 自带 σ18 BackdropFilter）同值
                    // 后，测试无法再按 sigma 唯一定位栏带，改按 key。
                    Positioned.fill(
                      child: BackdropFilter(
                        key: const ValueKey('sonify_bar_blur'),
                        filter: ImageFilter.blur(
                          sigmaX: kSonifyBarBlurSigma,
                          sigmaY: kSonifyBarBlurSigma,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    // ② tint 叠色层（模糊兄弟层，普通 srcOver，不受模糊
                    //   层裁剪影响）：surface 系，状态栏区域全强度
                    //   （[kSonifyBarTopAlpha]），自状态栏下缘线性淡出到
                    //   底缘 α0；亮=浅带/暗=深带，跟随主题（禁改回 scrim
                    //   黑白蒙层——会主题色翻转，见类文档）
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            // 状态栏条全强度、栏体段线性淡出到底缘
                            // 全透明；sb<=0 退化：stops [0, 1]
                            colors: statusBarHeight > 0
                                ? [
                                    cs.surface.withValues(
                                      alpha: kSonifyBarTopAlpha,
                                    ),
                                    cs.surface.withValues(
                                      alpha: kSonifyBarTopAlpha,
                                    ),
                                    cs.surface.withValues(alpha: 0),
                                  ]
                                : [
                                    cs.surface.withValues(
                                      alpha: kSonifyBarTopAlpha,
                                    ),
                                    cs.surface.withValues(alpha: 0),
                                  ],
                            stops: statusBarHeight > 0
                                ? [
                                    0.0,
                                    statusBarHeight /
                                        (statusBarHeight +
                                            SonifySpacing.topBar),
                                    1.0,
                                  ]
                                : const [0.0, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ],
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
                            // actions 与栏体同拍：滚动即浮现。
                            // 注入了 actionsVisible 时改随外部信号
                            // （本地音乐页的内层列表滚动），与栏体
                            // 背景不同拍。
                            if (actions != null && actions!.isNotEmpty)
                              ValueListenableBuilder<bool>(
                                valueListenable:
                                    actionsVisible ?? showBarBackground,
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

/// 大标题展开态几何（竖屏口径 / 横屏回顶态）：顶距 8dp + 20sp
/// largeTitle 行高 36dp（20 × 1.8，与 36dp 头像等高）+ 底部留白
/// （[SonifyTitleScaffold.titleBottomPadding]，默认 8dp）→ 标题区 52dp。
const double _kTitleTopPad = 8;
const double _kTitleFontSize = 20;
const double _kTitleLineHeight = 36;

/// 大标题紧凑态几何（批次 36 横屏收窄态）：
/// - 顶距 8 → **6dp**、底距（titleBottomPadding）→ **6dp**；
/// - 字号 20sp → **14.5sp**、行高 36 → **26dp**（height = 26/14.5
///   ≈ 1.793，与 largeTitle 的 1.8 同族比例）；
/// - 标题区 52 → **38dp**（6 + 26 + 6，落在任务约定的 36-40dp 区间）。
/// 定值依据：紧凑态仍需与栏体（54dp）内 36dp 头像/42dp actions 圆钮
/// 同带共存——26dp 行高 + 上下各 6dp 后标题区底缘 = 状态栏 + 32dp，
/// 仍完全落在渐变模糊带（状态栏 + 54dp）内，标题不被裁切；同时较展开
/// 态净省 14dp 纵向遮挡（52 − 38），满足横屏「减少遮挡」诉求。
const double _kCompactTitleTopPad = 6;
const double _kCompactTitleBottomPad = 6;
const double _kCompactTitleFontSize = 14.5;
const double _kCompactTitleLineHeight = 26;

/// 横屏「收窄顶栏」动画时长（批次 36）：150-200ms 区间取 180ms、
/// easeOut。与 [SonifyMotion.barFade]（120ms，透明度淡入）同族但更长
/// ——几何收窄（高度/字号/位置三属性插值）比单纯透明度更易被感知，
/// 取区间中值 180ms 兼顾跟手与柔和（批次 35 滑出动画同款取值）。
/// 竖屏不适用（顶栏固定悬浮，无收窄动画）。
/// 非私有：供 widget 测试断言动画收敛时长。
const Duration kSonifyTopBarCompactDuration = Duration(milliseconds: 180);

/// 顶栏渐变模糊带的模糊 sigma：**单片 dock 配方**（批次 25 起）。
///
/// 口径：3 切片（18/9/3）真机三段分界线明显、非线性，批次 17 退化为
/// 单片（σ3）；批次 25 因「不透明白卡内容（搜索/音乐库/设置）滚过时
/// σ3 糊不出磨砂结构、顶栏观感退化为实色条」（用户反馈）回归 dock 同
/// 档 18（与 LiquidGlassSurface 同配方、无切片分界）。层次由 tint 渐变
/// （状态栏全强度 → 底缘渐隐）提供。非私有：供 widget 测试断言
/// （见 test/widgets/sonify_title_scaffold_test.dart）。
const double kSonifyBarBlurSigma = 18;

/// 顶栏渐变模糊带在状态栏区域的叠色 alpha：状态栏条全强度覆盖，
/// 自状态栏下缘起对栏体线性淡出，至带底缘严格 alpha 0（渐变语义见
/// [_TopBar] 背景段与类文档「材质来源」）。
/// 双带合并后的单值（反馈③：偏实/两层叠加/渐变位置不对），风格值：
/// 介于 dock 透明档 0.12 与批次 12 磨砂带 0.32 之间——偏 0.32 一侧是
/// 为了补回加深带撤掉后文字区的可读性余量。
/// 非私有：供 widget 测试断言（见 test/widgets/sonify_title_scaffold_test.dart）。
const double kSonifyBarTopAlpha = 0.42;
