import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// material_ui re-export 了 MaterialApp/IconButton 等组件；PlaylistPage 本身
// 也消费 material_ui 的类型体系，断言 finder 必须用同一套组件类型。
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/data/models/playlist.dart';
import 'package:md3music/data/repositories/favorite_lists_cache.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/playlist/playlist_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:provider/provider.dart';
import 'package:nested/nested.dart' show SingleChildWidget;
import 'package:shared_preferences/shared_preferences.dart';
import '../../test_helpers/fake_secure_storage.dart';

/// 歌单页多选**底部操作条**行为测试（方案 §4.2「选中后下一步操作项」）。
///
/// 与基线测试（playlist_page_multi_select_baseline_test.dart）共用同一套
/// 测试数据注入方式：SharedPreferences mock 缓存歌曲 + dio adapter 快速
/// 失败走「缓存保留」分支。基线 B1-B9 行为不可回归，本文件只锁定操作条
/// 新增行为：
/// - C1 进入多选且选中 >0 时操作条出现，四个操作（收藏/歌单/下一首/队列）可见；
/// - C2 全选→取消全选（0 选中、多选模式保持）时操作条隐藏；
/// - C3 取消最后一首选中自动退出多选后操作条消失；
/// - C4 点「队列」→ PlayerProvider.appendPlaylist 生效（队列含选中歌曲，
///   且按 id 去重：重复追加不增加）；
/// - C5 点「下一首」→ PlayerProvider.insertAfterCurrent 生效；
/// - C6 点「收藏」→ FavoritesProvider 红心生效；
/// - C7 未登录点「歌单」→ 不弹歌单选择框（登录守卫）。
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

Song _song(int i) => Song(
      id: 'song-$i',
      title: '歌曲$i',
      artist: '歌手$i',
      album: '专辑$i',
      duration: Duration(seconds: 200 + i),
      isOnline: true,
    );

const _kTestPlaylistId = 'test-playlist-id';
const _kTestListid = 'test-listid';

Future<void> _seedCachedSongs() async {
  final songs = [_song(0), _song(1), _song(2)];
  await FavoriteListsCache.savePlaylistSongs(_kTestListid, songs);
  await FavoriteListsCache.savePlaylistSongs(_kTestPlaylistId, songs);
}

final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// mock fluttertoast 插件通道：操作条各 handler 完成后会 showToast，
/// 测试环境无插件宿主，必须拦截避免 MissingPluginException。
void _mockFlutterToast(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('PonnamKarthik/fluttertoast'),
    (call) async => true,
  );
}

Future<void> _pumpUntilListed(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.pump(); // postFrame 回调注册
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (find.text('歌曲0').evaluate().isNotEmpty) break;
  }
  await tester.pump(const Duration(seconds: 10));
}

late PlayerProvider _player;
late FavoritesProvider _favorites;

final List<SingleChildWidget> _providers = [
  ChangeNotifierProvider<ThemeProvider>(
    create: (_) => ThemeProvider(initialUseBackgroundImage: false),
  ),
  ChangeNotifierProvider<PlayerProvider>(create: (_) => _player),
  ChangeNotifierProvider<FavoritesProvider>(create: (_) => _favorites),
  ChangeNotifierProvider<LocalFavoritesProvider>(
    create: (_) => LocalFavoritesProvider(),
  ),
  ChangeNotifierProvider<KugouProvider>(create: (_) => KugouProvider()),
  ChangeNotifierProvider<PlaylistCollectionNotifier>(
    create: (_) => PlaylistCollectionNotifier(),
  ),
];

Widget _host() {
  return MultiProvider(
    providers: _providers,
    child: MaterialApp(
      theme: _testTheme,
      home: PlaylistPage(
        playlist: const Playlist(
          id: _kTestPlaylistId,
          name: '测试歌单',
          songCount: 3,
          songs: [],
          listCreateListid: _kTestListid,
        ),
        isInMyFavorites: true,
        isUserCreated: true,
      ),
    ),
  );
}

/// 泵帧直到异步 handler（append/insert/toggleFavorite）走完：
/// handler 内的 dio 请求经 _FailingAdapter 立即失败（服务已标记 ready，
/// 无 8s 就绪等待），冲刷微任务后 provider 状态即更新；再推进假时间
/// 冲掉 fluttertoast showToast 创建的 1s 定时器与 getSongUrlWithFallback
/// 的 45s deadline 定时器（请求快速失败后于 finally 中取消），
/// 避免 pending timer 断言失败。
Future<void> _pumpHandler(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late HttpClientAdapter originalAdapter;

  setUpAll(() {
    installFakeSecureStorage();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _seedCachedSongs();
    _player = PlayerProvider();
    // syncOnStart: false：构造函数触发的 loadFavorites 会发 /user/playlist
    // 请求，其异步链可能跨越 FakeAsync zone 在测试结束后才完成——届时
    // adapter 已被 tearDown 还原、provider 已被组件树 dispose，导致
    // notifyListeners 断言失败。C6 只验证 toggleFavorite 的红心状态流转，
    // 不依赖启动时同步云端收藏，关闭同步即可消除该悬挂请求。
    _favorites = FavoritesProvider(syncOnStart: false);
    final apiClient = KugouApiClient();
    originalAdapter = apiClient.dio.httpClientAdapter;
    apiClient.dio.httpClientAdapter = _FailingAdapter();
    // 标记本地服务已就绪：默认状态是 starting，_onRequest 会对每个请求
    // await 最长 8s 的就绪定时器（真实等待不会在 pump 内完成），导致
    // toggleFavorite 等链路永远走不到 provider 状态更新，且留下
    // pending timer。标记 ready 后请求直接落进 _FailingAdapter 快速失败。
    KugouApiClient.markServerReady();
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = originalAdapter;
  });

  tearDownAll(() {
    uninstallFakeSecureStorage();
  });

  group('PlaylistPage 多选操作条（C1-C7）', () {
    testWidgets('C1 进入多选且选中 >0：操作条出现，四个操作可见', (tester) async {
      _mockFlutterToast(tester);
      await _pumpUntilListed(tester);

      // 普通模式无操作条
      expect(find.text('收藏'), findsNothing);

      await tester.longPress(find.text('歌曲0'));
      await tester.pump();

      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('歌单'), findsOneWidget);
      expect(find.text('下一首'), findsOneWidget);
      expect(find.text('队列'), findsOneWidget);
    });

    testWidgets('C2 取消全选（0 选中、多选保持）：操作条隐藏', (tester) async {
      _mockFlutterToast(tester);
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      expect(find.text('收藏'), findsOneWidget);

      await tester.tap(find.byTooltip('全选'));
      await tester.pump();
      await tester.tap(find.byTooltip('取消全选'));
      await tester.pump();

      // 0 选中：操作条隐藏，但多选模式保持（顶栏「退出选择」仍在）
      expect(find.text('收藏'), findsNothing);
      expect(find.byTooltip('退出选择'), findsOneWidget);
    });

    testWidgets('C3 取消最后一首选中退出多选：操作条消失', (tester) async {
      _mockFlutterToast(tester);
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      expect(find.text('收藏'), findsOneWidget);

      await tester.tap(find.text('歌曲0'));
      await tester.pump();

      expect(find.text('收藏'), findsNothing);
      expect(find.byTooltip('退出选择'), findsNothing);
    });

    testWidgets('C4 点「队列」→ appendPlaylist 生效且按 id 去重', (tester) async {
      _mockFlutterToast(tester);
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      // 再选 1 首（song-0 + song-1）
      await tester.tap(find.text('歌曲1'));
      await tester.pump();

      await tester.tap(find.text('队列'));
      await _pumpHandler(tester);

      expect(_player.playlist.length, 2);
      expect(
        _player.playlist.map((s) => s.id),
        containsAll(<String>['song-0', 'song-1']),
      );

      // 重复追加同一批：appendPlaylist 按 id 去重，队列不增长
      await tester.tap(find.text('队列'));
      await _pumpHandler(tester);
      expect(_player.playlist.length, 2);
    });

    testWidgets('C5 点「下一首」→ insertAfterCurrent 生效', (tester) async {
      _mockFlutterToast(tester);
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();

      await tester.tap(find.text('下一首'));
      await _pumpHandler(tester);

      // 队列原本为空 → insertAfterCurrent 走 appendPlaylist 分支
      expect(_player.playlist.length, 1);
      expect(_player.playlist.first.id, 'song-0');
    });

    testWidgets('C6 点「收藏」→ FavoritesProvider 红心生效', (tester) async {
      _mockFlutterToast(tester);
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();

      expect(_favorites.isFavorite('song-0'), isFalse);

      await tester.tap(find.text('收藏'));
      await _pumpHandler(tester);

      expect(_favorites.isFavorite('song-0'), isTrue);
    });

    testWidgets('C7 未登录点「歌单」→ 不弹歌单选择框（登录守卫）', (tester) async {
      _mockFlutterToast(tester);
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();

      await tester.tap(find.text('歌单'));
      await _pumpHandler(tester);

      // 未登录：守卫直接 toast 返回，不出现「添加到歌单」对话框
      expect(find.text('添加到歌单'), findsNothing);
      // 多选模式保持
      expect(find.byTooltip('退出选择'), findsOneWidget);
    });
  });
}
