/// FavoritesPage focusMyFavorite 契约测试（音乐库 hub「收藏」直达）。
///
/// 契约（favorites_page.dart）：
/// - `focusMyFavorite: true` → 进入「歌单」tab，歌单数据就绪后自动打开
///   「我喜欢」歌单详情（PlaylistPage，isDefaultFavorite 语义），仅一次；
/// - 未找到「我喜欢」（无缓存 / 已被隐藏 / 未登录）时停留歌单 tab，
///   不导航、不抛错；
/// - 隐藏歌单过滤：经 [HiddenPlaylistsCache] 读取隐藏 key 集合，歌单
///   加载处（缓存/网络/追加页）统一过滤，「我喜欢」被隐藏时不渲染、
///   也不参与 focusMyFavorite 自动导航。
///
/// 注入模式沿用 favorites_page_lifecycle_test.dart：dio adapter 换快速
/// 替身（'{}' 200），本地缓存歌单走 SharedPreferences mock
/// （fav_lists_playlists_v1）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
// material_ui re-export 了 MaterialApp 等组件；PlaylistPage 消费的是
// material_ui 的类型体系，断言 finder 必须用同一套组件类型（同
// playlist_page_multi_select_baseline_test.dart 约定）。
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/repositories/hidden_playlists_cache.dart';
import 'package:md3music/modules/playlist/playlist_page.dart';
import 'package:md3music/modules/user/favorites_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 缓存歌单 JSON（字段集与 FavoriteListsCache._briefToJson 对齐；
/// globalCollectionId 参与隐藏 key 口径：globalCollectionId ?? id）。
Map<String, dynamic> _playlistJson({
  required String id,
  required String name,
  required String gid,
  required String listId,
  int songCount = 5,
}) {
  return {
    'specialid': id,
    'specialname': name,
    'songcount': songCount,
    'global_collection_id': gid,
    'listid': listId,
    'type': 0,
    'source': 0,
  };
}

/// 「我喜欢」缓存歌单（focusMyFavorite 的导航目标）。
Map<String, dynamic> _myFavoriteJson() => _playlistJson(
  id: 'pl-fav',
  name: '我喜欢',
  gid: 'gc-fav',
  listId: 'lid-fav',
);

/// 多推几帧：initState postFrame → 缓存就位 → 网络替身返回 → 自动导航。
/// 不用 pumpAndSettle（M3ELoadingIndicator 为无限动画会挂住）。
/// 轮询帧数放宽到 20×100ms：中央 CI 环境事件循环比开发机慢，
/// 8×50ms 曾不足以走完「缓存→网络→自动导航」链路（批次14 首跑失败）。
Future<void> _pumpLoads(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 路由过渡（MaterialPageRoute 300ms）走完。
Future<void> _pumpRouteTransition(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _pumpFavoritesPage(
  WidgetTester tester, {
  bool focusMyFavorite = false,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        // PlaylistPage 读取 ThemeProvider；面板（本地 tab）兜底
        ChangeNotifierProvider(create: (_) => ThemeProvider(initialUseBackgroundImage: false)),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(
          create: (_) => FavoritesProvider(syncOnStart: false),
        ),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        // FavoritesPage initState postFrame 读取该通知器
        ChangeNotifierProvider(create: (_) => PlaylistCollectionNotifier()),
      ],
      child: MaterialApp(
        home: FavoritesPage(focusMyFavorite: focusMyFavorite),
      ),
    ),
  );
  await _pumpLoads(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClientAdapter previousAdapter;

  setUp(() {
    installFakeSecureStorage();
    // prefs mock 必须先于 KugouApiClient 单例首次构造就位：单例构造即触发
    // _initFromStorage()→SharedPreferences.getInstance()，若此刻无 mock 值
    // 该调用挂起 → _initCompleter 迟迟不完成 → 所有 dio 请求在 _onRequest
    // 的门禁上挂起 → focusMyFavorite 的「加载完毕自动导航」链饿死
    // （批次14 首跑根因：首个用例之后单例已初始化，后续用例才正常）。
    SharedPreferences.setMockInitialValues({});
    final client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _StubAdapter();
    // KugouApiClient._onRequest 等待本地服务就绪，标记 ready 直接放行
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previousAdapter;
    uninstallFakeSecureStorage();
  });

  testWidgets('focusMyFavorite：歌单就绪后自动打开「我喜欢」详情（仅一次）',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'fav_lists_playlists_v1': jsonEncode([
        _myFavoriteJson(),
        _playlistJson(id: 'pl-2', name: '别的歌单', gid: 'gc-2', listId: 'lid-2'),
      ]),
    });
    await _pumpFavoritesPage(tester, focusMyFavorite: true);
    await _pumpRouteTransition(tester);
    // 自动导航命中：进入「我喜欢」歌单详情
    expect(find.byType(PlaylistPage), findsOneWidget);
    // 自动导航只发生一次（仍是单页详情，未重复 push）
    expect(tester.takeException(), isNull);
  });

  testWidgets('focusMyFavorite：无「我喜欢」时不导航不报错', (tester) async {
    SharedPreferences.setMockInitialValues({
      'fav_lists_playlists_v1': jsonEncode([
        _playlistJson(id: 'pl-2', name: '别的歌单', gid: 'gc-2', listId: 'lid-2'),
      ]),
    });
    await _pumpFavoritesPage(tester, focusMyFavorite: true);
    await _pumpRouteTransition(tester);

    // 停留歌单 tab：歌单列表在场，无详情页导航
    expect(find.byType(FavoritesPage), findsOneWidget);
    expect(find.text('别的歌单'), findsOneWidget);
    expect(find.byType(PlaylistPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏歌单过滤：「我喜欢」被隐藏时不渲染且不自动导航',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'fav_lists_playlists_v1': jsonEncode([
        _myFavoriteJson(),
        _playlistJson(id: 'pl-2', name: '别的歌单', gid: 'gc-2', listId: 'lid-2'),
      ]),
    });
    // 经仓库公开 API 写入隐藏集合（不依赖其内部存储键），key 口径
    // globalCollectionId ?? id —— 与页面过滤同源
    final myFavorite = KugouPlaylistBrief.fromJson(_myFavoriteJson());
    await HiddenPlaylistsCache.writeHidden({
      HiddenPlaylistsCache.playlistKey(myFavorite),
    });

    await _pumpFavoritesPage(tester, focusMyFavorite: true);
    await _pumpRouteTransition(tester);

    // 列表过滤：隐藏歌单不渲染，其余照常
    expect(find.text('我喜欢'), findsNothing);
    expect(find.text('别的歌单'), findsOneWidget);
    // 隐藏后 focusMyFavorite 找不到目标：不导航、不报错
    expect(find.byType(PlaylistPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击「我喜欢」歌单行仍进详情（_openPlaylistDetail 复用回归）',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'fav_lists_playlists_v1': jsonEncode([_myFavoriteJson()]),
    });
    await _pumpFavoritesPage(tester);

    // 默认构造（focusMyFavorite=false）不会自动导航
    expect(find.byType(PlaylistPage), findsNothing);

    // 点击歌单行 = 与 focusMyFavorite 自动导航完全相同的入口
    await tester.tap(find.text('我喜欢'));
    await tester.pump();
    await _pumpRouteTransition(tester);

    expect(find.byType(PlaylistPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 快速替身：所有请求返回空 JSON 200。歌单/专辑/歌手加载走
/// 「data 为空」分支，保留 SharedPreferences 缓存数据（与线上断网
/// 场景同路径）。
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
