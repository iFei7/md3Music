/// Dock 播放器坍缩语义测试（误触坍缩修复 / 语义收紧）：
///
/// 用户反馈「悬浮播放器仅用户点击展开悬浮导航时坍缩；当前未点击到悬浮
/// 导航条也会误触导致播放器坍缩」。根因：玻璃叠色层（LiquidGlassSurface
/// 内 Positioned.fill 的 ColoredBox）以 HitTestBehavior.opaque 命中，整个
/// 播放器胶囊矩形（含 padding / 边缘）均可点；胶囊外层 GestureDetector 的
/// onTap: _toggleControls 在背景区域即生效 → 点胶囊背景误触收起。
///
/// 修复：移除胶囊自身 tap 收起，播放器工具的收起只由「点坍缩导航圆 /
/// 切 tab → 导航展开 → _onNavExpandedChanged 强制收起」驱动。
///
/// 本文件锁定收紧后的语义（导航 notifier 接线与 app.dart _MainLayout 一致：
/// onNavExpandedChanged 真实驱动 navExpanded，保证单展开不变量）：
/// 1. 点胶囊背景（左缘 padding，未命中封面 / 歌名 / 按钮）→ 不坍缩；
/// 2. 点导航坍缩圆 → 导航展开且播放器坍缩（用户认可的唯一点击路径）；
/// 3. 坍缩后可再点播放器圆钮展开（展开 ↔ 收起往返完好）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/glass_dock_player.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/controlled_audio_service.dart';

const _playerButtonKey = ValueKey('glass_dock_player_button');
const _trackTitleKey = ValueKey('glass_dock_track_title');

Song _localSong(String id, String title) => Song(
      id: id,
      title: title,
      artist: '测试歌手',
      album: '测试专辑',
      duration: const Duration(minutes: 3),
      localPath: '/tmp/$id.mp3',
    );

/// 泵一个带播放器的 GlassDockPlayer（本地歌曲已同步设为 currentSong）。
///
/// 与 dock_player_gesture_test 的差异：navExpanded notifier 由
/// onNavExpandedChanged 真实驱动（复刻 app.dart _MainLayout 的双向闭环
/// 接线），否则点播放器圆钮后导航不会坍缩、无法构造「导航球 + 播放器
/// 胶囊」的合法组合，坍缩语义也就无从验证。
Future<({PlayerProvider player, ControlledAudioService audio, ValueNotifier<bool> navExpanded})>
    _pumpDock(WidgetTester tester, List<Song> songs) async {
  SharedPreferences.setMockInitialValues({});
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  final player = PlayerProvider();
  await player.playPlaylist(songs, 0);
  final navExpanded = ValueNotifier<bool>(true);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<TabConfigProvider>(
          create: (_) => TabConfigProvider(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: GlassDockPlayer(
              selectedTabId: 'discover',
              onSelectTab: (_) {},
              navExpanded: navExpanded,
              onNavExpandedChanged: (expanded) => navExpanded.value = expanded,
            ),
          ),
        ),
      ),
    ),
  );
  // TabConfigProvider 异步加载（SharedPreferences mock）settle
  await tester.pump();
  await tester.pump();
  return (player: player, audio: audio, navExpanded: navExpanded);
}

/// 点播放器圆钮展开胶囊（state A → state B：导航坍缩为球、播放器展开为胶囊）。
Future<void> _expandPlayerCapsule(WidgetTester tester) async {
  await tester.tap(find.byKey(_playerButtonKey));
  await tester.pumpAndSettle();
  // AppHaptics.click（圆钮点击反馈）fire-and-forget 注册 300ms 超时 Timer，
  // 必须推进 fake 时间到期，否则测试结束时 pending timer 断言失败
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // playerExpansion / playerDragActive / activePlayerRoute 是跨用例存活的
    // 全局单例，每个用例开始前统一归位，消除跨用例串扰。
    playerExpansion.value = 0.0;
    playerDragActive.value = false;
    activePlayerRoute = null;
  });

  group('误触坍缩修复：仅导航条点击才坍缩播放器', () {
    testWidgets('点胶囊背景（左缘 padding）不坍缩播放器', (tester) async {
      final (:player, :audio, :navExpanded) = await _pumpDock(tester, [
        _localSong('s1', '第一首歌'),
        _localSong('s2', '第二首歌'),
      ]);
      try {
        await _expandPlayerCapsule(tester);
        expect(find.byKey(_trackTitleKey), findsOneWidget,
            reason: '应处于「导航球 + 播放器胶囊」展开态');
        expect(navExpanded.value, isFalse, reason: '播放器展开时导航应坍缩');
        expect(find.byIcon(Icons.library_music_outlined), findsNothing,
            reason: '导航坍缩态不应渲染导航胶囊项');

        // 胶囊矩形左缘 + 3px：落在左 padding（6dp）内，未命中封面（39dp）/
        // 歌名 / 三个按钮的任何交互子元件。修复前此处命中玻璃叠色层
        // （ColoredBox opaque）→ 胶囊外层 onTap 生效 → 误触坍缩。
        final capsuleRect = tester.getRect(find.byKey(_playerButtonKey));
        await tester.tapAt(
          Offset(capsuleRect.left + 3, capsuleRect.center.dy),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(_trackTitleKey), findsOneWidget,
            reason: '点胶囊背景不应坍缩播放器（误触回归）');
        expect(find.byIcon(Icons.library_music_outlined), findsNothing,
            reason: '导航应保持坍缩（单展开不变量）');
        expect(navExpanded.value, isFalse);
      } finally {
        player.dispose();
        await audio.dispose();
        navExpanded.dispose();
        await tester.pump(const Duration(seconds: 5));
      }
    });

    testWidgets('点导航坍缩圆 → 导航展开且播放器坍缩（认可的语义）', (tester) async {
      final (:player, :audio, :navExpanded) = await _pumpDock(tester, [
        _localSong('s1', '第一首歌'),
        _localSong('s2', '第二首歌'),
      ]);
      try {
        await _expandPlayerCapsule(tester);

        // 点导航坍缩圆（当前 tab = discover，filled 图标 Icons.home）：
        // 用户认可的唯一点击坍缩路径。
        await tester.tap(find.byIcon(Icons.home));
        await tester.pumpAndSettle();
        // AppHaptics.click（导航圆点击反馈）300ms 超时 Timer
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(_trackTitleKey), findsNothing,
            reason: '点导航圆后播放器工具应坍缩');
        expect(find.byIcon(Icons.library_music_outlined), findsOneWidget,
            reason: '点导航圆后导航应展开为胶囊');
        expect(navExpanded.value, isTrue);

        // 往返：坍缩后可再点播放器圆钮展开（不破坏既有展开路径）。
        await _expandPlayerCapsule(tester);
        expect(find.byKey(_trackTitleKey), findsOneWidget,
            reason: '坍缩后应能再次展开播放器胶囊');
        expect(find.byIcon(Icons.library_music_outlined), findsNothing,
            reason: '再次展开后导航应重新坍缩（单展开不变量）');
      } finally {
        player.dispose();
        await audio.dispose();
        navExpanded.dispose();
        await tester.pump(const Duration(seconds: 5));
      }
    });
  });
}
