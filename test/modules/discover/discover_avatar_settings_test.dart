import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/modules/discover/discover_page.dart';
import 'package:md3music/modules/user/user_center_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/common/user_avatar_button.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无 Provider 树），避免测试环境异常。
/// builders 置空后 MaterialPageRoute 回退平台默认过渡（Zoom），可正常
/// pumpAndSettle。
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

/// 探测页：替身路由目标，仅用于断言「导航到了哪个路由」。
class _SettingsProbe extends StatelessWidget {
  const _SettingsProbe();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('SETTINGS_PROBE')));
}

class _UserProbe extends StatelessWidget {
  const _UserProbe();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('USER_PROBE')));
}

/// 假 Dio 适配器：每日推荐返回一首歌（让首页退出整页转圈、渲染
/// SonifyTitleScaffold 顶栏头像），其余路径一律空 JSON。
class _DiscoverAdapter implements HttpClientAdapter {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首页头像点击进设置页（/settings），不再进 /user', (tester) async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    final previousAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _DiscoverAdapter();
    _markLocalServerReady();
    // 注入假音频服务，避免 PlayerProvider 触发真实音频平台初始化
    AudioServiceLoader.setTestOverride(() async => _FakeAudioService());
    final kugou = KugouProvider(registerDeviceOnStart: false);
    final player = PlayerProvider();
    final favorites = FavoritesProvider(syncOnStart: false);
    final localFavorites = LocalFavoritesProvider();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme,
          routes: {
            '/settings': (_) => const _SettingsProbe(),
            '/user': (_) => const _UserProbe(),
          },
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<KugouProvider>.value(value: kugou),
              ChangeNotifierProvider<PlayerProvider>.value(value: player),
              ChangeNotifierProvider<FavoritesProvider>.value(value: favorites),
              ChangeNotifierProvider<LocalFavoritesProvider>.value(
                value: localFavorites,
              ),
            ],
            child: const DiscoverPage(),
          ),
        ),
      );
      // 首帧为整页转圈；等每日推荐数据到位后重建出 Scaffold + 顶栏头像
      // （假适配器即时返回，多轮 pump 让 initState/异步链路充分跑完）
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      // 首页大标题（首 item）+ 折叠态小标题（顶栏）两处文案均为「首页」
      expect(find.text('首页'), findsWidgets);
      // 批次 18 UI 统一：头像改为统一组件 UserAvatarButton（内部仍是
      // 36dp CircleAvatar + Selector<KugouProvider, String?> 按 avatar 最小重建）
      expect(find.byType(UserAvatarButton), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);

      // 点右上角头像 → 进设置页路由
      await tester.tap(find.byType(CircleAvatar));
      await tester.pumpAndSettle();
      expect(find.text('SETTINGS_PROBE'), findsOneWidget);
      expect(find.text('USER_PROBE'), findsNothing);
      expect(find.byType(UserCenterPage), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      localFavorites.dispose();
      favorites.dispose();
      player.dispose();
      kugou.dispose();
      AudioServiceLoader.setTestOverride(null);
      client.dio.httpClientAdapter = previousAdapter;
      uninstallFakeSecureStorage();
    }
  });
}

void _markLocalServerReady() {
  final generation = KugouApiClient.markServerStarting();
  KugouApiClient.markServerReady(generation);
}
