// 批次43：TV 播放页测试。
//
// 宿主：MaterialApp + MultiProvider 桩（PlayerProvider 走
// ControlledAudioService 受控音频 + AudioServiceLoader.setTestOverride，
// 照抄 test/providers/player_provider_pause_fade_volume_test.dart 的装配）。
// KugouProvider 歌词用 restoreLyric 静态钩子离线注入，避免真实网络。
//
// 纪律：AppleMusicLyricsView 自带 Ticker 自驱动内插、黑胶 18s/圈 repeat——
// **全部使用有界 pump，禁 pumpAndSettle**。
import 'dart:io';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/apple_music_lyrics_view.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/tv/player/tv_control_bar.dart';
import 'package:md3music/tv/player/tv_full_player.dart';
import 'package:md3music/widgets/common/liquid_glass_surface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/controlled_audio_service.dart';

/// 播放页测试 spy：记录 next/seek 调用（页级按键映射取证用）。
class SpyPlayer extends PlayerProvider {
  int nextCalls = 0;
  final List<Duration> seeks = [];

  @override
  Future<void> next({bool autoPlay = true}) async {
    nextCalls++;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }
}

Song buildSong({
  String id = 'tv43-song',
  String? artworkUri = 'https://img.example/tv43.jpg',
}) => Song(
  id: id,
  title: '测试歌曲',
  artist: '测试歌手',
  album: '测试专辑',
  duration: const Duration(minutes: 3),
  url: 'https://media.example/$id.mp3',
  isOnline: true,
  artworkUri: artworkUri,
);

Widget buildHost(PlayerProvider player) => MultiProvider(
  providers: [
    ChangeNotifierProvider<PlayerProvider>.value(value: player),
    ChangeNotifierProvider<KugouProvider>(
      create: (_) => KugouProvider(registerDeviceOnStart: false),
    ),
    ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
    ChangeNotifierProvider<LocalFavoritesProvider>(
      create: (_) => LocalFavoritesProvider(),
    ),
  ],
  child: MaterialApp(builder: Dpad.wrap(), home: const TvFullPlayer()),
);

/// 平台通道桩（照抄 full_player_landscape_test：connectivity / home_widget /
/// platform / path_provider），避免测试环境通道挂起与残留 Timer。
void _mockPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockStreamHandler(
    const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
    MockStreamHandler.inline(
      onListen: (_, events) => events.success(<String>['wifi']),
    ),
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.md3music.md3music/home_widget'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' ||
      'getApplicationSupportDirectory' ||
      'getApplicationDocumentsDirectory' ||
      'getDownloadsDirectory' => Directory.systemTemp.path,
      _ => null,
    },
  );
}

/// 装配一首在线歌进入播放态（受控音频，无真实网络）。
///
/// **必须包 tester.runAsync**：FakeAsync 区内裸 await audioReady 等真实
/// 异步链路会死锁（Timer 不推进），与 full_player_landscape_test 同因同解。
Future<({PlayerProvider player, ControlledAudioService audio})>
setupPlayingSong(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  _mockPlatformChannels();
  // 歌词走 restoreLyric 静态钩子离线注入：不设的话 getLyric 会进
  // LocalServerLifecycle.waitUntilReady（8s 假 Timer），testWidgets 结束时
  // 报 "A Timer is still pending"。默认注入有歌词版本；无歌词用例自行覆盖。
  KugouProvider.restoreLyric =
    (hash) async => const KugouLyric(
        content: '[00:01.00]第一行\n[00:05.00]第二行',
        decodedContent: '[00:01.00]第一行\n[00:05.00]第二行',
      );
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  PlayerProvider? player;
  await tester.runAsync(() async {
    final active = PlayerProvider();
    player = active;
    await active.audioReady.timeout(const Duration(seconds: 10));
    final playRequest = active.playSong(buildSong());
    await audio.waitForPlaylistLoads(1);
    await audio.completeSourceLoad(0);
    await playRequest;
    audio.emitPlaying(true);
  });
  return (player: player!, audio: audio);
}

/// 装配无歌态 provider（同样经 runAsync，理由同上）。
Future<({PlayerProvider player, ControlledAudioService audio})>
setupIdlePlayer(WidgetTester tester, {bool spy = false}) async {
  SharedPreferences.setMockInitialValues({});
  _mockPlatformChannels();
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  PlayerProvider? player;
  await tester.runAsync(() async {
    final active = spy ? SpyPlayer() : PlayerProvider();
    player = active;
    await active.audioReady.timeout(const Duration(seconds: 10));
  });
  return (player: player!, audio: audio);
}

/// 统一清理：卸载页面树（MultiProvider 随之 dispose KugouProvider 等）→
/// dispose PlayerProvider / 受控音频 → 还原静态钩子。
Future<void> teardown(
  WidgetTester tester,
  PlayerProvider player,
  ControlledAudioService audio,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  player.dispose(); // ChangeNotifier.dispose 为同步 void
  await audio.dispose();
  AudioServiceLoader.setTestOverride(null);
  KugouProvider.restoreLyric = null;
}

/// 有界推进若干微任务/短帧（歌词异步加载等，不 pumpAndSettle）。
Future<void> pumpLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Z1 动态环境背景', () {
    testWidgets('无歌时纯色基底降级（无模糊层，基底 #08090C）', (tester) async {
      final setup = await setupIdlePlayer(tester);
      try {
        await tester.pumpWidget(buildHost(setup.player));
        await pumpLoad(tester);
        // 无封面 → 无 ImageFiltered 模糊层；基底色由 Scaffold 提供
        expect(find.byType(ImageFiltered), findsNothing);
        final scaffold = tester.widget<Material>(
          find.descendant(
            of: find.byType(Scaffold),
            matching: find.byType(Material),
          ),
        );
        expect(scaffold.color, const Color(0xFF08090C));
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('有歌时模糊背景层存在（ImageFiltered，σ=90×scale 满血）', (tester) async {
      final setup = await setupPlayingSong(tester);
      try {
        await tester.pumpWidget(buildHost(setup.player));
        await pumpLoad(tester);
        await tester.pump(const Duration(milliseconds: 700)); // 越过 600ms 溶解
        expect(find.byType(ImageFiltered), findsOneWidget);
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });  });

  group('Z2 核心内容', () {
    testWidgets('歌名渲染 + 黑胶结构存在（有歌词：黑胶在左栏设计位）', (tester) async {
      KugouProvider.restoreLyric =
        (hash) async => const KugouLyric(
            content: '[00:01.00]第一行\n[00:05.00]第二行',
            decodedContent: '[00:01.00]第一行\n[00:05.00]第二行',
          );
      final setup = await setupPlayingSong(tester);
      try {
        await tester.pumpWidget(buildHost(setup.player));
        await pumpLoad(tester);
        await tester.pump(const Duration(milliseconds: 700));
        // 歌名 48 Bold（scale=0.5 → 24 逻辑 px）
        final title = tester.widget<Text>(
          find.byKey(const ValueKey('tv43_title')),
        );
        expect(title.data, '测试歌曲');
        expect(title.style?.fontSize, 24); // 48 × 0.5
        // 黑胶结构
        expect(find.byKey(const ValueKey('tv43_vinyl')), findsOneWidget);
        // 有歌词 → 歌词视图挂载、黑胶在左栏（设计中心 x=316 → left 28 逻辑 px）
        expect(find.byType(AppleMusicLyricsView), findsOneWidget);
        final vinylLeft = tester.getTopLeft(
          find.byKey(const ValueKey('tv43_vinyl')),
        );
        expect(vinylLeft.dx, 28.0); // (316-260)×0.5
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('无歌词时歌词区隐藏、黑胶水平居中补偿', (tester) async {
      final setup = await setupPlayingSong(tester);
      // 覆盖 setup 默认的有歌词注入：空内容 → 解析 0 行 → 歌词区隐藏
      KugouProvider.restoreLyric =
        (hash) async => const KugouLyric(content: '', decodedContent: '');
      try {
        await tester.pumpWidget(buildHost(setup.player));
        await pumpLoad(tester);
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.byType(AppleMusicLyricsView), findsNothing);
        final vinylLeft = tester.getTopLeft(
          find.byKey(const ValueKey('tv43_vinyl')),
        );
        expect(vinylLeft.dx, 350.0); // (960-260)×0.5，页面水平居中
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });

  group('Z3 呼出控制条', () {
    testWidgets('初始隐藏：opacity=0 + IgnorePointer=true', (tester) async {
      final setup = await setupIdlePlayer(tester);
      try {
        await tester.pumpWidget(buildHost(setup.player));
        await pumpLoad(tester);
        final opacity = tester.widget<AnimatedOpacity>(
          find.byKey(const ValueKey('tv43_bar_opacity')),
        );
        expect(opacity.opacity, 0);
        final ignore = tester.widget<IgnorePointer>(
          find.byKey(const ValueKey('tv43_bar_ignore')),
        );
        expect(ignore.ignoring, isTrue);
        // 玻璃背板存在（LiquidGlassSurface 常挂载）
        expect(find.byType(LiquidGlassSurface), findsOneWidget);
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('↑ 唤醒 → 显示；3.5s 无操作 → 600ms 淡出', (tester) async {
      final setup = await setupIdlePlayer(tester);
      try {
        await tester.pumpWidget(buildHost(setup.player));
        await pumpLoad(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        final opacity = tester.widget<AnimatedOpacity>(
          find.byKey(const ValueKey('tv43_bar_opacity')),
        );
        expect(opacity.opacity, 1);
        // 3.5s + 600ms 淡出
        await tester.pump(const Duration(milliseconds: 3500));
        await tester.pump(const Duration(milliseconds: 650));
        expect(
          tester.widget<AnimatedOpacity>(
            find.byKey(const ValueKey('tv43_bar_opacity')),
          ).opacity,
          0,
        );
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('按钮交互唤醒重置计时（3s 时再唤醒 → +2s 仍显示）', (tester) async {
      final setup = await setupIdlePlayer(tester);
      try {
        await tester.pumpWidget(buildHost(setup.player));
        await pumpLoad(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2000));
        // 再唤醒一次（重置 3.5s 计时）
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 2000));
        expect(
          tester.widget<AnimatedOpacity>(
            find.byKey(const ValueKey('tv43_bar_opacity')),
          ).opacity,
          1,
          reason: '距上次唤醒仅 2s，不应隐藏',
        );
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pump(const Duration(milliseconds: 650));
        expect(
          tester.widget<AnimatedOpacity>(
            find.byKey(const ValueKey('tv43_bar_opacity')),
          ).opacity,
          0,
        );
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('播放态下按 OK（select）→ isPlaying 翻转（盲操暂停）', (tester) async {
      final setup = await setupPlayingSong(tester);
      try {
        await tester.pumpWidget(buildHost(setup.player));
        await pumpLoad(tester);
        expect(setup.player.isPlaying, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump(const Duration(milliseconds: 1000)); // 越过暂停淡出计时器
        expect(setup.player.isPlaying, isFalse);
        expect(setup.audio.pauseCommandCount, 1);
        // 再按 OK → 恢复
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump(const Duration(milliseconds: 1000)); // 越过恢复淡入计时器
        expect(setup.player.isPlaying, isTrue);
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });

  group('按键映射（spy provider）', () {
    testWidgets('↓ 直接下一首', (tester) async {
      final setup = await setupIdlePlayer(tester, spy: true);
      final player = setup.player as SpyPlayer;
      try {
        await tester.pumpWidget(buildHost(player));
        await pumpLoad(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(player.nextCalls, 1);
      } finally {
        await teardown(tester, player, setup.audio);
      }
    });

    testWidgets('控制条隐藏时 ←/→ 直接 seek ±10s', (tester) async {
      final setup = await setupIdlePlayer(tester, spy: true);
      final player = setup.player as SpyPlayer;
      try {
        await tester.pumpWidget(buildHost(player));
        await pumpLoad(tester);
        player.positionNotifier.value = const Duration(seconds: 30);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(player.seeks.last, const Duration(seconds: 20));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(player.seeks.last, const Duration(seconds: 40));
      } finally {
        await teardown(tester, player, setup.audio);
      }
    });
  });

  group('进度 seek 步进器（TvSeekStepper）', () {
    testWidgets('← 步进 10s 显示推进；600ms 防抖后 seek 落定一次', (tester) async {
      final commits = <Duration>[];
      final stepper = TvSeekStepper(onCommit: commits.add);
      const current = Duration(seconds: 30);
      stepper.step(-1, current);
      expect(stepper.displayPosition(current), const Duration(seconds: 20));
      stepper.step(-1, current); // 第二步重置防抖
      expect(stepper.displayPosition(current), const Duration(seconds: 10));
      expect(commits, isEmpty);
      await tester.pump(const Duration(milliseconds: 599));
      expect(commits, isEmpty, reason: '599ms 仍在防抖窗口内');
      await tester.pump(const Duration(milliseconds: 1));
      expect(commits, [const Duration(seconds: 10)]);
      expect(stepper.isActive, isFalse);
    });

    testWidgets('OK 立即落定（commitNow）；下界钳制 0', (tester) async {
      final commits = <Duration>[];
      final stepper = TvSeekStepper(onCommit: commits.add);
      stepper.step(-1, const Duration(seconds: 5));
      expect(stepper.displayPosition(const Duration(seconds: 5)), Duration.zero);
      stepper.commitNow();
      expect(commits, [Duration.zero]);
      expect(stepper.isActive, isFalse);
    });

    testWidgets('reset 丢弃 pending 不落定', (tester) async {
      final commits = <Duration>[];
      final stepper = TvSeekStepper(onCommit: commits.add);
      stepper.step(1, Duration.zero);
      stepper.reset();
      await tester.pump(const Duration(milliseconds: 700));
      expect(commits, isEmpty);
      expect(stepper.isActive, isFalse);
    });
  });
}
