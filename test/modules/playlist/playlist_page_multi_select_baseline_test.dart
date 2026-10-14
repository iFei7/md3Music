import 'dart:typed_data';

import 'package:dio/dio.dart';
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

/// 歌单页（PlaylistPage）长按多选/批量操作 **行为基线测试**。
///
/// 批次 2 把歌单页多选抽为公共 MultiSelectController（方案 §8 批次 2 风险项
/// 「公共多选抽取是行为敏感重构」）——本文件在抽取**之前**锁定现状行为，
/// 抽取后逐项重跑必须全部保持绿，作为「歌单页行为逐项不变」的验收依据。
///
/// 行为核对表（B 编号 = 抽取前后逐项对照编号）：
/// - B1 长按歌曲进入多选：该首自动选中（已选 1 首），普通 AppBar 隐藏，
///   多选顶栏出现（关闭 / 全选 / 删除）；
/// - B2 多选模式下 tap 其他歌曲切换选中状态（计数增减）；
/// - B3 取消最后一首选中自动退出多选模式（回到普通 AppBar）；
/// - B4 多选顶栏关闭按钮退出多选并清空选中；
/// - B5 全选按钮 toggle：未全选→全选（计数=列表长度）；已全选→清空选中
///   但**保持**多选模式（不自动退出）；
/// - B6 isUserCreated=false 时多选顶栏**无**删除按钮；
/// - B7 isUserCreated=true 且未选任何歌曲时删除按钮禁用；
/// - B8 删除确认弹窗点「取消」不删除、保持多选模式；
/// - B9 自建歌单缺 listCreateListid 时点删除无响应（现状守卫，不弹窗）。
///
/// 测试数据注入：不走网络——「我的收藏」歌单先读
/// [FavoriteListsCache]（SharedPreferences mock）秒开缓存歌曲；
/// dio adapter 替换为快速失败替身，让 `_fetchSongs` 走「缓存保留」分支
/// （与线上断网场景同路径，见 playlist_page.dart `_fetchSongs` catch）。
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
  // 页面 cacheKey 优先级：subscribedListId ?? listCreateListid ?? id（见
  // playlist_page.dart _cacheKey）。host 与 B9 场景的 key 不同，两个都写。
  await FavoriteListsCache.savePlaylistSongs(_kTestListid, songs);
  await FavoriteListsCache.savePlaylistSongs(_kTestPlaylistId, songs);
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
  ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
  ChangeNotifierProvider<FavoritesProvider>(
    create: (_) => FavoritesProvider(),
  ),
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

/// 泵到缓存歌曲渲染完成。
///
/// initState 的 postFrame 异步链：读缓存 → `_fetchSongs`（dio 拦截器等待
/// 本地服务就绪最长 8s 后 reject，见 kugou_api_client.dart `_onRequest`）
/// → 保留缓存 setState。因此必须推进 ≥8s 的 fake 时间让 fetch 走完；
/// 结尾再补推 10s 让 8s 超时 Timer 到期，避免 pending timer 断言失败。
Future<void> _pumpUntilListed(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.pump(); // postFrame 回调注册
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (find.text('歌曲0').evaluate().isNotEmpty) break;
  }
  await tester.pump(const Duration(seconds: 10));
}

void main() {
  late HttpClientAdapter originalAdapter;

  setUpAll(() {
    installFakeSecureStorage();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _seedCachedSongs();
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

  group('PlaylistPage 多选行为基线（B1-B8，抽取前后对照）', () {
    testWidgets('B1 长按歌曲进入多选：该首自动选中 + 普通 AppBar 隐藏 + 多选顶栏出现',
        (tester) async {
      await _pumpUntilListed(tester);
      // 普通模式：无「已选」文本
      expect(find.textContaining('已选'), findsNothing);

      await tester.longPress(find.text('歌曲0'));
      await tester.pump();

      expect(find.text('已选 1 首'), findsOneWidget);
      // 普通 AppBar 隐藏（多选模式移除了 SliverAppBar）
      expect(find.byType(SliverAppBar), findsNothing);
      // 多选顶栏操作齐备
      expect(find.byTooltip('退出选择'), findsOneWidget);
      expect(find.byTooltip('全选'), findsOneWidget);
      expect(find.byTooltip('删除'), findsOneWidget);
    });

    testWidgets('B2 多选模式 tap 其他歌曲切换选中（计数递增）', (tester) async {
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();

      await tester.tap(find.text('歌曲1'));
      await tester.pump();
      expect(find.text('已选 2 首'), findsOneWidget);

      // 再 tap 已选中的歌曲 → 取消选中（计数回落）
      await tester.tap(find.text('歌曲1'));
      await tester.pump();
      expect(find.text('已选 1 首'), findsOneWidget);
    });

    testWidgets('B3 取消最后一首选中自动退出多选', (tester) async {
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      expect(find.text('已选 1 首'), findsOneWidget);

      await tester.tap(find.text('歌曲0'));
      await tester.pump();

      // 回到普通模式：多选栏消失、普通 AppBar 恢复
      expect(find.textContaining('已选'), findsNothing);
      expect(find.byType(SliverAppBar), findsOneWidget);
    });

    testWidgets('B4 多选顶栏关闭按钮退出并清空', (tester) async {
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      await tester.tap(find.text('歌曲1'));
      await tester.pump();
      expect(find.text('已选 2 首'), findsOneWidget);

      await tester.tap(find.byTooltip('退出选择'));
      await tester.pump();

      expect(find.textContaining('已选'), findsNothing);
      expect(find.byType(SliverAppBar), findsOneWidget);
    });

    testWidgets('B5 全选 toggle：全选→计数=列表长度；已全选→清空但保持多选模式',
        (tester) async {
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      expect(find.text('已选 1 首'), findsOneWidget);

      await tester.tap(find.byTooltip('全选'));
      await tester.pump();
      expect(find.text('已选 3 首'), findsOneWidget);
      // 全选后按钮 tooltip 切换为「取消全选」
      expect(find.byTooltip('取消全选'), findsOneWidget);

      // 再点 → 清空全部选中，但多选模式保持（顶栏还在）
      await tester.tap(find.byTooltip('取消全选'));
      await tester.pump();
      expect(find.text('已选 0 首'), findsOneWidget);
      expect(find.byTooltip('退出选择'), findsOneWidget);
      expect(find.byType(SliverAppBar), findsNothing);
    });

    testWidgets('B7 isUserCreated=true：未选歌曲时删除按钮禁用', (tester) async {
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      // 全选再清空 → 删除按钮禁用（onPressed null）
      await tester.tap(find.byTooltip('全选'));
      await tester.pump();
      await tester.tap(find.byTooltip('取消全选'));
      await tester.pump();
      final deleteBtn = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('删除'),
          matching: find.byType(IconButton),
        ),
      );
      expect(deleteBtn.onPressed, isNull);
    });

    testWidgets('B6+B8 删除确认弹窗点取消：不删除、保持多选', (tester) async {
      await _pumpUntilListed(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      expect(find.text('已选 1 首'), findsOneWidget);

      await tester.tap(find.byTooltip('删除'));
      // dialog route：push + 过渡动画各需一帧
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 确认弹窗出现
      expect(find.text('删除歌曲'), findsOneWidget);
      expect(find.textContaining('确定从歌单中删除选中的 1 首歌曲吗'), findsOneWidget);

      // 点「取消」→ 弹窗关闭、歌曲仍在、多选模式保持
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('删除歌曲'), findsNothing);
      expect(find.text('歌曲0'), findsOneWidget);
      expect(find.text('已选 1 首'), findsOneWidget);
    });

    testWidgets('B9 自建歌单缺 listCreateListid：点删除无响应（现状守卫）',
        (tester) async {
      // 无 listCreateListid 的歌单：_deleteListid 为空，删除入口无操作
      await tester.pumpWidget(MultiProvider(
        providers: _providers,
        child: MaterialApp(
          theme: _testTheme,
          home: PlaylistPage(
            playlist: const Playlist(
              id: _kTestPlaylistId,
              name: '无listid歌单',
              songCount: 3,
              songs: [],
            ),
            isInMyFavorites: true,
            isUserCreated: true,
          ),
        ),
      ));
      await tester.pump();
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(seconds: 1));
        if (find.text('歌曲0').evaluate().isNotEmpty) break;
      }
      await tester.pump(const Duration(seconds: 10));

      await tester.longPress(find.text('歌曲0'));
      await tester.pump();
      await tester.tap(find.byTooltip('删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 无弹窗、无删除请求副作用
      expect(find.text('删除歌曲'), findsNothing);
      expect(find.text('歌曲0'), findsOneWidget);
    });
  });
}
