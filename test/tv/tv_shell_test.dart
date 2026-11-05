// 批次44：TV 顶栏壳层（TvTopChrome / TvMiniBar / TvContentFocusRegion）测试。
//
// 背景：批次43 的左侧玻璃 Rail 壳层真机不可用，批次44 废弃并移植上游
// （origin/rust-local-force）「顶栏双层 chrome + 真实 tab 内容」结构：
// - 第一层：头像胶囊 / TvMiniBar（迷你播放条）/ 搜索钮；
// - 第二层：横向 tab（聚焦即选中，参照上游 TvTabBarItem 语义，设置固定追加）；
// - 内容区：真实 tab 页（_MainLayout body），TvContentFocusRegion 承接
//   上边缘 → 第二层当前 tab 的焦点移交。
//
// 宿主装配（照抄 test/tv/player/tv_player_page_test.dart 的口径）：
// PlayerProvider 走 ControlledAudioService 受控音频 + 平台通道桩；
// KugouProvider 关闭设备注册避免真实网络。全部有界 pump，禁 pumpAndSettle
// （AppHaptics 兜底 300ms Timer、dpad 焦点请求异步生效，统一 pump(400ms) 越过）。
import 'dart:io';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/layout/tv_nav_focus_bridge.dart';
import 'package:md3music/core/layout/tv_shell.dart';
import 'package:md3music/core/remote/tv_player_bar_focus_bridge.dart';
import 'package:md3music/core/remote/tv_top_chrome_scope.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/widgets/common/glass_circle_button.dart';
import 'package:md3music/widgets/common/liquid_glass_surface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// 播放控制 spy：钉住「迷你条播放/暂停 → PlayerProvider 调用」。
///
/// isPlaying / currentSong 为桩值（基类读私有字段无法直接置位），
/// pause / resume 只计数不发播放指令。
class _SpyPlayer extends PlayerProvider {
  int resumeCalls = 0;
  int pauseCalls = 0;
  bool forcedPlaying = false;

  @override
  bool get isPlaying => forcedPlaying;

  @override
  Song? get currentSong => Song(
        id: 'spy-song',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        duration: Duration(minutes: 3),
        url: 'https://media.example/spy.mp3',
        isOnline: true,
      );

  @override
  Future<void> resume() async => resumeCalls++;

  @override
  Future<void> pause() async => pauseCalls++;
}

/// 平台通道桩（照抄 tv_player_page_test：connectivity / home_widget /
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

/// 装配空闲态 provider（无歌/有歌均由 spy 桩值控制），经 runAsync 等待
/// 音频引擎就绪（FakeAsync 区内裸 await 真实异步链路会死锁，同因同解）。
Future<({PlayerProvider player, ControlledAudioService audio})>
setupPlayer(WidgetTester tester, {bool spy = false}) async {
  SharedPreferences.setMockInitialValues({});
  _mockPlatformChannels();
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  PlayerProvider? player;
  await tester.runAsync(() async {
    final active = spy ? _SpyPlayer() : PlayerProvider();
    player = active;
    await active.audioReady.timeout(const Duration(seconds: 10));
  });
  return (player: player!, audio: audio);
}

/// 统一清理：卸载树 → dispose provider / 受控音频 → 还原静态钩子。
Future<void> teardown(
  WidgetTester tester,
  PlayerProvider player,
  ControlledAudioService audio,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  player.dispose();
  await audio.dispose();
  AudioServiceLoader.setTestOverride(null);
}

Song buildSong({
  String id = 'tv44-song',
  String? artworkUri,
}) =>
    Song(
      id: id,
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      duration: const Duration(minutes: 3),
      url: 'https://media.example/$id.mp3',
      isOnline: true,
      artworkUri: artworkUri,
    );

/// 与 app.dart TV 分支同构的装配：Column[TvTopChrome,
/// Expanded(TvContentFocusRegion(body))]，body 放一枚可聚焦探针。
/// TabConfigProvider 桩供 _MainLayout 之外的映射读取（chrome 本身吃纯参数）。
Widget buildHost({
  required PlayerProvider player,
  int selectedIndex = 0,
  void Function(int index)? onTabSelected,
  List<TabItem>? visibleTabs,
}) {
  final tabs = visibleTabs ?? List.of(kDefaultTabs);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider<KugouProvider>(
        create: (_) => KugouProvider(registerDeviceOnStart: false),
      ),
    ],
    child: MaterialApp(
      builder: Dpad.wrap(),
      routes: {
        '/player': (_) => const SizedBox(key: ValueKey('player_page')),
        '/search': (_) => const SizedBox(key: ValueKey('search_page')),
      },
      home: Scaffold(
        body: Column(
          children: [
            TvTopChrome(
              visibleTabs: tabs,
              selectedIndex: selectedIndex,
              onTabSelected: onTabSelected ?? (_) {},
            ),
            Expanded(
              child: TvContentFocusRegion(
                selectedIndex: selectedIndex,
                child: DpadFocusable(
                  focusNode: _probeNode,
                  debugLabel: 'probe',
                  child: const Text('内容探针'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 内容区探针节点（测试自持，随 testWidgets 环境回收）。
final FocusNode _probeNode = FocusNode(debugLabel: 'test/probe');

/// TV 布局按 1920 设计宽换算，测试面设为 1920×1080（dpr=1 → scale=1）。
void prepareView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 首帧 + 越过 AppHaptics 兜底 Timer（300ms）。
Future<void> pumpHost(WidgetTester tester, Widget host) async {
  prepareView(tester);
  await tester.pumpWidget(host);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('顶栏渲染（第一层 + 第二层）', () {
    testWidgets('第一层三元素：头像胶囊（未登录）/ 迷你条占位 / 搜索钮', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        expect(find.text('未登录'), findsOneWidget,
            reason: '未登录态头像胶囊显示「未登录」占位');
        expect(find.text('未在播放'), findsOneWidget,
            reason: '无歌时迷你条显示占位文案');
        expect(find.byType(GlassCircleButton), findsOneWidget,
            reason: '第一层右侧有玻璃搜索钮');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('第二层 tab 数 = visibleTabs + 设置（固定追加末尾）', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        // 四个默认 tab 按 TV 口径换名 + 固定追加的设置。
        // 初始选中第 1 项（discover）：仅当前 tab 显示名称（上游口径），
        // 其余 tab 以图标呈现。
        expect(find.text('推荐'), findsOneWidget, reason: 'discover → 推荐（选中项显示名称）');
        expect(find.text('我的音乐'), findsNothing, reason: '非选中 tab 不显示名称');
        expect(find.byIcon(Icons.explore), findsOneWidget);
        expect(find.byIcon(Icons.library_music), findsOneWidget);
        expect(find.byIcon(Icons.radio), findsOneWidget);
        expect(find.byIcon(Icons.search), findsNWidgets(2),
            reason: 'search tab 图标 + 第一层搜索钮');
        expect(find.byIcon(Icons.settings), findsOneWidget,
            reason: '设置固定追加在第二层末尾');

        // 顶栏玻璃材质（LiquidGlassSurface 承载两层 chrome）。
        expect(find.byType(LiquidGlassSurface), findsAtLeastNWidgets(1));
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('有歌时迷你条显示封面外的歌名/歌手与播放钮', (tester) async {
      final setup = await setupPlayer(tester, spy: true);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        expect(find.text('测试歌曲'), findsOneWidget);
        expect(find.text('测试歌手'), findsOneWidget);
        // 未播放 → 显示播放箭头；播放中 → 暂停图标（由 spy 翻转后断言）。
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });

  group('聚焦即选中（第二层 tab）', () {
    testWidgets('模拟节点焦点 → onTabSelected 回调 + 指示条出现', (tester) async {
      final setup = await setupPlayer(tester);
      final selected = <int>[];
      try {
        await pumpHost(
          tester,
          buildHost(player: setup.player, onTabSelected: selected.add),
        );

        // 模拟遥控把焦点移到第 2 项（discover → 推荐）：经生产同款节点池。
        final node = TvNavFocusBridge.instance.nodeFor(1);
        expect(node, isNotNull, reason: 'tab 项构建时必须登记焦点节点到桥接池');
        node!.requestFocus();
        await tester.pump(const Duration(milliseconds: 400));

        expect(selected, [1], reason: '聚焦即选中：无需 OK 确认');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('选中态视觉：玻璃底块 + 品牌色指示条（120ms 淡入）+ 仅当前 tab 显示名称', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(
          tester,
          buildHost(player: setup.player, selectedIndex: 1),
        );
        // 指示条淡入完成。
        await tester.pump(const Duration(milliseconds: 200));

        // 仅当前 tab 显示名称：selectedIndex=1 → library → 我的音乐。
        expect(find.text('我的音乐'), findsOneWidget);
        expect(find.text('推荐'), findsNothing, reason: '非选中 tab 不显示名称');

        // 选中项：品牌色指示条（AnimatedOpacity → 1）恰好一枚。
        final opacities = tester
            .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
            .where((o) => o.opacity == 1.0)
            .toList();
        expect(opacities, hasLength(1), reason: '仅当前 tab 有可见指示条');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });

  group('焦点链路（顶栏 ↔ 内容区）', () {
    testWidgets('第二层下键 → 内容区第一可聚焦点获得焦点（探针断言）', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        // 初始焦点在当前 tab（autofocus）；按方向键下。
        expect(TvNavFocusBridge.instance.nodeFor(0)!.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 400));

        expect(FocusManager.instance.primaryFocus, same(_probeNode),
            reason: '第二层下键把焦点移交内容区第一可聚焦点');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('内容区上边缘 → 第二层当前 tab 聚焦', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        // 焦点先落到内容探针，再按方向键上。
        _probeNode.requestFocus();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 400));

        expect(FocusManager.instance.primaryFocus,
            same(TvNavFocusBridge.instance.nodeFor(0)),
            reason: '内容区上边缘经桥接池聚焦第二层当前 tab');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });

  group('TvMiniBar', () {
    testWidgets('播放/暂停点击 → PlayerProvider 调用（桩计数）', (tester) async {
      final setup = await setupPlayer(tester, spy: true);
      final spy = setup.player as _SpyPlayer;
      try {
        await pumpHost(tester, buildHost(player: spy));

        // 未播放 → 点击 → resume。
        await tester.tap(find.byKey(const ValueKey('tv_mini_bar_play_pause')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(spy.resumeCalls, 1);

        // 翻转播放态（spy 桩）→ 点击 → pause。
        spy.forcedPlaying = true;
        // ignore: invalid_use_of_protected_member
        spy.notifyListeners();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('tv_mini_bar_play_pause')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(spy.pauseCalls, 1);
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('迷你条 FocusNode 已登记 TvPlayerBarFocusBridge（焦点移交桥）', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        final barFocus = tester
            .widgetList<Focus>(find.byWidgetPredicate(
              (w) => w is Focus && w.focusNode?.debugLabel == 'tv/mini-bar',
            ))
            .first;
        expect(
          TvPlayerBarFocusBridge.instance.isMiniNode(barFocus.focusNode!),
          isTrue,
          reason: '迷你条节点必须登记到焦点移交桥（内容区长按上键 → 迷你条）',
        );
        // 桥接路径冒烟：focusMiniPlayer 能把焦点落到迷你条。
        expect(TvPlayerBarFocusBridge.instance.focusMiniPlayer(), isTrue);
        await tester.pump(const Duration(milliseconds: 400));
        expect(FocusManager.instance.primaryFocus, same(barFocus.focusNode));
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('迷你条 OK 键 → 打开播放页（/player）', (tester) async {
      final setup = await setupPlayer(tester, spy: true);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        // TV 真实路径：桥接池把焦点落到迷你条 → OK 键（dpad 的 select
        // 键管线 → DpadFocusable._handleKeyEvent/onSelect → pushNamed）。
        expect(TvPlayerBarFocusBridge.instance.focusMiniPlayer(), isTrue);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byKey(const ValueKey('player_page')), findsOneWidget,
            reason: '迷你条 OK → pushNamed(/player)');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });

  group('''/' 路由 TV 分支组合冒烟''', () {
    testWidgets('顶栏 + 内容区作用域同构装配渲染无异常', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        // 组合装配（app.dart TV 分支同构）：chrome 与内容区作用域都在树里。
        expect(find.byType(TvTopChrome), findsOneWidget);
        expect(find.byType(TvContentFocusRegion), findsOneWidget);
        expect(find.byType(TvTopChromeScope), findsOneWidget,
            reason: '第一层 chrome 落点合法性作用域已挂载');
        expect(find.text('内容探针'), findsOneWidget);
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('顶栏 chrome 叠放为推挤式（不遮挡内容探针）', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        // 推挤式论证：chrome 与探针的纵向几何不相交。
        final chromeTop = tester.getTopLeft(find.byType(TvTopChrome)).dy;
        final chromeBottom = tester.getBottomRight(find.byType(TvTopChrome)).dy;
        final probeTop = tester.getTopLeft(find.text('内容探针')).dy;
        expect(probeTop, greaterThanOrEqualTo(chromeBottom - 0.5),
            reason: '内容区起点不低于 chrome 底缘（推挤式，非悬浮遮挡）');
        expect(chromeTop, greaterThanOrEqualTo(0));
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });
}
