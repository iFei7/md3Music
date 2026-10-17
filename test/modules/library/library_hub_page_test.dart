/// 音乐库一级页（LibraryHubPage）测试（IA 改版：收藏｜本地｜已购｜云盘）。
///
/// 覆盖：骨架渲染（SonifyTitleScaffold + 搜索玻璃圆钮、无搜索胶囊 +
/// 4 段分段控件）、分段切换（PageView 联动 + 各段空态/未登录引导态）、
/// 已购/云盘段未登录空态、tab label「音乐库」、歌曲段入口行跳转语义
/// （本地收藏/文件夹 → LibraryPage initialTab 契约）、排序钮仅本地段显示。
library;

import 'dart:convert';
import 'dart:typed_data';

// material_ui re-export 了 MaterialApp 等组件；LibraryHubPage 的
// Scaffold/AppBar 消费 material_ui 类型体系，harness 必须用
// material_ui 的 MaterialApp（见 library_hub_entries_test.dart 同款约定）。
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/data/repositories/local_music_repository.dart';
import 'package:md3music/modules/library/library_hub_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/widgets/common/sonify_segmented_control.dart';
import 'package:md3music/widgets/common/sonify_title_scaffold.dart';
import 'package:md3music/widgets/m3e_sort_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地缓存歌曲种子（经 LocalMusicRepository._cachedSongsKey 注入，
/// artworkUri 置 null 避免测试发起网络图片加载）。
String _seedSongsJson() => jsonEncode([
      {
        'id': 's1',
        'title': '测试歌曲一',
        'artist': '歌手甲',
        'album': '测试专辑一',
        'duration': 180000,
      },
      {
        'id': 's2',
        'title': '测试歌曲二',
        'artist': '歌手乙',
        'album': '测试专辑二',
        'duration': 200000,
      },
    ]);

/// KugouApiClient 快速响应 adapter：HistoryRepository 读取账号隔离后缀、
/// TabConfig 等构造链路会触达 KugouApiClient 单例（构造即发 /register/dev），
/// 注入快速失败/空响应 adapter 吸收请求，避免 flutter_tester 真发网络。
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
      ],
      child: const MaterialApp(home: LibraryHubPage()),
    ),
  );
  // initState postFrame：loadSavedSongs / loadScanFolders / 歌单缓存 /
  // 播放历史 / 排序偏好（多次 await SharedPreferences 均为 mock 即时完成）
  await tester.pump();
  await tester.pump();
  await tester.pump();
  await tester.pump();
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

  testWidgets('骨架渲染：大标题「音乐库」+ 搜索图标按钮（无搜索胶囊）+ 4 段分段控件', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 头部：SonifyTitleScaffold 固定大标题
    expect(find.byType(SonifyTitleScaffold), findsOneWidget);
    expect(find.text('音乐库'), findsWidgets);
    // 旧版搜索胶囊已移除，改为顶栏搜索图标按钮
    expect(find.text('搜索音乐库'), findsNothing);
    expect(find.byIcon(Icons.search), findsOneWidget);
    // 扫描钮保留（原 FAB 职责）
    expect(find.byIcon(Icons.add), findsOneWidget);
    // 4 段分段控件（收藏｜本地｜已购｜云盘）
    expect(find.byType(SonifySegmentedControl), findsOneWidget);
    for (final segment in kHubSegments) {
      expect(find.text(segment), findsOneWidget, reason: '分段控件应包含「$segment」');
    }
    // tab label 契约：library 标签由「本地音乐」升级为「音乐库」
    expect(
      kDefaultTabs.firstWhere((t) => t.id == 'library').label,
      '音乐库',
    );
  });

  testWidgets('默认收藏段：无数据时渲染空态，排序钮不显示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 收藏段（默认）：歌单缓存空 + 无播放历史 → 空态
    expect(find.text('暂无收藏内容'), findsOneWidget);
    expect(find.text('我的歌单'), findsNothing);
    expect(find.text('收藏的歌单'), findsNothing);
    expect(find.text('最近'), findsNothing);
    // 排序钮仅本地段显示
    expect(find.byType(M3ESortButton<HubSongSort>), findsNothing);
  });

  testWidgets('分段切换：本地段空态、已购/云盘段未登录引导空态', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 本地段：无本地音乐 → 空库空态
    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();
    expect(find.text('你的音乐库还是空的'), findsOneWidget);

    // 已购段：未登录 → 引导登录空态（PurchasedPanel 内嵌 + 单曲/专辑二次切换）
    await tester.tap(find.text('已购'));
    await tester.pumpAndSettle();
    expect(find.text('登录后查看已购内容'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    expect(find.text('单曲'), findsWidgets);
    expect(find.text('专辑'), findsWidgets);

    // 云盘段：未登录 → 引导登录空态（CloudHubPanel 精简列表）
    await tester.tap(find.text('云盘'));
    await tester.pumpAndSettle();
    expect(find.text('登录后查看云盘音乐'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);

    // 回到默认收藏段：空态恢复
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.text('暂无收藏内容'), findsOneWidget);
  });

  testWidgets('本地段：有本地音乐时渲染入口行/随机胶囊/专辑歌手网格/歌曲列表，排序钮显示', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocalMusicRepository.cachedSongsKeyForTest: _seedSongsJson(),
    });
    await _pumpHub(tester);

    // 收藏段（默认）：无歌单无历史 → 空态；排序钮不显示
    expect(find.text('暂无收藏内容'), findsOneWidget);
    expect(find.byType(M3ESortButton<HubSongSort>), findsNothing);

    // 切到「本地」段：入口行 + 随机播放胶囊 + 专辑/歌手网格 + 歌曲列表
    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();
    expect(find.text('本地收藏'), findsOneWidget);
    expect(find.text('文件夹'), findsOneWidget);
    expect(find.text('随机播放'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('歌手'), findsOneWidget);
    expect(find.text('测试专辑一'), findsOneWidget);
    expect(find.text('测试专辑二'), findsOneWidget);
    // 排序钮仅本地段（歌曲列表）显示
    expect(find.byType(M3ESortButton<HubSongSort>), findsOneWidget);
    // 歌曲列表在专辑/歌手网格下方（测试视口较小），滚动到可见再断言；
    // 本地段的 CustomScrollView 在 PageView 内（与 SonifyTitleScaffold
    // 自身的 CustomScrollView 区分）
    await tester.dragUntilVisible(
      find.text('测试歌曲一'),
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(CustomScrollView),
      ),
      const Offset(0, -400),
    );
    expect(find.text('歌曲'), findsOneWidget);
    expect(find.text('测试歌曲一'), findsOneWidget);
  });

  testWidgets('本地段入口行跳转语义：本地收藏 → LibraryPage(initialTab: 4)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocalMusicRepository.cachedSongsKeyForTest: _seedSongsJson(),
    });
    await _pumpHub(tester);

    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地收藏'));
    await tester.pumpAndSettle();

    // 压入的是 LibraryPage（initialTab: 4 → LocalFavoritesPanel）：
    // 其固定大标题「本地音乐」出现即说明跳转命中兼容路由契约
    expect(find.text('本地音乐'), findsWidgets);
  });
}
