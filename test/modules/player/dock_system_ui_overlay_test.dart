/// Dock 上滑展开过程系统栏样式稳定性测试（真机反馈：上滑过程中设备
/// 状态栏 / 导航栏颜色不停跳变）。
///
/// 根因方向（与本测试锁定的修复口径对应）：
/// 1. 拖拽期跟手覆盖层 / 路由的 FullPlayer 经 [PlayerSystemUiScope] 挂
///    `AnnotatedRegion<SystemUiOverlayStyle>`，其「过渡样式」与主页面稳态
///    样式（AppBar 注解 + app 级 applyMainEdgeToEdge）取值不一致，
///    RenderView._updateSystemChrome 每帧合并出的样式在拖拽起点、
///    settle 末段、完成时刻多次跳变 → 平台侧系统栏反复重设（闪烁）；
/// 2. 展开完成时 applyImmersiveForOrientation 直设 kPlayerOverlayStyle
///    （恒浅色图标）与 FullPlayer 自己的 AnnotatedRegion（主题图标）
///    竞态，且 manual→edgeToEdge 模式切换引发 didChangeMetrics 回灌，
///    app 级 _SystemUiUpdater 再次覆写，形成多数据源混战。
///
/// 修复口径（单一数据源）：过渡期间系统栏样式恒等于主页面稳态样式
/// （不产生任何平台调用），仅在展开完成时切换一次播放器样式；
/// 竖屏下不再手动切系统 UI 模式（本就是 edgeToEdge）。
///
/// 本文件 mock flutter/platform channel 记录 SystemChrome.setSystemUIOverlayStyle /
/// setEnabledSystemUIMode 调用，复现「上滑全过程调用序列」，并锁定修复后的
/// 稳定序列。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/glass_dock_player.dart';
import 'package:md3music/modules/player/player_drag_overlay.dart';
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
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/utils/landscape_immersive.dart';

import '../../support/controlled_audio_service.dart';

const _playerButtonKey = ValueKey('glass_dock_player_button');

Song _localSong(String id, String title) => Song(
      id: id,
      title: title,
      artist: '测试歌手',
      album: '测试专辑',
      duration: const Duration(minutes: 3),
      localPath: '/tmp/$id.mp3',
    );

/// 平台 channel 调用记录（method + 参数快照）。
class _PlatformCall {
  _PlatformCall(this.method, this.args);

  final String method;

  /// setSystemUIOverlayStyle 的 style map / setEnabledSystemUIMode 的
  /// {mode, overlays} map；原样保留便于断言与失败信息比对。
  final Object? args;

  @override
  String toString() => '$method $args';
}

final List<_PlatformCall> _platformCalls = [];

void _installPlatformRecorder() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    final method = call.method;
    if (method == 'SystemChrome.setSystemUIOverlayStyle' ||
        method == 'SystemChrome.setEnabledSystemUIMode' ||
        method == 'SystemChrome.setEnabledSystemUIOverlays' ||
        method == 'SystemChrome.restoreSystemUIOverlays') {
      _platformCalls.add(_PlatformCall(method, call.arguments));
    }
    return null;
  });
}

List<_PlatformCall> get _styleCalls =>
    _platformCalls.where((c) => c.method == 'SystemChrome.setSystemUIOverlayStyle').toList();

List<_PlatformCall> get _modeCalls => _platformCalls
    .where((c) =>
        c.method == 'SystemChrome.setEnabledSystemUIMode' ||
        c.method == 'SystemChrome.setEnabledSystemUIOverlays' ||
        c.method == 'SystemChrome.restoreSystemUIOverlays')
    .toList();

/// app 级系统栏维护者（复刻 app.dart _SystemUiUpdater 的行为：首帧后 /
/// 依赖变化 / metrics 变化 / 亮屏时以主界面沉浸态覆写；播放器沉浸生效中让位）。
class _SystemUiUpdater extends StatefulWidget {
  const _SystemUiUpdater({required this.child});

  final Widget child;

  @override
  State<_SystemUiUpdater> createState() => _SystemUiUpdaterState();
}

class _SystemUiUpdaterState extends State<_SystemUiUpdater>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateSystemUi();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateSystemUi();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _updateSystemUi();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updateSystemUi();
    }
  }

  void _updateSystemUi() {
    if (kPlayerZenImmersiveActive.value) return;
    if (kPlayerLandscapeImmersiveActive.value) return;
    applyMainEdgeToEdge(brightness: Theme.of(context).brightness);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 泵一个贴近真机层次的应用：
/// - 主页面 Scaffold + AppBar（appBarTheme.systemOverlayStyle 与 app_theme 一致，
///   主页面的 AnnotatedRegion 稳态来源）；
/// - MaterialApp.builder 的 Stack 内提供 PlayerDragOverlay（与 app.dart 一致，
///   拖拽期跟手覆盖层渲染真实 FullPlayer）；
/// - _SystemUiUpdater（app 级系统栏来源）。
Future<({PlayerProvider player, ControlledAudioService audio})> _pumpApp(
  WidgetTester tester,
  List<Song> songs,
) async {
  // 竖屏视口（默认 800x600 是横屏，会让 applyImmersiveForOrientation 走
  // 横屏沉浸分支，与真机竖屏场景不符）
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  SharedPreferences.setMockInitialValues({});
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  final player = PlayerProvider();
  await player.playPlaylist(songs, 0);
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
        theme: ThemeData.light(useMaterial3: true).copyWith(
          appBarTheme: AppBarTheme(
            systemOverlayStyle: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
          ),
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('主页')),
          body: Align(
            alignment: Alignment.bottomCenter,
            child: GlassDockPlayer(
              selectedTabId: 'discover',
              onSelectTab: (_) {},
              navExpanded: ValueNotifier<bool>(true),
              onNavExpandedChanged: (_) {},
            ),
          ),
        ),
        builder: (context, child) => _SystemUiUpdater(
          child: Stack(
            children: [
              child!,
              const PlayerDragOverlay(),
            ],
          ),
        ),
      ),
    ),
  );
  // TabConfigProvider 异步加载（SharedPreferences mock）settle
  await tester.pump();
  await tester.pump();
  return (player: player, audio: audio);
}

/// 推进 n 帧（不依赖 pumpAndSettle：FullPlayer 内含跑马灯等常驻节拍，
/// pumpAndSettle 永不返回）。
Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 收尾：收起播放页卸载 FullPlayer（停掉其内部动画 / 节拍），并冲净歌词
/// 请求触发的本地服务就绪等待（8s 超时 Timer）等异步残留，避免测试结束时
/// 残留 pending timer 断言失败。
///
/// 先卸载整棵 widget 树再 dispose provider：Dock 仍挂载时 provider.dispose()
/// 的通知会触发重建，访问已 disposed 的 positionNotifier 断言失败。
Future<void> _teardown(WidgetTester tester, PlayerProvider player,
    ControlledAudioService audio) async {
  activePlayerRoute?.dismiss();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpWidget(const SizedBox.shrink());
  player.dispose();
  await audio.dispose();
  await tester.pump(const Duration(seconds: 9));
  await _pumpFrames(tester, 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _platformCalls.clear();
    // playerExpansion / playerDragActive / activePlayerRoute 是跨用例存活的
    // 全局单例，每个用例开始前统一归位，消除跨用例串扰。
    playerExpansion.value = 0.0;
    playerDragActive.value = false;
    activePlayerRoute = null;
  });

  group('Dock 上滑展开：系统栏样式单一数据源', () {
    testWidgets('拖拽 + settle 全程系统栏样式稳定，完成时仅切换一次', (tester) async {
      _installPlatformRecorder();
      final (:player, :audio) = await _pumpApp(tester, [_localSong('s1', '第一首歌')]);
      try {
        expect(find.byKey(_playerButtonKey), findsOneWidget);
        // 稳态：记录拖拽前的平台调用作为基线（含冷启动的一次性设置）
        final baseline = _styleCalls.length;
        final baselineMode = _modeCalls.length;

        // —— 上滑拖拽：累计距离 220px ≥ 屏高 20%（120px）——
        final center = tester.getCenter(find.byKey(_playerButtonKey));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(const Offset(0, -40)); // 越过 touch slop
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 100));
        expect(playerDragActive.value, isTrue,
            reason: '拖拽应已激活跟手覆盖层');
        expect(playerExpansion.value, greaterThan(0.0));

        // 拖拽过程中：覆盖层展示真实 FullPlayer，系统栏样式不得跳变
        final duringDrag = _styleCalls.length - baseline;
        expect(
          duringDrag,
          0,
          reason: '拖拽过程不应重设系统栏样式（保持主页面稳态），'
              '实际调用序列：${_styleCalls.join('\n')}',
        );

        await gesture.up();

        // —— settleToFull（300ms）：路由接管，从当前进度收敛到全屏 ——
        // 前半程（128ms < 300ms，进度约 0.85 < 1）：样式保持主页面稳态
        await _pumpFrames(tester, 8);
        expect(activePlayerRoute, isNotNull,
            reason: '越过阈值松手应 push 播放页路由');
        final duringSettle = _styleCalls.length - baseline;
        expect(
          duringSettle,
          0,
          reason: 'settle 过程不应重设系统栏样式（保持主页面稳态），'
              '实际调用序列：${_styleCalls.join('\n')}',
        );

        // —— settle 完成（累计 448ms > 300ms）：切换一次播放器样式 ——
        await _pumpFrames(tester, 20);
        final afterComplete = _styleCalls.length - baseline;
        expect(
          afterComplete,
          1,
          reason: '展开完成应只切换一次系统栏样式（播放器样式），'
              '实际调用序列：${_styleCalls.join('\n')}',
        );
        final playerStyle = _styleCalls.last.args as Map;
        expect(playerStyle['statusBarColor'], 0x00000000,
            reason: '播放器样式状态栏应透明');
        expect(playerStyle['systemNavigationBarColor'], 0x00000000,
            reason: '播放器样式导航栏应透明');

        // 竖屏展开不应手动切换系统 UI 模式（本就处于 edgeToEdge），
        // manual→edgeToEdge 往返会引发 metrics 回灌与系统栏显隐闪烁
        expect(
          _modeCalls.length - baselineMode,
          0,
          reason: '竖屏上滑展开不应切换系统 UI 模式，'
              '实际：${_modeCalls.skip(baselineMode).join('\n')}',
        );
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('展开后收起：系统栏样式同样只切换一次且不抖动', (tester) async {
      _installPlatformRecorder();
      final (:player, :audio) = await _pumpApp(tester, [_localSong('s1', '第一首歌')]);
      try {
        // 直接以拖拽链路展开（与上一用例相同的越阈拖拽）
        final center = tester.getCenter(find.byKey(_playerButtonKey));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await _pumpFrames(tester, 30);
        expect(activePlayerRoute, isNotNull);

        final beforeCollapse = _styleCalls.length;

        // 收起：走 dismiss（reverse 300ms + removeRoute），等价顶栏下滑松手
        activePlayerRoute!.dismiss();
        await _pumpFrames(tester, 40);

        // 收起过程 + 完成后：最多一次切回主页面样式的平台调用，
        // 不得出现两种样式快速交替
        final collapseCalls = _styleCalls.length - beforeCollapse;
        expect(
          collapseCalls,
          lessThanOrEqualTo(1),
          reason: '收起过程系统栏样式切换应至多一次，'
              '实际调用序列：${_styleCalls.skip(beforeCollapse).join('\n')}',
        );
        expect(activePlayerRoute, isNull,
            reason: 'reverse 完成后路由应被移除');
        expect(playerExpansion.value, 0.0);
      } finally {
        await _teardown(tester, player, audio);
      }
    });

    testWidgets('未达阈值松手：回归收敛全程系统栏样式稳定', (tester) async {
      _installPlatformRecorder();
      final (:player, :audio) = await _pumpApp(tester, [_localSong('s1', '第一首歌')]);
      try {
        final baseline = _styleCalls.length;
        final baselineMode = _modeCalls.length;

        // 上滑但累计距离 31px < 屏高 20%（160px）、速度 ~350 < 900：
        // 不展开，覆盖层从松手进度 200ms 回归收敛归位
        final center = tester.getCenter(find.byKey(_playerButtonKey));
        final gesture = await tester.startGesture(center);
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 100));
        expect(playerDragActive.value, isTrue,
            reason: '垂直拖拽回调必须已注册');
        expect(playerExpansion.value, greaterThan(0.0));
        await gesture.up();
        // 回归收敛（200ms） + 收敛完成释放拖拽激活
        await _pumpFrames(tester, 20);

        expect(playerExpansion.value, 0.0,
            reason: '未达阈值应回归归位');
        expect(playerDragActive.value, isFalse);
        expect(activePlayerRoute, isNull,
            reason: '未达阈值不得 push 播放页');
        expect(
          _styleCalls.length - baseline,
          0,
          reason: '回归收敛过程不应重设系统栏样式，'
              '实际调用序列：${_styleCalls.skip(baseline).join('\n')}',
        );
        expect(_modeCalls.length - baselineMode, 0,
            reason: '回归收敛不应切换系统 UI 模式');
      } finally {
        await _teardown(tester, player, audio);
      }
    });
  });
}
