/// 四个导航页顶栏几何统一回归测试（批次 20）。
///
/// discover / library hub / fm / search 四个 tab 页的顶栏必须逐像素一致：
/// - 大标题：`SonifyTextStyles.largeTitle`（20sp w800、行高 36）、
///   位置 = 状态栏 + 8dp、左 20dp，固定悬浮不折叠；
/// - 用户头像 `UserAvatarButton()`（36dp）：右 20dp、竖向居中于栏体，
///   常驻不随滚动淡入；
/// - 渐变模糊带：单个 BackdropFilter（sigma kSonifyBarBlurSigma）+
///   tint 兄弟层（状态栏锚定渐变），ClipRect 在外、滚动 120ms
///   （SonifyMotion.barFade）淡入、回顶消失。
///
/// 实现路线：搜索页与其余三页共用 SonifyTitleScaffold 抽出的顶栏 overlay
/// 组件（`SonifyTitleOverlay`），几何一致性由构造保证；本测试以运行时
/// getTopLeft/getSize 相等断言兜底（含状态栏注入 sb=24 的变体）。
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
import 'package:md3music/modules/personal_fm/personal_fm_page.dart';
import 'package:md3music/modules/search/search_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/common/glass_circle_button.dart';
import 'package:md3music/widgets/common/sonify_title_scaffold.dart';
import 'package:md3music/widgets/common/user_avatar_button.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无完整 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// 假音频服务：init 立即返回，其余方法经 noSuchMethod 抛错——使
/// PlayerProvider 的音频初始化快速走完内部 try/catch，不触发真实
/// just_audio 平台加载（Windows 宿主上可能挂起）。
class _FakeAudioService {
  Future<void> init() async {}

  // ignore: annotate_overrides
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_FakeAudioService: 未实现的方法 ${invocation.memberName}',
  );
}

/// 假 Dio 适配器：每日推荐返回一首歌（让首页退出整页转圈、渲染
/// SonifyTitleScaffold 顶栏），其余路径一律空 JSON（离线路径）。
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

/// 四页 provider 装配（对齐 app.dart MultiProvider 的最小子集）：
/// ThemeProvider（背景壁纸开关）、KugouProvider（头像 Selector 源 +
/// 数据链路）、PlayerProvider（结果列表点播）、LibraryProvider（本地
/// 歌曲计数）、FavoritesProvider / LocalFavoritesProvider /
/// PlaylistCollectionNotifier（二级子页读取，首屏不触发）。
///
/// 以列表字面量直接内联到 MultiProvider.providers 参数位置（按
/// `List<SingleChildWidget>` 上下文自动转型），避免引入未声明的 nested
/// 依赖（既有页面测试走 import 路线，此处以零新增依赖为先）。

/// 一页顶栏几何快照（大标题 + 用户头像的位置与尺寸）。
class _TopBarGeometry {
  const _TopBarGeometry({
    required this.titleTopLeft,
    required this.titleSize,
    required this.avatarTopLeft,
    required this.avatarSize,
  });

  final Offset titleTopLeft;
  final Size titleSize;
  final Offset avatarTopLeft;
  final Size avatarSize;
}

/// 四页几何记录（每个页面用例各记一条，末尾用例统一比较）。
final Map<String, _TopBarGeometry> _geometries = {};

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
    // KugouApiClient._onRequest 等待本地服务就绪，标记 ready 直接放行
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
    // 注入假音频服务，避免 PlayerProvider 触发真实音频平台初始化
    AudioServiceLoader.setTestOverride(() async => _FakeAudioService());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previousAdapter;
    AudioServiceLoader.setTestOverride(null);
  });

  tearDownAll(() {
    uninstallFakeSecureStorage();
  });

  /// 宿主装配 + 多帧推进：发现页等异步数据链（每日推荐 → 退出转圈）
  /// 需要若干帧才重建出 SonifyTitleScaffold 顶栏。
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MultiProvider(
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
        ],
        child: MaterialApp(theme: _testTheme, home: child),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  }

  /// 记录一页顶栏几何：大标题取树中最后一个同文本 widget（固定悬浮项，
  /// 与 sonify_title_scaffold_test 的定位约定一致——列表首项是不可见
  /// 占位，find.text 仍能匹配但排在前面）。
  void recordGeometry(WidgetTester tester, String pageKey, String titleText) {
    final titleFinder = find.text(titleText).last;
    final avatarFinder = find.byType(UserAvatarButton);
    expect(titleFinder, findsOneWidget, reason: '$pageKey 应渲染固定悬浮大标题');
    expect(avatarFinder, findsOneWidget, reason: '$pageKey 应渲染常驻用户头像');
    _geometries[pageKey] = _TopBarGeometry(
      titleTopLeft: tester.getTopLeft(titleFinder),
      titleSize: tester.getSize(titleFinder),
      avatarTopLeft: tester.getTopLeft(avatarFinder),
      avatarSize: tester.getSize(avatarFinder),
    );
  }

  testWidgets('discover：记录顶栏几何', (tester) async {
    await pumpHost(tester, const DiscoverPage());
    recordGeometry(tester, 'discover', '首页');
  });

  testWidgets('library hub：记录顶栏几何', (tester) async {
    await pumpHost(tester, const LibraryHubPage());
    recordGeometry(tester, 'library', '音乐库');
  });

  testWidgets('fm：记录顶栏几何', (tester) async {
    await pumpHost(tester, const PersonalFmPage());
    recordGeometry(tester, 'fm', '私人FM');
  });

  testWidgets('search：记录顶栏几何', (tester) async {
    await pumpHost(tester, const SearchPage());
    recordGeometry(tester, 'search', '搜索');
  });

  testWidgets('四页大标题与用户头像几何完全一致（getTopLeft/getSize 逐一相等）', (tester) async {
    expect(
      _geometries.keys,
      containsAll(['discover', 'library', 'fm', 'search']),
      reason: '四页几何均应已被各自用例记录',
    );
    final reference = _geometries['discover']!;
    for (final entry in _geometries.entries) {
      expect(
        entry.value.titleTopLeft,
        reference.titleTopLeft,
        reason: '${entry.key} 大标题左上角应与 discover 一致',
      );
      expect(
        entry.value.titleSize,
        reference.titleSize,
        reason: '${entry.key} 大标题尺寸应与 discover 一致',
      );
      expect(
        entry.value.avatarTopLeft,
        reference.avatarTopLeft,
        reason: '${entry.key} 用户头像左上角应与 discover 一致',
      );
      expect(
        entry.value.avatarSize,
        reference.avatarSize,
        reason: '${entry.key} 用户头像尺寸应与 discover 一致',
      );
    }

    // 锚点值（测试环境无系统 inset，sb=0）：大标题左 20dp、顶距 8dp、
    // 行高 36dp（20sp w800 largeTitle 规格）；头像 36dp、右 20dp、
    // 竖向居中于「状态栏 + 54dp」栏体（中心 y=27 → 顶 9）。
    expect(reference.titleTopLeft, const Offset(20, 8));
    expect(reference.titleSize.height, 36);
    expect(reference.avatarSize, const Size(36, 36));
    expect(reference.avatarTopLeft.dy, 27 - 18);
  });

  testWidgets('注入状态栏 sb=24：四页几何仍完全一致且随 sb 平移', (tester) async {
    // 逐页重记（MediaQuery 覆盖整个宿主，各页几何重新采集后比较）。
    // 注意：MediaQueryData 的 size 默认为 Size.zero——必须显式传入测试
    // 窗口的逻辑尺寸，否则 fm/library 的「视口 − 状态栏 − 52」业务 item
    // 固定高会算出负值（真实设备 size 恒非零，无此问题）。
    final view = tester.view;
    final sbData = MediaQueryData(
      size: view.physicalSize / view.devicePixelRatio,
      devicePixelRatio: view.devicePixelRatio,
      padding: const EdgeInsets.only(top: 24),
    );
    final sbGeometries = <String, _TopBarGeometry>{};
    Future<void> pumpWithStatusBar(Widget child, String key, String title) async {
      await tester.pumpWidget(
        MediaQuery(
          data: sbData,
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
            ],
            child: MaterialApp(theme: _testTheme, home: child),
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final titleFinder = find.text(title).last;
      final avatarFinder = find.byType(UserAvatarButton);
      sbGeometries[key] = _TopBarGeometry(
        titleTopLeft: tester.getTopLeft(titleFinder),
        titleSize: tester.getSize(titleFinder),
        avatarTopLeft: tester.getTopLeft(avatarFinder),
        avatarSize: tester.getSize(avatarFinder),
      );
    }

    await pumpWithStatusBar(const DiscoverPage(), 'discover', '首页');
    await pumpWithStatusBar(const LibraryHubPage(), 'library', '音乐库');
    await pumpWithStatusBar(const PersonalFmPage(), 'fm', '私人FM');
    await pumpWithStatusBar(const SearchPage(), 'search', '搜索');

    final reference = sbGeometries['discover']!;
    for (final entry in sbGeometries.entries) {
      expect(entry.value.titleTopLeft, reference.titleTopLeft,
          reason: 'sb=24 下 ${entry.key} 大标题左上角应一致');
      expect(entry.value.avatarTopLeft, reference.avatarTopLeft,
          reason: 'sb=24 下 ${entry.key} 用户头像左上角应一致');
      expect(entry.value.titleSize, reference.titleSize);
      expect(entry.value.avatarSize, reference.avatarSize);
    }
    // 锚点值（sb=24）：标题顶距 = 24+8，头像中心 y = 24+27。
    expect(reference.titleTopLeft, const Offset(20, 32));
    expect(reference.avatarTopLeft.dy, 24 + 27 - 18);
  });

  testWidgets('search：滚动后渐变模糊带与三页同构造（单片 BackdropFilter + tint 兄弟层）', (tester) async {
    await pumpHost(tester, const SearchPage());

    // 顶栏带的那枚 BackdropFilter（按 sigma 唯一定位；批次 23 起坍缩
    // 态顶栏多了 GlassCircleButton 自带的一枚 LiquidGlassSurface 模糊，
    // 二者不能混）：栏带 sigma = kSonifyBarBlurSigma，圆钮玻璃 sigma 18
    // 且只作用于 42dp 圆钮自身区域（ClipOval 裁剪）。
    final barBlur = find.byWidgetPredicate((w) {
      if (w is! BackdropFilter) return false;
      return w.filter ==
          ui.ImageFilter.blur(
            sigmaX: kSonifyBarBlurSigma,
            sigmaY: kSonifyBarBlurSigma,
          );
    });
    expect(
      barBlur,
      findsOneWidget,
      reason: '顶栏渐变带应有且仅有一枚 sigma=kSonifyBarBlurSigma 的模糊',
    );

    // 初始态（outer offset=0）：栏背景不浮现（与 SonifyTitleScaffold 同拍）
    final barOpacityFinder = find.ancestor(
      of: barBlur,
      matching: find.byType(AnimatedOpacity),
    );
    // 展开态模糊带不可见：AnimatedOpacity 目标值 0（此时带仍在树中，
    // BackdropFilter 常驻渲染，由外层 AnimatedOpacity 门控可见性）
    expect(
      tester.widget<AnimatedOpacity>(barOpacityFinder.first).opacity,
      0,
      reason: '回顶态栏背景应隐藏',
    );

    // 滚动任意距离：栏背景浮现（120ms 淡入）
    final outerScrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(NestedScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    outerScrollable.position.jumpTo(60);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester.widget<AnimatedOpacity>(barOpacityFinder.first).opacity,
      1,
      reason: '滚动后栏背景应浮现',
    );
    expect(
      tester.widget<AnimatedOpacity>(barOpacityFinder.first).duration,
      SonifyMotion.barFade,
      reason: '栏背景淡入时长应为 120ms',
    );

    // 带内单片均匀模糊：sigma 3、child 非 null（SizedBox.expand）
    // （批次 17 口径；本 finder 已按 sigma 唯一定位到栏带）
    expect(
      tester.widget<BackdropFilter>(barBlur).child,
      isA<SizedBox>(),
      reason: 'BackdropFilter child 非 null（SizedBox.expand）',
    );

    // 图层纪律：栏带模糊不得被 ShaderMask / Opacity 包裹
    // （saveLayer 内嵌模糊失效；AnimatedOpacity 全显不产生 saveLayer）
    expect(
      find.ancestor(of: barBlur, matching: find.byType(ShaderMask)),
      findsNothing,
    );
    expect(
      find.ancestor(of: barBlur, matching: find.byType(Opacity)),
      findsNothing,
    );

    // 坍缩态圆钮自带玻璃模糊：只存在于 GlassCircleButton 内部
    // （LiquidGlassSurface sigma 18），与栏带模糊分层互不干扰
    expect(
      find.descendant(
        of: find.byType(GlassCircleButton),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
      reason: '坍缩圆钮（GlassCircleButton）自带一枚玻璃模糊',
    );

    // tint 叠色层：与模糊层同 Stack 的兄弟层（带内唯一 DecoratedBox），
    // 状态栏锚定渐变（sb=0 退化 stops [0, 1]），surface 系
    final band = find
        .ancestor(of: barBlur, matching: find.byType(ClipRect))
        .last;
    final tint = find.descendant(of: band, matching: find.byType(DecoratedBox));
    expect(tint, findsOneWidget,
        reason: '带内仅 tint 一层 DecoratedBox（模糊层只包 BackdropFilter）');
    final tintGradient = (tester.widget<DecoratedBox>(tint).decoration
            as BoxDecoration)
        .gradient! as LinearGradient;
    final surface =
        Theme.of(tester.element(barBlur)).colorScheme.surface;
    expect(tintGradient.begin, Alignment.topCenter);
    expect(tintGradient.end, Alignment.bottomCenter);
    expect(tintGradient.stops, const [0.0, 1.0]);
    expect(
      tintGradient.colors.first,
      surface.withValues(alpha: kSonifyBarTopAlpha),
    );
    expect(tintGradient.colors.last, surface.withValues(alpha: 0));

    // 回顶：栏背景消失（与三页同拍）
    outerScrollable.position.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<AnimatedOpacity>(barOpacityFinder.first).opacity,
      0,
      reason: '回顶后栏背景应消失',
    );
  });
}
