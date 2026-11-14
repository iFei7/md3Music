/// 二级页（仅播放器形态）悬浮播放器打开播放页链路复现测试。
///
/// 真机实测（v6.0.1-lite-563dadb）：二级页上滑或点击悬浮播放器无法打开
/// 播放页，上滑后必现悬浮播放器透明或消失；退出二级页后一级页 Dock 也
/// 受影响。既有链路测试（dock_system_ui_overlay_test）只覆盖一级形态
/// （showNav=true，Dock 在 Navigator 内），本文件复刻 app.dart 的二级页
/// 装配（Dock 在 MaterialApp.builder Stack、Navigator 之上，showNav=false
/// 恒展开胶囊 + 二级路由栈深 2）真跑「点击 openFullPlayer / 上滑拖拽达标
/// → push FullPlayer → settle」链路，复现或排除真机必现问题。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/bootstrap_common.dart' show appNavigatorKey;
import 'package:md3music/core/layout/secondary_dock_controller.dart';
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

import '../../support/controlled_audio_service.dart';

const _playerButtonKey = ValueKey('glass_dock_player_button');
const _secondaryDockKey = ValueKey('secondary_dock');

Song _localSong(String id, String title) => Song(
      id: id,
      title: title,
      artist: '测试歌手',
      album: '测试专辑',
      duration: const Duration(minutes: 3),
      localPath: '/tmp/$id.mp3',
    );

/// 复刻 app.dart 二级页装配：push 二级页后 builder Stack 在 Navigator 之上
/// 挂仅播放器 Dock（showNav=false 恒展开胶囊）。
Future<({
  PlayerProvider player,
  ControlledAudioService audio,
  SecondaryDockController controller,
})> _pumpSecondaryPage(WidgetTester tester, List<Song> songs) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  final player = PlayerProvider();
  await player.playPlaylist(songs, 0);
  final controller = SecondaryDockController();
  final observer = SecondaryDockRouteObserver(controller);
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
        // 复刻 app.dart：全局 navigatorKey（resolveRootNavigator 的
        // builder-Stack Dock 回退通道依赖它）
        navigatorKey: appNavigatorKey,
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('push-secondary'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        const Scaffold(body: Center(child: Text('二级页'))),
                  ),
                ),
                child: const Text('push 二级页'),
              ),
            ),
          ),
        ),
        // 复刻 app.dart builder：二级态在 Navigator 之上挂仅播放器 Dock
        builder: (context, child) {
          return ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return Stack(
                children: [
                  ?child,
                  if (controller.visible)
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Overlay(
                          initialEntries: [
                            OverlayEntry(
                              builder: (_) => GlassDockPlayer(
                                key: _secondaryDockKey,
                                selectedTabId: '',
                                onSelectTab: (_) {},
                                navExpanded: const _ConstNav(),
                                onNavExpandedChanged: (_) {},
                                showNav: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const PlayerDragOverlay(),
                ],
              );
            },
          );
        },
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (player: player, audio: audio, controller: controller);
}

class _ConstNav implements ValueListenable<bool> {
  const _ConstNav();

  @override
  bool get value => true;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// 复刻 dock_system_ui_overlay_test 的收尾：卸载 widget 树 + 冲净音频替身
/// /歌词服务就绪等待（8s 超时 Timer）等异步残留，避免 pending timer 断言。
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    playerExpansion.value = 0.0;
    playerDragActive.value = false;
    activePlayerRoute = null;
    playerDragOriginTop = 0.0;
  });

  testWidgets('前置：push 二级页后仅播放器 Dock 挂出（harness 自检）',
      (tester) async {
    final harness = await _pumpSecondaryPage(
      tester,
      [_localSong('s1', '第一首歌')],
    );
    final player = harness.player;
    final audio = harness.audio;
    final controller = harness.controller;
    try {
      await tester.tap(find.byKey(const ValueKey('push-secondary')));
      await tester.pumpAndSettle();
      expect(controller.visible, isTrue);
      expect(find.byKey(_secondaryDockKey), findsOneWidget);
      expect(find.byKey(_playerButtonKey), findsOneWidget);
    } finally {
      await _teardown(tester, player, audio);
    }
  });

  testWidgets('二级页点击悬浮播放器 → openFullPlayer → 播放页展开',
      (tester) async {
    final harness = await _pumpSecondaryPage(
      tester,
      [_localSong('s1', '第一首歌')],
    );
    final player = harness.player;
    final audio = harness.audio;
    final controller = harness.controller;
    try {
      await tester.tap(find.byKey(const ValueKey('push-secondary')));
      await tester.pumpAndSettle();
      expect(find.byKey(_playerButtonKey), findsOneWidget);

      // 点击胶囊封面（onTap → openFullPlayer）。胶囊可能含多个 onTap 命中区，
      // 用播放器按钮中心点直接 tap（外层 GestureDetector behavior: opaque）。
      await tester.tap(find.byKey(_playerButtonKey), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint('after-tap: activeRoute=${activePlayerRoute != null} '
          'exp=${playerExpansion.value} dragActive=${playerDragActive.value}');

      await tester.pumpAndSettle(const Duration(seconds: 1));

      debugPrint('after-settle: activeRoute=${activePlayerRoute != null} '
          'exp=${playerExpansion.value} dragActive=${playerDragActive.value}');

      expect(activePlayerRoute, isNotNull,
          reason: '点击悬浮播放器应 push 播放页路由');
      expect(playerExpansion.value, 1.0, reason: '播放页应完整展开');
      expect(playerDragActive.value, isFalse);
      expect(controller.visible, isFalse,
          reason: '完整播放页属排除路由，二级页 Dock 应隐藏');
    } finally {
      await _teardown(tester, player, audio);
    }
  });

  testWidgets('二级页上滑悬浮播放器（达标）→ push 播放页 → settle 全屏',
      (tester) async {
    final harness = await _pumpSecondaryPage(
      tester,
      [_localSong('s1', '第一首歌')],
    );
    final player = harness.player;
    final audio = harness.audio;
    try {
      await tester.tap(find.byKey(const ValueKey('push-secondary')));
      await tester.pumpAndSettle();
      expect(find.byKey(_playerButtonKey), findsOneWidget);

      // 上滑拖拽：累计 220px ≥ 阈值（长边 800 的 20% = 160）
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

      debugPrint('mid-drag: exp=${playerExpansion.value} '
          'dragActive=${playerDragActive.value} '
          'originTop=$playerDragOriginTop');

      expect(playerDragActive.value, isTrue, reason: '拖拽应已激活跟手覆盖层');
      expect(playerExpansion.value, greaterThan(0.0));

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 16));

      debugPrint('after-up: activeRoute=${activePlayerRoute != null} '
          'exp=${playerExpansion.value} dragActive=${playerDragActive.value}');

      expect(activePlayerRoute, isNotNull,
          reason: '越过阈值松手应 push 播放页路由（修复前此处为 null：'
              'builder-Stack Dock 的 Navigator.of 抛异常，exp 卡中间值）');

      await tester.pumpAndSettle(const Duration(seconds: 1));
      debugPrint('after-settle: exp=${playerExpansion.value} '
          'dragActive=${playerDragActive.value}');
      expect(playerExpansion.value, 1.0, reason: '播放页应 settle 到全屏');
      expect(playerDragActive.value, isFalse);
    } finally {
      await _teardown(tester, player, audio);
    }
  });

  testWidgets('播放页关闭回到二级页 → 再点悬浮播放器可再次打开（复现残留影响）',
      (tester) async {
    final harness = await _pumpSecondaryPage(
      tester,
      [_localSong('s1', '第一首歌')],
    );
    final player = harness.player;
    final audio = harness.audio;
    final controller = harness.controller;
    try {
      await tester.tap(find.byKey(const ValueKey('push-secondary')));
      await tester.pumpAndSettle();

      // 第一次：点击打开
      await tester.tap(find.byKey(_playerButtonKey), warnIfMissed: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(activePlayerRoute, isNotNull, reason: '首次点击应打开播放页');

      // 关闭播放页（dismiss 等价：reverse + removeRoute）
      activePlayerRoute!.dismiss();
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(activePlayerRoute, isNull);
      expect(playerExpansion.value, 0.0);
      expect(controller.visible, isTrue, reason: '回到二级页 Dock 应恢复');

      // 第二次：再点（真机场景：此前打不开）
      await tester.tap(find.byKey(_playerButtonKey), warnIfMissed: false);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      debugPrint('second-open: activeRoute=${activePlayerRoute != null} '
          'exp=${playerExpansion.value}');
      expect(activePlayerRoute, isNotNull, reason: '再次点击应能重新打开播放页');
      expect(playerExpansion.value, 1.0);
    } finally {
      await _teardown(tester, player, audio);
    }
  });
}
