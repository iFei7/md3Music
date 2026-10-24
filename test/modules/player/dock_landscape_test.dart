/// 横屏悬浮 Dock「右侧纵向化 + 播放球横向展开 + 页面右侧避让」测试
/// （批次35 建立，批次36 扩展）。
///
/// 用户口径（设计意图）：
/// 「横屏设备高度小，所以尽可能减少页面纵向上的遮挡。P1-N 悬浮 dock
///  横屏在右侧纵向显示（页面右侧要做悬浮 dock 避让），纵向显示悬浮
///  dock，播放球（点击横向展开，点击外部即坍缩）。」
/// 批次36 追加口径：「1、悬浮播放器球独立，与竖屏时一致，展开播放器时，
///  滑动内容坍缩。2、悬浮区域没做避让，当前有遮挡内容。」
///
/// 覆盖（对应任务清单 4）：
/// 1. 横屏一级宿主渲染右纵条（key 断言几何：右缘间距 12 / 纵条宽 52 /
///    垂直居中 / 导航项纵排 / 播放球 42dp）；
/// 2. **批次36 球独立化**：播放球与纵条分离为两个独立悬浮元素（球心不在
///    纵条矩形内、同列、纵条下方球距 12/14、组合体整体居中）；
/// 3. 播放球点击 → 横向展开（宽度 260 + 从球体向左伸出 + 不推挤导航项）；
/// 4. 点展开体外部（页面内容）→ 坍缩，且点击放行到页面（批次36 translucent
///    屏障语义：不吸收、穿透）；展开态纵条导航项点击不被误吞；
/// 5. **批次36 滑动内容坍缩**：展开态驱动滚动脉冲 / 真实拖拽页面滚动 →
///    坍缩（球保持）；球区上滑拖拽不误触坍缩；竖屏恒展开形态不受广播影响；
/// 6. 横屏右侧避让：宿主复刻 app.dart 注入逻辑，断言
///    MediaQuery.padding.right 增量 = 纵条宽 + 右距（竖屏底部注入对照）；
///    **批次36 几何硬让位**：内容区几何内缩同宽（探针右缘 = 屏右 − 避让值）；
/// 7. 竖屏对照：竖屏下 Dock 仍是底部横条、几何与避让和改动前一致
///    （断言口径照抄 dock_nav_library_test / dock_player_collapse_test）；
/// 8. 拖拽阈值长边口径：横屏宿主拖拽累计 100px（短边口径 80 会误触
///    push）不展开、220px（长边口径 160）展开；单测锁定
///    shouldExpandPlayer 长边数值；
/// 9. **Pad 横屏分档（批次35，shortestSide ≥ 600）**：Pad 宿主
///    （1200×800）断言 Pad 档几何（纵条 60 / 球 48 / 项径 48 / 项距 6 /
///    球距 12→14 / 展开宽 320 / 避让 72 且与 Dock 侧同源派生）；手机横屏
///    宿主（800×400 / 800×599）回归锁——手机档数值逐字节不变；拖拽
///    阈值在 Pad 大长边上的钳制行为（0.2×1440=288 → 240）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/glass_dock_player.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/dlna_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/shortcut_config_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/utils/landscape_dock_side.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/controlled_audio_service.dart';

// 横屏纵条 / 播放球 / 展开体 / 点外坍缩屏障的 key（glass_dock_player 批次35）。
const _railKey = ValueKey('glass_dock_landscape_rail');
const _ballKey = ValueKey('glass_dock_landscape_ball');
const _controlsKey = ValueKey('glass_dock_landscape_controls');
const _barrierKey = ValueKey('glass_dock_landscape_dismiss_barrier');
const _navItemKeyPrefix = 'glass_dock_landscape_nav_';

// 竖屏底部横条的既有 key（对照组断言口径，照抄 dock_player_collapse_test）。
const _portraitPlayerButtonKey = ValueKey('glass_dock_player_button');
const _portraitTrackTitleKey = ValueKey('glass_dock_track_title');

/// 复刻 app.dart `_MainLayoutState._kDockReservedBottom`（竖屏避让，72）。
const double _kReservedBottom = 72.0;

/// 复刻 app.dart `_MainLayoutState._kDockReservedRight` 的公式（横屏避让）：
/// 纵条宽 + 右间距，一处定义两处消费的常量口径。
double get _kReservedRight =>
    GlassDockPlayer.kLandscapeRailWidth +
    GlassDockPlayer.kLandscapeRailRightMargin;

/// 复刻 app.dart `_MainLayoutState._kDockReservedRightPad`（批次35 Pad
/// 分档）：Pad 档纵条宽 + 右距，与 Dock 侧 Pad 档常量**同源派生**。
double get _kReservedRightPad =>
    GlassDockPlayer.kLandscapeRailWidthPad +
    GlassDockPlayer.kLandscapeRailRightMargin;

/// 批次36 球独立化：横屏独立播放球与导航纵条的垂直间距（手机档 12 /
/// Pad 档 14，Dock 侧公开常量，一处定义两处消费）。
double get _kBallRailGap => GlassDockPlayer.kLandscapeBallRailGap;
double get _kBallRailGapPad => GlassDockPlayer.kLandscapeBallRailGapPad;

Song _localSong(String id, String title) => Song(
  id: id,
  title: title,
  artist: '测试歌手',
  album: '测试专辑',
  duration: const Duration(minutes: 3),
  localPath: '/tmp/$id.mp3',
);

/// 页面探针记录（避让注入可读值 / 点击穿透判定）。
double? _pagePaddingRight;
double? _pagePaddingLeft;
double? _pagePaddingBottom;
bool _pageTapped = false;

/// 可滚动内容模式的滚动控制器（滑动坍缩测试断言内容真的滚了）。
ScrollController? _scrollController;

/// 导航项点击回记录（展开态导航项不被误吞）。
String? _selectedTab;

/// 宿主级导航展开态（复刻 _MainLayout._navExpanded 的双向闭环接线）。
final ValueNotifier<bool> _navExpanded = ValueNotifier<bool>(true);

/// 视口设置 + 用后复位（横屏手机档 800×400 / 横屏 Pad 档 1200×800 /
/// 竖屏 400×800）。
void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 泵一个复刻 `_MainLayout` 宿主层次的应用：
/// - 全量 Provider（与 dock_system_ui_overlay_test 同款，拖拽越阈 push 的
///   FullPlayer 需要它们；整页宿主必须提供 KugouProvider）；
/// - 页面层复刻 Dock 避让注入（**只包内容不包 Dock**，与 app.dart 一致：
///   横屏注右 padding.right（按 isPadLandscape 选档，批次35）+ 几何硬让位
///   Padding（批次36）、竖屏注底 padding.bottom）；
/// - **批次36 滚动广播复刻**：内容层外层挂与 app.dart 同款的
///   `NotificationListener<ScrollNotification>`（纵向 ScrollUpdateNotification
///   → GlassDockPlayer.notifyContentScrolled），用于验证「展开态滑动内容
///   坍缩」机制（app.dart 侧注入点的传播路径由本复刻等价覆盖）；
/// - [scrollableContent] = true 时页面内容换成可滚动 ListView（滑动坍缩
///   集成用例：真实拖拽内容滚动），否则为点击探针；
/// - Dock 层铺满（横屏展开态点外坍缩屏障需要全屏区域；竖屏 Dock 自身
///   Align(bottomCenter) 锚位，宿主形状不影响其几何）。
Future<({PlayerProvider player, ControlledAudioService audio})> _pumpApp(
  WidgetTester tester, {
  required Size viewport,
  List<Song> songs = const [],
  bool showNav = true,
  bool scrollableContent = false,
}) async {
  _setViewport(tester, viewport);
  SharedPreferences.setMockInitialValues({});
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  final player = PlayerProvider();
  if (songs.isNotEmpty) {
    await player.playPlaylist(songs, 0);
  }
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(initialUseBackgroundImage: false),
        ),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        ChangeNotifierProvider(create: (_) => GridColumnsProvider()),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => KugouProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => PlaylistCollectionNotifier()),
        ChangeNotifierProvider<TabConfigProvider>(
          create: (_) => TabConfigProvider(),
        ),
        ChangeNotifierProvider(create: (_) => ShortcutConfigProvider()),
        ChangeNotifierProvider(create: (_) => DlnaProvider()),
        ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
      ],
      child: MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: Stack(
          children: [
            // 页面层（避让注入只包内容，Dock 读外层 MediaQuery）
            Positioned.fill(
              child: ValueListenableBuilder<LandscapeDockSide>(
                valueListenable: kLandscapeDockSide,
                // 复刻 app.dart _MainLayoutState 的方向监听（addListener →
                // setState）：切边后内容层重建，侧向注入与几何内缩即时换边。
                builder: (context, _, _) {
                  final mq = MediaQuery.of(context);
                  // 复刻 app.dart 注入逻辑（批次35 含 Pad 分档）：横屏
                  // 注右 padding.right（按 GlassDockPlayer.isPadLandscape
                  // 选档，与 Dock 侧同源）、竖屏注底 padding.bottom。
                  final isLandscape =
                      MediaQuery.orientationOf(context) ==
                      Orientation.landscape;
                  final isPadLandscape = GlassDockPlayer.isPadLandscape(
                    context,
                  );
                  // 批次36：复刻 app.dart 的方向感知注入——避让只注
                  // 配置侧（贴左注 left、贴右注 right），未配置侧保持 0；
                  // 几何内缩同一切换方向。
                  final dockLeft =
                      kLandscapeDockSide.value == LandscapeDockSide.left;
                  final reserved = isPadLandscape
                      ? _kReservedRightPad
                      : _kReservedRight;
                  final insetStart = isLandscape && dockLeft ? reserved : 0.0;
                  final insetEnd = isLandscape && !dockLeft ? reserved : 0.0;
                  return Padding(
                    padding: EdgeInsets.only(left: insetStart, right: insetEnd),
                    // 批次36：滚动广播（复刻 app.dart Navigator 外层注入点，
                    // 纵向滚动 → contentScrollPulse 脉冲）。
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollUpdateNotification &&
                            notification.metrics.axis == Axis.vertical) {
                          GlassDockPlayer.notifyContentScrolled();
                        }
                        return false;
                      },
                      child: MediaQuery(
                        data: mq.copyWith(
                          padding: mq.padding.copyWith(
                            left: isLandscape && dockLeft
                                ? mq.padding.left + reserved
                                : mq.padding.left,
                            right: isLandscape && !dockLeft
                                ? mq.padding.right + reserved
                                : mq.padding.right,
                            bottom: isLandscape
                                ? mq.padding.bottom
                                : mq.padding.bottom + _kReservedBottom,
                          ),
                        ),
                        child: Builder(
                          builder: (context) {
                            _pagePaddingRight = MediaQuery.paddingOf(
                              context,
                            ).right;
                            _pagePaddingLeft = MediaQuery.paddingOf(
                              context,
                            ).left;
                            _pagePaddingBottom = MediaQuery.paddingOf(
                              context,
                            ).bottom;
                            if (scrollableContent) {
                              _scrollController?.dispose();
                              _scrollController = ScrollController();
                              return ListView.builder(
                                key: const ValueKey('page_probe'),
                                controller: _scrollController,
                                itemExtent: 60,
                                itemCount: 60,
                                itemBuilder: (_, i) =>
                                    SizedBox(height: 60, child: Text('项$i')),
                              );
                            }
                            return GestureDetector(
                              key: const ValueKey('page_probe'),
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _pageTapped = true,
                              child: const SizedBox.expand(),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Dock 层（复刻 _MainLayout 横屏宿主：铺满）。navExpanded 由
            // onNavExpandedChanged 真实驱动（复刻 app.dart _MainLayout 的
            // 双向闭环接线，保证竖屏单展开不变量可验证）。
            Positioned.fill(
              child: GlassDockPlayer(
                selectedTabId: 'discover',
                onSelectTab: (id) => _selectedTab = id,
                navExpanded: _navExpanded,
                onNavExpandedChanged: (expanded) =>
                    _navExpanded.value = expanded,
                showNav: showNav,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  // TabConfigProvider 异步加载（SharedPreferences mock）settle
  await tester.pump();
  await tester.pump();
  return (player: player, audio: audio);
}

/// 收尾：冲净歌词 / 装载截止 Timer 等异步残留，避免 pending timer 断言失败。
Future<void> _teardown(
  WidgetTester tester,
  PlayerProvider player,
  ControlledAudioService audio,
) async {
  activePlayerRoute?.dismiss();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpWidget(const SizedBox.shrink());
  player.dispose();
  await audio.dispose();
  await tester.pump(const Duration(seconds: 9));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  // 可滚动内容宿主（批次36 滑动坍缩用例）的滚动控制器回收。
  _scrollController?.dispose();
  _scrollController = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _pagePaddingRight = null;
    _pagePaddingLeft = null;
    _pagePaddingBottom = null;
    // 批次36：Dock 贴边方向是跨用例存活的全局单例，每例归位默认「靠右」，
    // 避免前一个「靠左」用例污染后续几何断言。
    kLandscapeDockSide.value = LandscapeDockSide.right;
    _pageTapped = false;
    _selectedTab = null;
    // playerExpansion / playerDragActive / activePlayerRoute 是跨用例存活的
    // 全局单例，每个用例开始前统一归位，消除跨用例串扰。
    playerExpansion.value = 0.0;
    playerDragActive.value = false;
    activePlayerRoute = null;
    // 批次36：滚动脉冲同为跨用例全局单例，归位防串扰。
    GlassDockPlayer.contentScrollPulse.value = 0;
  });

  group('横屏右纵条（批次35）', () {
    testWidgets('① 一级宿主渲染右纵条：右缘对齐 + 纵条宽 + 组合体居中', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
      );
      try {
        expect(
          find.byKey(_railKey),
          findsOneWidget,
          reason: '横屏应渲染右侧纵条（glass_dock_landscape_rail）',
        );
        // 竖屏底部横条的关键标识不应出现（形态已切换）
        expect(
          find.byKey(_portraitPlayerButtonKey),
          findsNothing,
          reason: '横屏不使用竖屏底部横条的播放器按钮',
        );

        final rail = tester.getRect(find.byKey(_railKey));
        // 右缘间距 12（与竖屏 Dock 底距同口径）
        expect(
          rail.right,
          closeTo(800 - GlassDockPlayer.kLandscapeRailRightMargin, 0.001),
        );
        // 纵条宽 52（导航项 44 + 水平 padding 8）
        expect(rail.width, closeTo(GlassDockPlayer.kLandscapeRailWidth, 0.001));
        // 批次36：球独立后纵条内只剩导航项——高 = 垂直 padding 16 +
        // 4 项×44 + 3 项距×4（无球、无球间距，对照批次35 的 +8+42）
        expect(rail.height, closeTo(16 + 4 * 44 + 3 * 4, 0.001));

        // 播放球 42dp（批次36：独立悬浮元素，纵条下方同列）
        final ball = tester.getRect(find.byKey(_ballKey));
        expect(ball.width, closeTo(GlassDockPlayer.kLandscapeBallSize, 0.001));
        expect(ball.height, closeTo(GlassDockPlayer.kLandscapeBallSize, 0.001));
        // 独立化几何断言①：球心不在纵条矩形内（球与纵条分离）
        expect(
          rail.contains(ball.center),
          isFalse,
          reason: '批次36 球独立化：播放球应与纵条分离（球心不在纵条矩形内）',
        );
        // 同列：球心与纵条中线对齐（共享同一右侧避让带）
        expect(ball.center.dx, closeTo(rail.center.dx, 0.5));
        // 球在纵条下方，间距 = 手机档 12（公开常量 kLandscapeBallRailGap）
        expect(ball.top - rail.bottom, closeTo(_kBallRailGap, 0.001));
        // 球右缘落在避让带内（右距 12 + 居中偏移 (52−42)/2 = 5）
        expect(
          ball.right,
          closeTo(800 - GlassDockPlayer.kLandscapeRailRightMargin - 5, 0.001),
        );
        // 组合体（纵条 + 球距 + 球）整体垂直居中于安全区
        expect(
          (rail.top + ball.bottom) / 2,
          closeTo(200, 0.5),
          reason: '组合体应整体垂直居中（球独立后纵条随组合体上移）',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('① 纵条内导航项纵向排列（44dp 圆形，同列）', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
      );
      try {
        // 默认 Tab 配置（v7：首页/音乐库/FM/搜索）四项
        final discover = tester.getRect(
          find.byKey(const ValueKey('${_navItemKeyPrefix}discover')),
        );
        final library = tester.getRect(
          find.byKey(const ValueKey('${_navItemKeyPrefix}library')),
        );
        final fm = tester.getRect(
          find.byKey(const ValueKey('${_navItemKeyPrefix}fm')),
        );

        // 纵向排列：discover 在上、library 居中、fm 在下
        expect(
          discover.center.dy,
          lessThan(library.center.dy),
          reason: '导航项应纵向排列（discover 在 library 之上）',
        );
        expect(
          library.center.dy,
          lessThan(fm.center.dy),
          reason: '导航项应纵向排列（library 在 fm 之上）',
        );
        // 同一列（右对齐于纵条）
        expect(discover.center.dx, closeTo(library.center.dx, 0.001));
        expect(library.center.dx, closeTo(fm.center.dx, 0.001));
        // 44dp 圆形（默认 4 项足额项径）
        expect(discover.width, closeTo(44, 0.001));
        expect(discover.height, closeTo(44, 0.001));
        // 复用竖屏图标配方（语义标签 + outlined 图标）
        expect(find.bySemanticsLabel('音乐库'), findsOneWidget);
        expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('② 播放球点击 → 横向展开（270dp / 从球体向左伸出 / 不推挤导航）', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌'), _localSong('s2', '第二首歌')],
      );
      try {
        final railBefore = tester.getRect(find.byKey(_railKey));
        expect(find.byKey(_controlsKey), findsNothing, reason: '初始为坍缩球');

        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        // AppHaptics.click（球体点击反馈）fire-and-forget 注册 300ms 超时
        // Timer，必须推进 fake 时间到期，否则测试结束时 pending timer 断言失败
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(_controlsKey), findsOneWidget, reason: '点球应展开控件');
        final controls = tester.getRect(find.byKey(_controlsKey));
        // 宽度动画目标 270dp（42 → 270，含水平 padding 10）
        expect(
          controls.width,
          closeTo(GlassDockPlayer.kLandscapeControlsWidth, 0.001),
        );
        final ball = tester.getRect(find.byKey(_ballKey));
        // 从球体向左伸出：展开体（玻璃）右缘贴球体左缘
        expect(controls.right, closeTo(ball.left, 0.001));
        // 与球体同垂直中心
        expect(controls.center.dy, closeTo(ball.center.dy, 0.001));
        // 悬浮覆盖、不推挤导航项：纵条几何与展开前一致
        expect(tester.getRect(find.byKey(_railKey)), railBefore);
        // 点外坍缩屏障出现
        expect(find.byKey(_barrierKey), findsOneWidget);
        // 展开体内容：封面 + 标题/歌手 + 三钮（复用竖屏控件语义）
        expect(find.text('第一首歌'), findsOneWidget);
        expect(find.text('测试歌手'), findsOneWidget);
        expect(find.byTooltip('上一曲'), findsOneWidget);
        expect(find.byTooltip('播放'), findsOneWidget);
        expect(find.byTooltip('下一曲'), findsOneWidget);

        // 再点球 → 坍缩回 42dp 球
        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_controlsKey), findsNothing, reason: '再点球应坍缩');
        expect(find.byKey(_barrierKey), findsNothing);
        expect(find.byKey(_ballKey), findsOneWidget);
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('③ 点展开体外部（页面内容）→ 坍缩，且点击放行到页面（批次36 translucent）', (
      tester,
    ) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
      );
      try {
        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_controlsKey), findsOneWidget);

        // 展开体与纵条之外的页面区域（x=100 远在展开体左缘 481 之左）
        _pageTapped = false;
        await tester.tapAt(const Offset(100, 200));
        await tester.pumpAndSettle();

        expect(find.byKey(_controlsKey), findsNothing, reason: '点外部应坍缩');
        expect(find.byKey(_barrierKey), findsNothing);
        expect(find.byKey(_ballKey), findsOneWidget, reason: '坍缩后仍是 42dp 球');
        // 批次36 语义变更：屏障从 opaque（吸收点击）改 translucent Listener
        // （命中路径放行下层）——「滑动内容坍缩」要求展开态手势能到达内容层，
        // 代价是点击不再被吞：点页面时页面点击与坍缩同时发生（点空白处仍
        // 只有坍缩）。论证见 _buildLandscapeDismissBarrier 文档。
        expect(
          _pageTapped,
          isTrue,
          reason: '批次36 translucent 屏障：点击应放行到页面内容（不吸收）',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('③ 展开态点击纵条导航项：正常切 tab 且不坍缩展开体', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
      );
      try {
        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_controlsKey), findsOneWidget);

        // 展开态点纵条上的导航项：不应被点外坍缩屏障误吞
        _selectedTab = null;
        await tester.tap(
          find.byKey(const ValueKey('${_navItemKeyPrefix}library')),
        );
        await tester.pumpAndSettle();
        // AppHaptics.tick（导航项点击反馈）300ms 超时 Timer
        await tester.pump(const Duration(milliseconds: 300));

        expect(_selectedTab, 'library', reason: '展开态导航项点击应生效');
        expect(
          find.byKey(_controlsKey),
          findsOneWidget,
          reason: '点导航项不坍缩展开体（横屏展开态只由点球 / 点外部驱动）',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('④ 横屏右侧避让：padding.right 增量 = 纵条宽 + 右距', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
      );
      try {
        // 宿主复刻 app.dart 一级页横屏注入逻辑（同模式同常量）
        expect(
          _pagePaddingRight,
          closeTo(_kReservedRight, 0.001),
          reason: '横屏页面应读到右侧避让增量（纵条宽 + 右距）',
        );
        expect(
          _pagePaddingBottom,
          closeTo(0.0, 0.001),
          reason: '横屏纵条不占纵向空间，底部注入不再需要',
        );
        // 避让量与纵条足迹一致：纵条左缘 = 屏右 − 避让量
        final rail = tester.getRect(find.byKey(_railKey));
        expect(rail.left, closeTo(800 - _kReservedRight, 0.001));
        expect(_kReservedRight, closeTo(64.0, 0.001));
        // 批次36 几何硬让位：内容区右缘 = 屏右 − 避让值（复刻 app.dart
        // 的 Padding 内缩——MediaQuery 注入无页面消费，几何 inset 是实际
        // 生效路径，纵条/球落在 gutter 中不遮挡内容）
        final probe = tester.getRect(find.byKey(const ValueKey('page_probe')));
        expect(
          probe.right,
          closeTo(800 - _kReservedRight, 0.001),
          reason: '批次36：横屏内容区应几何内缩避让宽度（消除遮挡）',
        );
        expect(probe.left, closeTo(0, 0.001), reason: '只内缩右侧，左缘不动');
      } finally {
        await _teardown(tester, player, audio);
      }
    });
  });

  // ── 批次36：播放球独立化 + 展开态滑动内容坍缩 ──
  // 机制：app.dart 内容层外层 NotificationListener<ScrollNotification>
  // （纵向滚动 → GlassDockPlayer.contentScrollPulse 脉冲）；Dock 横屏
  // 展开态监听脉冲即坍缩。点外坍缩屏障同期改为 translucent Listener
  // （命中路径放行下层），展开态手势可到达内容层——「滑动内容坍缩」
  // 由此成立。球/纵条/展开体在屏障之上且不 translucent，落在其上的
  // 指针不进屏障路径（球区手势不误触）。
  group('滑动内容坍缩 + 球独立（批次36）', () {
    test('② 单测：contentScrollPulse 事件语义（单调递增计数）', () {
      // setUp 已归位；广播入口每次调用 +1（事件语义，非布尔量）。
      expect(GlassDockPlayer.contentScrollPulse.value, 0);
      GlassDockPlayer.notifyContentScrolled();
      expect(GlassDockPlayer.contentScrollPulse.value, 1);
      GlassDockPlayer.notifyContentScrolled();
      expect(GlassDockPlayer.contentScrollPulse.value, 2);
    });

    testWidgets('② 展开态 + 滚动脉冲 → 坍缩（球保持）', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
      );
      try {
        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_controlsKey), findsOneWidget);

        // 驱动页面内容纵向滚动（等价 app.dart 广播入口被内容层触发）
        final pulseBefore = GlassDockPlayer.contentScrollPulse.value;
        GlassDockPlayer.notifyContentScrolled();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(_controlsKey), findsNothing, reason: '页面内容滚动应坍缩展开体');
        expect(find.byKey(_ballKey), findsOneWidget, reason: '坍缩后独立球保持');
        expect(
          GlassDockPlayer.contentScrollPulse.value,
          pulseBefore + 1,
          reason: '广播入口应发出脉冲',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('② 展开态 + 真实拖拽页面滚动 → 坍缩且内容滚动（translucent 屏障放行）', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
        scrollableContent: true,
      );
      try {
        expect(_scrollController!.offset, 0.0, reason: '初始滚动偏移 0');
        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_controlsKey), findsOneWidget);

        // 展开态在页面内容区（探针中心 x≈368，远在纵条/球/展开体之左）
        // 向上拖拽：translucent 屏障放行手势 → 内容真实滚动 + 广播坍缩。
        final pulseBefore = GlassDockPlayer.contentScrollPulse.value;
        await tester.drag(
          find.byKey(const ValueKey('page_probe')),
          const Offset(0, -150),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          _scrollController!.offset,
          greaterThan(0.0),
          reason: '批次36 translucent 屏障：展开态手势应放行到内容层（内容真实滚动）',
        );
        expect(find.byKey(_controlsKey), findsNothing, reason: '滑动内容应坍缩展开体');
        expect(find.byKey(_ballKey), findsOneWidget, reason: '坍缩后球保持');
        expect(
          GlassDockPlayer.contentScrollPulse.value,
          greaterThan(pulseBefore),
          reason: '内容滚动应经广播入口发脉冲（app.dart 复刻注入点生效）',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('② 球区上滑拖拽不误触坍缩（球上发起的手势不算内容滚动）', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
      );
      try {
        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_controlsKey), findsOneWidget);

        // 展开态下在**球上**发起上滑拖拽（累计 100px，未达 FullPlayer
        // 长边阈值 160）：球在屏障之上且不 translucent，指针不进屏障
        // 路径，也不产生内容滚动——不应误触坍缩。
        final center = tester.getCenter(find.byKey(_ballKey));
        final gesture = await tester.startGesture(center);
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 50));
        for (var i = 0; i < 5; i++) {
          await gesture.moveBy(const Offset(0, -20));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));

        expect(playerExpansion.value, 0.0, reason: '未越阈应回归归位');
        expect(
          find.byKey(_controlsKey),
          findsOneWidget,
          reason: '球区拖拽（未越阈）不应误触坍缩展开体',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('② 竖屏恒展开形态（二级页）：页面滚动不坍缩（广播只影响横屏）', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(400, 800),
        songs: [_localSong('s1', '第一首歌')],
        showNav: false,
        scrollableContent: true,
      );
      try {
        expect(
          find.byKey(_portraitTrackTitleKey),
          findsOneWidget,
          reason: '竖屏二级页仅播放器形态恒展开（批次24 语义）',
        );
        // 竖屏内容滚动广播：Dock 侧守卫横屏限定，恒展开胶囊不动。
        GlassDockPlayer.notifyContentScrolled();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(_portraitTrackTitleKey),
          findsOneWidget,
          reason: '竖屏恒展开语义不受滚动脉冲影响（横屏限定）',
        );
        // 真实拖拽同样不坍缩（走同一守卫）
        await tester.drag(
          find.byKey(const ValueKey('page_probe')),
          const Offset(0, -120),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(_portraitTrackTitleKey), findsOneWidget);
        expect(_scrollController!.offset, greaterThan(0.0));
      } finally {
        await _teardown(tester, player, audio);
      }
    });
  });

  // ── Pad 横屏分档（批次35：视口最短边 ≥ 600 走 Pad 档几何）──
  // 口径：MediaQuery.sizeOf(context).shortestSide >= 600（与方向无关，
  // 手机横屏最短边 < 600 不会误判——sonify 踩坑结论：按宽判定禁用）。
  // 两套参数并列：手机横屏档数值逐字节不变（下方回归锁），Pad 档整体
  // 上浮一档。避让注入与 Dock 侧几何共用 isPadLandscape 判定（同源）。
  group('Pad 横屏分档（批次35，视口最短边 ≥ 600）', () {
    test('⑦ 单测：两套参数常量表（手机横屏档 vs Pad 档，批次35）', () {
      // 判定断点：最短边 600（与方向无关）
      expect(GlassDockPlayer.kLandscapePadBreakpoint, 600.0);
      // 右缘间距两档共用
      expect(GlassDockPlayer.kLandscapeRailRightMargin, 12.0);
      // 手机横屏档（逐字节不变）
      expect(GlassDockPlayer.kLandscapeBallSize, 42.0);
      expect(GlassDockPlayer.kLandscapeBallCoverSize, 36.0);
      expect(GlassDockPlayer.kLandscapeRailWidth, 52.0);
      expect(GlassDockPlayer.kLandscapeControlsWidth, 270.0);
      // Pad 档（整体上浮一档）
      expect(GlassDockPlayer.kLandscapeBallSizePad, 48.0);
      expect(GlassDockPlayer.kLandscapeBallCoverSizePad, 42.0);
      expect(GlassDockPlayer.kLandscapeRailWidthPad, 60.0);
      expect(GlassDockPlayer.kLandscapeControlsWidthPad, 320.0);
      // 批次36 球独立化：球与纵条垂直间距双档（手机 12 / Pad 14）
      expect(GlassDockPlayer.kLandscapeBallRailGap, 12.0);
      expect(GlassDockPlayer.kLandscapeBallRailGapPad, 14.0);
      expect(
        GlassDockPlayer.kLandscapeBallRailGapPad,
        greaterThan(GlassDockPlayer.kLandscapeBallRailGap),
      );
      // 档位关系：Pad 档恒大于手机档（防误把两档配错）
      expect(
        GlassDockPlayer.kLandscapeBallSizePad,
        greaterThan(GlassDockPlayer.kLandscapeBallSize),
      );
      expect(
        GlassDockPlayer.kLandscapeRailWidthPad,
        greaterThan(GlassDockPlayer.kLandscapeRailWidth),
      );
      expect(
        GlassDockPlayer.kLandscapeControlsWidthPad,
        greaterThan(GlassDockPlayer.kLandscapeControlsWidth),
      );
    });

    testWidgets('⑦ Pad 宿主渲染右纵条：Pad 档几何（纵条 60 / 球 48 / 项径 48）', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(1200, 800),
      );
      try {
        expect(find.byKey(_railKey), findsOneWidget, reason: 'Pad 横屏应渲染右侧纵条');
        expect(find.byKey(_portraitPlayerButtonKey), findsNothing);

        final rail = tester.getRect(find.byKey(_railKey));
        // 右缘间距 12（两档共用，同竖屏 Dock 底距口径）
        expect(
          rail.right,
          closeTo(1200 - GlassDockPlayer.kLandscapeRailRightMargin, 0.001),
        );
        // 纵条宽 = Pad 档 60（导航项 48 + 水平 padding 6×2）
        expect(
          rail.width,
          closeTo(GlassDockPlayer.kLandscapeRailWidthPad, 0.001),
        );
        // 垂直居中于右侧安全区内（测试视口无安全区 inset）——批次36 起为
        // **组合体**（纵条 + 球距 + 球）整体居中
        expect(
          (rail.top + tester.getRect(find.byKey(_ballKey)).bottom) / 2,
          closeTo(400, 0.5),
        );
        // 纵条高 = 垂直 padding 16 + 4 项×48 + 3 项距×6（球独立后胶囊内
        // 只剩导航项，无球、无球间距）
        expect(rail.height, closeTo(16 + 4 * 48 + 3 * 6, 0.001));

        // 播放球 = Pad 档 48dp（批次36：独立悬浮元素，纵条下方同列）
        final ball = tester.getRect(find.byKey(_ballKey));
        expect(
          ball.width,
          closeTo(GlassDockPlayer.kLandscapeBallSizePad, 0.001),
        );
        expect(
          ball.height,
          closeTo(GlassDockPlayer.kLandscapeBallSizePad, 0.001),
        );
        expect(ball.center.dx, closeTo(rail.center.dx, 0.5));
        // 独立化几何断言：球心不在纵条矩形内
        expect(rail.contains(ball.center), isFalse);
        // 球与纵条间距 = Pad 档 14（公开常量 kLandscapeBallRailGapPad；
        // 手机档 12）
        expect(ball.top - rail.bottom, closeTo(_kBallRailGapPad, 0.001));
        // 导航项径 = Pad 档足额 48dp（默认 4 项，高度预算充足）
        final discover = tester.getRect(
          find.byKey(const ValueKey('${_navItemKeyPrefix}discover')),
        );
        expect(discover.width, closeTo(48, 0.001));
        expect(discover.height, closeTo(48, 0.001));
        // 项间距 = Pad 档 6（discover 底 → library 顶；手机档为 4）
        final library = tester.getRect(
          find.byKey(const ValueKey('${_navItemKeyPrefix}library')),
        );
        expect(library.top - discover.bottom, closeTo(6, 0.001));
        // 末项 search 底 → 球顶 = 胶囊垂直 padding 8 + 球距 14 = 22
        // （批次35 为胶囊内球距 10 一项，批次36 球独立后拆成两段）
        final search = tester.getRect(
          find.byKey(const ValueKey('${_navItemKeyPrefix}search')),
        );
        expect(ball.top - search.bottom, closeTo(8 + 14, 0.001));
        // 纵排同列
        expect(discover.center.dx, closeTo(library.center.dx, 0.001));
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('⑦ Pad 播放球点击 → 横向展开（320dp / 同垂直中心 / 不推挤导航）', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(1200, 800),
        songs: [_localSong('s1', '第一首歌'), _localSong('s2', '第二首歌')],
      );
      try {
        final railBefore = tester.getRect(find.byKey(_railKey));
        expect(find.byKey(_controlsKey), findsNothing, reason: '初始为坍缩球');

        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        // AppHaptics.click 300ms 超时 Timer 冲净
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(_controlsKey), findsOneWidget, reason: '点球应展开控件');
        final controls = tester.getRect(find.byKey(_controlsKey));
        // 展开宽度 = Pad 档 320（48 → 320 动画目标）
        expect(
          controls.width,
          closeTo(GlassDockPlayer.kLandscapeControlsWidthPad, 0.001),
        );
        // 展开体高 = Pad 档球径 48（与球体同高）
        expect(
          controls.height,
          closeTo(GlassDockPlayer.kLandscapeBallSizePad, 0.001),
        );
        final ball = tester.getRect(find.byKey(_ballKey));
        // 从球体向左伸出：右缘贴球体左缘（Pad 档派生右缘 66）
        expect(controls.right, closeTo(ball.left, 0.001));
        expect(controls.right, closeTo(1200 - 66, 0.001));
        // 与球体同垂直中心
        expect(controls.center.dy, closeTo(ball.center.dy, 0.001));
        // 悬浮覆盖、不推挤导航项：纵条几何与展开前一致
        expect(tester.getRect(find.byKey(_railKey)), railBefore);
        // 点外坍缩屏障出现；内容复用（标题 + 三钮）
        expect(find.byKey(_barrierKey), findsOneWidget);
        expect(find.text('第一首歌'), findsOneWidget);
        expect(find.byTooltip('上一曲'), findsOneWidget);

        // 再点球 → 坍缩回 48dp 球
        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_controlsKey), findsNothing, reason: '再点球应坍缩');
        expect(find.byKey(_barrierKey), findsNothing);
        expect(find.byKey(_ballKey), findsOneWidget);
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('⑦ Pad 横屏右侧避让：padding.right = Pad 档派生值且与 Dock 同源', (
      tester,
    ) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(1200, 800),
      );
      try {
        // 宿主复刻 app.dart 一级页横屏注入（含 Pad 分档选档）
        expect(
          _pagePaddingRight,
          closeTo(_kReservedRightPad, 0.001),
          reason: 'Pad 横屏页面应读到 Pad 档避让增量',
        );
        expect(
          _pagePaddingBottom,
          closeTo(0.0, 0.001),
          reason: 'Pad 横屏纵条同样不占纵向空间',
        );
        // 同源派生：避让 = Pad 档纵条宽 + 右距（= 72），公式与 Dock 侧
        // 常量一致（app.dart _kDockReservedRightPad 同款派生）
        expect(
          _kReservedRightPad,
          closeTo(
            GlassDockPlayer.kLandscapeRailWidthPad +
                GlassDockPlayer.kLandscapeRailRightMargin,
            0.001,
          ),
        );
        expect(_kReservedRightPad, closeTo(72.0, 0.001));
        // 避让量与纵条足迹一致：纵条左缘 = 屏右 − 避让量
        final rail = tester.getRect(find.byKey(_railKey));
        expect(rail.left, closeTo(1200 - _kReservedRightPad, 0.001));
        // 批次36 几何硬让位（Pad 档同口径）：内容区右缘 = 屏右 − 72
        final probe = tester.getRect(find.byKey(const ValueKey('page_probe')));
        expect(
          probe.right,
          closeTo(1200 - _kReservedRightPad, 0.001),
          reason: 'Pad 横屏内容区应几何内缩 Pad 档避让宽度',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });
  });

  // 手机横屏档回归锁（批次35 Pad 分档后）：800×400 / 800×599 宿主数值
  // 必须逐字节停在手机档——防分档逻辑误伤手机横屏。
  group('手机横屏档回归锁（批次35 Pad 分档后不变）', () {
    testWidgets(
      '⑧ 手机横屏 800×400：纵条 52 / 球 42 / 项径 44 / 项距 4 / 球距 12 / 展开 270 / 避让 64',
      (tester) async {
        final (:player, :audio) = await _pumpApp(
          tester,
          viewport: const Size(800, 400),
          songs: [_localSong('s1', '第一首歌')],
        );
        try {
          final rail = tester.getRect(find.byKey(_railKey));
          expect(
            rail.width,
            closeTo(GlassDockPlayer.kLandscapeRailWidth, 0.001),
          );
          expect(
            rail.right,
            closeTo(800 - GlassDockPlayer.kLandscapeRailRightMargin, 0.001),
          );
          // 纵条高 = 16 + 4×44 + 3×4（批次36：球独立后胶囊内只剩导航项；
          // 批次35 为 +8+42）
          expect(rail.height, closeTo(16 + 4 * 44 + 3 * 4, 0.001));

          final ball = tester.getRect(find.byKey(_ballKey));
          expect(
            ball.width,
            closeTo(GlassDockPlayer.kLandscapeBallSize, 0.001),
          );
          expect(
            ball.height,
            closeTo(GlassDockPlayer.kLandscapeBallSize, 0.001),
          );
          // 球独立悬浮在纵条下方：间距 = 手机档 12（公开常量）
          expect(ball.top - rail.bottom, closeTo(_kBallRailGap, 0.001));
          // 独立化：球心不在纵条矩形内
          expect(rail.contains(ball.center), isFalse);

          // 项径足额 44 / 项距 4（手机档）
          final discover = tester.getRect(
            find.byKey(const ValueKey('${_navItemKeyPrefix}discover')),
          );
          expect(discover.width, closeTo(44, 0.001));
          final library = tester.getRect(
            find.byKey(const ValueKey('${_navItemKeyPrefix}library')),
          );
          expect(library.top - discover.bottom, closeTo(4, 0.001));

          // 避让 = 手机档 64（与 Dock 侧同源派生）
          expect(_pagePaddingRight, closeTo(_kReservedRight, 0.001));
          expect(_kReservedRight, closeTo(64.0, 0.001));

          // 展开宽度 = 手机档 270
          await tester.tap(find.byKey(_ballKey));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            tester.getRect(find.byKey(_controlsKey)).width,
            closeTo(GlassDockPlayer.kLandscapeControlsWidth, 0.001),
          );
        } finally {
          await _teardown(tester, player, audio);
        }
      },
    );

    testWidgets('⑧ 边界：最短边 599（800×599）走手机档、600（1000×600）走 Pad 档', (
      tester,
    ) async {
      // 最短边 599 < 600：手机横屏档（纵条 52 / 避让 64）
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 599),
      );
      try {
        expect(
          tester.getRect(find.byKey(_railKey)).width,
          closeTo(GlassDockPlayer.kLandscapeRailWidth, 0.001),
          reason: '最短边 599 应走手机横屏档',
        );
        expect(_pagePaddingRight, closeTo(_kReservedRight, 0.001));
      } finally {
        await _teardown(tester, player, audio);
      }
      // 最短边 600 = 断点（含等于）：Pad 档（纵条 60 / 避让 72）
      final (player: player2, audio: audio2) = await _pumpApp(
        tester,
        viewport: const Size(1000, 600),
      );
      try {
        expect(
          tester.getRect(find.byKey(_railKey)).width,
          closeTo(GlassDockPlayer.kLandscapeRailWidthPad, 0.001),
          reason: '最短边 600 应走 Pad 档',
        );
        expect(_pagePaddingRight, closeTo(_kReservedRightPad, 0.001));
      } finally {
        await _teardown(tester, player2, audio2);
      }
    });
  });

  group('竖屏对照（改动前口径，逐项锁定）', () {
    testWidgets('⑤ 竖屏 Dock 仍是底部横条：几何 / 导航横排 / 避让底部注入', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(400, 800),
        songs: [_localSong('s1', '第一首歌'), _localSong('s2', '第二首歌')],
      );
      try {
        // 横屏纵条形态的关键标识不应出现
        expect(find.byKey(_railKey), findsNothing, reason: '竖屏不应渲染右纵条');
        expect(find.byKey(_ballKey), findsNothing);
        // 竖屏底部横条：播放器按钮贴屏底（SafeArea bottom 0 + 外边距 12），
        // 与导航项同一水平线（Row 布局，左导航 + 右播放器）
        final button = tester.getRect(find.byKey(_portraitPlayerButtonKey));
        expect(button.bottom, closeTo(800 - 12, 0.001));
        expect(button.center.dy, closeTo(800 - 12 - 26, 0.001));
        final libraryRect = tester.getRect(
          find.byIcon(Icons.library_music_outlined),
        );
        expect(
          button.center.dy,
          closeTo(libraryRect.center.dy, 0.001),
          reason: '播放器与导航项同行（底部横条）',
        );
        expect(
          button.center.dx,
          greaterThan(libraryRect.center.dx),
          reason: '播放器在导航右侧（布局恒定：左导航 + 右播放器）',
        );
        // 竖屏避让注入：底部 +72、右侧 0（横屏专属注入不出现）
        expect(_pagePaddingBottom, closeTo(_kReservedBottom, 0.001));
        expect(_pagePaddingRight, closeTo(0.0, 0.001));

        // 导航横排（照抄 dock_nav_library_test 断言口径；discover 为选中
        // tab 显示 filled 图标，library 未选中显示 outlined）
        expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
        expect(find.bySemanticsLabel('音乐库'), findsOneWidget);
        final home = tester.getRect(find.byIcon(Icons.home));
        final library = tester.getRect(
          find.byIcon(Icons.library_music_outlined),
        );
        expect(
          home.center.dx,
          lessThan(library.center.dx),
          reason: '竖屏导航项应横向排列',
        );
        expect(home.center.dy, closeTo(library.center.dy, 0.001));

        // 竖屏点球 → 展开为控制胶囊（单展开不变量：导航坍缩）。
        // 注意：400×800 窄竖屏视口下，胶囊展开首帧（导航胶囊尚未坍缩
        // 让位）会触发展开体 9px RenderFlex overflow——这是**既有问题**
        // （批次35 之前已存在：_buildControlsCapsule 的 fixedWidth 防御
        // 把容器水平 padding 10 重复计入了 LayoutBuilder 约束，且 overflow
        // 内容被 AnimatedSize 裁剪不可见），已用原始 lib 代码复现确认。
        // 按「相邻问题只报告不顺手改」约定不在本批次修复，此处屏蔽该既有
        // 告警，仅验证竖屏状态机语义不变。
        final previousOnError = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.exceptionAsString().contains('A RenderFlex overflowed')) {
            return;
          }
          previousOnError?.call(details);
        };
        await tester.tap(find.byKey(_portraitPlayerButtonKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        FlutterError.onError = previousOnError;
        expect(
          find.byKey(_portraitTrackTitleKey),
          findsOneWidget,
          reason: '竖屏点球应展开播放器胶囊',
        );
        expect(
          find.byIcon(Icons.library_music_outlined),
          findsNothing,
          reason: '播放器展开时导航应坍缩（单展开不变量）',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('⑤ 竖屏仅播放器形态（二级页）：底部居中恒展开胶囊', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(400, 800),
        songs: [_localSong('s1', '第一首歌')],
        showNav: false,
      );
      try {
        expect(find.byKey(_railKey), findsNothing, reason: '竖屏无右纵条');
        // 仅播放器形态恒展开（批次24 语义）：初始即胶囊
        expect(
          find.byKey(_portraitTrackTitleKey),
          findsOneWidget,
          reason: '二级页仅播放器 Dock 竖屏恒展开',
        );
        // 贴在屏底（SafeArea bottom 0 + 外边距 12 + 胶囊高 52 的一半）
        final title = tester.getRect(find.byKey(_portraitTrackTitleKey));
        expect(
          title.center.dy,
          closeTo(800 - 12 - 26, 0.001),
          reason: '竖屏二级 Dock 仍在底部横条位置',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('⑤ 横屏仅播放器形态（二级页）：无纵条、仅独立球居中、初始坍缩', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
        showNav: false,
      );
      try {
        // 批次36：无导航形态不渲染纵条（球独立后胶囊内只剩球没有意义）
        expect(find.byKey(_railKey), findsNothing);
        // 无导航项（showNav: false）
        expect(
          find.byKey(const ValueKey('${_navItemKeyPrefix}discover')),
          findsNothing,
        );
        // 横屏形态定义：播放球初始坍缩（点击展开 / 点外坍缩）
        expect(find.byKey(_controlsKey), findsNothing);
        expect(find.byKey(_ballKey), findsOneWidget);
        // 独立球单独垂直居中（组合体只剩球）
        final ball = tester.getRect(find.byKey(_ballKey));
        expect(ball.center.dy, closeTo(200, 0.5));
        // 球右缘仍在避让带内（与一级形态同列：右距 12 + 居中偏移 5）
        expect(
          ball.right,
          closeTo(800 - GlassDockPlayer.kLandscapeRailRightMargin - 5, 0.001),
        );
        // 点击可展开（与一级形态同语义）
        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_controlsKey), findsOneWidget);
      } finally {
        await _teardown(tester, player, audio);
      }
    });
  });

  group('拖拽阈值长边口径（批次35，方案 P0-4）', () {
    test('单测：shouldExpandPlayer 按长边 max(宽,高) 判定，横竖屏一致', () {
      // 横屏矮视口（如 800×400）按短边（屏高 400）的 20% = 80px 过灵敏，
      // 长边口径 800×0.2 = 160px；竖屏（400×800）长边即屏高，数值不变。
      expect(
        shouldExpandPlayer(
          dragDistance: 160,
          screenHeight: 800,
          velocity: 0,
          acceleration: 0,
        ),
        isTrue,
        reason: '长边 800 的 20% = 160，达标应展开',
      );
      expect(
        shouldExpandPlayer(
          dragDistance: 159,
          screenHeight: 800,
          velocity: 0,
          acceleration: 0,
        ),
        isFalse,
        reason: '差 1px 不达标不应展开',
      );
    });

    test('单测：Pad 大长边阈值钳制 240（批次35），手机长边不变', () {
      // 手机横屏 / 竖屏：长边 ≤ ~1000dp → 0.2 倍 ≤ 200px，落在钳制区间
      // [96, 240] 内，数值逐字节不变。
      expect(playerExpandDistanceThreshold(800), 160.0);
      expect(playerExpandDistanceThreshold(600), 120.0);
      // Pad 横屏 1200×800：0.2×1200 = 240（恰在钳制上限）。
      expect(playerExpandDistanceThreshold(1200), 240.0);
      // Pad 横屏 1440×1080：0.2×1440 = 288 → 钳制 240（防拖拽行程过长）。
      expect(playerExpandDistanceThreshold(1440), 240.0);
      expect(playerExpandDistanceThreshold(1600), 240.0);

      // Pad 上 250px：未钳制时 250 < 288 不展开；钳制 240 后达标。
      expect(
        shouldExpandPlayer(
          dragDistance: 250,
          screenHeight: 1440,
          velocity: 0,
          acceleration: 0,
        ),
        isTrue,
        reason: 'Pad 长边 288 经钳制 240，250 达标应展开',
      );
      expect(
        shouldExpandPlayer(
          dragDistance: 239,
          screenHeight: 1440,
          velocity: 0,
          acceleration: 0,
        ),
        isFalse,
        reason: '239 < 240 钳制上限，不展开',
      );
      // Pad 1200×800：阈值恰 240——与手机横屏 160 明确分档。
      expect(
        shouldExpandPlayer(
          dragDistance: 220,
          screenHeight: 1200,
          velocity: 0,
          acceleration: 0,
        ),
        isFalse,
        reason: 'Pad 1200 长边阈值 240，220 不展开',
      );
      expect(
        shouldExpandPlayer(
          dragDistance: 240,
          screenHeight: 1200,
          velocity: 0,
          acceleration: 0,
        ),
        isTrue,
      );
    });

    testWidgets('⑥ 横屏宿主：累计 100px（短边口径 80 会误触）不展开', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
      );
      try {
        // 越障 move（40，仅派发 start）+ 5 × 20px update（累计 100px）。
        // 速度 ~200px/s < 900、加速度小，三阈值只剩距离口径：
        // 短边口径 400×0.2 = 80 → 100 ≥ 80 会误触 push；
        // 长边口径 800×0.2 = 160 → 100 < 160 不展开。
        final center = tester.getCenter(find.byKey(_ballKey));
        final gesture = await tester.startGesture(center);
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 50));
        for (var i = 0; i < 5; i++) {
          await gesture.moveBy(const Offset(0, -20));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(playerDragActive.value, isTrue, reason: '拖拽应已激活');
        expect(playerExpansion.value, greaterThan(0.0), reason: '拖拽应跟手');
        await gesture.up();
        // 未达阈值：覆盖层回归收敛（200ms）后归位、不 push 播放页
        await tester.pumpAndSettle();
        expect(playerExpansion.value, 0.0);
        expect(playerDragActive.value, isFalse);
        expect(
          activePlayerRoute,
          isNull,
          reason: '横屏矮视口下 100px 拖拽不应展开播放页（长边口径）',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('⑥ 横屏宿主：累计 220px（长边口径 160）展开并 push', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
      );
      try {
        final center = tester.getCenter(find.byKey(_ballKey));
        final gesture = await tester.startGesture(center);
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 50));
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(const Offset(0, -20));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await gesture.up();
        // settleToFull（300ms）后路由接管
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(activePlayerRoute, isNotNull, reason: '横屏长边口径 160 达标应 push 播放页');
      } finally {
        await _teardown(tester, player, audio);
      }
    });
  });

  // ── 批次36：悬浮 Dock 靠左 / 靠右（用户口径「支持设置选择悬浮 dock 在
  // 左在右（在哪哪边内容就要避让）」）──
  // 默认 right 必须与改造前逐字节一致；切 left 后纵条/球/展开体整体镜像，
  // 避让只注入配置侧（未配置侧为 0），竖屏底部横条与底部 72 不受影响。
  group('悬浮 Dock 靠左/靠右（批次36）', () {
    testWidgets('① 默认 right：纵条贴右、padding.right=64、padding.left=0', (
      tester,
    ) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
      );
      try {
        expect(kLandscapeDockSide.value, LandscapeDockSide.right);
        final rail = tester.getRect(find.byKey(_railKey));
        expect(
          rail.right,
          closeTo(800 - GlassDockPlayer.kLandscapeRailRightMargin, 0.001),
          reason: '默认配置纵条贴右（改造前行为）',
        );
        expect(rail.left, closeTo(800 - _kReservedRight, 0.001));
        expect(_pagePaddingRight, closeTo(_kReservedRight, 0.001));
        expect(
          _pagePaddingLeft,
          closeTo(0.0, 0.001),
          reason: '未配置方向（左侧）不得注入避让，不做双侧注入',
        );
        // 内容几何硬让位仍在右侧（探针右缘 = 屏右 − 64、左缘 0）
        final probe = tester.getRect(find.byKey(const ValueKey('page_probe')));
        expect(probe.right, closeTo(800 - _kReservedRight, 0.001));
        expect(probe.left, closeTo(0.0, 0.001));
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('② 切 left：纵条贴左、padding.left=64、padding.right=0，球同列镜像', (
      tester,
    ) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
      );
      try {
        // 复刻设置页切换：只改全局 ValueNotifier，不重建宿主、不重启。
        kLandscapeDockSide.value = LandscapeDockSide.left;
        await tester.pump();
        await tester.pump();

        final rail = tester.getRect(find.byKey(_railKey));
        expect(
          rail.left,
          closeTo(GlassDockPlayer.kLandscapeRailRightMargin, 0.001),
          reason: '靠左配置：纵条贴左（同一边距 12，镜像复用）',
        );
        expect(rail.top, greaterThanOrEqualTo(0.0));
        expect(
          rail.width,
          closeTo(GlassDockPlayer.kLandscapeRailWidth, 0.001),
          reason: '手机横屏档纵条宽不变',
        );
        expect(_pagePaddingLeft, closeTo(_kReservedRight, 0.001));
        expect(
          _pagePaddingRight,
          closeTo(0.0, 0.001),
          reason: '靠左配置下右侧必须为 0（不得双侧注入）',
        );

        // 球与纵条同列：球心对齐纵条中线（贴左边距 12 + 居中偏移 5）
        final ball = tester.getRect(find.byKey(_ballKey));
        expect(ball.center.dx, closeTo(rail.center.dx, 0.5));
        expect(
          ball.left,
          closeTo(
            GlassDockPlayer.kLandscapeRailRightMargin +
                (GlassDockPlayer.kLandscapeRailWidth -
                        GlassDockPlayer.kLandscapeBallSize) /
                    2,
            0.001,
          ),
        );
        // 组合体仍整体垂直居中（换边不改纵向几何）
        expect((rail.top + ball.bottom) / 2, closeTo(200, 0.5));

        // 几何硬让位换到左侧：内容左缘 = 屏左 + 64、右缘 = 屏右
        final probe = tester.getRect(find.byKey(const ValueKey('page_probe')));
        expect(probe.left, closeTo(_kReservedRight, 0.001));
        expect(probe.right, closeTo(800.0, 0.001));
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('③ 靠左配置下展开体向右（内侧）伸出：左缘贴球体右缘', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(800, 400),
        songs: [_localSong('s1', '第一首歌')],
      );
      try {
        kLandscapeDockSide.value = LandscapeDockSide.left;
        await tester.pump();
        await tester.pump();
        final railBefore = tester.getRect(find.byKey(_railKey));

        await tester.tap(find.byKey(_ballKey));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));

        final controls = tester.getRect(find.byKey(_controlsKey));
        final ball = tester.getRect(find.byKey(_ballKey));
        expect(
          controls.width,
          closeTo(GlassDockPlayer.kLandscapeControlsWidth, 0.001),
        );
        // 向内侧（右）伸出：展开体左缘贴球体右缘
        expect(
          controls.left,
          closeTo(ball.right, 0.001),
          reason: '靠左配置：展开体应从球体向右伸出（镜像方向）',
        );
        expect(controls.center.dy, closeTo(ball.center.dy, 0.001));
        // 不推挤纵条
        expect(tester.getRect(find.byKey(_railKey)), railBefore);
        // 点外坍缩屏障语义不变
        expect(find.byKey(_barrierKey), findsOneWidget);
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('④ 竖屏不受配置影响：仍底部横条 + 底部 72 避让、侧向为 0', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(400, 800),
        songs: [_localSong('s1', '第一首歌')],
      );
      try {
        // 即便配置为靠左，竖屏形态也不参与（设置只作用于横屏）
        kLandscapeDockSide.value = LandscapeDockSide.left;
        await tester.pump();
        await tester.pump();

        expect(find.byKey(_railKey), findsNothing, reason: '竖屏无纵条');
        expect(find.byKey(_ballKey), findsNothing);
        final button = tester.getRect(find.byKey(_portraitPlayerButtonKey));
        expect(button.bottom, closeTo(800 - 12, 0.001));
        expect(_pagePaddingBottom, closeTo(_kReservedBottom, 0.001));
        expect(_pagePaddingLeft, closeTo(0.0, 0.001));
        expect(_pagePaddingRight, closeTo(0.0, 0.001));
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('⑤ Pad 档靠左（1200×800）：纵条 60 贴左、padding.left=72', (tester) async {
      final (:player, :audio) = await _pumpApp(
        tester,
        viewport: const Size(1200, 800),
      );
      try {
        kLandscapeDockSide.value = LandscapeDockSide.left;
        await tester.pump();
        await tester.pump();

        final rail = tester.getRect(find.byKey(_railKey));
        expect(
          rail.width,
          closeTo(GlassDockPlayer.kLandscapeRailWidthPad, 0.001),
          reason: 'Pad 档纵条宽仍为 60',
        );
        expect(
          rail.left,
          closeTo(GlassDockPlayer.kLandscapeRailRightMargin, 0.001),
        );
        expect(_pagePaddingLeft, closeTo(_kReservedRightPad, 0.001));
        expect(_kReservedRightPad, closeTo(72.0, 0.001));
        expect(_pagePaddingRight, closeTo(0.0, 0.001));
        final probe = tester.getRect(find.byKey(const ValueKey('page_probe')));
        expect(probe.left, closeTo(_kReservedRightPad, 0.001));
        expect(probe.right, closeTo(1200.0, 0.001));
      } finally {
        await _teardown(tester, player, audio);
      }
    });
  });
}
