import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/modules/discover/discover_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无 Provider 树），避免测试环境异常。
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

/// 假 Dio 适配器：每日推荐返回一首歌（让首页退出整页转圈、渲染
/// SonifyTitleScaffold），FM 接口返回空（未登录时本就不该被调），其余
/// 路径一律空 JSON。
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

  /// 搭建首页宿主：注入全部 provider + 假网络/假音频，等数据到位后
  /// 渲染出 SonifyTitleScaffold。
  Future<(KugouProvider, PlayerProvider, FavoritesProvider,
      LocalFavoritesProvider)> _pumpDiscover(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final client = KugouApiClient();
    client.dio.httpClientAdapter = _DiscoverAdapter();
    _markLocalServerReady();
    AudioServiceLoader.setTestOverride(() async => _FakeAudioService());
    final kugou = KugouProvider(registerDeviceOnStart: false);
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
          child: const DiscoverPage(),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    return (kugou, player, favorites, localFavorites);
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

  group('首页滚动链路', () {
    testWidgets('上滑拖拽后滚动 offset 变化、标题位置固定', (tester) async {
      final (kugou, player, favorites, localFavorites) =
          await _pumpDiscover(tester);
      try {
        // 主列表 = 树中第一个纵向 CustomScrollView（SonifyTitleScaffold）
        final listFinder = find.byType(CustomScrollView).first;
        expect(listFinder, findsOneWidget);
        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(of: listFinder, matching: find.byType(Scrollable))
              .first,
        );
        expect(scrollable.position.pixels, 0);

        // 固定悬浮大标题（可见标题 = 树中最后一个『首页』文本；
        // 列表首项是不可见占位）
        final titleFinder = find.text('首页').last;
        final titleRectBefore = tester.getRect(titleFinder);

        // 上滑 300px：滚动 offset 必须随之变化（否则滚动失效）。
        // 历史根因：内容不足一屏时 maxScrollExtent == 0，上滑零位移——
        // 骨架已加「视口 + 折叠区」minHeight 兜底，短内容态（本测试
        // mock 仅一首歌）也必须能滚。
        await tester.drag(listFinder, const Offset(0, -300));
        await tester.pump();
        expect(
          scrollable.position.pixels,
          greaterThan(0),
          reason: '上滑拖拽后主列表 offset 应 > 0（页面应跟随滚动）',
        );

        // 拖拽超过标题 item 高度后：标题仍固定在原位（批次 8 起不再折叠
        // 为小标题，用户反馈①：上滑时标题位置会变，不想要）
        await tester.pumpAndSettle();
        expect(scrollable.position.pixels, greaterThan(0));
        expect(
          tester.getRect(titleFinder),
          titleRectBefore,
          reason: '上滑过程中标题不位移、不缩放',
        );
        // 标题始终完整可见（不溶解）
        expect(titleFinder, findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('快捷入口行已删除（FM/识曲块不在首页列表）', (tester) async {
      final (kugou, player, favorites, localFavorites) =
          await _pumpDiscover(tester);
      try {
        // 旧快捷行是两枚 56dp 色块（文案「私人 FM」/「识曲」）。删除后：
        // 未登录宿主里 FM 卡片显示登录引导（无这些文案），识曲入口只
        // 剩内容区搜索框右侧的识曲钮（批次 19 移除顶栏圆钮）。
        expect(find.text('私人 FM'), findsNothing);
        expect(find.text('识曲'), findsNothing);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });
  });

  group('首页大标题加粗', () {
    testWidgets('大标题样式携带 wght=800 字轴（不被 M3E emphasized 的 wght 轴覆盖）',
        (tester) async {
      final (kugou, player, favorites, localFavorites) =
          await _pumpDiscover(tester);
      try {
        // 取可见的固定悬浮标题（树中最后一个『首页』；列表首项是
        // 不可见占位，不参与渲染）
        final titleFinder = find.text('首页').last;
        final style = tester.widget<Text>(titleFinder).style!;
        expect(style.fontWeight, FontWeight.w800);
        // 关键：显式 wght 字轴必须存在且为 800，否则 DefaultTextStyle 合并会把
        // M3E emphasized 注入 bodyMedium 的 wght=500 轴带进来，可变字体渲染时
        // 轴优先级高于 fontWeight，标题实际渲染为 Medium（不加粗）。
        final wght = style.fontVariations
            ?.where((v) => v.axis == 'wght')
            .firstOrNull;
        expect(wght, isNotNull);
        expect(wght!.value, 800.0);

        // 模拟 Text 的 DefaultTextStyle 合并路径：合并后的生效样式 wght 轴
        // 仍为 800（不被主题 bodyMedium 的 wght=500 覆盖）。
        final dts = DefaultTextStyle.of(
          tester.element(titleFinder),
        );
        final merged = dts.style.merge(style);
        final mergedWght =
            merged.fontVariations?.where((v) => v.axis == 'wght').firstOrNull;
        expect(mergedWght, isNotNull);
        expect(mergedWght!.value, 800.0);
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
