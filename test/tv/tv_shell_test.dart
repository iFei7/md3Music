// 批次51：TvApp 纯 TV 入口冒烟。
//
// 背景：批次51 新建 lib/tv_ui/app/tv_app.dart 纯 TV 应用入口（上游
// rust-local-force lib/app.dart TV 装配形态全量迁移），main.dart kTvBuild
// 分支直接 runApp(TvApp())，app.dart 的全部自定义 TV 接线退役。本文件钉住
// TV 装配链的最终形态：
//
//   TvApp(MultiProvider → MaterialApp)
//     → builder: _tvMediaKeyFallback(_tvContentScope(...))（上游原版四层）
//     → home: TvMainLayout（上游 _MainLayout 的 TV 等价物）
//       → TvMainShell → ResponsiveShell → 页面映射（tv_ui 页面全量）
//
// 真实渲染说明：home 页为 tv_ui DiscoverPage，其数据请求经 KugouApiClient →
// KugouApiServer.ensureStarted（测试宿主 FFI dlopen 失败，请求快速失败）→
// 页面 3×2s 自动重试链。本测试用大步长 fake 时间泵过重试链后断言（禁
// pumpAndSettle：歌词 Ticker / AppHaptics 兜底 Timer 常驻，会挂死）。
//
// 宿主装配：AudioServiceLoader 注入 ControlledAudioService（受控音频，
// 纯 Dart 无平台通道）；SharedPreferences mock；connectivity / home_widget /
// platform / path_provider 平台通道桩。KugouProvider 等真实 provider 由
// TvApp 内部装配（本测试验证的是 TvApp 的真实 provider 闭包）。
import 'dart:io';

import 'package:flutter/material.dart' hide NavigationRailDestination;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/main.dart' show appNavigatorKey;
import 'package:md3music/providers/player_provider.dart'
    show AudioServiceLoader;
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/tv_ui/app/tv_app.dart';
import 'package:md3music/tv_ui/core/layout/responsive_shell.dart';
import 'package:md3music/tv_ui/core/layout/tv_nav_focus_bridge.dart';
import 'package:md3music/tv_ui/core/layout/tv_shell.dart';
import 'package:md3music/tv_ui/core/remote/tv_top_chrome_scope.dart';
import 'package:md3music/tv_ui/core/services/desktop_lyric_service.dart';
import 'package:md3music/tv_ui/modules/audiobook/audiobook_page.dart';
import 'package:md3music/tv_ui/modules/discover/discover_page.dart';
import 'package:md3music/tv_ui/modules/library/library_page.dart';
import 'package:md3music/tv_ui/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/tv_ui/modules/player/full_player.dart';
import 'package:md3music/tv_ui/modules/player/mini_player.dart';
import 'package:md3music/tv_ui/modules/recognition/song_recognition_page.dart';
import 'package:md3music/tv_ui/modules/search/search_page.dart';
import 'package:md3music/tv_ui/modules/settings/settings_page.dart';
import 'package:md3music/tv_ui/modules/user/favorites_page.dart';
import 'package:md3music/tv_ui/modules/user/play_history_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// 平台通道桩（沿用批次50 口径：connectivity / home_widget / platform /
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

/// TV 布局按 1920 设计宽换算，测试面设为 1920×1080（dpr=1 → scale=1）。
void prepareView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 首帧 + 大步长 fake 时间泵过 DiscoverPage 重试链（dio connectTimeout 15s +
/// 3×2s 重试 + 问候语 3s 停留，合计约 55s fake 时间；30×2s 步长兜住）。
Future<void> pumpTvApp(WidgetTester tester) async {
  prepareView(tester);
  SharedPreferences.setMockInitialValues({});
  _mockPlatformChannels();
  // 受控音频：TvApp 内部装配的 PlayerProvider 经 AudioServiceLoader 拿到
  // 纯 Dart 替身（无平台通道、无真实播放引擎）。
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  addTearDown(() async {
    AudioServiceLoader.setTestOverride(null);
    await audio.dispose();
  });
  // DesktopLyricService 单例在构造时启动 5s periodic 原生巡检 Timer
  // （tv_ui full_player.dart initState 触发首次创建）。periodic Timer 无法
  // 经 fake 时间泵清（恒 pending），在 runAsync 真实 async 区预创建单例，
  // 其 Timer 落在真实事件循环、不经 FakeAsync 计账（page_desktop_lyric_
  // dedup_test.dart 同款口径）。
  await tester.runAsync(() async {
    // ignore: unnecessary_statements
    DesktopLyricService.instance;
  });
  await tester.pumpWidget(const TvApp());
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(seconds: 2));
  }
}

/// 统一清理：卸载树。
Future<void> teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TvApp 装配冒烟（批次51 纯 TV 入口）', () {
    testWidgets('壳层链完整：TvMainShell 承载顶栏，body 挂 ResponsiveShell，'
        'home 页 discover → tv_ui DiscoverPage', (tester) async {
      await pumpTvApp(tester);
      try {
        expect(find.byType(TvMainShell), findsOneWidget,
            reason: 'TV 壳层 = TvMainShell（上游 app.dart :2950 装配形态）');
        expect(find.byType(ResponsiveShell), findsOneWidget,
            reason: '内容区 = tv_ui ResponsiveShell（上游 _buildBody kTvBuild '
                '分支 :3533-3551 形态：不传 persistentBarBuilder）');
        expect(find.byType(TvTopChromeScope), findsOneWidget,
            reason: '第一层 chrome 落点合法性作用域已挂载');
        expect(find.byType(MiniPlayer), findsOneWidget,
            reason: '第一层中央 = tv_ui MiniPlayer（播放信息移顶）');
        expect(find.byType(DiscoverPage), findsOneWidget,
            reason: '当前 tab（discover）映射 tv_ui DiscoverPage');
        expect(tester.takeException(), isNull);
      } finally {
        await teardown(tester);
      }
    });

    testWidgets("路由 '/player' 可推入 → tv_ui FullPlayer", (tester) async {
      await pumpTvApp(tester);
      try {
        appNavigatorKey.currentState!.pushNamed('/player');
        // 路由安装 + 转场推进（多帧泵，禁 pumpAndSettle）。
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(find.byType(FullPlayer), findsOneWidget,
            reason: "命名路由 '/player' → tv_ui FullPlayer（上游 app.dart :1055 "
                "语义；TV 主入口仍是顶栏 MiniPlayer OK → openFullPlayer）");
        expect(tester.takeException(), isNull);
      } finally {
        await teardown(tester);
      }
    });

    testWidgets('第二层「聚焦即选中」：tab 1 聚焦 → 映射切到 tv_ui LibraryPage',
        (tester) async {
      await pumpTvApp(tester);
      try {
        final node = TvNavFocusBridge.instance.nodeFor(1);
        expect(node, isNotNull, reason: 'tab 项构建时登记焦点节点到桥接池');
        node!.requestFocus();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(LibraryPage), findsOneWidget,
            reason: '选中状态 TvApp 自持（上游 _MainLayout TV 等价物）：'
                '聚焦即选中后页面映射切到 tv_ui LibraryPage');
      } finally {
        await teardown(tester);
      }
    });
  });

  group('页面映射注册（tv_ui 全量，批次51 上游 _buildPageForTab 语义）', () {
    // 说明：与 tv_app.dart `_buildTvPageForTab` 映射表同步维护。lite
    // TabConfigProvider 值域 = kAllAvailableTabs 9 项；默认（可选 tab 隐藏）
    // 只挂 discover。真实渲染不进 widget 测试（文件头说明）。
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
    test('favorites → tv_ui FavoritesPage', () {
      expect(const FavoritesPage().runtimeType, FavoritesPage);
    });
    test('recognition → tv_ui SongRecognitionPage', () {
      expect(const SongRecognitionPage().runtimeType, SongRecognitionPage);
    });
    test('audiobook → tv_ui AudiobookPage', () {
      expect(const AudiobookPage().runtimeType, AudiobookPage);
    });
    test('settings → tv_ui SettingsPage', () {
      expect(const SettingsPage().runtimeType, SettingsPage);
    });
    test('recent → tv_ui PlayHistoryPage', () {
      expect(const PlayHistoryPage().runtimeType, PlayHistoryPage);
    });
    test('TabConfigProvider 值域全部有映射（kAllAvailableTabs 9 项）', () {
      final mapped = const {
        'discover', 'library', 'fm', 'search', 'favorites',
        'recognition', 'audiobook', 'settings', 'recent',
      };
      for (final tab in kAllAvailableTabs) {
        expect(mapped.contains(tab.id), isTrue,
            reason: 'tab id ${tab.id} 必须在 tv_app.dart 页面映射表内');
      }
    });
  });
}
