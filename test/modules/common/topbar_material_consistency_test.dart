/// 批次 37：五页顶栏栏带材质一致性取证测试（横屏滚动视口）。
///
/// 背景（用户原话）：「音乐库和搜索到顶栏透明度是不是和其他页面不一致？」
///
/// 取证对象：五个代表页（discover / library hub / search / favorites /
/// settings）在**同一横屏滚动视口**（逻辑 800×480，手机横屏口径——
/// shortestSide < 600 保证设置页走单列 SonifyTitleScaffold 形态而非
/// Pad 双列）滚动态下的栏带材质：
/// - 模糊层：key `'sonify_bar_blur'` 的 [BackdropFilter] 的 filter
///   （sigma 相等断言，按 [kSonifyBarBlurSigma] 锚定）；
/// - tint 层：模糊层所属 ClipRect 带内唯一 [DecoratedBox] 的
///   [LinearGradient] colors / stops；
/// - 栏带可见性：[AnimatedOpacity] 目标值（滚动态应为 1，即完全浮现、
///   无半透明折扣）。
///
/// 结构预期：五页共用 [SonifyTitleOverlay] → `_TopBar`（同一构建路径），
/// 材质应**构造级一致**——本测试即该性质的运行时取证 + 回归锁（若未来
/// 任何一页分叉实现顶栏，此处全等断言立即失败）。
///
/// 取证口径说明：栏带材质参数（sigma / tint alpha / stops）只由
/// `_TopBar` 的常量与 statusBarHeight 决定，与触发滚动的信号来源
/// （骨架 offset / 内层列表 ContentScrollSignal / 搜索页坍缩态）无关，
/// 故统一以「首个 Scrollable jumpTo(60)」驱动滚动态——对单固定高 item
/// 页（hub / favorites / settings）等价于外层橡皮筋滚动，触发路径与
/// 真实内层滚动共用同一 `_updateFromScroll` 出口，材质取证有效。
///
/// 状态栏变体：sb=0（stops 退化 [0,1] 两色）与 sb=24（状态栏锚定三段
/// stops [0, 24/(24+54), 1]）各取证一轮，覆盖 tint 渐变的两个分支。
library;

import 'dart:typed_data';
import 'dart:ui' as ui show ImageFilter;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/modules/discover/discover_page.dart';
import 'package:md3music/modules/library/library_hub_page.dart';
import 'package:md3music/modules/search/search_page.dart';
import 'package:md3music/modules/settings/settings_page.dart';
import 'package:md3music/modules/user/favorites_page.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/common/sonify_title_scaffold.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无完整 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// 假音频服务：init 立即返回，其余方法经 noSuchMethod 抛错（与
/// search_page_topbar_unification_test 同款）。
class _FakeAudioService {
  Future<void> init() async {}

  // ignore: annotate_overrides
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_FakeAudioService: 未实现的方法 ${invocation.memberName}',
  );
}

/// 假 Dio 适配器：每日推荐返回一首歌（让发现页退出整页转圈），其余
/// 路径一律空 JSON（离线路径）。
class _StubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/everyday/recommend') {
      return ResponseBody.fromString(
        '{"data":{"song_list":[{"hash":"h1","songname":"测试歌曲"}]}}',
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 一页栏带材质快照：模糊 filter、tint 渐变 colors/stops、栏带
/// AnimatedOpacity 目标值、取证处的 surface 色（tint 颜色锚定的基准）。
class _BarMaterial {
  const _BarMaterial({
    required this.filter,
    required this.tintColors,
    required this.tintStops,
    required this.bandOpacity,
    required this.surface,
  });

  final Object filter;
  final List<Color> tintColors;
  final List<double> tintStops;
  final double bandOpacity;
  final Color surface;
}

/// 五页取证结果（sb=0 一轮，键 = 页面 key）。
final Map<String, _BarMaterial> _materials = {};

/// 五页取证结果（sb=24 一轮）。
final Map<String, _BarMaterial> _sbMaterials = {};

void main() {
  late HttpClientAdapter previousAdapter;

  setUpAll(() {
    installFakeSecureStorage();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _StubAdapter();
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
    AudioServiceLoader.setTestOverride(() async => _FakeAudioService());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previousAdapter;
    AudioServiceLoader.setTestOverride(null);
  });

  tearDownAll(() {
    uninstallFakeSecureStorage();
  });

  /// 横屏手机视口：逻辑 800×480（shortestSide 480 < 600 → isPadLayout
  /// false，设置页走单列 SonifyTitleScaffold 形态）。
  void useLandscapeViewport(WidgetTester tester) {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(1600, 960);
    addTearDown(tester.view.reset);
  }

  /// 宿主装配 + 多帧推进 + 滚动到滚动态（首个 Scrollable jumpTo 60，
  /// 单固定高 item 页钳制到外层橡皮筋上限 52，同样 > 0 触发栏带/收窄）
  /// + 动画收敛（收窄 180ms / 淡入 120ms）。
  Future<void> pumpScrolled(
    WidgetTester tester,
    Widget page, {
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          devicePixelRatio: tester.view.devicePixelRatio,
          padding: padding,
        ),
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>(
              create: (_) => ThemeProvider(initialUseBackgroundImage: false),
            ),
            ChangeNotifierProvider<KugouProvider>(
              create: (_) => KugouProvider(registerDeviceOnStart: false),
            ),
            ChangeNotifierProvider<PlayerProvider>(
              create: (_) => PlayerProvider(),
            ),
            ChangeNotifierProvider<LibraryProvider>(
              create: (_) => LibraryProvider(),
            ),
            ChangeNotifierProvider<FavoritesProvider>(
              create: (_) => FavoritesProvider(syncOnStart: false),
            ),
            ChangeNotifierProvider<LocalFavoritesProvider>(
              create: (_) => LocalFavoritesProvider(),
            ),
            ChangeNotifierProvider<PlaylistCollectionNotifier>(
              create: (_) => PlaylistCollectionNotifier(),
            ),
            ChangeNotifierProvider<DeviceProvider>(
              create: (_) => DeviceProvider(),
            ),
          ],
          child: MaterialApp(theme: _testTheme, home: page),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(60);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // 冲净页面异步链的挂起 Timer（搜索页本地服务 8s 等待等）
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  }

  /// 取证一页栏带材质（见文件头注释的取证口径）。
  _BarMaterial extract(WidgetTester tester, String pageKey) {
    final blurFinder = find.byKey(const ValueKey('sonify_bar_blur'));
    expect(
      blurFinder,
      findsOneWidget,
      reason: '$pageKey 栏带应有且仅有一枚模糊层（key sonify_bar_blur）',
    );
    final filter = tester.widget<BackdropFilter>(blurFinder).filter!;
    expect(filter, isNotNull, reason: '$pageKey 栏带模糊 filter 不应为 null');
    final band = find
        .ancestor(of: blurFinder, matching: find.byType(ClipRect))
        .last;
    final tintFinder = find.descendant(
      of: band,
      matching: find.byType(DecoratedBox),
    );
    expect(
      tintFinder,
      findsOneWidget,
      reason: '$pageKey 带内应仅 tint 一层 DecoratedBox',
    );
    final gradient =
        (tester.widget<DecoratedBox>(tintFinder).decoration as BoxDecoration)
            .gradient! as LinearGradient;
    final opacity = tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(of: blurFinder, matching: find.byType(AnimatedOpacity))
              .first,
        )
        .opacity;
    final surface = Theme.of(tester.element(blurFinder)).colorScheme.surface;
    return _BarMaterial(
      filter: filter,
      tintColors: List.of(gradient.colors),
      tintStops: List.of(gradient.stops ?? const <double>[]),
      bandOpacity: opacity,
      surface: surface,
    );
  }

  testWidgets('discover（首页）：记录滚动态栏带材质', (tester) async {
    useLandscapeViewport(tester);
    await pumpScrolled(tester, const DiscoverPage());
    _materials['discover'] = extract(tester, 'discover');
  });

  testWidgets('library hub（音乐库）：记录滚动态栏带材质', (tester) async {
    useLandscapeViewport(tester);
    await pumpScrolled(tester, const LibraryHubPage());
    _materials['library'] = extract(tester, 'library');
  });

  testWidgets('search（搜索）：记录滚动态栏带材质', (tester) async {
    useLandscapeViewport(tester);
    await pumpScrolled(tester, const SearchPage());
    _materials['search'] = extract(tester, 'search');
  });

  testWidgets('favorites（我的收藏）：记录滚动态栏带材质', (tester) async {
    useLandscapeViewport(tester);
    await pumpScrolled(tester, const FavoritesPage());
    _materials['favorites'] = extract(tester, 'favorites');
  });

  testWidgets('settings（设置）：记录滚动态栏带材质', (tester) async {
    useLandscapeViewport(tester);
    await pumpScrolled(tester, const SettingsPage());
    _materials['settings'] = extract(tester, 'settings');
  });

  testWidgets('取证结论：五页 sigma/tint/stops/透明度全等 + 锚点常量', (tester) async {
    expect(
      _materials.keys,
      containsAll(['discover', 'library', 'search', 'favorites', 'settings']),
      reason: '五页材质均应已被各自用例记录',
    );

    final reference = _materials['discover']!;
    for (final entry in _materials.entries) {
      expect(
        entry.value.filter,
        reference.filter,
        reason: '${entry.key} 栏带模糊 filter 应与 discover 一致',
      );
      expect(
        entry.value.tintColors,
        reference.tintColors,
        reason: '${entry.key} tint 渐变 colors 应与 discover 一致',
      );
      expect(
        entry.value.tintStops,
        reference.tintStops,
        reason: '${entry.key} tint 渐变 stops 应与 discover 一致',
      );
      expect(
        entry.value.bandOpacity,
        reference.bandOpacity,
        reason: '${entry.key} 栏带透明度目标值应与 discover 一致',
      );
    }

    // 锚点：sigma = kSonifyBarBlurSigma（dock 配方 18）；sb=0 时 tint
    // 退化两段（surface α=kSonifyBarTopAlpha → α=0，stops [0,1]）；
    // 滚动态栏带完全浮现（opacity 目标 1，无半透明折扣）。
    expect(
      reference.filter,
      ui.ImageFilter.blur(
        sigmaX: kSonifyBarBlurSigma,
        sigmaY: kSonifyBarBlurSigma,
      ),
      reason: '栏带模糊 sigma 应为 kSonifyBarBlurSigma（dock 配方 18）',
    );
    expect(reference.bandOpacity, 1);
    expect(
      reference.tintColors,
      [
        reference.surface.withValues(alpha: kSonifyBarTopAlpha),
        reference.surface.withValues(alpha: 0),
      ],
      reason: 'sb=0 tint 应为 surface α0.42 → α0 两段渐变',
    );
    expect(reference.tintStops, const [0.0, 1.0]);
  });

  testWidgets('sb=24 变体：五页状态栏锚定三段 stops 逐页全等', (tester) async {
    useLandscapeViewport(tester);
    const sb = 24.0;
    final pages = <String, Widget>{
      'discover': const DiscoverPage(),
      'library': const LibraryHubPage(),
      'search': const SearchPage(),
      'favorites': const FavoritesPage(),
      'settings': const SettingsPage(),
    };
    for (final entry in pages.entries) {
      await pumpScrolled(
        tester,
        entry.value,
        padding: const EdgeInsets.only(top: sb),
      );
      _sbMaterials[entry.key] = extract(tester, entry.key);
    }

    final reference = _sbMaterials['discover']!;
    for (final item in _sbMaterials.entries) {
      expect(item.value.filter, reference.filter,
          reason: 'sb=24 ${item.key} 模糊 filter 应与 discover 一致');
      expect(item.value.tintColors, reference.tintColors,
          reason: 'sb=24 ${item.key} tint colors 应与 discover 一致');
      expect(item.value.tintStops, reference.tintStops,
          reason: 'sb=24 ${item.key} tint stops 应与 discover 一致');
    }
    // 状态栏锚定三段渐变：状态栏条全强度，自状态栏下缘线性淡出到带底
    // 缘 α0；stops [0, sb/(sb+54), 1]。
    expect(
      reference.tintColors,
      [
        reference.surface.withValues(alpha: kSonifyBarTopAlpha),
        reference.surface.withValues(alpha: kSonifyBarTopAlpha),
        reference.surface.withValues(alpha: 0),
      ],
    );
    expect(reference.tintStops, [0.0, sb / (sb + 54), 1.0]);
  });
}
