/// 音乐库一级页（LibraryHubPage）测试（IA 改版 v2）。
///
/// 覆盖：骨架渲染（SonifyTitleScaffold + 常驻用户头像、无分段控件 /
/// 无 PageView）、2×2 入口卡片文案（批次18：收藏卡改名「收藏」并去
/// 副标题）、收藏卡「直接播放」钮（存在性 + 未登录守卫）、
/// 最近播放 Top 3 截断与标题行跳转播放历史、歌单调区 CoverRail/
/// CoverRailCard 渲染与导航、四卡导航契约（收藏 → PlaylistPage 默认
/// 收藏详情 / LibraryPage / PurchasedPage / CloudMusicPage）、隐藏
/// 歌单管理全流程（管理态多选 → 隐藏所选 → 已隐藏提示 → 底部弹层
/// 恢复）、批次18 登录态首开空缓存自动同步云端歌单。
library;

import 'dart:convert';
import 'dart:typed_data';

// material_ui re-export 了 MaterialApp 等组件；LibraryHubPage 的
// Scaffold 消费 material_ui 类型体系，harness 必须用
// material_ui 的 MaterialApp（见 library_hub_entries_test.dart 同款约定）。
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/favorite_lists_cache.dart';
import 'package:md3music/data/repositories/hidden_playlists_cache.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/data/repositories/playlist_cover_cache.dart';
import 'package:md3music/modules/library/library_hub_page.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/modules/playlist/playlist_page.dart';
import 'package:md3music/modules/user/cloud_music_page.dart';
import 'package:md3music/modules/user/favorites_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/modules/user/play_history_page.dart';
import 'package:md3music/modules/user/purchased_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/common/sonify_segmented_control.dart';
import 'package:md3music/widgets/common/sonify_title_scaffold.dart';
import 'package:md3music/widgets/common/user_avatar_button.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 本地缓存歌曲种子（经 LocalMusicRepository._cachedSongsKey 注入，
/// artworkUri 置 null 避免测试发起网络图片加载）。
String _seedSongsJson() => jsonEncode([
  {
    'id': 's1',
    'title': '本地歌曲一',
    'artist': '歌手甲',
    'album': '测试专辑一',
    'duration': 180000,
  },
  {
    'id': 's2',
    'title': '本地歌曲二',
    'artist': '歌手乙',
    'album': '测试专辑二',
    'duration': 200000,
  },
]);

/// 测试歌曲（播放历史种子，artworkUri 置 null 避免网络图片加载）。
Song _seedSong(String id, String title, String artist) => Song(
  id: id,
  title: title,
  artist: artist,
  album: '测试专辑',
  duration: const Duration(milliseconds: 180000),
);

/// 歌单缓存种子：type=0/source=0 → 「创建」；type=1 → 「收藏」
/// （_isCreatedPlaylist 未登录兜底规则）。含 name='我喜欢' 默认收藏
/// 项（收藏卡点击导航 PlaylistPage 的数据源）。
Future<void> _seedPlaylists() async {
  await FavoriteListsCache.savePlaylists(const [
    KugouPlaylistBrief(
      id: 'created_1',
      name: '我的私藏歌单',
      songCount: 8,
      type: 0,
      source: 0,
    ),
    KugouPlaylistBrief(
      id: 'collected_1',
      name: '他人分享歌单',
      songCount: 12,
      type: 1,
      source: 0,
    ),
    KugouPlaylistBrief(
      id: 'fav_1',
      name: '我喜欢',
      songCount: 5,
      type: 0,
      source: 0,
    ),
  ]);
}

/// 播放历史种子：h1 播放 2 次、h2 播放 1 次（播放次数已不在 hub
/// 渲染，种子保留仅为历史数据真实性）。
Future<void> _seedHistory() async {
  final repo = HistoryRepository();
  await repo.addHistory(_seedSong('h1', '历史歌曲一', '歌手甲'));
  await repo.addHistory(_seedSong('h1', '历史歌曲一', '歌手甲'));
  await repo.addHistory(_seedSong('h2', '历史歌曲二', '歌手乙'));
  await repo.flush();
}

/// 播放历史种子：5 条互不相同的歌曲（最近播放 Top 3 截断断言用；
/// addHistory 最新插到队首，故 getHistory 顺序为 5,4,3,2,1）。
Future<void> _seedFiveHistory() async {
  final repo = HistoryRepository();
  for (var i = 1; i <= 5; i++) {
    await repo.addHistory(_seedSong('m$i', '最近歌曲$i', '歌手甲'));
  }
  await repo.flush();
}

/// KugouApiClient 快速响应 adapter：HistoryRepository 读取账号隔离后缀、
/// 二级子页（收藏/已购/云盘）构造链路会触达 KugouApiClient 单例
/// （构造即发 /register/dev），注入快速失败/空响应 adapter 吸收请求，
/// 避免 flutter_tester 真发网络。
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

class _PlaylistSyncStubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 批次18：登录态首开自动同步用例专用——/user/playlist 返回云端
    // 歌单数据（type=0/source=0 创建 + type=1 收藏），其余路径同
    // _StubAdapter 空响应。
    final body = options.path.contains('/user/playlist')
        ? jsonEncode({
            'data': {
              'info': [
                {
                  'specialid': 'cloud_created_1',
                  'specialname': '云端新建歌单',
                  'songcount': 3,
                  'type': 0,
                  'source': 0,
                  'list_create_userid': 'test-uid',
                },
                {
                  'specialid': 'cloud_collected_1',
                  'specialname': '云端收藏歌单',
                  'songcount': 6,
                  'type': 1,
                  'source': 0,
                },
              ],
            },
          })
        : '{}';
    return ResponseBody.fromString(
      body,
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _pumpHub(WidgetTester tester) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        // 收藏卡 push 的 FavoritesPage 在 postFrame 读取该通知器
        ChangeNotifierProvider(create: (_) => PlaylistCollectionNotifier()),
        // 播放历史页 SongListItem 读取收藏态（FavoritesProvider）
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        // 批次18：顶栏用户头像钮（UserAvatarButton）的 Selector 源
        ChangeNotifierProvider(
          create: (_) => KugouProvider(registerDeviceOnStart: false),
        ),
        // 「我喜欢」卡点击直达的 PlaylistPage 读取主题态（背景图开关）
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const MaterialApp(home: LibraryHubPage()),
    ),
  );
  // initState postFrame：loadSavedSongs（本地卡计数）+ 歌单缓存 +
  // 播放历史（多次 await SharedPreferences 均为 mock 即时完成）
  await tester.pump();
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// 入口卡点击 + 等路由过渡完成（MaterialPageRoute 300ms）。
Future<void> _tapEntryCard(WidgetTester tester, String cardLabel) async {
  await tester.tap(find.text(cardLabel));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// 返回 hub：避免二级页定时器 / 异步任务跨用例悬挂。
Future<void> _popBackToHub(WidgetTester tester) async {
  // FavoritesPage / LibraryPage 走 SonifyTitleScaffold 骨架，顶栏无
  // AppBar 样式的返回钮（面板回到 hub 依赖物理返回/手势），
  // tester.pageBack() 对 CupertinoNavigationBarBackButton 的硬断言
  // 对这两个页面不成立；改用当前路由栈的程序化 pop（等价系统返回）。
  final navigatorState = tester.state<NavigatorState>(
    find.byType(Navigator).first,
  );
  navigatorState.pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byType(LibraryHubPage), findsOneWidget);
}

/// 把列表内目标滚进视口安全区（y∈[110,480]）——不点击。
///
/// 两个坑：① dragUntilVisible 末尾的 ensureVisible 会把目标送到视口顶部，
/// 而悬浮顶栏（状态栏+54dp）吸收该区域的点击——分区标题行落到顶栏后面
/// 时 tap 会 miss；② 数据异步加载使滚动落点在运行间漂移。故用收敛式
/// 拖动：每轮按目标当前位置决定拖动方向（ListView.first = hub 内层
/// 纵向列表，横滑轨是其后代）。
Future<void> _scrollIntoSafeZone(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 40; i++) {
    if (finder.evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 50));
      continue;
    }
    final dy = tester.getCenter(finder).dy;
    if (dy >= 110 && dy <= 480) return;
    await tester.drag(
      find.byType(ListView).first,
      Offset(0, dy < 110 ? 140 : -140),
    );
    await tester.pump();
  }
}

/// 在列表安全区点击指定目标（先 [_scrollIntoSafeZone] 再 tap）。
Future<void> _tapInList(WidgetTester tester, Finder finder) async {
  await _scrollIntoSafeZone(tester, finder);
  await tester.tap(finder);
  await tester.pump();
}

/// mock fluttertoast 插件通道：收藏卡播放钮未登录守卫会 showToast，
/// 测试环境无插件宿主，必须拦截避免 MissingPluginException。
void _mockFlutterToast(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('PonnamKarthik/fluttertoast'),
    (call) async => true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClientAdapter previousAdapter;

  setUp(() {
    HistoryRepository.debugResetForTest();
    final client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    client.dio.httpClientAdapter = _StubAdapter();
    // KugouApiClient._onRequest 等待本地服务就绪，标记 ready 直接放行
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previousAdapter;
    HistoryRepository.debugResetForTest();
  });

  testWidgets('骨架渲染：大标题「音乐库」+ 常驻头像 + 无分段控件', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 头部：SonifyTitleScaffold 固定大标题
    expect(find.byType(SonifyTitleScaffold), findsOneWidget);
    expect(find.text('音乐库'), findsWidgets);
    // 批次19：顶栏常驻搜索圆钮已移除（全局搜索由底部导航常驻搜索
    // tab 承载）——hub 内 Icons.search 一处都不到
    expect(find.byIcon(Icons.search), findsNothing);
    // 右上角用户头像钮常驻（四页顶栏完全统一）
    expect(find.byType(UserAvatarButton), findsOneWidget);
    // 扫描钮保留（原 FAB 职责）
    expect(find.byIcon(Icons.add), findsOneWidget);
    // 旧四段结构整体移除：无分段控件、无 PageView
    expect(find.byType(SonifySegmentedControl), findsNothing);
    expect(find.byType(PageView), findsNothing);
    // 四段文案收敛为 2×2 入口卡片（每张各出现一次；若分段控件仍在
    // 会与卡片文案重复 → findsOneWidget 即双重断言）
    for (final label in const ['收藏', '本地', '已购', '云盘']) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: '入口卡片应包含「$label」',
      );
    }
    // 三个列表分区标题常驻
    expect(find.text('最近播放'), findsOneWidget);
    expect(find.text('我创建的歌单'), findsOneWidget);
    expect(find.text('我收藏的歌单'), findsOneWidget);
  });

  testWidgets('无数据空态：三分区空文案 + 入口卡不渲染 0 计数副标题', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 三分区空态文案（登录引导交由目标子页处理）
    expect(find.text('暂无播放记录'), findsOneWidget);
    expect(find.text('暂无创建的歌单'), findsOneWidget);
    expect(find.text('暂无收藏的歌单'), findsOneWidget);
    // 最近播放分区带「显示全部」（跳 PlayHistoryPage）
    expect(find.text('显示全部'), findsOneWidget);
    // 无歌单 / 无本地歌曲时收藏卡、本地卡不显示副标题
    expect(find.text('0 个歌单'), findsNothing);
    expect(find.text('0 首歌曲'), findsNothing);
  });

  testWidgets('数据注入：入口卡副标题 + CoverRail 歌单调区 + 最近播放', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocalMusicRepository.cachedSongsKeyForTest: _seedSongsJson(),
    });
    await _seedPlaylists();
    await _seedHistory();
    await _pumpHub(tester);

    // 批次18：收藏卡已去副标题（不再显示「N 个歌单」计数）；
    // 本地卡副标题 = 本地歌曲数（2 首）
    expect(find.text('2 首歌曲'), findsOneWidget);
    // 空态文案全部消失
    expect(find.text('暂无播放记录'), findsNothing);
    expect(find.text('暂无创建的歌单'), findsNothing);
    expect(find.text('暂无收藏的歌单'), findsNothing);
    // 最近播放：历史歌曲标题渲染（播放次数已不在 hub 展示）
    expect(find.text('历史歌曲一'), findsOneWidget);
    expect(find.text('历史歌曲二'), findsOneWidget);
    expect(find.text('2 次'), findsNothing);
    // 我创建的歌单分区：CoverRailCard 标题 + 副标题（歌曲数）
    await tester.dragUntilVisible(
      find.text('我的私藏歌单'),
      find.byType(CustomScrollView),
      const Offset(0, -80),
    );
    expect(find.text('我的私藏歌单'), findsOneWidget);
    expect(find.text('8 首'), findsOneWidget);
    // 我收藏的歌单分区：type=1 → 收藏轨渲染
    await tester.dragUntilVisible(
      find.text('他人分享歌单'),
      find.byType(CustomScrollView),
      const Offset(0, -80),
    );
    expect(find.text('他人分享歌单'), findsOneWidget);
    expect(find.text('12 首'), findsOneWidget);
  });

  testWidgets('无封面歌单：读取首曲封面缓存并用于封面卡', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _seedPlaylists();
    // 预置首曲封面缓存（playlistKey = created_1，无 globalCollectionId）
    await PlaylistCoverCache.put('created_1', 'https://img.example/first.jpg');
    await _pumpHub(tester);

    // 滚到歌单分区，让 CoverRail 内的封面卡进入构建范围
    await tester.dragUntilVisible(
      find.text('我的私藏歌单'),
      find.byType(CustomScrollView),
      const Offset(0, -80),
    );
    await tester.pump();

    // 缓存命中 → 封面卡渲染 CachedNetworkImage，且 url 为缓存值
    final urls = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .map((w) => w.imageUrl)
        .toList();
    expect(urls, contains('https://img.example/first.jpg'));
  });

  testWidgets('最近播放只渲染最近 3 条（注入 5 条）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _seedFiveHistory();
    await _pumpHub(tester);

    // 最新 3 条（m5/m4/m3）渲染；更早的 m2/m1 被 take(3) 截断
    expect(find.text('最近歌曲5'), findsOneWidget);
    expect(find.text('最近歌曲4'), findsOneWidget);
    expect(find.text('最近歌曲3'), findsOneWidget);
    expect(find.text('最近歌曲2'), findsNothing);
    expect(find.text('最近歌曲1'), findsNothing);
  });

  testWidgets('收藏卡播放钮：存在且位于收藏卡内；未登录点击不导航', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    _mockFlutterToast(tester);
    await _pumpHub(tester);

    // 播放钮（play_arrow_rounded）仅出现在收藏卡内
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('hub-entry-favorites')),
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );
    // 未登录（_StubAdapter 空响应无 token）点击：仅 toast 守卫，
    // 不跳歌单详情 / 不退出 hub
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LibraryHubPage), findsOneWidget);
    expect(find.byType(FavoritesPage), findsNothing);
    expect(find.byType(PlaylistPage), findsNothing);
    // fluttertoast 插件内部有 1s 定时器；pump 足够时间让其结束后再收尾，
    // 否则测试退出时 pending timer 断言失败。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('点「最近播放」分区标题 → PlayHistoryPage', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _seedHistory();
    await _pumpHub(tester);

    // 整个标题行可点（「显示全部」退化为视觉文案）
    await tester.tap(find.text('最近播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PlayHistoryPage), findsOneWidget);
    await _popBackToHub(tester);
  });

  testWidgets('入口卡导航：我喜欢 → PlaylistPage（默认收藏详情）', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // 登录态：_openMyFavorite 对未登录先 toast 拦截，这里写假凭证过守卫
    // （假 secure storage 供 setLoginCookies 落盘）。
    installFakeSecureStorage();
    await KugouApiClient().setLoginCookies('test-token', 'test-uid');
    await _seedPlaylists();
    await _pumpHub(tester);

    // 点入口卡内「收藏」文案（批次18：卡名由「我喜欢」改为「收藏」，
    // 歌单调区也有同名卡，须限定在入口卡内）
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('hub-entry-favorites')),
        matching: find.text('收藏'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PlaylistPage), findsOneWidget);
    // 「我喜欢」歌单标题（PlaylistPage 顶栏/封面区显示歌单名）
    expect(find.text('我喜欢'), findsWidgets);
    await _popBackToHub(tester);

    // 清理登录态，避免污染同文件后续用例（未登录守卫断言）
    await KugouApiClient().clearCookies();
    uninstallFakeSecureStorage();
  });

  testWidgets('「我创建的歌单」里点「我喜欢」→ PlaylistPage 带 isDefaultFavorite', (
    tester,
  ) async {
    // 批次 22 回归：此前横滑轨卡片走 _openPlaylist 只传 isInMyFavorites，
    // 漏传 isDefaultFavorite/isUserCreated，导致同一「我喜欢」歌单
    // 「收藏页点开有封面（动态最新收藏封面）、我创建的歌单点开无封面」。
    SharedPreferences.setMockInitialValues({});
    await _seedPlaylists();
    await _pumpHub(tester);

    // 「我喜欢」文案只出现在歌单调区的卡片上（入口卡卡名是「收藏」）
    await _tapInList(tester, find.text('我喜欢'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PlaylistPage), findsOneWidget);
    final page = tester.widget<PlaylistPage>(find.byType(PlaylistPage));
    expect(page.isDefaultFavorite, isTrue,
        reason: '「我喜欢」必须带默认收藏标记，头部封面才套用动态来源');
    expect(page.isUserCreated, isTrue, reason: '自己创建的歌单标记');
    await _popBackToHub(tester);
  });

  testWidgets('0 首歌单不进「我创建的歌单」（对齐 sonify 空歌单过滤）', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await FavoriteListsCache.savePlaylists(const [
      KugouPlaylistBrief(
        id: 'created_empty',
        name: '空空歌单',
        songCount: 0,
        type: 0,
        source: 0,
      ),
      KugouPlaylistBrief(
        id: 'created_ok',
        name: '有歌的歌单',
        songCount: 3,
        type: 0,
        source: 0,
      ),
    ]);
    await _pumpHub(tester);

    // 0 首条目默认隐藏（HiddenPlaylistsCache.isEmptyCreatedPlaylist 口径）
    expect(find.text('空空歌单'), findsNothing,
        reason: '0 首歌单不应出现在我创建的歌单分区');
    expect(find.text('有歌的歌单'), findsOneWidget);
    // 有歌的歌单正常显示，空态文案不应因过滤而出错渲染
    expect(tester.takeException(), isNull);
  });

  testWidgets('入口卡导航：本地 → LibraryPage(initialTab: 0)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    await _tapEntryCard(tester, '本地');
    expect(find.byType(LibraryPage), findsOneWidget);
    // LibraryPage 固定大标题「本地音乐」出现即说明跳转命中兼容路由契约
    expect(find.text('本地音乐'), findsWidgets);
    await _popBackToHub(tester);
  });

  testWidgets('入口卡导航：已购 → PurchasedPage', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    await _tapEntryCard(tester, '已购');
    expect(find.byType(PurchasedPage), findsOneWidget);
    await _popBackToHub(tester);
  });

  testWidgets('入口卡导航：云盘 → CloudMusicPage', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    await _tapEntryCard(tester, '云盘');
    expect(find.byType(CloudMusicPage), findsOneWidget);
    // CloudMusicPage AppBar 标题「云盘音乐」
    expect(find.text('云盘音乐'), findsOneWidget);
    await _popBackToHub(tester);
  });

  testWidgets('隐藏歌单全流程：管理 → 选中 → 隐藏所选 → 恢复', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _seedPlaylists();
    await _pumpHub(tester);

    // 初始：创建分区渲染歌单（只滚动不断言点击——普通态点卡会导航到
    // 歌单详情，管理态入口在下一步）
    await _scrollIntoSafeZone(tester, find.text('我的私藏歌单'));
    expect(find.text('我的私藏歌单'), findsOneWidget);

    // 进入创建分区管理态（标题行「管理」钮）
    await _tapInList(tester, find.byKey(const ValueKey('hub-manage-created')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('隐藏所选(0)'), findsOneWidget);

    // 点歌单卡切换选中（管理态不跳详情）
    await _tapInList(tester, find.text('我的私藏歌单'));
    await tester.pump();
    expect(find.text('隐藏所选(1)'), findsOneWidget);

    // 隐藏所选：该歌单从创建分区消失 + 已隐藏提示行（「我喜欢」
    // 默认收藏同属创建分区且种子含该项，故分区不再显示空态文案）
    await _tapInList(tester, find.text('隐藏所选(1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('我的私藏歌单'), findsNothing);
    expect(find.text('暂无创建的歌单'), findsNothing);
    final hintFinder = find.text('已隐藏 1 个歌单，点击管理');
    expect(hintFinder, findsOneWidget);

    // 底部弹层：列出被隐藏歌单 + 「恢复」
    await _tapInList(tester, hintFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('隐藏的创建歌单'), findsOneWidget);
    expect(find.text('我的私藏歌单'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);

    // 恢复：hub 重新渲染该歌单，弹层列表清空
    await tester.tap(find.text('恢复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('我的私藏歌单'), findsOneWidget);

    // 关闭弹层后断言 hub 终态
    final navigatorState = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigatorState.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('我的私藏歌单'), findsOneWidget);
    expect(find.text('暂无创建的歌单'), findsNothing);
    expect(find.text('已隐藏 1 个歌单，点击管理'), findsNothing);

    // 仓库状态同步：隐藏集合已清空
    expect(await HiddenPlaylistsCache.readHidden(), isEmpty);
  });

  testWidgets('隐藏歌单：取消退出管理态不写仓库', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _seedPlaylists();
    await _pumpHub(tester);

    await _tapInList(tester, find.byKey(const ValueKey('hub-manage-created')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('完成'), findsOneWidget);

    // 「取消」退出：歌单照常渲染、仓库无隐藏 key
    await _tapInList(tester, find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('我的私藏歌单'), findsOneWidget);
    expect(find.text('完成'), findsNothing);
    expect(await HiddenPlaylistsCache.readHidden(), isEmpty);
  });

  testWidgets('批次18 登录态首开：空缓存自动同步云端歌单并渲染', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    _mockFlutterToast(tester);
    // 登录态：hub._loadPlaylists 在缓存为空时自动 _syncPlaylistsIfLoggedIn
    installFakeSecureStorage();
    await KugouApiClient().setLoginCookies('test-token', 'test-uid');
    // /user/playlist 命中云端歌单数据
    KugouApiClient().dio.httpClientAdapter = _PlaylistSyncStubAdapter();

    await _pumpHub(tester);
    // initState postFrame 链：读缓存 → setState → 登录态同步（dio
    // stub）→ 写缓存 → 重读 → setState
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 同步结果已写回 FavoriteListsCache
    expect(await FavoriteListsCache.readPlaylists(), isNotEmpty);
    // 云端歌单渲染进对应分区（创建 / 收藏）
    await tester.dragUntilVisible(
      find.text('云端新建歌单'),
      find.byType(CustomScrollView),
      const Offset(0, -80),
    );
    expect(find.text('云端新建歌单'), findsOneWidget);
    // 收藏分区在列表更下方，继续下滚入视口
    await tester.dragUntilVisible(
      find.text('云端收藏歌单'),
      find.byType(CustomScrollView),
      const Offset(0, -80),
    );
    expect(find.text('云端收藏歌单'), findsOneWidget);
    // 空态文案消失（首开不再停留在空态）
    expect(find.text('暂无创建的歌单'), findsNothing);
    expect(find.text('暂无收藏的歌单'), findsNothing);

    // 清理登录态，避免污染同文件后续用例
    await KugouApiClient().clearCookies();
    uninstallFakeSecureStorage();
  });
}
