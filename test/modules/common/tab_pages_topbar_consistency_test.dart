/// 「主页管理」九个导航页顶栏一致性回归（批次 22）。
///
/// 背景：主页管理里可开启的页面（首页 / 音乐库 / FM / 搜索 / 收藏 /
/// 听歌识曲 / 听书 / 设置 / 最近播放）此前混用三套顶栏形态——
/// SonifyTitleScaffold 大标题（首页/音乐库/FM/搜索/收藏/设置）、
/// ScrollAwareAppBar（听书）、原生 AppBar 小标题（听歌识曲），
/// 且收藏/最近播放缺右上角常驻头像。批次 22 统一为
/// [SonifyTitleScaffold] 一套形态。
///
/// 四页几何（首页/音乐库/FM/搜索）的相互一致性已由
/// `test/modules/search/search_page_topbar_unification_test.dart` 覆盖；
/// 本文件补齐**新纳入统一**的四页（我的收藏 / 听歌识曲 / 听书 /
/// 播放历史），断言与那四页相同的锚点：
/// - 大标题：左上 (20, 8)、行高 36（20sp w800 largeTitle）；
/// - 用户头像 [UserAvatarButton]：36×36、右 20dp、竖向居中于
///   「状态栏 + 54dp」栏体（sb=0 时 top = 27 - 18 = 9）。
///
/// 设置页不在本断言内：它是账号入口页本身，顶栏按设计**不放假头像**
/// （点自己进自己无意义），标题与模糊带仍与其余八页同构。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/modules/audiobook/audiobook_page.dart';
import 'package:md3music/modules/recognition/song_recognition_page.dart';
import 'package:md3music/modules/search/search_page.dart';
import 'package:md3music/modules/user/favorites_page.dart';
import 'package:md3music/modules/user/play_history_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/common/glass_circle_button.dart';
import 'package:md3music/widgets/common/user_avatar_button.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 与 search_page_topbar_unification_test 同款：清除页面过渡 builder
/// （其内嵌 AppBackground 需要 ThemeProvider，组件级测试无完整树）。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// 假音频服务：init 立即返回，其余方法抛错——让 PlayerProvider 的音频
/// 初始化快速走完内部 try/catch，不触发真实 just_audio 平台加载。
class _FakeAudioService {
  Future<void> init() async {}

  // ignore: annotate_overrides
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_FakeAudioService: 未实现的方法 ${invocation.memberName}',
  );
}

/// 全路径空 JSON 替身（听书四接口 / 歌单接口 / 识别接口均走离线路径）。
class _StubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

class _Geometry {
  const _Geometry(this.titleTopLeft, this.titleSize, this.avatarTopLeft,
      this.avatarSize);

  final Offset titleTopLeft;
  final Size titleSize;
  final Offset avatarTopLeft;
  final Size avatarSize;
}

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

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
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
        child: MaterialApp(theme: _testTheme, home: page),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  }

  _Geometry recordGeometry(
    WidgetTester tester,
    String pageKey,
    String titleText,
  ) {
    final titleFinder = find.text(titleText).last;
    final avatarFinder = find.byType(UserAvatarButton);
    expect(titleFinder, findsOneWidget, reason: '$pageKey 应有固定悬浮大标题');
    expect(avatarFinder, findsOneWidget, reason: '$pageKey 应有常驻右上角头像');
    return _Geometry(
      tester.getTopLeft(titleFinder),
      tester.getSize(titleFinder),
      tester.getTopLeft(avatarFinder),
      tester.getSize(avatarFinder),
    );
  }

  /// 九页统一锚点：标题左上 (20, 8)、行高 36；头像 36×36、右 20、
  /// 竖向居中于栏体（top = 9）；测试窗口宽 800 → 头像 left = 800-20-36。
  void expectUnified(_Geometry g, String pageKey) {
    expect(g.titleTopLeft, const Offset(20, 8), reason: '$pageKey 标题左上角');
    expect(g.titleSize.height, 36, reason: '$pageKey 标题行高');
    expect(g.avatarSize, const Size(36, 36), reason: '$pageKey 头像尺寸');
    expect(g.avatarTopLeft.dy, 9, reason: '$pageKey 头像竖向位置（栏体居中）');
    expect(g.avatarTopLeft.dx, 744, reason: '$pageKey 头像右间距 20dp');
  }

  testWidgets('我的收藏：顶栏与其余导航页同构', (tester) async {
    await pumpPage(tester, const FavoritesPage());
    expectUnified(recordGeometry(tester, 'favorites', '我的收藏'), 'favorites');
  });

  testWidgets('听歌识曲：顶栏与其余导航页同构（原 AppBar 小标题已撤）', (tester) async {
    await pumpPage(tester, const SongRecognitionPage());
    // 原 AppBar 必须彻底消失（不能与固定大标题并存造成双标题）
    expect(find.byType(AppBar), findsNothing, reason: '识曲页不应再有 AppBar');
    expectUnified(
      recordGeometry(tester, 'recognition', '听歌识曲'),
      'recognition',
    );
  });

  testWidgets('听书：顶栏与其余导航页同构（原 ScrollAwareAppBar 已撤）', (tester) async {
    await pumpPage(tester, const AudiobookPage());
    expect(find.byType(AppBar), findsNothing, reason: '听书页不应再有 AppBar');
    expectUnified(recordGeometry(tester, 'audiobook', '听书'), 'audiobook');
    // 批次 23：本页无页面内搜索框 → 顶栏搜索圆钮常驻 trailing（与头像
    // 并排），配方为 GlassCircleButton（与主页同款）
    final searchButton = find.ancestor(
      of: find.byTooltip('搜索听书'),
      matching: find.byType(GlassCircleButton),
    );
    expect(searchButton, findsOneWidget,
        reason: '听书页应有常驻的搜索圆钮（GlassCircleButton）');
    final searchRect = tester.getRect(searchButton);
    final avatarRect = tester.getRect(find.byType(UserAvatarButton));
    expect(searchRect.size, const Size(42, 42), reason: '圆钮 42dp');
    expect(searchRect.right, lessThanOrEqualTo(avatarRect.left),
        reason: '搜索圆钮在头像左侧');
  });

  testWidgets('播放历史：顶栏与其余导航页同构', (tester) async {
    await pumpPage(tester, const PlayHistoryPage());
    expectUnified(
      recordGeometry(tester, 'play_history', '播放历史'),
      'play_history',
    );
  });

  testWidgets('搜索页：坍缩后顶栏搜索圆钮为 GlassCircleButton（与主页同款）',
      (tester) async {
    await pumpPage(tester, const SearchPage());

    // 展开态：坍缩圆钮不在场（胶囊行内的搜索框在场）
    expect(find.byKey(const ValueKey('search-collapsed-icon')), findsNothing);

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
    await tester.pump(const Duration(milliseconds: 350));

    // 坍缩态：圆钮在场且为 GlassCircleButton（批次 23 前是裸 IconButton，
    // 与其余页面圆钮样式不一致）。key 挂在 GlassCircleButton 本体上，
    // 直接用 widget 类型断言（ancestor 查找器不含自身）。
    final finder = find.byKey(const ValueKey('search-collapsed-icon'));
    expect(finder, findsOneWidget);
    expect(
      tester.widget<GlassCircleButton>(finder),
      isA<GlassCircleButton>(),
      reason: '坍缩搜索钮应为 42dp 圆形液态玻璃（GlassCircleButton）',
    );
  });
}
