/// Dock 播放器手势回归测试（批次 5）：
///
/// 1. 「收起后无法再次上滑展开」回归——根因是拖拽回调注册在 build 期
///    快照判定（含 activePlayerRoute 检查）：播放页展开期间 Dock 子树被
///    移除，收起动画中段（exp 回落 ≤ 0.5、路由仍在栈中）子树重挂载时
///    注册了空回调；暂停态无 position tick 通知重建，回调永久缺失。
///    修复后注册只看 song != null，「播放页已在栈中」由拖拽 start 运行时
///    守卫拦截。测试模拟该窗口并验证拖拽可再次驱动 playerExpansion。
/// 2. 左右滑切歌动效：歌名跟手位移露出相邻方向歌名预览；未过阈值回弹
///    归位；过距离阈值（≥ 歌名区宽一半）松手切歌。
///
/// 注意：不真跑完整展开→收起链路（拖拽松手 push 的是重量级 FullPlayer，
/// 含歌词网络请求等测试环境不可控依赖），收起路径用轻量
/// DraggablePlayerRoute + playerExpansion 直接驱动复现同一注册窗口。
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
/// 音频服务经 [AudioServiceLoader.setTestOverride] 注入 [ControlledAudioService]：
/// playSong/playPlaylist 在首帧前调用、真实引擎尚未就位（_initAudioService 由
/// 首帧 postFrameCallback 触发），状态更新后即返回、不发起装载；首帧后替身
/// 就位，让用例内后续 next()/previous() 的平台调用（setSpeed 等）立即完成——
/// 否则 just_audio 平台通道在测试环境无应答，next() 会永久挂起在
/// resetAutomixRate 上，永远走不到 currentSong 更新。
///
/// 批次35：① 竖屏视口（默认 800×600 是横屏，Dock 会走横屏右纵条形态；
/// 本组用例锁定竖屏底部横条的手势语义）；② navExpanded 由
/// onNavExpandedChanged 真实驱动（复刻 app.dart _MainLayout 的双向闭环
/// 接线，同 dock_player_collapse_test）——点播放器圆钮后导航坍缩让位，
/// 歌名 marquee 才拿得到宽度（400×800 视口下不接线时 marquee 恒为 0，
/// 左右滑切歌用例无从验证）。
Future<({PlayerProvider player, ControlledAudioService audio})> _pumpDock(
  WidgetTester tester,
  List<Song> songs,
) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  final player = PlayerProvider();
  if (songs.length == 1) {
    await player.playSong(songs.first);
  } else {
    await player.playPlaylist(songs, 0);
  }
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
  return (player: player, audio: audio);
}

/// 模拟一次「播放页在栈中 → 收起窗口（exp 回落、路由仍 active）→
/// 路由移除」的完整窗口，与真机 dismiss() 的时序等价。
Future<void> _pumpCollapseWindow(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  final route = DraggablePlayerRoute<void>(
    builder: (_) => const SizedBox.shrink(),
    dragOriginTop: 400,
    screenHeight: 600,
  );
  navigator.push(route);
  await tester.pump();

  // 展开态：Dock 整体移除（exp > 0.5 且无拖拽豁免）
  playerExpansion.value = 1.0;
  await tester.pump();
  expect(find.byKey(_playerButtonKey), findsNothing,
      reason: '播放页展开时 Dock 播放器钮应被移除');

  // 收起动画中段窗口：exp 回落 ≤ 0.5，此刻路由仍在栈中
  // （真机上 removeRoute 发生在 dismiss 的 reverse 动画完成后）
  playerExpansion.value = 0.0;
  await tester.pump();

  // 收起完成：路由移除（等价 dismiss() reverse 完成后的 navigator.removeRoute）
  navigator.removeRoute(route);
  await tester.pump();
  expect(activePlayerRoute, isNull);
}

/// 拖拽事件注入注意（DragStartBehavior.start 语义）：竞技场接受拖拽的那一
/// 个 move（越过 touch slop）只派发 onVerticalDragStart——接受前的位移被折
/// 进拖拽起点、不产生 update（见 flutter monodrag.dart `_checkDrag`）。
/// 因此每个拖拽序列必须由「越障 move + 跟进 move」两段组成，update 回调
/// 才会被触发、跟手映射才会被验证。
Future<void> _dragUpBelowThreshold(WidgetTester tester) async {
  final center = tester.getCenter(find.byKey(_playerButtonKey));
  final gesture = await tester.startGesture(center);
  await tester.pump(const Duration(milliseconds: 16));
  // 越过 touch slop（40 > 18）：仅派发 start，激活 playerDragActive。
  await gesture.moveBy(const Offset(0, -40));
  await tester.pump(const Duration(milliseconds: 16));
  // 接受后的首个 move：派发 update，验证拖拽通道活着且跟手驱动 exp。
  await gesture.moveBy(const Offset(0, -1));
  await tester.pump(const Duration(milliseconds: 84));
  expect(playerDragActive.value, isTrue,
      reason: '垂直拖拽回调必须已注册（回归：过期快照曾注册空回调）');
  expect(playerExpansion.value, greaterThan(0.0), reason: '拖拽应跟手驱动 exp');
  await gesture.moveBy(const Offset(0, -30));
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.up();
  // 未达三阈值（update 口径累计 31 < 120、速度 ~350 < 900）→ 覆盖层从
  // 松手进度收敛归位（200ms easeOutCubic 回归动画 _startDragReturn，
  // 替代此前的瞬跳置 0），settle 后归位、释放拖拽激活且不 push 播放页
  await tester.pumpAndSettle();
  expect(playerExpansion.value, 0.0);
  expect(playerDragActive.value, isFalse,
      reason: '回归收敛结束后应释放拖拽激活');
  expect(activePlayerRoute, isNull);
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
    // 全局单例：前一个用例若在拖拽中途断言失败（手势未 up），残留的
    // playerDragActive=true 会让下一用例的「exp > 0.5 移除 Dock」被拖拽豁免
    // 拦截。每个用例开始前统一归位，消除跨用例串扰。
    playerExpansion.value = 0.0;
    playerDragActive.value = false;
    activePlayerRoute = null;
  });

  group('收起后可再次上滑展开（回归）', () {
    testWidgets('「路由 active 期重挂载」窗口后拖拽通道可用', (tester) async {
      final (:player, :audio) = await _pumpDock(tester, [_localSong('s1', '第一首歌')]);
      try {
        expect(find.byKey(_playerButtonKey), findsOneWidget);
        await _pumpCollapseWindow(tester);
        await _dragUpBelowThreshold(tester);
      } finally {
        player.dispose();
        await audio.dispose();
        await tester.pump(const Duration(seconds: 5));
      }
    });

    testWidgets('两轮展开↔收起往复后拖拽通道仍可用', (tester) async {
      final (:player, :audio) = await _pumpDock(tester, [_localSong('s1', '第一首歌')]);
      try {
        for (var round = 0; round < 2; round++) {
          await _pumpCollapseWindow(tester);
          await _dragUpBelowThreshold(tester);
        }
      } finally {
        player.dispose();
        await audio.dispose();
        await tester.pump(const Duration(seconds: 5));
      }
    });
  });

  group('左右滑切歌：歌名跟手预览 + 阈值判定', () {
    testWidgets('向左滑露出下一曲预览；未过阈值回弹；过阈值切歌', (tester) async {
      final (:player, :audio) = await _pumpDock(tester, [
        _localSong('s1', '第一首歌'),
        _localSong('s2', '第二首歌'),
      ]);
      try {
        // 点圆钮展开播放器胶囊。批次35：展开首帧屏蔽既有 9px overflow
        // 伪影（见 _installOverflowFilter 注释）。
        _installOverflowFilter();
        await tester.tap(find.byKey(_playerButtonKey));
        await tester.pumpAndSettle();
        _restoreOverflowFilter();
        final title = find.byKey(_trackTitleKey);
        expect(title, findsOneWidget);
        final origin = tester.getCenter(title);

        // 向左拖（< 歌名区宽 120 的一半）：露出下一曲预览。
        // 两段 move：首段 -24 越过水平 touch slop（仅派发 start），
        // 次段 -6 才派发 update（DragStartBehavior.start 语义，见
        // _dragUpBelowThreshold 注释），_switchDx 跟手为 -6。
        var gesture = await tester.startGesture(origin);
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump(const Duration(milliseconds: 84));
        await gesture.moveBy(const Offset(-6, 0));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('第二首歌'), findsOneWidget,
            reason: '向左滑应露出下一曲歌名预览');
        // 未过阈值（距离 6 < 60、速度 ~60 < 400）松手 → 回弹归位
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.text('第二首歌'), findsNothing, reason: '回弹后预览层应消失');
        expect(player.currentSong?.id, 's1', reason: '未过阈值不得切歌');

        // 再向左拖 80px（update 口径 ≥ 60）→ 过距离阈值切歌。
        // 同样两段：-20 越障 + -60 update（dx = -60 ≥ 60）。
        gesture = await tester.startGesture(origin);
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(-60, 0));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(player.currentSong?.id, 's2', reason: '过距离阈值应切到下一曲');

        // 收尾：next() 内挂起的替身装载手动完成，避免装载截止 Timer 残留。
        if (audio.playlistLoads.isNotEmpty) {
          await audio.completeSourceLoad(audio.playlistLoads.length - 1);
        }
      } finally {
        player.dispose();
        await audio.dispose();
        await tester.pump(const Duration(seconds: 5));
      }
    });
  });
}
