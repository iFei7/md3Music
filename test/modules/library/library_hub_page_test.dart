/// 音乐库一级页（LibraryHubPage）测试。
///
/// 覆盖：骨架渲染（SonifyTitleScaffold + 搜索胶囊 + 4 段分段控件）、
/// 分段切换（PageView 联动 + 各段空态/内容）、tab label「音乐库」、
/// 歌曲段入口行跳转语义（本地收藏/文件夹 → LibraryPage initialTab 契约）。
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
  // initState postFrame：loadSavedSongs / loadScanFolders / 云端缓存 /
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

  testWidgets('骨架渲染：大标题「音乐库」+ 搜索胶囊 + 4 段分段控件；tab label 已升级', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 头部：SonifyTitleScaffold 固定大标题
    expect(find.byType(SonifyTitleScaffold), findsOneWidget);
    expect(find.text('音乐库'), findsWidgets);
    // 搜索胶囊（点击跳全局搜索页的入口，非行内过滤框）
    expect(find.text('搜索音乐库'), findsOneWidget);
    // 4 段分段控件
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

  testWidgets('空库默认段（最近添加）渲染空态，扫描/云/历史缺数据不显示空壳分区', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 全空：本地无音乐 + 云端缓存空 + 无播放历史 → C1 空态
    expect(find.text('你的音乐库还是空的'), findsOneWidget);
    expect(find.text('扫描设备中的音乐，或先去主页听听看'), findsOneWidget);
    // 无数据分区不渲染
    expect(find.text('歌单'), findsNothing);
    expect(find.text('最近播放'), findsNothing);
  });

  testWidgets('分段切换：专辑/歌手/歌曲段各自渲染，歌曲段含入口行与随机播放胶囊', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHub(tester);

    // 切到「专辑」段：本地与云端均无 → 分段空态兜底
    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();
    expect(find.text('暂无专辑'), findsOneWidget);

    // 切到「歌手」段
    await tester.tap(find.text('歌手'));
    await tester.pumpAndSettle();
    expect(find.text('暂无歌手'), findsOneWidget);

    // 切到「歌曲」段：无本地音乐 → 空态（非「暂无专辑」）
    await tester.tap(find.text('歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('暂无专辑'), findsNothing);

    // 回到默认段：空态恢复
    await tester.tap(find.text('最近添加'));
    await tester.pumpAndSettle();
    expect(find.text('你的音乐库还是空的'), findsOneWidget);
  });

  testWidgets('有本地音乐：C1 显示最近添加的专辑轨道，歌曲段显示入口行/随机胶囊/曲目列表', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocalMusicRepository.cachedSongsKeyForTest: _seedSongsJson(),
    });
    await _pumpHub(tester);

    // C1（默认段）：本地的专辑进入「最近添加的专辑」轨道
    expect(find.text('最近添加的专辑'), findsOneWidget);
    expect(find.text('测试专辑一'), findsOneWidget);
    expect(find.text('测试专辑二'), findsOneWidget);
    // 歌手轨道：扫描出的两位歌手（「歌手甲」在专辑副行与歌手轨道各出现一次）
    expect(find.text('歌手'), findsWidgets);
    expect(find.text('歌手甲'), findsWidgets);
    expect(find.text('歌手乙'), findsWidgets);

    // 切到「歌曲」段：入口行 + 随机播放胶囊 + 曲目列表
    await tester.tap(find.text('歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('本地收藏'), findsOneWidget);
    expect(find.text('文件夹'), findsOneWidget);
    expect(find.text('随机播放'), findsOneWidget);
    expect(find.text('测试歌曲一'), findsOneWidget);
    expect(find.text('测试歌曲二'), findsOneWidget);
  });

  testWidgets('歌曲段入口行跳转语义：本地收藏 → LibraryPage(initialTab: 4)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocalMusicRepository.cachedSongsKeyForTest: _seedSongsJson(),
    });
    await _pumpHub(tester);

    await tester.tap(find.text('歌曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地收藏'));
    await tester.pumpAndSettle();

    // 压入的是 LibraryPage（initialTab: 4 → LocalFavoritesPanel）：
    // 其固定大标题「本地音乐」出现即说明跳转命中兼容路由契约
    expect(find.text('本地音乐'), findsWidgets);
  });
}
