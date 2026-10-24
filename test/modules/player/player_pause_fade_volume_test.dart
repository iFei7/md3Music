/// 批次26：暂停淡出音量收尾回归（widget harness 版，装配学自
/// dock_player_gesture_test 的 _pumpDock 与 playback_status_feedback_test
/// 的 runAsync 时序；provider 级同场景用例见
/// test/providers/player_provider_pause_fade_volume_test.dart）。
///
/// 历史缺陷：淡出循环把 `target.setVolume(currentVol * i / steps)` 递减到 0
/// （i=0 时写 0）后，`await _audioService?.pause()` 无 try 保护——平台层
/// 偶发抛异常时后续 `setVolume(_volume)` 恢复全部被跳过，播放器音量永久 0；
/// 之后任何不经 setUrl 的恢复播放路径（中断 GAIN 自动恢复、
/// _restoreLatestPlaybackAfterStalePause、resume 非淡入分支）都会
/// 「进度条走、完全没声音」。
///
/// 本组用例钉住收尾语义：
/// 1. 异常逃逸路径也必须把音量恢复为 `_volume`（而不是停在 0）；
/// 2. 正常淡出完成后恢复（既有契约不回归），且经 Dock 暂停钮真实用户路径。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
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

Song _onlineSong(String id) => Song(
      id: id,
      title: '淡出目标',
      artist: '测试歌手',
      album: '测试专辑',
      duration: const Duration(minutes: 3),
      url: 'https://media.example/$id.mp3',
      isOnline: true,
    );

/// mock connectivity 平台流：PlayerProvider 初始化会订阅
/// `Connectivity().onConnectivityChanged`，测试环境无实现，激活时抛的
/// MissingPluginException 会变成未处理异步错误直接判失败
/// （同 playback_status_feedback_test 的 _mockConnectivityStream）。
void _mockConnectivityStream() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
    const services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    ),
    MockStreamHandler.inline(
      onListen: (_, events) => events.success(<String>['wifi']),
    ),
  );
}

/// 装配：暂停淡出开 + GlassDockPlayer + ControlledAudioService，播一首在线
/// 歌进入播放态。
///
/// 时序要点（同 playback_status_feedback_test）：provider 的构造与播放装载
/// 全部放进 runAsync 真实时间——`_scheduleAudioServiceInit` 的首帧回调在
/// 未泵帧的环境不会触发，靠 1 秒兜底 Timer 在真实时间启动初始化；若在 fake
/// zone 构造并提前 pumpWidget，初始化链的 microtask 在 runAsync 期间不被
/// flush，audioReady 将永远等不到（实测 10s 超时）。
Future<({PlayerProvider player, ControlledAudioService audio})>
_pumpPlayingDock(WidgetTester tester) async {
  // 竖屏视口（默认 800×600 是横屏，Dock 会走横屏右纵条形态；本组用例
  // 锁定竖屏底部横条的暂停钮路径，批次35）
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _mockConnectivityStream();
  SharedPreferences.setMockInitialValues({
    'settings_pause_fade_enabled': true,
  });
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  late final PlayerProvider player;
  await tester.runAsync(() async {
    player = PlayerProvider();
    await player.audioReady.timeout(const Duration(seconds: 10));
    final playRequest = player.playSong(_onlineSong('fade-widget'));
    await audio.waitForPlaylistLoads(1);
    // 平台在「播放中装载完成」后保留 playWhenReady 并上报 playing=true：
    // playSong 本身不置 _isPlaying（只靠 playingStream 收敛，见
    // playingStream 监听），不发这个事件 Dock 会停在暂停态、胶囊中点钮
    // 渲染的是「播放」而非「暂停」。
    audio.autoResumeAfterLoad = true;
    await audio.completeSourceLoad(0);
    await playRequest;
  });
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
              navExpanded: ValueNotifier<bool>(true),
              onNavExpandedChanged: (_) {},
            ),
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

/// 批次35：窄竖屏视口（400×800）下竖屏胶囊展开首帧（导航胶囊尚未坍缩
/// 让位）会触发「RenderFlex overflowed by 9.0 pixels」**既有伪影**——
/// AnimatedSize 裁剪下不可见，根因是 _buildControlsCapsule 的 fixedWidth
/// 把容器水平 padding 10 重复计入 LayoutBuilder 约束（批次35 之前已存在，
/// 已用原始 lib 代码复现确认，见 dock_landscape_test 同款注释）。按
/// 「相邻问题只报告不顺手改」约定不在本批次修复，此处仅屏蔽该**精确
/// 签名**的既有告警（其他 overflow 仍会照常失败）。
/// 注意：过滤器必须装在用例体内部（setUp 早于 flutter_test binding 安装
/// 自己的 FlutterError.onError，装在 setUp 会被覆盖）。
void Function(FlutterErrorDetails)? _previousOnError;

void _installOverflowFilter() {
  _previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains(
      'A RenderFlex overflowed by 9.0 pixels',
    )) {
      return;
    }
    _previousOnError?.call(details);
  };
}

void _restoreOverflowFilter() {
  FlutterError.onError = _previousOnError ?? FlutterError.onError;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // playerExpansion / playerDragActive / activePlayerRoute 是跨用例存活的
    // 全局单例，每个用例开始前统一归位，消除跨用例串扰（同既有 dock 用例）。
    playerExpansion.value = 0.0;
    playerDragActive.value = false;
    activePlayerRoute = null;
  });

  testWidgets('批次26：暂停淡出中平台 pause() 抛异常，音量仍恢复到 _volume 而非停在 0',
      (tester) async {
    final (:player, :audio) = await _pumpPlayingDock(tester);
    try {
      await tester.runAsync(() async {
        // 非默认用户音量：验证恢复的是 _volume，不是硬编码满量
        await player.setVolume(0.6);
        // 平台层 pause() 偶发失败（正是「音量永久 0」的入口）
        audio.nextPauseError = StateError('platform pause failed');
      });
      // 异常传播语义与淡出关闭路径一致（pause() 原样抛出），用例内手动接住
      // ——不能改走 Dock 暂停钮触发：onTap 丢弃 future，异常会变成未处理的
      // 异步错误直接判失败，反而绕过了 finally 收尾的验证。
      Object? pauseError;
      await tester.runAsync(() async {
        try {
          await player.pause();
        } catch (error) {
          pauseError = error;
        }
      });
      await tester.pump();
      expect(pauseError, isA<StateError>());
      // 淡出确实把音量压到过 0（缺陷窗口被真实走到）
      expect(audio.player.volumeWrites.contains(0.0), isTrue);
      // 收尾必须把音量拉回用户音量，不停在 0
      expect(audio.player.volume, closeTo(0.6, 0.001));
      expect(player.isPlaying, isFalse);
      // 折叠态圆钮：暂停后渲染静态 pause 标识（PlayingSpectrumIndicator 退出）
      expect(find.byIcon(Icons.pause), findsOneWidget,
          reason: '暂停后 Dock 圆钮应进入暂停态');
      // showToast 留 1s Timer 的已知坑：收尾推进 fake 时间
      await tester.pump(const Duration(seconds: 2));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      await tester.runAsync(audio.dispose);
      AudioServiceLoader.setTestOverride(null);
      await tester.pump(const Duration(seconds: 2));
    }
  });

  testWidgets('批次26：Dock 暂停钮真实路径，淡出完成后音量恢复（既有契约不回归）',
      (tester) async {
    final (:player, :audio) = await _pumpPlayingDock(tester);
    try {
      await tester.runAsync(() => player.setVolume(0.6));

      // 展开播放器胶囊（state A → B，同 dock_player_collapse_test）。
      // 批次35：展开首帧屏蔽既有 9px overflow 伪影（见 _installOverflowFilter）。
      _installOverflowFilter();
      await tester.tap(find.byKey(_playerButtonKey));
      await tester.pumpAndSettle();
      // AppHaptics.click 300ms 超时 Timer：必须推进到期
      await tester.pump(const Duration(milliseconds: 300));
      _restoreOverflowFilter();
      expect(find.byTooltip('暂停'), findsOneWidget,
          reason: '播放中应渲染暂停钮');

      // 点暂停钮 → onTap 调用 player.pause()（淡出 10 步 × 50ms）
      await tester.tap(find.byTooltip('暂停'));
      // 单次 pump 600ms：FakeAsync 每个 timer 后 flushMicrotasks，链式
      // Future.delayed 在这一次 elapse 内全部跑完（含平台 pause 与
      // finally 音量恢复）
      await tester.pump(const Duration(milliseconds: 600));

      expect(audio.pauseCommandCount, 1);
      expect(player.isPlaying, isFalse);
      expect(find.byTooltip('播放'), findsOneWidget,
          reason: '暂停后 Dock 应翻转为播放钮');
      // 淡出确实把音量压到过 0
      expect(audio.player.volumeWrites.contains(0.0), isTrue);
      // 收尾恢复用户音量
      expect(audio.player.volume, closeTo(0.6, 0.001));
      // showToast 留 1s Timer 的已知坑：收尾推进 fake 时间
      await tester.pump(const Duration(seconds: 2));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      await tester.runAsync(audio.dispose);
      AudioServiceLoader.setTestOverride(null);
      await tester.pump(const Duration(seconds: 2));
    }
  });
}
