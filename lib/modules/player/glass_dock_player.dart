import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/services/player_frame_driver.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/widgets/liquid_glass_container.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/player_provider.dart';
import '../../providers/tab_config_provider.dart';
import '../../utils/landscape_dock_side.dart';
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
/// - **横屏纵条 + 独立播放球（批次35 纵条化，批次36 球独立化）**：
///   **贴边方向可配置（批次36）**——设置 → 播放 → 屏幕与显示 →
///   「悬浮 Dock 位置」可选靠左 / 靠右，默认靠右（= 改造前行为）。
///   纵条与球按 [kLandscapeDockSide] 贴左或贴右（单一布局代码 + 方向
///   映射，不复制两套），展开体恒从球体向**内侧**伸出，页面避让由
///   app.dart 按同方向注入 `padding.left` 或 `padding.right`（未配置侧
///   为 0，不做双侧避让）；竖屏底部横条与该设置无关。
///   `MediaQuery.orientationOf` 为横屏时 Dock 从底部横条切换为**右侧
///   纵向悬浮条**（用户口径「横屏设备高度小，尽可能减少页面纵向遮挡」）。
///   **批次36（用户口径「悬浮播放器球独立，与竖屏时一致，展开播放器时，
///   滑动内容坍缩」）起播放球与导航纵条分离为两个独立悬浮元素**：
///   · 上部：导航项**纵排**（复用竖屏 [_DockNavItem] 配方，44dp 圆形；
///     横屏导航恒展开——纵排不占横向预算，无坍缩态，不参与竖屏单展开
///     闭环；项径随横屏矮视口高度预算自适应，见 [_landscapeNavItemSize]）；
///     玻璃胶囊内**不再嵌播放球**（球独立后纵条只剩导航项）；
///   · 下部：独立播放球 42dp（[kLandscapeBallSize]，GlassCircleButton
///     同口径，进度环 + 圆形封面缩略图 + 播放态指示，与竖屏播放球同源
///     配方）——悬浮在纵条**下方**、与纵条同右距同列（球心对齐纵条中线，
///     两者作为一个组合体整体垂直居中，垂直间距
///     [kLandscapeBallRailGap]）。无导航形态（二级页仅播放器 / 可见
///     tab 为空）不渲染纵条，球单独垂直居中。
///   **避让口径（批次36）**：纵条与球同右距同列、落在同一右侧避让带内
///   （app.dart 注入 `MediaQuery.padding.right += 纵条宽 + 右距`，与竖屏
///   底部注入 `_kDockReservedBottom` 完全同模式，常量一处定义两处消费，
///   见 [kLandscapeRailWidth] / [kLandscapeRailRightMargin]）——**独立球
///   不额外增加避让值**（它不在内容区之上，而与纵条共享避让带）；展开体
///   为瞬时悬浮层，同样不占避让。**批次36 几何硬让位**：页面侧暂无消费
///   `padding.right` 的滚动容器（注入只改 MediaQuery，各页滚动容器只读
///   `.bottom`），app.dart 在横屏下额外把内容区几何内缩同一宽度
///   （Padding），纵条/球落在内缩出的 gutter 带中不再遮挡内容。
///   播放球点击 → 控件**横向展开**（宽度动画 42 → [kLandscapeControlsWidth]
///   270dp，260ms easeOutCubic）：展开体 = 封面小图（外周进度环）+ 标题/
///   歌手 + 上一曲/播放暂停/下一曲（复用竖屏胶囊控件与 PlayerProvider
///   交互语义，横向排布），**从球体向左伸出**、悬浮覆盖在页面右下
///   之上，不推挤导航项。
///   **坍缩路径（批次36 扩展，原有两条不变）**：①再点球；②点展开体
///   外部；③**滑动页面内容**——展开态下用户滑动/滚动页面内容 → 控件
///   自动坍缩（球保持）。③的信号机制见 [contentScrollPulse]：app.dart
///   在主布局/二级路由内容外层挂 `NotificationListener<ScrollNotification>`，
///   纵向滚动时广播脉冲，本 Dock 展开态收到即坍缩。为使「滑动内容」成立，
///   点外坍缩屏障从批次35 的 opaque GestureDetector（吸收整屏触摸、
///   展开态内容无法滚动）改为 **translucent Listener**（命中路径放行
///   下层）：页面滚动控件照常赢下手势竞技场、内容真实滚动，屏障仍收
///   同一指针流据此坍缩；点空白处照旧坍缩（点可交互元素时元素点击与
///   坍缩同时发生——语义变更论证见 [_buildLandscapeDismissBarrier]）。
///   球/纵条/展开体在 Stack 中位于屏障之上且均不 translucent，落在它们
///   上面的指针根本进不到屏障路径——「球上发起的滚动手势不算内容滚动」
///   「展开态点球/导航项行为不变」由结构保证。横屏播放球保留竖屏同款
///   上滑拖拽（展开 FullPlayer，松手三阈值按**长边口径**，见
///   [_onPlayerDragEnd]）。
///   页面右侧避让由 app.dart 注入
///   `MediaQuery.padding.right += 纵条宽 + 右距`（与竖屏底部注入
///   `_kDockReservedBottom` 完全同模式），常量一处定义两处消费（见
///   [kLandscapeRailWidth] / [kLandscapeRailRightMargin]）。
/// - **Pad 横屏分档（批次35，最短边口径；批次36 球距换档）**：横屏内再按
///   视口**最短边**分档——[GlassDockPlayer.isPadLandscape]（横屏 + 最短边
///   ≥ [kLandscapePadBreakpoint] 600）命中 Pad 档，纵条/球几何整体上浮一档
///   （球 42→48、项径足额/上限 44→48、项间距 4→6、
///   纵条宽 52→60、展开宽 270→320、球与纵条间距 12→14，见 Pad 档常量）；
///   手机横屏档（最短边 < 600，含全部手机横屏形态）数值逐字节不变。
///   app.dart 两处避让注入（一级页 / 二级页）按同一判定选档——
///   壳与内容判据同源，防「Pad 壳装手机内容」错位。
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

  // ── 横屏右纵条几何常量（批次35）：一处定义，Dock 布局与 app.dart
  //    避让注入（MediaQuery.padding.right += 纵条宽 + 右距）同源消费 ──

  /// 横屏播放球直径（与 GlassCircleButton 42dp 圆钮同口径）。
  static const double kLandscapeBallSize = 42.0;

  /// 横屏播放球中央的圆形封面直径（42dp 球内，距外缘各 3dp）。
  static const double kLandscapeBallCoverSize = 36.0;

  /// 横屏纵条外宽（导航项足径 44dp + 容器水平 padding 4×2 = 52dp；
  /// 项径压缩时容器宽不变——SizedBox 锁定，球体 42dp 恒可容纳）。
  static const double kLandscapeRailWidth = 52.0;

  /// 横屏纵条与**贴边侧**屏幕边缘的间距（与竖屏 Dock 底距 12dp 同口径）。
  ///
  /// 批次36 起 Dock 可配置贴左/贴右：本常量是「到贴边侧」的距离，贴左时
  /// 镜像为左间距（同一数值、单一常量，不做左右两套常量）。
  static const double kLandscapeRailRightMargin = 12.0;

  /// 横屏展开体（玻璃容器）宽度：270dp = 内容 260（封面含环 39 + 间距 8
  /// + 标题/歌手 ~83 + 三钮 120）+ 水平 padding 10；落在设计规格
  /// 240-280dp 区间。AnimatedSize 动画的即此宽度（42 → 270）。
  static const double kLandscapeControlsWidth = 270.0;

  // ── 横屏 Pad 分档常量（批次35）：最短边 ≥ 600 的横屏平板专用档，
  //    与上方手机横屏档并列；app.dart 避让注入按同源判定选档消费 ──

  /// Pad 横屏分档断点：视口**最短边** ≥ 600dp 判为 Pad 横屏档（与方向
  /// 无关——手机横屏最短边 < 600，不会误判成 Pad）。
  ///
  /// sonify 踩坑结论：按 screenWidthDp（宽）判定时手机横屏宽度也超
  /// 600，会误入 Pad 档——禁用；必须按最短边。数值与
  /// core/layout/responsive_layout.dart 的 `_compactBreakpoint` 一致，
  /// 但此处按纯视口口径判定（不读 DeviceProvider 的用户覆盖），保证
  /// Dock 壳与 app.dart 避让内容判据同源。
  static const double kLandscapePadBreakpoint = 600.0;

  /// Pad 档横屏播放球直径（手机档 [kLandscapeBallSize] 42 上浮一档）。
  static const double kLandscapeBallSizePad = 48.0;

  /// Pad 档横屏播放球中央的圆形封面直径（48dp 球内，距外缘各 3dp，
  /// 同手机档 6dp 总口径）。
  static const double kLandscapeBallCoverSizePad = 42.0;

  /// Pad 档横屏纵条外宽（导航项足径 48dp + 容器水平 padding 6×2 =
  /// 60dp；项径压缩时容器宽不变——SizedBox 锁定，球体 48dp 恒可容纳）。
  static const double kLandscapeRailWidthPad = 60.0;

  /// Pad 档横屏展开体（玻璃容器）宽度：320dp = 手机档 270 上浮一档
  /// （内容 310 = 封面含环 39 + 间距 8 + 标题/歌手 ~143 + 三钮 120）。
  /// AnimatedSize 动画目标宽度（48 → 320）。
  static const double kLandscapeControlsWidthPad = 320.0;

  /// 横屏独立播放球与导航纵条的垂直间距（手机横屏档，批次36）。
  ///
  /// 批次36 起播放球与纵条**分离**为两个独立悬浮元素（球独立化，用户
  /// 口径「悬浮播放器球独立」）：纵条胶囊内只剩导航项，播放球悬浮在
  /// 纵条**下方**、同右距同列（球心对齐纵条中线，共享同一右侧避让带，
  /// 不额外增加避让值），本常量即两者的垂直间距。球不再嵌在胶囊内，
  /// 间距取 12（略大于原胶囊内「导航与球间距」8，从视觉上区隔两个
  /// 独立元素）；组合体（纵条 + 本间距 + 球）整体垂直居中。
  static const double kLandscapeBallRailGap = 12.0;

  /// Pad 档横屏独立播放球与导航纵条的垂直间距（手机档 12 上浮一档）。
  static const double kLandscapeBallRailGapPad = 14.0;

  /// 批次39：二级页（仅播放器形态，`showNav: false`）横屏**纵向展开**
  /// 播放面板宽度（手机档）。用户口径「横屏二级页面悬浮播放器纵向展开
  /// 显示」——二级页没有导航纵条，展开体不再沿用一级页的横向控件条
  /// （270dp 横条盖在内容上），改为贴边纵排玻璃面板（封面在上、歌名/
  /// 歌手居中、传输钮在下），从球体下方竖向生长。
  static const double kLandscapeVerticalControlsWidth = 200.0;

  /// Pad 档二级页横屏纵向展开面板宽度（手机档 200 上浮一档）。
  static const double kLandscapeVerticalControlsWidthPad = 230.0;

  /// 二级页横屏纵向展开面板与球体 / 屏幕底缘（安全区内）的垂直间距。
  static const double kLandscapeVerticalGap = 10.0;

  /// Pad 横屏分档判定（批次35）：横屏 + 视口最短边 ≥
  /// [kLandscapePadBreakpoint]。
  ///
  /// **同源不变量**：Dock 布局（本文件选档）与 app.dart 两处避让注入
  /// （一级页 / 二级页 `padding.right`）共用本函数——壳与内容判据必须
  /// 同源，否则会出现「Pad 壳装手机内容」的避让错位。
  static bool isPadLandscape(BuildContext context) =>
      MediaQuery.orientationOf(context) == Orientation.landscape &&
      MediaQuery.sizeOf(context).shortestSide >= kLandscapePadBreakpoint;

  // ── 页面内容纵向滚动脉冲广播（批次36，「展开态滑动内容坍缩」信号）──

  /// 页面内容纵向滚动脉冲（批次36）：单调递增计数，每次页面内容发生纵向
  /// 滚动 +1（事件语义，非布尔量）。
  ///
  /// **发布方**：app.dart 在主布局内容 / 二级路由（MaterialApp builder 的
  /// Navigator 外层）挂 `NotificationListener<ScrollNotification>`，捕获纵向
  /// `ScrollUpdateNotification` 时调 [notifyContentScrolled]。
  /// **订阅方**：本 Dock 横屏展开态（[_onContentScrollPulse]），收到脉冲即
  /// 坍缩展开体（球保持）——用户口径「展开播放器时，滑动内容坍缩」。
  ///
  /// **选型论证（为什么不用各页已有的 `_contentScrolled`）**：那些是
  /// [ContentScrollSignal] 泵入的**页面私有** `ValueNotifier<bool>`，Dock
  /// 拿不到引用（且不改页面文件是本任务约束）；其口径「已离开顶部」在
  /// 回顶时复位，无法表达「滚动发生」的瞬时事件。计数器脉冲天然事件化、
  /// 与页面完全解耦，一处广播多处订阅（后续顶栏收窄等需求可复用）。
  ///
  /// **「球区手势不算内容滚动」由结构保证**：Dock 自身（球 / 纵条 / 展开体）
  /// 是内容层的 Stack 兄弟层，其手势不产生 ScrollNotification、也不经过
  /// 内容层外层的 listener——无需额外过滤，见 [_buildLandscapeDock] 分层。
  static final ValueNotifier<int> contentScrollPulse = ValueNotifier<int>(0);

  /// 页面内容发生纵向滚动时的广播入口（app.dart 侧调用，批次36）。
  static void notifyContentScrolled() =>
      contentScrollPulse.value = contentScrollPulse.value + 1;

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

  // ── 横屏右纵条私有几何（批次35）：由 [GlassDockPlayer] 公开常量派生 ──

  /// 展开体**靠球侧**边缘距贴边侧屏缘的距离 = 球体靠球侧边缘
  /// = 边距 + (纵条宽 − 球径)/2 + 球径。
  ///
  /// 贴右（默认）时即「右缘距屏右」；批次36 支持贴左，同一数值镜像为
  /// 「左缘距屏左」——展开体始终从球体向**内侧**伸出，方向由宿主换算，
  /// 不需要左右两套几何。展开体悬浮覆盖在纵条内侧边缘之上（纵条层后
  /// 渲染，玻璃盖住展开体靠球端）。
  static const double _kLandscapeControlsRight =
      GlassDockPlayer.kLandscapeRailRightMargin +
      (GlassDockPlayer.kLandscapeRailWidth -
              GlassDockPlayer.kLandscapeBallSize) /
          2 +
      GlassDockPlayer.kLandscapeBallSize;

  /// Pad 档展开体**靠球侧**边缘距贴边侧屏缘的距离（Pad 档几何，推导公式同
  /// [_kLandscapeControlsRight]；手机档逐字节不变，贴左时同样镜像复用）。
  static const double _kLandscapeControlsRightPad =
      GlassDockPlayer.kLandscapeRailRightMargin +
      (GlassDockPlayer.kLandscapeRailWidthPad -
              GlassDockPlayer.kLandscapeBallSizePad) /
          2 +
      GlassDockPlayer.kLandscapeBallSizePad;

  /// 横屏纵条内导航项之间的纵向间距（手机横屏档）。
  static const double _kLandscapeNavItemGap = 4.0;

  /// Pad 档导航项之间的纵向间距（手机档 4 上浮一档）。
  static const double _kLandscapeNavItemGapPad = 6.0;

  /// 横屏纵条容器水平 padding（手机横屏档 4；纵条宽 = 项径足额 + 2×本值）。
  static const double _kLandscapeRailPaddingH = 4.0;

  /// Pad 档纵条容器水平 padding（手机档 4 上浮一档）。
  static const double _kLandscapeRailPaddingHPad = 6.0;

  /// 横屏导航项足径 / 压缩下限（手机横屏档：高度预算充足时足额 44，
  /// 项数多 / 矮视口逐档压缩，下限 28）。
  static const double _kLandscapeNavItemFullSize = 44.0;
  static const double _kLandscapeNavItemMinSize = 28.0;

  /// Pad 档导航项足径（手机档 44 上浮一档；压缩下限沿用
  /// [_kLandscapeNavItemMinSize]——Pad 横屏高度充裕踩不到下限）。
  static const double _kLandscapeNavItemFullSizePad = 48.0;

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

  /// 横屏首次布局修正标记（批次35）：initState 期读不到 MediaQuery
  /// （继承依赖未就绪），「仅播放器形态恒展开」（竖屏二级页语义）的
  /// 横屏复位改在 [didChangeDependencies] 首帧前一次性完成。
  bool _landscapeInitDone = false;

  // ── 横屏展开态「点外坍缩 / 滑动坍缩」屏障手势状态（批次36）──
  //
  // 屏障是 translucent Listener（不参与手势竞技场、不收 recognizer），
  // 只跟踪「首个按下的指针」：移动超 slop 判拖拽（= 滑动内容）、抬起未超
  // 判点击（= 点外部）。多指针时忽略次级指针（保持单指针语义简单）。
  // 详见 [_buildLandscapeDismissBarrier]。

  /// 屏障上首个按下的全局位置（null = 无按下中的指针）。
  Offset? _barrierDownPosition;

  /// 本次按下是否已判定为拖拽（超 slop，已坍缩；抬起时不再重复触发）。
  bool _barrierGestureIsDrag = false;

  @override
  void initState() {
    super.initState();
    // 仅播放器形态恒展开（二级 push 路由页，用户口径），见字段注释。
    // 横屏形态下由 didChangeDependencies 复位为「播放球初始坍缩」
    // （横屏展开语义：点击展开 / 点外坍缩）。
    if (!widget.showNav) _controlsExpanded = true;
    // 状态联动（单展开不变量的反向闭环）：导航展开 ⇒ 播放器工具强制收起。
    // 正向闭环（播放器工具展开 ⇒ 导航坍缩）在 [_expandControls] 中经
    // onNavExpandedChanged 回调完成。两个展开态不得同时存在，否则总宽
    // 超出屏宽。
    widget.navExpanded.addListener(_onNavExpandedChanged);
    // 页面内容纵向滚动脉冲（批次36）：展开态收到即坍缩展开体（横屏限定，
    // 竖屏仅播放器形态的「恒展开」语义不受影响）。
    GlassDockPlayer.contentScrollPulse.addListener(_onContentScrollPulse);
    // 批次36：横屏悬浮 Dock 贴边方向（左/右）——设置页写全局 ValueNotifier
    // 后即时重建（左右 Positioned 约束互换，展开态等交互状态保留）。
    kLandscapeDockSide.addListener(_onDockSideChanged);
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 横屏首次布局：把「仅播放器形态恒展开」（竖屏二级页语义）复位为
    // 横屏播放球初始坍缩态——横屏形态定义为「播放球（点击横向展开，
    // 点击外部即坍缩）」，纵条常驻形态是球而非展开体。initState 期不能
    // 读 MediaQuery（继承依赖未就绪），故在此一次性修正（仅首次，
    // 不覆盖用户后续操作）。
    if (_landscapeInitDone) return;
    _landscapeInitDone = true;
    if (_controlsExpanded &&
        MediaQuery.orientationOf(context) == Orientation.landscape) {
      setState(() => _controlsExpanded = false);
    }
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
    GlassDockPlayer.contentScrollPulse.removeListener(_onContentScrollPulse);
    kLandscapeDockSide.removeListener(_onDockSideChanged);
    _switchSettle.dispose();
    _switchDx.dispose();
    _dragReturnSettle.dispose();
    super.dispose();
  }

  /// 页面内容纵向滚动脉冲回调（批次36，「展开态滑动内容坍缩」）：
  /// 横屏 + 展开态收到脉冲 → 坍缩展开体（球保持）。
  ///
  /// 竖屏不响应：竖屏仅播放器形态（二级页）是**恒展开**语义（批次24），
  /// 滚动不参与其状态；竖屏一级页的展开/收起仍走既有单展开闭环。
  /// 折叠态与旋转中的守卫：未展开时纯 no-op（脉冲 ~60fps 高频，回调
  /// 必须极廉价，不 setState）。
  void _onContentScrollPulse() {
    if (!mounted || !_controlsExpanded) return;
    if (MediaQuery.orientationOf(context) != Orientation.landscape) return;
    setState(() => _controlsExpanded = false);
  }

  /// 横屏展开体坍缩（点外 / 滑动内容共用入口，批次36）：只改状态，
  /// 动画由 AnimatedSize 既有 260ms 参数收敛。不发声反馈——滚动坍缩是
  /// 滚动的副作用，点外坍缩沿用批次35 的无反馈口径。
  void _collapseLandscapeControls() {
    if (!_controlsExpanded) return;
    setState(() => _controlsExpanded = false);
  }

  /// 悬浮 Dock 贴边方向变化（批次36，设置页 → [kLandscapeDockSide]）：
  /// 仅重建布局（左右 Positioned 约束互换），不改展开态 / 导航态——
  /// 所有几何都在布局期按当前方向重新推导，状态无方向语义，无需重置。
  void _onDockSideChanged() {
    if (mounted) setState(() {});
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
    // 横屏：导航恒纵排（全部可见项），不参与竖屏单展开闭环——
    // navExpanded 变化不驱动播放球展开态（横屏展开/坍缩只由点球 /
    // 点展开体外部驱动，见 _toggleLandscapeControls）。
    if (MediaQuery.orientationOf(context) == Orientation.landscape) return;
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

  /// 横屏播放球点击：展开 ↔ 坍缩（批次35，横屏形态语义）。
  ///
  /// 与竖屏的差异：竖屏播放器工具的展开走 [_expandControls]（同时请求
  /// 导航坍缩让位，单展开不变量），收起只经「点坍缩导航圆 / 切 tab」闭环；
  /// 横屏导航恒纵排、展开体悬浮覆盖不推挤导航项，故球体自身即可双向
  /// 切换，且不触碰 navExpanded（避免横屏操作污染竖屏单展开状态——
  /// 旋转回竖屏后 Dock 恢复「打开前的那个唯一展开组件」，可预期）。
  void _toggleLandscapeControls() {
    AppHaptics.click();
    setState(() => _controlsExpanded = !_controlsExpanded);
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

    // 横屏壳层判定用**纯方向**（项目约定，批次35）：横屏 → 右侧纵条形态；
    // 竖屏 → 既有底部横条逻辑（逐字节不变）。
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

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
      child: isLandscape
          ? _buildLandscapeDock(player, song, isPlaying, duration, tabConfig)
          : SafeArea(
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

  // ── 横屏右纵条 + 独立播放球（批次35 纵条化 / 批次36 球独立化）──

  /// 横屏形态：**独立播放球** + 导航纵条（球与纵条分离）+ 播放球横向
  /// 展开。贴边方向由 [kLandscapeDockSide] 决定（批次36，默认右）——
  /// 本方法只有一份布局，各层用 `edgeStart/edgeEnd` 把「距贴边侧的距离」
  /// 映射成 left / right 约束，几何在贴左时自动镜像。
  ///
  /// 四层 Stack（后渲染者命中测试优先）：
  /// 1. **点外坍缩屏障**（仅展开态，批次36 改 translucent Listener）：命中
  ///    路径放行下层（页面滚动/点击不被吸收），自身据此坍缩；见
  ///    [_buildLandscapeDismissBarrier]；
  /// 2. **展开体层**：靠球侧边缘贴球体内侧边缘（悬浮覆盖在页面之上，
  ///    不推挤纵条），AnimatedSize 以该边缘锚定向内侧生长（球径 → 展开
  ///    宽，手机档 42→270dp / Pad 档 48→320dp；贴左时向左缘锚定、向右
  ///    生长）；
  /// 3. **独立播放球层**（批次36）：与纵条分离的独立悬浮元素，Positioned
  ///    定位在纵条下方（间距 [GlassDockPlayer.kLandscapeBallRailGap]）、
  ///    同右距同列（球心对齐纵条中线，共享同一右侧避让带）；
  /// 4. **导航纵条层**（仅存在可见导航项时渲染）：玻璃胶囊内只剩导航项
  ///    纵排（球独立后不再嵌球）；Positioned(top/right) 显式定位。
  ///
  /// **组合体垂直居中（批次36）**：纵条 + 球距 + 球作为一个组合体整体在
  /// 安全区内垂直居中（球独立后纵条上移、球落在纵条下方）；无导航形态
  /// （二级页仅播放器 / 可见 tab 为空）不渲染纵条，球单独居中。展开体层
  /// 与球体同垂直中心（top = 球心 − 球径/2）——横屏展开体从球体向左伸出。
  ///
  /// **Pad 横屏分档（批次35）**：入口处按 [GlassDockPlayer.isPadLandscape]
  /// （横屏 + 最短边 ≥ 600）选档——Pad 档球径/项径/间距/纵条宽/展开宽/
  /// 球距整体上浮一档；手机横屏档（最短边 < 600）选档结果与改造前逐字节
  /// 一致。判定与 app.dart 避让注入同源（防「Pad 壳装手机内容」错位）。
  Widget _buildLandscapeDock(
    PlayerProvider player,
    dynamic song,
    bool isPlaying,
    Duration? duration,
    TabConfigProvider tabConfig,
  ) {
    final padding = MediaQuery.paddingOf(context);
    final viewport = MediaQuery.sizeOf(context);
    // Pad 横屏分档（批次35）：横屏内按视口最短边再分档——最短边 ≥ 600
    // 命中 Pad 档（球/项径/间距/纵条宽/展开宽/球距整体上浮一档）；手机横屏
    // （最短边 < 600，含全部手机横屏形态）走手机档，数值逐字节不变。
    // 判定与 app.dart 避让注入同源（GlassDockPlayer.isPadLandscape）。
    final isPad = GlassDockPlayer.isPadLandscape(context);
    final ballSize = isPad
        ? GlassDockPlayer.kLandscapeBallSizePad
        : GlassDockPlayer.kLandscapeBallSize;
    final ballCoverSize = isPad
        ? GlassDockPlayer.kLandscapeBallCoverSizePad
        : GlassDockPlayer.kLandscapeBallCoverSize;
    final railWidth = isPad
        ? GlassDockPlayer.kLandscapeRailWidthPad
        : GlassDockPlayer.kLandscapeRailWidth;
    final railPaddingH = isPad
        ? _kLandscapeRailPaddingHPad
        : _kLandscapeRailPaddingH;
    final controlsWidth = isPad
        ? GlassDockPlayer.kLandscapeControlsWidthPad
        : GlassDockPlayer.kLandscapeControlsWidth;
    final navItemGap = isPad ? _kLandscapeNavItemGapPad : _kLandscapeNavItemGap;
    // 球与纵条的垂直间距（批次36 公开常量，手机档 12 / Pad 档 14）：
    // 球独立后取代原胶囊内「导航与球间距」私有常量（已废止）。
    final ballRailGap = isPad
        ? GlassDockPlayer.kLandscapeBallRailGapPad
        : GlassDockPlayer.kLandscapeBallRailGap;
    final controlsEdge = isPad
        ? _kLandscapeControlsRightPad
        : _kLandscapeControlsRight;
    // 批次36：悬浮 Dock 贴边方向（默认右 = 改造前行为逐字节一致）。
    // 左右镜像不复制布局：所有层共用同一份构建代码，只把「距贴边侧的
    // 距离」按方向映射成 left / right 约束（非贴边侧传 null 不约束）。
    final dockLeft = kLandscapeDockSide.value == LandscapeDockSide.left;
    double? edgeStart(double inset) => dockLeft ? inset : null;
    double? edgeEnd(double inset) => dockLeft ? null : inset;
    final allTabs = tabConfig.visibleTabs;
    // 项径自适应（横屏矮视口高度预算，见 [_landscapeNavItemSize]）。
    final navItemSize = _landscapeNavItemSize(
      allTabs.length,
      viewport,
      padding,
      isPad,
    );
    // 批次36：纵条只剩导航项（球独立）——无导航（二级页仅播放器形态，
    // 或可见 tab 为空）时整个纵条不渲染。
    final hasRail = widget.showNav && allTabs.isNotEmpty;
    // 导航区高（项数 × 项径 + 项间距；不再含球与球间距）。
    final navSectionHeight = hasRail
        ? allTabs.length * navItemSize + (allTabs.length - 1) * navItemGap
        : 0.0;
    // 纵条高 = 垂直 padding(16) + 导航区（胶囊内无球）。
    final railHeight = hasRail ? 16 + navSectionHeight : 0.0;
    // 组合体（纵条 + 球距 + 球）整体垂直居中：球独立后纵条随组合体上移，
    // 球落在纵条下方同一避让带内；无纵条形态组合体只剩球，单独居中。
    final groupHeight = railHeight + (hasRail ? ballRailGap : 0.0) + ballSize;
    final groupTop =
        padding.top +
        (viewport.height - padding.top - padding.bottom - groupHeight) / 2;
    final ballTop = groupTop + (hasRail ? railHeight + ballRailGap : 0.0);
    final ballCenterY = ballTop + ballSize / 2;
    // 球层距**贴边侧**屏缘（含该侧系统安全区）：球心对齐纵条中线（同列
    // 共享避让带）= 该侧 padding + 边距 + (纵条宽 − 球径)/2。
    // 批次36 起各层 Positioned 均显式叠加贴边侧 padding（系统安全区）：
    // 批次35 的展开体层漏加，安全区 inset > 0 的设备上展开体会压住球体
    // padding dp——此处一并修正；贴左时镜像为 padding.left，同一公式。
    final edgePadding = dockLeft ? padding.left : padding.right;
    final ballEdge =
        edgePadding +
        GlassDockPlayer.kLandscapeRailRightMargin +
        (railWidth - ballSize) / 2;
    final railEdge = edgePadding + GlassDockPlayer.kLandscapeRailRightMargin;
    return Stack(
      children: [
        // 1) 点外坍缩 / 滑动坍缩屏障（仅展开态；translucent 放行下层手势）
        if (_controlsExpanded)
          Positioned.fill(child: _buildLandscapeDismissBarrier()),
        // 2) 展开体层（批次39 分两形态）：
        //    二级页（showNav:false，无导航纵条）→ **纵向展开**：面板贴
        //    纵条同侧边缘、从球体下方竖向生长（top = 球底 + 间距，bottom
        //    钉在底部安全区上方 + 间距——固定高度区域，封面 Expanded 吃
        //    剩余高，任何视口不溢出）；
        //    一级页（showNav:true）→ 横向控件条：靠球侧边缘贴球体内侧
        //    边缘、与球体同垂直中心。
        if (!widget.showNav)
          Positioned(
            left: edgeStart(
              edgePadding + GlassDockPlayer.kLandscapeRailRightMargin,
            ),
            right: edgeEnd(
              edgePadding + GlassDockPlayer.kLandscapeRailRightMargin,
            ),
            top: ballTop + ballSize + GlassDockPlayer.kLandscapeVerticalGap,
            bottom: padding.bottom + GlassDockPlayer.kLandscapeVerticalGap,
            child: AnimatedSize(
              duration: _kMorphDuration,
              curve: Curves.easeOutCubic,
              // 纵向生长：顶缘固定在球体下方，向下展开/坍缩
              alignment: Alignment.topCenter,
              child: _controlsExpanded
                  ? _buildLandscapeVerticalControlsBody(
                      player,
                      song,
                      duration,
                    )
                  : const SizedBox(width: 0, height: 0),
            ),
          )
        else
          Positioned(
            left: edgeStart(padding.left + controlsEdge),
            right: edgeEnd(padding.right + controlsEdge),
            top: ballCenterY - ballSize / 2,
            child: AnimatedSize(
              duration: _kMorphDuration,
              curve: Curves.easeOutCubic,
              // 锚定靠球侧边缘：贴右时右缘固定、向左生长；贴左时左缘固定、
              // 向右生长——两个方向都从球体向**内侧**伸出，不顶出纵条
              // （同竖屏播放器部分）。
              alignment: dockLeft ? Alignment.centerLeft : Alignment.centerRight,
              child: _controlsExpanded
                  ? _buildLandscapeControlsBody(
                      player,
                      song,
                      duration,
                      ballSize: ballSize,
                      controlsWidth: controlsWidth,
                    )
                  : SizedBox(width: 0, height: ballSize),
            ),
          ),
        // 3) 独立播放球层（批次36：与纵条分离，Positioned 显式定位）
        Positioned(
          left: edgeStart(ballEdge),
          right: edgeEnd(ballEdge),
          top: ballTop,
          child: _buildLandscapePlayerBall(
            player,
            song,
            isPlaying,
            duration,
            ballSize: ballSize,
            ballCoverSize: ballCoverSize,
          ),
        ),
        // 4) 导航纵条层（仅可见导航项存在时渲染；胶囊内只剩导航项纵排）
        if (hasRail)
          Positioned(
            top: groupTop,
            left: edgeStart(railEdge),
            right: edgeEnd(railEdge),
            child: LiquidGlassContainer(
              key: const ValueKey('glass_dock_landscape_rail'),
              shape: GlassShape.pill,
              padding: EdgeInsets.symmetric(
                horizontal: railPaddingH,
                vertical: 8,
              ),
              child: SizedBox(
                width: railWidth - railPaddingH * 2,
                child: _buildLandscapeNavPart(allTabs, navItemSize, navItemGap),
              ),
            ),
          ),
      ],
    );
  }

  /// 横屏展开态「点外坍缩 / 滑动内容坍缩」屏障（批次36 重写）。
  ///
  /// **为什么从批次35 的 `GestureDetector(opaque)` 改为
  /// `Listener(translucent)`**：opaque 屏障把整屏触摸全部吸收，展开态下
  /// 页面内容**无法滚动**——用户口径「展开播放器时，滑动内容坍缩」要求
  /// 滑动内容时控件坍缩，前提是手势能到达内容层。translucent 下屏障只把
  /// 自身加入命中路径（不阻断下层命中测试）：页面滚动控件照常赢下手势
  /// 竞技场、内容真实滚动；同时屏障的 [Listener] 仍收到同一指针流
  /// （Listener 不注册 recognizer、不参与竞技场），据此坍缩。
  ///
  /// 手势判定（原始指针流，不抢内容手势）：
  /// - 按下记全局位置（只跟踪首个指针，忽略次级指针）；
  /// - 移动超过 [kTouchSlop] → 判为拖拽（= 滑动内容）→ 坍缩；
  /// - 抬起且未超 slop → 判为点击（= 点展开体外部）→ 坍缩；
  /// - 取消 → 只清状态不坍缩（手势被系统仲裁掉，无用户意图）。
  ///
  /// **语义变更（批次36 论证后接受）**：点击不再被屏障「吞掉」——点页面
  /// 可交互元素时，元素点击与坍缩**同时**发生（批次35 旧语义需点两次：
  /// 第一次只坍缩、元素不响应）；点空白处仍只有坍缩。这与「滑动内容
  /// 坍缩」的用户意图同向：与页面内容的任何交互都放行并收起播放控件。
  /// 坍缩的补充分量（页面滚动广播）见 [GlassDockPlayer.contentScrollPulse]
  /// ——程序化滚动（非手势）也走那条路径坍缩。
  ///
  /// 球 / 纵条 / 展开体在本层之上且均不 translucent，落在它们上面的指针
  /// 根本不进入本屏障的命中路径——「球上发起的滚动手势不算内容滚动」
  /// 「展开态点球 / 导航项行为不变」由结构保证。
  Widget _buildLandscapeDismissBarrier() {
    return Listener(
      key: const ValueKey('glass_dock_landscape_dismiss_barrier'),
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        // 只跟踪首个按下的指针；次级指针（双指）忽略。
        if (_barrierDownPosition != null) return;
        _barrierDownPosition = event.position;
        _barrierGestureIsDrag = false;
      },
      onPointerMove: (event) {
        final down = _barrierDownPosition;
        if (down == null || _barrierGestureIsDrag) return;
        if ((event.position - down).distance > kTouchSlop) {
          // 超 slop = 滑动内容（页面滚动控件已赢下竞技场、内容在滚）→ 坍缩。
          _barrierGestureIsDrag = true;
          _collapseLandscapeControls();
        }
      },
      onPointerUp: (event) {
        final down = _barrierDownPosition;
        _barrierDownPosition = null;
        // 未超 slop 的抬起 = 点击（点展开体外部）→ 坍缩；拖拽已在 move
        // 中坍缩过，不重复。
        if (down == null || _barrierGestureIsDrag) return;
        _collapseLandscapeControls();
      },
      onPointerCancel: (event) {
        // 手势被系统仲裁掉（来电 / 竞争）：清状态，不坍缩。
        _barrierDownPosition = null;
        _barrierGestureIsDrag = false;
      },
    );
  }

  /// 横屏导航项径自适应：足额 44dp（手机档）；项数多时按「纵条可用高度」
  /// 逐档压缩，保证横屏矮视口下组合体（纵条 + 球距 + 球）不溢出。
  /// 可用高 = 视口高 − 上下安全区 − 纵条垂直 padding(16) − 球与纵条间距
  ///  − 球径；剩余预算在各项 + 间距间均分，下限 28dp。
  ///
  /// 【Pad 分档点】（批次35落地，批次36 球距换档）：[isPad]（= 宿主
  /// [GlassDockPlayer.isPadLandscape] 判定结果，最短边 ≥ 600）时足额档 /
  /// 上限上浮一档（44→48），项间距 / 球距 / 球径同步换 Pad 档常量——
  /// Pad 横屏可视高度更充裕（~600-800），足额 48dp 不溢出且更舒展；
  /// 手机横屏档（isPad = false）公式与数值逐字节不变。
  double _landscapeNavItemSize(
    int count,
    Size viewport,
    EdgeInsets padding,
    bool isPad,
  ) {
    final fullSize = isPad
        ? _kLandscapeNavItemFullSizePad
        : _kLandscapeNavItemFullSize;
    final gap = isPad ? _kLandscapeNavItemGapPad : _kLandscapeNavItemGap;
    final ballSize = isPad
        ? GlassDockPlayer.kLandscapeBallSizePad
        : GlassDockPlayer.kLandscapeBallSize;
    // 球独立后（批次36）：球距用公开常量 kLandscapeBallRailGap(12/14)，
    // 替代原胶囊内「导航与球间距」私有常量（8/10，已废止）——组合体必须
    // 在视口内完整居中，预算口径与实际渲染结构同源。
    final ballRailGap = isPad
        ? GlassDockPlayer.kLandscapeBallRailGapPad
        : GlassDockPlayer.kLandscapeBallRailGap;
    if (count <= 0) return fullSize;
    final budget =
        viewport.height -
        padding.top -
        padding.bottom -
        16 -
        ballRailGap -
        ballSize;
    final perItem = (budget - (count - 1) * gap) / count;
    return perItem.clamp(_kLandscapeNavItemMinSize, fullSize);
  }

  /// 横屏导航部分：可见 tab **纵向排列**（复用竖屏 [_DockNavItem] 配方，
  /// 圆形 + 选中态 secondaryContainer 圆底 + filled 图标）。
  /// 横屏导航恒展开（纵排不占横向预算，无坍缩态），不参与竖屏单展开闭环。
  ///
  /// [itemGap] 由宿主按 Pad 分档传入（手机档 4 / Pad 档 6）——必须与
  /// [_buildLandscapeDock] 的导航区高（= 项径预算同源推算）一致，否则
  /// 「预算按 6、渲染按 4」会让组合体垂直居中偏移、展开体与球体错位。
  Widget _buildLandscapeNavPart(
    List<TabItem> tabs,
    double itemSize,
    double itemGap,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tabs.length; i++) ...[
          if (i > 0) SizedBox(height: itemGap),
          KeyedSubtree(
            key: ValueKey('glass_dock_landscape_nav_${tabs[i].id}'),
            child: _DockNavItem(
              tab: _dockTabFor(tabs[i].id),
              label: tabs[i].label,
              selected: widget.selectedTabId == tabs[i].id,
              width: itemSize,
              height: itemSize,
              margin: EdgeInsets.zero,
              onTap: () {
                AppHaptics.tick();
                widget.onSelectTab(tabs[i].id);
              },
            ),
          ),
        ],
      ],
    );
  }

  /// 横屏播放球：42dp（手机档）/ 48dp（Pad 档）玻璃球（与竖屏播放球
  /// 同源配方：外周进度环 + 中央圆形封面缩略图 / 音符占位 + 播放态
  /// 指示），点击横向展开/坍缩；保留竖屏同款上滑拖拽（拖拽展开
  /// FullPlayer，松手三阈值长边口径见 [_onPlayerDragEnd]）。
  ///
  /// **批次36 球独立化**：本球由宿主以 Positioned 定位为**独立悬浮元素**
  /// （纵条下方、同右距同列共享避让带），不再嵌在纵条玻璃胶囊内——与
  /// 竖屏播放球的交互语义（点击展开 / 独立可点 / 上滑拖拽）保持一致，
  /// 即用户口径「悬浮播放器球独立，与竖屏时一致」。
  ///
  /// [ballSize] / [ballCoverSize] 由宿主按 Pad 分档传入（批次35）。
  Widget _buildLandscapePlayerBall(
    PlayerProvider player,
    dynamic song,
    bool isPlaying,
    Duration? duration, {
    required double ballSize,
    required double ballCoverSize,
  }) {
    // RepaintBoundary 隔离：进度环 ~200ms 重绘不外溢（同竖屏口径）。
    return RepaintBoundary(
      child: Builder(
        builder: (buttonContext) {
          // 上滑展开（P0-1）：song == null 不注册拖拽回调（不抢手势）。
          final canDrag = song != null;
          return GestureDetector(
            key: const ValueKey('glass_dock_landscape_ball'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: canDrag
                ? (d) => _onPlayerDragStart(buttonContext, d)
                : null,
            onVerticalDragUpdate: canDrag ? _onPlayerDragUpdate : null,
            onVerticalDragEnd: canDrag ? _onPlayerDragEnd : null,
            onVerticalDragCancel: canDrag ? _onPlayerDragCancel : null,
            child: _buildCircle(
              song,
              isPlaying,
              duration,
              player,
              size: ballSize,
              coverSize: ballCoverSize,
              iconSize: 20,
              onTap: _toggleLandscapeControls,
            ),
          );
        },
      ),
    );
  }

  /// 横屏展开体：封面小图（外周进度环）+ 标题/歌手 + 上一曲/播放暂停/
  /// 下一曲（复用竖屏 [_buildControlsCapsule] 的控件与 [PlayerProvider]
  /// 交互语义，横向排布；封面 / 歌名点击进播放页）。
  /// 不注册左右滑切歌（横屏展开体窄条形态，手势让位给点外坍缩屏障；
  /// 竖屏胶囊的 onHorizontalDrag* 路径不变）。
  ///
  /// [ballSize] / [controlsWidth] 由宿主按 Pad 分档传入（批次35）：展开体
  /// 与球体同高，宽度 = 档位展开宽（手机档 270 / Pad 档 320）。
  Widget _buildLandscapeControlsBody(
    PlayerProvider player,
    dynamic song,
    Duration? duration, {
    required double ballSize,
    required double controlsWidth,
  }) {
    final cs = Theme.of(context).colorScheme;
    return LiquidGlassContainer(
      key: const ValueKey('glass_dock_landscape_controls'),
      shape: GlassShape.pill,
      padding: const EdgeInsets.fromLTRB(6, 0, 4, 0),
      child: SizedBox(
        height: ballSize,
        width: controlsWidth - 10,
        child: Row(
          children: [
            // 封面小图（外周进度环，与竖屏胶囊同一 painter 口径）：点击进播放页。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: song == null ? null : () => openFullPlayer(context),
              child: SizedBox(
                width: _kCapsuleCoverSize + _kRingStroke * 2,
                height: _kCapsuleCoverSize + _kRingStroke * 2,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: ValueListenableBuilder<Duration>(
                        valueListenable: player.positionNotifier,
                        builder: (context, position, _) {
                          final progress =
                              (duration != null && duration > Duration.zero)
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
                              // 环中心线 = 18 + 0.75：环内缘贴 36dp 封面外缘。
                              ringRadius:
                                  _kCapsuleCoverSize / 2 + _kRingStroke / 2,
                              trackColor: cs.onSurface.withValues(alpha: 0.15),
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
                          // 36dp 缩略图按 128px 解码（同竖屏胶囊口径）。
                          decodeCap: 128,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: _kCapsuleCoverGap),
            // 标题 / 歌手：点击进播放页。
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: song == null ? null : () => openFullPlayer(context),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song?.displayName ?? '未在播放',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      song?.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
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
                  : () => player.isPlaying ? player.pause() : player.resume(),
            ),
            _DockIconButton(
              icon: Icons.skip_next,
              tooltip: '下一曲',
              onTap: song == null ? null : player.next,
            ),
          ],
        ),
      ),
    );
  }

  /// 二级页（仅播放器形态）横屏**纵向展开**播放面板（批次39）。
  ///
  /// 形态（用户口径「横屏二级页面悬浮播放器纵向展开显示」）：贴边玻璃
  /// 纵排面板——封面（吃剩余高、上限 140dp）在上、歌名/歌手居中、
  /// 上一曲/播放/下一曲传输钮在下；与一级页的横向控件条
  /// （[_buildLandscapeControlsBody]）共用交互语义：封面/歌名点击进
  /// 播放页、传输钮走 [PlayerProvider]、点球或点外部（屏障）坍缩、
  /// 页面滚动脉冲坍缩。定位由 [_buildLandscapeDock] 的 Positioned 顶层
  /// 完成（top=球底+间距、bottom=底部安全区+间距），本方法只管面板
  /// 内部——高度由父级约束固定，任何视口不溢出（极端矮视口下封面
  /// 相应收窄，标题/按钮行高约 110dp 为硬下限）。
  Widget _buildLandscapeVerticalControlsBody(
    PlayerProvider player,
    dynamic song,
    Duration? duration,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isPad = GlassDockPlayer.isPadLandscape(context);
    final panelWidth = isPad
        ? GlassDockPlayer.kLandscapeVerticalControlsWidthPad
        : GlassDockPlayer.kLandscapeVerticalControlsWidth;
    return LiquidGlassContainer(
      key: const ValueKey('glass_dock_landscape_controls_vertical'),
      shape: GlassShape.pill,
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        width: panelWidth - 24,
        child: Column(
          children: [
            // 封面：吃掉标题/按钮之外的剩余高（上限 140dp），点击进播放页。
            Expanded(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final side = constraints.biggest.shortestSide.clamp(
                      0.0,
                      140.0,
                    );
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: song == null ? null : () => openFullPlayer(context),
                      child: SizedBox(
                        width: side,
                        height: side,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: PlayerArtworkImage(
                            artworkUri: song?.artworkUri as String?,
                            fallbackFilePath: song?.localPath as String?,
                            fit: BoxFit.cover,
                            iconSize: 36,
                            backgroundColor: cs.surfaceContainerHighest,
                            iconColor: cs.onSurfaceVariant,
                            // 面板封面比球内缩略图大，解码上限放宽到 256px。
                            decodeCap: 256,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 歌名 / 歌手：居中，点击进播放页。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: song == null ? null : () => openFullPlayer(context),
              child: Column(
                children: [
                  Text(
                    song?.displayName ?? '未在播放',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    song?.artist ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 传输钮：与横向控件条同一 [_DockIconButton] 配方，横排居中。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                      : () => player.isPlaying ? player.pause() : player.resume(),
                ),
                _DockIconButton(
                  icon: Icons.skip_next,
                  tooltip: '下一曲',
                  onTap: song == null ? null : player.next,
                ),
              ],
            ),
          ],
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
    // 长边口径（批次35，方案 P0-4）：横屏矮视口下按屏高（短边）的 20%
    // 过灵敏（如 800×400 横屏阈值仅 80px，轻扫即展开）。统一按长边
    // max(宽, 高) 计算——竖屏时长边即屏高，数值不变。
    final viewport = MediaQuery.sizeOf(context);
    final screenHeight = max(viewport.width, viewport.height);
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
  ///
  /// [size] / [coverSize] / [iconSize] 支持横屏 42dp 球（批次35；竖屏
  /// 默认值与改动前逐项一致）。[onTap] 非空时替代默认的 [_expandControls]
  /// ——横屏球体用 [_toggleLandscapeControls] 双向切换语义（竖屏胶囊
  /// 自身不响应 tap 收起的收紧语义不适用于横屏）。
  Widget _buildCircle(
    dynamic song,
    bool isPlaying,
    Duration? duration,
    PlayerProvider player, {
    double size = _kButtonSize,
    double coverSize = _kCircleCoverSize,
    double iconSize = 22,
    VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: song == null ? null : (onTap ?? _expandControls),
      child: LiquidGlassContainer(
        shape: GlassShape.circle,
        child: SizedBox(
          width: size,
          height: size,
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
                      size: Size.square(size),
                      painter: _ProgressRingPainter(
                        progress: progress,
                        stroke: _kRingStroke,
                        // 环贴按钮外缘：环中心线 = size/2 − 0.75 − 0.5，
                        // 环外缘 size/2 − 0.5 < size/2 不出界（52dp 口径下
                        // 环内缘 24.0 距 46dp 封面外缘 1dp，封面充满圆内）。
                        ringRadius: size / 2 - _kRingStroke / 2 - 0.5,
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
                  size: iconSize,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                )
              else
                _buildCircleArtwork(song, isPlaying, cs, coverSize: coverSize),
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
  ///
  /// [coverSize] 支持横屏 42dp 球（36dp 封面，批次35；竖屏默认 46dp 不变）。
  Widget _buildCircleArtwork(
    dynamic song,
    bool isPlaying,
    ColorScheme cs, {
    double coverSize = _kCircleCoverSize,
  }) {
    Widget cover = ClipOval(
      child: SizedBox(
        width: coverSize,
        height: coverSize,
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
            width: coverSize,
            height: coverSize,
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
            width: coverSize,
            height: coverSize,
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
///
/// [height] / [margin] 为横屏纵排形态开放（批次35：44dp 圆形、零外边距）；
/// 竖屏默认值与改动前逐项一致。
class _DockNavItem extends StatelessWidget {
  const _DockNavItem({
    required this.tab,
    required this.label,
    required this.selected,
    required this.width,
    required this.onTap,
    this.height = 44,
    this.margin = const EdgeInsets.symmetric(horizontal: 1),
  });

  final _DockTab tab;
  final String label;
  final bool selected;

  /// 图标块宽度（dp），左右各另有 1dp 外边距。
  final double width;

  /// 图标块高度（dp）。
  final double height;

  /// 图标块外边距（竖屏横排为左右各 1dp；横屏纵排为零）。
  final EdgeInsetsGeometry margin;

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
          height: height,
          margin: margin,
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
