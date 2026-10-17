/// 搜索页搜索框玻璃胶囊化回归测试（UI 重设计批次 9，真机反馈构建号 104）。
///
/// 用户反馈「搜索页搜索框仍方形」：`_buildSearchField` 由 52dp squircle r9
/// Container（sonify.surfaceCard 底）改为首页/音乐库同款
/// [LiquidGlassSurface] + [GlassShape.pill]，高度对齐 44dp 基准；
/// **交互全保留**——真实 TextField 可输入（onChanged 实时联想）、有文字时
/// 清空钮在场（点击恢复无文字态），聚焦 1.5dp primary 描边由
/// StadiumBorder foregroundDecoration 外覆玻璃面等价实现。
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
import 'package:md3music/widgets/common/liquid_glass_surface.dart';
import 'package:nested/nested.dart' show SingleChildWidget;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../test_helpers/fake_secure_storage.dart';

/// 网络隔离：SearchPage initState 拉热门搜索、输入触发实时联想
/// （getSearchSuggest），统一走 KugouApiClient；注入快速失败 adapter
/// （与 search_page_keyboard_inset_test 同法），让请求走离线路径。
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
  /// 触发 pending timer 断言（见 search_page_keyboard_inset_test 同款处理）。
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

  testWidgets('搜索框为玻璃胶囊（pill + 44dp），输入/清空交互保留',
      (tester) async {
    await pumpHost(tester, const SearchPage());

    // 玻璃胶囊材质：LiquidGlassSurface + GlassShape.pill（首页
    // _buildSearchFieldItem / library_page 批次 8 同款外壳）
    final glass = tester.widget<LiquidGlassSurface>(
      find.byType(LiquidGlassSurface),
    );
    expect(glass.shape, GlassShape.pill);
    // 高度对齐首页基准 44dp（SizedBox 固定高，pill 圆角取半高 = 完美胶囊）
    expect(tester.getSize(find.byType(LiquidGlassSurface)).height, 44);

    // 交互语义不变：可输入 TextField + 占位文案 + 20dp 搜索图标在场
    // （搜索图标按胶囊内范围断言，避免空态音乐探索区的同名图标干扰）
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('搜索歌曲、歌手、专辑'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LiquidGlassSurface),
        matching: find.byIcon(Icons.search),
      ),
      findsOneWidget,
    );

    // 无文字时清空钮不在场（右侧为 10dp 占位）
    expect(find.byIcon(Icons.clear), findsNothing);

    // 可输入 → onChanged 实时联想触发，清空钮出现
    await tester.enterText(find.byType(TextField), '周杰伦');
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(find.byIcon(Icons.clear), findsOneWidget);

    // 清空钮可用：点击后恢复无文字态（清空钮退场）
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(find.byIcon(Icons.clear), findsNothing);

    // 收尾推进 fake 时间：空态音乐探索区 postFrame 发起的探索数据请求
    // （getThemePlaylist/getSceneMusic 等）超时 Timer 挂在 fake async 区，
    // 不推进会在测试结束时触发 pending timer 断言
    await tester.pump(const Duration(seconds: 10));
  });
}
