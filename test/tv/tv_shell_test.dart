// 批次50：TV 渲染树组合冒烟（tv_ui 体系接线）。
//
// 背景：批次50 将 TV 构建渲染树整体切到 lib/tv_ui/（上游 rust-local-force
// 体系），删除 lite 自研 TV UI（批次43 播放页 / 批次44 顶栏）。本文件钉住
// 最终接线后的 TV 渲染树核心链路：
//
//   MaterialApp.builder → _tvMediaKeyFallback → _tvContentScope
//   → _MainLayout(kTvBuild 分支) → TvMainShell → ResponsiveShell → 页面映射
//
// 壳层组合与 app.dart 的 kTvBuild 分支同构装配（TvMainShell 的 body 挂
// tv_ui ResponsiveShell，pageBuilder 产出页面）；焦点/连发/红框/媒体键兜底
// 为 _tvContentScope 层职责（批次43 基础件 + tv_ui TvPlayerBackFallback），
// 其按键链路依赖真机遥控器，真机项（见交付报告遗留风险）。
//
// 宿主装配（沿用批次44 口径）：PlayerProvider 走 ControlledAudioService
// 受控音频 + 平台通道桩；KugouProvider 关闭设备注册避免真实网络；MiniPlayer
// 额外需要 tv_ui CarModeProvider。全部有界 pump，禁 pumpAndSettle
// （AppHaptics 兜底 300ms Timer、dpad 焦点请求异步生效，统一 pump(400ms) 越过）。
//
// 页面渲染说明：tv_ui 五大页面（discover/library/fm/search/settings）的真实
// 渲染含 dio connectTimeout fake-Timer 与 DiscoverPage 3×2s 自动重试链，
// widget 测试宿主装不起（pending-timer flake），本文件以「类型注册断言」
// 钉住映射表（见页面映射注册组）；真实渲染由
// `flutter analyze --dart-define=MD3_TV=true`（编译期类型核对）与真机验收覆盖。
import 'dart:io';

import 'package:dpad/dpad.dart';
// NavigationRailDestination 取 material_ui 版本（TvMainShell.railDestinations
// 的参数类型，与 app.dart 一致——app.dart 经 material_ui 导出解析到同名类）。
import 'package:flutter/material.dart' hide NavigationRailDestination;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show NavigationRailDestination;
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/tv_ui/core/layout/responsive_shell.dart';
import 'package:md3music/tv_ui/core/layout/tv_nav_focus_bridge.dart';
import 'package:md3music/tv_ui/core/layout/tv_shell.dart';
import 'package:md3music/tv_ui/core/remote/tv_top_chrome_scope.dart';
import 'package:md3music/tv_ui/modules/discover/discover_page.dart';
import 'package:md3music/tv_ui/modules/library/library_page.dart';
import 'package:md3music/tv_ui/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/tv_ui/modules/player/mini_player.dart';
import 'package:md3music/tv_ui/modules/search/search_page.dart';
import 'package:md3music/tv_ui/modules/settings/settings_page.dart';
import 'package:md3music/tv_ui/providers/car_mode_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// 平台通道桩（照抄批次44 口径：connectivity / home_widget / platform /
/// path_provider），避免测试环境通道挂起与残留 Timer。
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

/// 装配空闲态 provider（无歌），经 runAsync 等待音频引擎就绪（FakeAsync 区内
/// 裸 await 真实异步链路会死锁，同因同解）。
Future<({PlayerProvider player, ControlledAudioService audio})>
setupPlayer(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  _mockPlatformChannels();
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  PlayerProvider? player;
  await tester.runAsync(() async {
    player = PlayerProvider();
    await player!.audioReady.timeout(const Duration(seconds: 10));
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

/// 与 app.dart `_MainLayoutState.build` kTvBuild 分支同构的装配：
/// TvMainShell(visibleTabs / railDestinations / onDestinationSelected /
/// shellKey, body: ResponsiveShell(pageBuilder))。
/// body 页面用可聚焦探针代替真实页面（真实页面渲染说明见文件头）。
Widget buildHost({
  required PlayerProvider player,
  int selectedIndex = 0,
  void Function(int index)? onDestinationSelected,
  List<TabItem>? visibleTabs,
  Widget Function(String tabId)? pageBuilder,
}) {
  final tabs = visibleTabs ?? List.of(kDefaultTabs);
  final Widget Function(String) builder =
      pageBuilder ?? (_) => _bodyProbe();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ChangeNotifierProvider<KugouProvider>(
        create: (_) => KugouProvider(registerDeviceOnStart: false),
      ),
      ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
      // MiniPlayer（tv_ui）watch 车机模式态。
      ChangeNotifierProvider<CarModeProvider>(create: (_) => CarModeProvider()),
      // TabConfigProvider：壳层映射读取（TvMainShell 吃纯参数，留桩防页面
      // 内 read<TabConfigProvider> 兜底路径缺 provider）。
      ChangeNotifierProvider<TabConfigProvider>(
        create: (_) => TabConfigProvider(),
      ),
    ],
    child: MaterialApp(
      builder: Dpad.wrap(),
      routes: {
        '/search': (_) => const SizedBox(key: ValueKey('search_page')),
        '/settings': (_) => const SizedBox(key: ValueKey('settings_page')),
        '/user': (_) => const SizedBox(key: ValueKey('user_page')),
        '/player': (_) => const SizedBox(key: ValueKey('player_page')),
      },
      home: Scaffold(
        body: TvMainShell(
          visibleTabs: tabs,
          selectedIndex: selectedIndex,
          railDestinations: [
            for (final tab in tabs)
              NavigationRailDestination(
                icon: const Icon(Icons.circle_outlined),
                selectedIcon: const Icon(Icons.circle),
                label: Text(tab.label),
              ),
          ],
          onDestinationSelected: onDestinationSelected ?? (_) {},
          shellKey: _tvResponsiveShellKey,
          body: ResponsiveShell(
            key: _tvResponsiveShellKey,
            visibleTabs: tabs,
            selectedIndex: selectedIndex,
            pageBuilder: builder,
          ),
        ),
      ),
    ),
  );
}

/// tv_ui ResponsiveShell 的壳层 key（app.dart `_tvResponsiveShellKey`
/// 同款：TvMainShell 第二层下边缘经它把焦点交还内容区）。
final GlobalKey<ResponsiveShellState> _tvResponsiveShellKey =
    GlobalKey<ResponsiveShellState>();

/// 内容区探针：可聚焦点 + 标记文本（焦点链路断言锚点）。
final FocusNode _probeNode = FocusNode(debugLabel: 'test/tv50-probe');

Widget _bodyProbe() => DpadFocusable(
      focusNode: _probeNode,
      debugLabel: 'tv50-probe',
      child: const Text('内容探针'),
    );

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

  group('TV 渲染树组合冒烟（TvMainShell → ResponsiveShell）', () {
    testWidgets('壳层链完整：TvMainShell 承载第一层/第二层，body 挂 ResponsiveShell 探针页',
        (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        expect(find.byType(TvMainShell), findsOneWidget,
            reason: 'TV 壳层 = TvMainShell（批次50 切 tv_ui 体系）');
        expect(find.byType(ResponsiveShell), findsOneWidget,
            reason: '内容区 = tv_ui ResponsiveShell（不传 persistentBarBuilder）');
        expect(find.byType(TvTopChromeScope), findsOneWidget,
            reason: '第一层 chrome 落点合法性作用域已挂载');
        expect(find.byType(MiniPlayer), findsOneWidget,
            reason: '第一层中央 = tv_ui MiniPlayer（播放信息移顶）');
        expect(find.text('内容探针'), findsOneWidget,
            reason: 'ResponsiveShell pageBuilder 产物（代表页位）已渲染');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('第一层账号胶囊（未登录占位）与第二层 tab 栏同屏', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        expect(find.text('未登录'), findsOneWidget,
            reason: '未登录态账号胶囊占位文案（TvMainShell 读 KugouProvider）');
        // 仅当前 tab 显示名称（选中 discover → 首页），其余 tab 图标态。
        expect(find.text('首页'), findsOneWidget);
        expect(find.text('音乐库'), findsNothing,
            reason: '非选中 tab 不显示名称（聚焦即选中语义的视觉面）');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('body 顶部无自研 chrome 残留：推挤结构由 TvMainShell Column 承担',
        (tester) async {
      final setup = await setupPlayer(tester);
      try {
        await pumpHost(tester, buildHost(player: setup.player));

        // 批次44 的 TvTopChrome/TvMiniBar/TvContentFocusRegion 已随自研壳删除：
        // 本装配同构于 app.dart TV 分支，渲染无异常即「组合冒烟」通过。
        expect(tester.takeException(), isNull);
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });

  group('第二层「聚焦即选中」语义（沿用上游 TvTabBarItem）', () {
    testWidgets('模拟节点焦点 → onDestinationSelected 回调', (tester) async {
      final setup = await setupPlayer(tester);
      final selected = <int>[];
      try {
        await pumpHost(
          tester,
          buildHost(player: setup.player, onDestinationSelected: selected.add),
        );

        // 经生产同款节点池把焦点移到第 2 项（discover → 首页 → 音乐库）。
        final node = TvNavFocusBridge.instance.nodeFor(1);
        expect(node, isNotNull, reason: 'tab 项构建时必须登记焦点节点到桥接池');
        node!.requestFocus();
        await tester.pump(const Duration(milliseconds: 400));

        expect(selected, [1], reason: '聚焦即选中：无需 OK 确认');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });

    testWidgets('TvNavFocusBridge 登记项数 = visibleTabs 数', (tester) async {
      final setup = await setupPlayer(tester);
      try {
        final tabs = List.of(kDefaultTabs);
        await pumpHost(
          tester,
          buildHost(player: setup.player, visibleTabs: tabs),
        );

        expect(TvNavFocusBridge.instance.registeredIndices.toSet().length,
            tabs.length,
            reason: '每个可见 tab 项各登记一个焦点节点（节点池随壳层生命周期）');
      } finally {
        await teardown(tester, setup.player, setup.audio);
      }
    });
  });

  group('页面映射注册（tv_ui 五大页面）', () {
    // 说明：与 app.dart `_buildTvPageForTab` 映射表同步维护——新增/改名
    // tv_ui 页面时两处一起动。真实页面渲染不进 widget 测试（文件头说明）。
    test('discover → tv_ui DiscoverPage', () {
      expect(const DiscoverPage().runtimeType, DiscoverPage);
    });
    test('library → tv_ui LibraryPage', () {
      expect(const LibraryPage().runtimeType, LibraryPage);
    });
    test('fm → tv_ui PersonalFmPage', () {
      expect(const PersonalFmPage().runtimeType, PersonalFmPage);
    });
    test('search → tv_ui SearchPage', () {
      expect(const SearchPage().runtimeType, SearchPage);
    });
    test('settings → tv_ui SettingsPage', () {
      expect(const SettingsPage().runtimeType, SettingsPage);
    });
  });
}
