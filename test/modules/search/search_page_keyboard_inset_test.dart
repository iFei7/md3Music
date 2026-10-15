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
import 'package:nested/nested.dart' show SingleChildWidget;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../test_helpers/fake_secure_storage.dart';

/// SearchPage 键盘 inset 单一来源测试的真机回归宿主。
///
/// SearchPage 直接依赖 ThemeProvider（背景壁纸开关/模糊/透明度）、
/// KugouProvider（热门搜索/搜索结果）与 PlayerProvider（结果列表点播），
/// 页面级测试必须补齐完整 Provider 栈（与 app.dart MultiProvider 对齐的
/// 最小子集），否则 pump 即抛 ProviderNotFoundException。
///
/// 网络隔离：SearchPage initState 拉热门搜索、空态 MusicExploreSections
/// 补拉探索数据，统一走 KugouApiClient；注入快速失败 adapter（与
/// playlist_page_multi_select_baseline_test 同法），让请求走离线路径。
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
  /// 触发 pending timer 断言（见 playlist_page_multi_select_baseline_test
  /// `_pumpUntilListed` 的同款处理）。
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

  group('SearchPage 键盘 inset 单一来源（真机遮挡 bug 回归）', () {
    testWidgets('Tab 模式（外层 Scaffold 宿主）：本页关闭 resize，由宿主单一消费',
        (tester) async {
      await pumpHost(
        tester,
        // 模拟 Dock 导航宿主：SearchPage 嵌在外层 Scaffold body 内
        Scaffold(
          body: Builder(
            builder: (context) => const SearchPage(),
          ),
        ),
      );

      // 外层宿主 Scaffold：保持默认 resize（消费 inset 的一方）
      final outer = tester.widget<Scaffold>(
        find.ancestor(
          of: find.byType(SearchPage),
          matching: find.byType(Scaffold),
        ).first,
      );
      expect(outer.resizeToAvoidBottomInset, isNull,
          reason: '宿主 Scaffold 保持默认（resize 生效）');

      // 内层 SearchPage 自己的 Scaffold：resizeToAvoidBottomInset: false
      final inner = tester.widget<Scaffold>(find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(Scaffold),
      ));
      expect(inner.resizeToAvoidBottomInset, isFalse,
          reason: '祖先已有 Scaffold 时本页不得二次消费 inset');
    });

    testWidgets('独立路由模式：本页保持 resize（栈顶唯一 Scaffold）',
        (tester) async {
      await pumpHost(
        tester,
        // 直接作为 Navigator 顶层路由，无祖先 Scaffold（首页入口 push 等价）
        const SearchPage(),
      );

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.resizeToAvoidBottomInset, isTrue,
          reason: '独立路由时必须 resize，否则键盘遮挡内容');
    });
  });
}
