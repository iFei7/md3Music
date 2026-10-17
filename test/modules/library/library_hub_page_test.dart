/// 音乐库一级页（LibraryHubPage）测试（IA 改版：2×2 入口卡片 + 列表分区）。
///
/// 覆盖：骨架渲染（SonifyTitleScaffold + 常驻搜索玻璃圆钮、无分段控件 /
/// 无 PageView）、2×2 入口卡片文案与副标题计数、三个列表分区
/// （最近播放 / 我创建的歌单 / 我收藏的歌单）空态与数据态、入口卡
/// 导航契约（FavoritesPage / LibraryPage / PurchasedPage / CloudMusicPage）。
library;

import 'dart:convert';
import 'dart:typed_data';

// material_ui re-export 了 MaterialApp 等组件；LibraryHubPage 的
// Scaffold 消费 material_ui 类型体系，harness 必须用
// material_ui 的 MaterialApp（见 library_hub_entries_test.dart 同款约定）。
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/favorite_lists_cache.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/modules/library/library_hub_page.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/modules/user/cloud_music_page.dart';
import 'package:md3music/modules/user/favorites_page.dart';
import 'package:md3music/modules/user/purchased_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playlist_collection_notifier.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/common/sonify_segmented_control.dart';
import 'package:md3music/widgets/common/sonify_title_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
/// （_isCreatedPlaylist 未登录兜底规则）。
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
  ]);
}

/// 播放历史种子：h1 播放 2 次（计数断言用）、h2 播放 1 次。
Future<void> _seedHistory() async {
  final repo = HistoryRepository();
  await repo.addHistory(_seedSong('h1', '历史歌曲一', '歌手甲'));
  await repo.addHistory(_seedSong('h1', '历史歌曲一', '歌手甲'));
  await repo.addHistory(_seedSong('h2', '历史歌曲二', '歌手乙'));
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

Future<void> _pumpHub(WidgetTester tester) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        // 收藏卡 push 的 FavoritesPage 在 postFrame 读取该通知器
        ChangeNotifierProvider(create: (_) => PlaylistCollectionNotifier()),
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

  testWidgets('骨架渲染：大标题「音乐库」+ 常驻搜索钮 + 无分段控件', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 头部：SonifyTitleScaffold 固定大标题
    expect(find.byType(SonifyTitleScaffold), findsOneWidget);
    expect(find.text('音乐库'), findsWidgets);
    // 右上角常驻玻璃搜索圆钮（trailing，不随滚动淡入）
    expect(find.byIcon(Icons.search), findsOneWidget);
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

  testWidgets('数据注入：入口卡副标题 + 创建/收藏歌单分区 + 最近播放', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocalMusicRepository.cachedSongsKeyForTest: _seedSongsJson(),
    });
    await _seedPlaylists();
    await _seedHistory();
    await _pumpHub(tester);

    // 收藏卡副标题 = 歌单缓存总数（2 个）；本地卡副标题 = 本地歌曲数（2 首）
    expect(find.text('2 个歌单'), findsOneWidget);
    expect(find.text('2 首歌曲'), findsOneWidget);
    // 空态文案全部消失
    expect(find.text('暂无播放记录'), findsNothing);
    expect(find.text('暂无创建的歌单'), findsNothing);
    expect(find.text('暂无收藏的歌单'), findsNothing);
    // 最近播放：历史歌曲标题 + 播放次数（h1 计 2 次）
    expect(find.text('历史歌曲一'), findsOneWidget);
    expect(find.text('历史歌曲二'), findsOneWidget);
    expect(find.text('2 次'), findsOneWidget);
    // 我创建的歌单分区：type=0/source=0 → 创建轨渲染
    await tester.dragUntilVisible(
      find.text('我的私藏歌单'),
      find.byType(CustomScrollView),
      const Offset(0, -80),
    );
    expect(find.text('我的私藏歌单'), findsOneWidget);
    // 我收藏的歌单分区：type=1 → 收藏轨渲染
    await tester.dragUntilVisible(
      find.text('他人分享歌单'),
      find.byType(CustomScrollView),
      const Offset(0, -80),
    );
    expect(find.text('他人分享歌单'), findsOneWidget);
  });

  testWidgets('入口卡导航：收藏 → FavoritesPage(initialTab: 0)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    await _tapEntryCard(tester, '收藏');
    expect(find.byType(FavoritesPage), findsOneWidget);
    // FavoritesPage 大标题「我的收藏」出现即说明跳转命中兼容路由契约
    expect(find.text('我的收藏'), findsWidgets);
    await _popBackToHub(tester);
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
}
