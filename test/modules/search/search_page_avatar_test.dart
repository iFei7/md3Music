/// 搜索页顶栏 UI 统一回归测试（批次 18）。
///
/// 搜索页 SliverAppBar 从「title 槽放搜索胶囊」改为统一顶栏形态：
/// - 左上角页面标题「搜索」（显式 centerTitle: false，主题默认居中）；
/// - 右上角常驻 [UserAvatarButton]（统一组件，点击进设置页 /settings）；
/// - 玻璃胶囊搜索框从 title 迁入 flexibleSpace 展开区（贴 header 底部，
///   pinned 收起后标题 + 头像仍可见、胶囊被裁掉），输入/清空交互不变；
/// - 双形态保留：tab 宿主态（外层 Scaffold，关闭 resize）与独立路由态
///   （栈顶唯一 Scaffold，保持 resize）。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/modules/search/search_page.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/common/user_avatar_button.dart';
import 'package:nested/nested.dart' show SingleChildWidget;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../test_helpers/fake_secure_storage.dart';

/// 网络隔离：SearchPage initState 拉热门搜索、输入触发实时联想
/// （getSearchSuggest），统一走 KugouApiClient；注入快速失败 adapter
/// （与 search_page_capsule_test 同法），让请求走离线路径。
class _FailingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'offline test adapter',
    );
  }
}

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无完整 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

final List<SingleChildWidget> _providers = [
  ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(initialUseBackgroundImage: false),
  ),
  ChangeNotifierProvider<KugouProvider>(create: (_) => KugouProvider()),
  ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
];

void main() {
  late HttpClientAdapter originalAdapter;

  setUpAll(() {
    installFakeSecureStorage();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final apiClient = KugouApiClient();
    originalAdapter = apiClient.dio.httpClientAdapter;
    apiClient.dio.httpClientAdapter = _FailingAdapter();
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = originalAdapter;
  });

  tearDownAll(() {
    uninstallFakeSecureStorage();
  });

  /// 收尾推进 ≥8s fake 时间：KugouApiClient `_onRequest` 等待本地服务就绪的
  /// 8s 超时 Timer 在请求失败后仍挂在 fake async 区，不推进会在测试结束时
  /// 触发 pending timer 断言（见 search_page_capsule_test 同款处理）。
  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: _providers,
        child: MaterialApp(theme: _testTheme, home: child),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
  }

  /// 统一顶栏三要素 + 胶囊在位（读代码取实际 hintText）。
  void expectUnifiedTopBar(WidgetTester tester) {
    // 左上角页面标题（空态「搜索历史/热门搜索」是不同字符串，精确匹配不干扰）
    expect(find.text('搜索'), findsOneWidget);
    // 右上角常驻用户头像（统一组件）
    expect(find.byType(UserAvatarButton), findsOneWidget);
    // 搜索胶囊仍在：真实 TextField + 占位文案（_buildSearchField 实际 hintText）
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
    // 胶囊在展开区（标题行下方）：header = 状态栏(0) + 56 工具栏 + 52 胶囊行
    final titleTop = tester.getTopLeft(find.text('搜索')).dy;
    final capsuleTop = tester.getTopLeft(find.byType(TextField)).dy;
    expect(
      capsuleTop,
      greaterThan(titleTop),
      reason: '胶囊应位于标题行下方的 flexibleSpace 展开区',
    );
  }

  testWidgets('tab 宿主态：左上角标题 + 右上角头像 + 胶囊在展开区', (tester) async {
    await pumpHost(
      tester,
      // 模拟 Dock 导航宿主：SearchPage 嵌在外层 Scaffold body 内
      Scaffold(
        body: Builder(
          builder: (context) => const SearchPage(),
        ),
      ),
    );

    expectUnifiedTopBar(tester);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('独立路由态：左上角标题 + 右上角头像 + 胶囊在展开区', (tester) async {
    await pumpHost(tester, const SearchPage());

    expectUnifiedTopBar(tester);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 10));
  });

  group('坍缩交互（批次 19）', () {
    /// NestedScrollView 的外层 Scrollable（含 SliverAppBar 最近的滚动
    /// 祖先即 outer；inner 结果列表在其内部）。
    ScrollableState outerScrollable(WidgetTester tester) {
      return tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(NestedScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }

    testWidgets('outer 滚过 52dp 坍缩阈值：头像左侧浮出搜索图标、胶囊收起',
        (tester) async {
      await pumpHost(tester, const SearchPage());

      // 展开态：坍缩图标不在场，胶囊在场
      const collapsedIcon = ValueKey('search-collapsed-icon');
      expect(find.byKey(collapsedIcon), findsNothing);
      expect(find.byType(TextField), findsOneWidget);

      // 外层滚动定位到 60（> 坍缩阈值 52 = expandedHeight 108 − 56）：
      // 胶囊行被滚完 → 坍缩态通知器翻转
      outerScrollable(tester).position.jumpTo(60);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.byKey(collapsedIcon),
        findsOneWidget,
        reason: '坍缩态顶栏头像左侧应浮出搜索图标',
      );
      // 位置契约：搜索图标在头像左侧（同一 actions Row，图标为首个）
      final iconRect = tester.getRect(find.byKey(collapsedIcon));
      final avatarRect = tester.getRect(find.byType(UserAvatarButton));
      expect(
        iconRect.right,
        lessThanOrEqualTo(avatarRect.left),
        reason: '坍缩搜索图标应位于头像左侧',
      );
      // 搜索胶囊坍缩退场（outer offset ≥ 52 后不在场）
      expect(find.byType(TextField), findsNothing);
      // 头像常驻：坍缩不消失（四页顶栏统一）
      expect(find.byType(UserAvatarButton), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('点坍缩搜索图标：回顶展开并聚焦输入框', (tester) async {
      await pumpHost(tester, const SearchPage());
      const collapsedIcon = ValueKey('search-collapsed-icon');

      final outer = outerScrollable(tester);
      outer.position.jumpTo(60);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(collapsedIcon), findsOneWidget);

      await tester.tap(find.byKey(collapsedIcon));
      await tester.pump(); // animateTo 启动 + postFrame 请求焦点
      await tester.pump(const Duration(milliseconds: 300)); // 250ms 动画结束

      // 回顶：outer offset 归 0，坍缩图标退场
      expect(outer.position.pixels, 0);
      expect(find.byKey(collapsedIcon), findsNothing);

      // 胶囊重新展开且输入框获得焦点（点击图标应唤起键盘）
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode?.hasFocus, isTrue);

      await tester.pump(const Duration(seconds: 10));
    });
  });
}
