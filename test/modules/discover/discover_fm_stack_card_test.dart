import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/modules/discover/discover_home_cards.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// AppTheme 主题但清除页面过渡 builder（组件级测试无 ThemeProvider）。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// 假音频服务：init 立即返回，其余方法抛错（不触发真实 just_audio 加载）。
class _FakeAudioService {
  Future<void> init() async {}

  // ignore: annotate_overrides
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_FakeAudioService: 未实现的方法 ${invocation.memberName}',
  );
}

/// 按 mode 分流的 FM 假响应：normal → 甲/乙，small → 丙/丁，peak → 戊；
/// 带 hash 游标（补货请求）一律返回空列表。
class _FmAdapter implements HttpClientAdapter {
  final List<String> requestedModes = [];

  ResponseBody _songs(List<Map<String, String>> list) => ResponseBody.fromString(
        jsonEncode({
          'data': {
            'song_list': list
                .map((s) => {
                      'hash': s['hash'],
                      'songname': s['name'],
                      'songid': s['hash'].toString().replaceAll('h', '1'),
                    })
                .toList(),
          },
        }),
        200,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/personal/fm') {
      final mode = options.uri.queryParameters['mode'] ?? 'normal';
      requestedModes.add(mode);
      if (options.uri.queryParameters['hash'] != null) {
        // 补货请求：无更多
        return _songs(const []);
      }
      switch (mode) {
        case 'small':
          return _songs(const [
            {'hash': 'hc', 'name': '丙'},
            {'hash': 'hd', 'name': '丁'},
          ]);
        case 'peak':
          return _songs(const [
            {'hash': 'he', 'name': '戊'},
          ]);
        default:
          return _songs(const [
            {'hash': 'ha', 'name': '甲'},
            {'hash': 'hb', 'name': '乙'},
          ]);
      }
    }
    if (options.uri.path == '/user/detail') {
      // 登录态校验（checkTokenValid）：error_code=0 + 非空 data 视为有效
      return ResponseBody.fromString(
        jsonEncode({
          'error_code': 0,
          'status': 1,
          'data': {'userid': 'test-uid'},
        }),
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

  Future<(
    KugouProvider,
    PlayerProvider,
    FavoritesProvider,
    LocalFavoritesProvider,
    _FmAdapter,
  )> _pumpCard(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    // mock path_provider：switchAccount 会触发 DefaultCacheManager 清头像缓存，
    // 其内部用 path_provider 拿临时目录，测试环境无插件实现会抛未处理异常
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => switch (call.method) {
            'getTemporaryDirectory' ||
            'getApplicationSupportDirectory' ||
            'getApplicationDocumentsDirectory' ||
            'getDownloadsDirectory' => Directory.systemTemp.path,
            _ => null,
          },
        );
    final client = KugouApiClient();
    final adapter = _FmAdapter();
    client.dio.httpClientAdapter = adapter;
    // 登录态：FM 卡片内容分支需要 isLoggedIn（token+userid 写假存储）
    await client.setLoginCookies('test-token', 'test-uid');
    _markLocalServerReady();
    AudioServiceLoader.setTestOverride(() async => _FakeAudioService());
    final kugou = KugouProvider(registerDeviceOnStart: false);
    // 注入 provider 登录态：registerDeviceOnStart:false 时 _autoConnect 不跑，
    // _isLoggedIn 恒为 false，卡片会走登录引导分支。setLoginCookies 只写了
    // apiClient 单例凭证，provider 侧经 switchAccount 同步（switchToUser 从
    // 假 secure storage 读回凭证 → _isLoggedIn = true）。登录态置位发生在
    // switchToUser 返回之后、checkTokenValid 之前，因此不 await 整链：
    // pump 序列排空 microtask 即可让 _restoreStation 读到已登录态，
    // 后续的用户信息/VIP 校验请求由假 adapter 消化。
    unawaited(kugou.switchAccount('test-uid'));
    final player = PlayerProvider();
    final favorites = FavoritesProvider(syncOnStart: false);
    final localFavorites = LocalFavoritesProvider();
    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme,
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<KugouProvider>.value(value: kugou),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<FavoritesProvider>.value(value: favorites),
            ChangeNotifierProvider<LocalFavoritesProvider>.value(
              value: localFavorites,
            ),
          ],
          child: const Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [DiscoverFmStackCard()],
              ),
            ),
          ),
        ),
      ),
    );
    // 档位恢复/首刷（postFrame）+ 异步加载
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return (kugou, player, favorites, localFavorites, adapter);
  }

  void _teardown(
    KugouProvider kugou,
    PlayerProvider player,
    FavoritesProvider favorites,
    LocalFavoritesProvider localFavorites,
  ) {
    localFavorites.dispose();
    favorites.dispose();
    player.dispose();
    kugou.dispose();
    AudioServiceLoader.setTestOverride(null);
    uninstallFakeSecureStorage();
  }

  group('首页 FM 堆叠卡片', () {
    testWidgets('加载推荐：前卡展示第一首，下方层堆叠下一首', (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        expect(kugou.personalFmSongs, isNotEmpty);
        expect(find.text('甲'), findsOneWidget);
        expect(find.text('乙'), findsOneWidget);
        expect(adapter.requestedModes, contains('normal'));
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('风格切换（红心/小众/速览）：点击后按新档位重拉推荐',
        (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        expect(find.text('甲'), findsOneWidget);

        await tester.tap(find.text('小众'));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        // 小众档（mode=small）返回 丙/丁，列表被替换
        expect(adapter.requestedModes, contains('small'));
        expect(kugou.personalFmSongs.first.songName, '丙');
        expect(find.text('丙'), findsOneWidget);
        expect(find.text('甲'), findsNothing);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('滑动堆叠卡切歌：前卡滑出后下一首前移', (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        expect(find.text('甲'), findsOneWidget);

        // 未播放态：滑动只前移视觉指针，不抢启动播放
        await tester.drag(find.text('甲'), const Offset(-500, 0));
        await tester.pumpAndSettle();
        // dismiss 后视觉指针前移触发 build 内的补货请求（unawaited），
        // dio 请求携带 zero-duration Timer，pumpAndSettle 结束时仍挂起；
        // 补 pump 推进 fake 时间让请求完成，避免 Pending timers 误报。
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(player.currentSong, isNull,
            reason: '未播放时滑动切歌不应擅自起播');
        expect(find.text('乙'), findsOneWidget,
            reason: 'dismiss 前卡后，下一首（乙）应前移为前卡');
        expect(find.text('甲'), findsNothing);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('未播放态：卡片提供播放/暂停与收藏按钮（语义元素在场）',
        (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        expect(find.byTooltip('播放'), findsOneWidget);
        expect(find.byTooltip('收藏'), findsOneWidget);

        // 收藏切换：FavoritesProvider 内存态翻转
        await tester.tap(find.byTooltip('收藏'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(favorites.isFavorite('ha'), isTrue);
        expect(find.byTooltip('取消收藏'), findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });
  });
}

void _markLocalServerReady() {
  final generation = KugouApiClient.markServerStarting();
  KugouApiClient.markServerReady(generation);
}
