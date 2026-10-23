import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/core/theme/app_dimens.dart';
import 'package:md3music/core/theme/app_theme.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/discover/discover_home_cards.dart';
import 'package:md3music/modules/user/play_history_page.dart';
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

/// 分页假响应：模拟真机失败路径——带 hash 游标的补货请求一律回放空列表
/// （服务端对同游标返回已消费批次），不带游标的 normal 请求按调用次序依次
/// 给新批次（首刷 → 兜底补货 1 → 兜底补货 2 …）。
class _FmPaginationAdapter extends _FmAdapter {
  final List<List<Map<String, String>>> _batches = const [
    [
      {'hash': 'ha', 'name': '甲'},
      {'hash': 'hb', 'name': '乙'},
    ],
    [
      {'hash': 'hc', 'name': '丙'},
      {'hash': 'hd', 'name': '丁'},
    ],
    [
      {'hash': 'he', 'name': '戊'},
    ],
  ];

  int noCursorNormalRequests = 0;
  int cursorRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/personal/fm') {
      if (options.uri.queryParameters['hash'] != null) {
        cursorRequests++;
        // 真机失败路径：带游标的补货请求拿不到新歌
        return _songs(const []);
      }
      if ((options.uri.queryParameters['mode'] ?? 'normal') == 'normal') {
        final i = noCursorNormalRequests++;
        return _songs(i < _batches.length ? _batches[i] : const []);
      }
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

/// 默认滚动宿主：纵向 SingleChildScrollView（与首页列表同轴）。
Widget _defaultScrollHost(Widget child) => Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [child],
        ),
      ),
    );

/// 真机竞争环境宿主：CustomScrollView（SonifyTitleScaffold 同款纵向
/// 滚动容器）+ 垫高内容，保证 maxScrollExtent > 0——垂直滚动 recognizer
/// 真实参与手势竞技场，复现「FM 卡嵌在上滑页里」的真机场景。
Widget _customScrollHost(Widget child) => Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: child),
          SliverList.builder(
            itemCount: 30,
            itemBuilder: (context, i) => SizedBox(
              height: 80,
              child: ListTile(title: Text('filler $i')),
            ),
          ),
        ],
      ),
    );

/// 批次31：帧序列断言——被划走的卡（[title]）只要还在 widget 树里，
/// 就必须处于「飞出中」：祖先 Opacity 叠乘后 < 1（渐隐）或祖先
/// Transform 水平平移非零（飞移）。二者皆无 = 「无变换、全不透明、
/// 停在原位」的可见帧，即用户看到的「划走后往回闪一下」。
///
/// 卡面子树（SmoothClipRRect→ClipPath / CachedNetworkImage / Text）不引入
/// Opacity/Transform，故祖先链上只有飞出/跟手两种包装。
void _expectDismissedCardInFlight(WidgetTester tester, String title) {
  final finder = find.text(title);
  if (finder.evaluate().isEmpty) return; // 已切走（指针前移）：无所谓
  final element = tester.element(finder);
  var opacity = 1.0;
  var dx = 0.0;
  element.visitAncestorElements((e) {
    final w = e.widget;
    if (w is Opacity) {
      opacity *= w.opacity;
    } else if (w is Transform) {
      dx += w.transform.storage[12]; // Matrix4 列主序：平移 x
    }
    return true; // 继续向上遍历
  });
  expect(
    opacity < 0.999 || dx.abs() > 0.5,
    isTrue,
    reason: '「$title」出现闪回可见帧（opacity=$opacity, dx=$dx）',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(
    KugouProvider,
    PlayerProvider,
    FavoritesProvider,
    LocalFavoritesProvider,
    _FmAdapter,
  )> _pumpCard(
    WidgetTester tester, {
    Widget Function(Widget child)? host,
    _FmAdapter? adapterOverride,
    // 批次31：播放路径用例注入可控 next() 的测试播放器（真机
    // player.next() 有异步耗时窗口，真实 PlayerProvider 在假音频服务下
    // 不可驱动）。
    PlayerProvider? playerOverride,
  }) async {
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
    final adapter = adapterOverride ?? _FmAdapter();
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
    final player = playerOverride ?? PlayerProvider();
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
          child: Scaffold(
            body: (host ?? _defaultScrollHost)(const DiscoverFmStackCard()),
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

    testWidgets('真机竞争环境：CustomScrollView 内水平拖拽（拖拽中途有帧落地）仍能切歌',
        (tester) async {
      // 真机反馈「FM 卡片无法左右滑动切换」的复现用例：
      // ① 宿主换成 CustomScrollView（SonifyTitleScaffold 同款纵向滚动），
      //    垂直 recognizer 真实参与竞技场；
      // ② 关键差异——两段 move 之间插入 tester.pump()：真机上每次 move
      //    事件间必有帧落地。此前拖拽态会把前卡的 GestureDetector 换成
      //    Transform，首帧重建即 dispose 掉 HorizontalDragGestureRecognizer
      //    （recognizer.dart:485-493 会把它从 pointerRouter 摘除），后续
      //    move/up 全部丢失、onHorizontalDragEnd 不触发——卡片停在几 px
      //    位移处「滑不动」。既有 drag() 用例 move 与 up 之间不插帧，
      //    识别器没被换掉才侥幸绿，覆盖不到真机。
      // 注：DragStartBehavior.start 下首个 move 只触发 drag start（pending
      // offset 被吸收进初始位置、不发 update，monodrag.dart:805-808），
      // 故需要两个 move 才产出首个 onHorizontalDragUpdate。
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester, host: _customScrollHost);
      try {
        expect(find.text('甲'), findsOneWidget);

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        // move ①：越过 touchSlop，HorizontalDrag 胜出竞技场、拖拽开始
        await gesture.moveBy(const Offset(-60, 0));
        // move ②：首个 onHorizontalDragUpdate → _dragDx 非零 → setState
        // （拖拽态分支从此生效）
        await gesture.moveBy(const Offset(-40, 0));
        // 帧在拖拽中途落地：拖拽态重建发生在识别器存活期间
        await tester.pump();
        // move ③ + 抬手：位移累计越过 dismiss 阈值
        await gesture.moveBy(const Offset(-400, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(player.currentSong, isNull,
            reason: '未播放时滑动切歌不应擅自起播');
        expect(find.text('乙'), findsOneWidget,
            reason: '前卡滑出后下一首（乙）应前移为前卡（真机滑动手感）');
        expect(find.text('甲'), findsNothing);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次31：dismiss 收尾无「划走卡闪回」——逐帧检查（未播放路径）',
        (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        expect(find.text('甲'), findsOneWidget);

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump(); // 帧在拖拽中途落地（真机必有）
        await gesture.moveBy(const Offset(-400, 0));
        await gesture.up();

        // 逐帧推进飞出（220ms）与收尾：每一帧里，被划走的甲只要还在
        // 树里就必须处于「飞出中」（渐隐/飞移）——不允许出现无变换、
        // 全不透明、停在原位的可见帧（即「划走后往回闪一下」）。
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          _expectDismissedCardInFlight(tester, '甲');
        }
        // 收尾后的补货 dio 请求带 zero-duration Timer，补 pump 排空
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('甲'), findsNothing, reason: '收尾后甲应被切走');
        expect(find.text('乙'), findsOneWidget, reason: '乙前移为前卡');
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次31：dismiss 收尾无「划走卡闪回」——播放跟随 next() 的异步窗口内也不闪回',
        (tester) async {
      // 真机主场景：正在播本电台时滑走前卡。player.next() 有真实异步
      // 耗时（解析播放链/装载），该窗口内被划走的卡必须保持不可见——
      // 用延迟 100ms 的测试 next() 坐实这个窗口（回归前此处必有
      // 多帧「甲全不透明停原位」的闪回）。
      final testPlayer = _FmTestPlayerProvider(
        nextDelay: const Duration(milliseconds: 100),
      );
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester, playerOverride: testPlayer);
      try {
        testPlayer.setTestPlaybackState(
          currentSong: const Song(
            id: 'ha', // 与 personalFmSongs[0].hash 对齐 → playingIndex=0
            title: '甲',
            artist: '测试歌手',
            album: '测试专辑',
            duration: Duration(minutes: 3),
          ),
          isPlaying: true,
        );
        // next() 完成后切到乙（hash 'hb' → playingIndex=1 → base 前移）
        testPlayer.nextTarget = const Song(
          id: 'hb',
          title: '乙',
          artist: '测试歌手',
          album: '测试专辑',
          duration: Duration(minutes: 3),
        );
        await tester.pump();
        expect(find.text('甲'), findsOneWidget);

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-40, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(-400, 0));
        await gesture.up();

        // 飞出 220ms + next() 延迟 100ms：逐帧检查整个窗口无闪回。
        for (var i = 0; i < 26; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          _expectDismissedCardInFlight(tester, '甲');
        }
        await tester.pump(const Duration(milliseconds: 100));

        expect(testPlayer.nextCallCount, 1,
            reason: '播放中滑走 → player.next() 播放跟随契约');
        expect(find.text('甲'), findsNothing);
        expect(find.text('乙'), findsOneWidget,
            reason: 'next() 切歌后乙应成为前卡');
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次31：未过阈值松手 → 回弹动画收敛到 0（非瞬移，有中间值帧）',
        (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        final origin = tester.getTopLeft(find.text('甲'));

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-30, 0)); // 越过 slop：drag start
        await gesture.moveBy(const Offset(-30, 0)); // 首个 update → _dragDx<0
        await gesture.up(); // |dx| < 90、零时间戳 → 速度 0 → 回弹分支

        await tester.pump(); // 第 0 帧：回弹起点 = 松手位移
        final released = tester.getTopLeft(find.text('甲')).dx - origin.dx;
        expect(released, lessThan(0.0), reason: '松手时卡应停在拖拽位移处');

        // 16ms：明显收敛但远未归位（easeOutCubic 约 76% 保留）——
        // 瞬移实现会在这一帧直接归位。
        await tester.pump(const Duration(milliseconds: 16));
        final mid = tester.getTopLeft(find.text('甲')).dx - origin.dx;
        expect(mid, greaterThan(released), reason: '已开始回弹（非瞬移）');
        expect(mid, lessThan(released * 0.5), reason: '16ms 时仍保留一半以上位移');

        // 100ms：仍在回弹中途（easeOutCubic 约 9% 保留）
        await tester.pump(const Duration(milliseconds: 84));
        final late = tester.getTopLeft(find.text('甲')).dx - origin.dx;
        expect(late, lessThan(0.0), reason: '100ms 时仍未归位');
        expect(late, greaterThan(released * 0.3), reason: '保留已不足三成');

        // 180ms 播完：精确归位（isAnimating=false → 读 _dragDx=0）
        await tester.pump(const Duration(milliseconds: 80));
        final settled = tester.getTopLeft(find.text('甲')).dx - origin.dx;
        expect(settled, 0.0, reason: '回弹播完后应精确归位');

        expect(find.text('甲'), findsOneWidget, reason: '未过阈值不得 dismiss');
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次31 契约：速度放行——位移不足 90 但速度 > 700 也能 dismiss',
        (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        // fling 用 50 个带时间戳的 move 坐实速度估算：位移 -90（吸收
        // slop 后 _dragDx≈-71，仍不足 90 阈值）、速度 1000px/s（> 700）
        // → 必须走速度分支放行飞出。注：距离不能太短——识别器的
        // isFlingGesture 还要求拟合样本跨度 > touchSlop(18)，-30px 的
        // fling 跨度仅 ~11px 会被判非 fling、速度清零。
        await tester.fling(find.text('甲'), const Offset(-90, 0), 1000);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('甲'), findsNothing);
        expect(find.text('乙'), findsOneWidget,
            reason: '速度放行：快速轻扫也应 dismiss');
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次31 契约：拖拽中途帧落地，前卡 GestureDetector 实例不换（批次7 回归）',
        (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        final frontDetector = find.ancestor(
          of: find.text('甲'),
          matching: find.byType(GestureDetector),
        );
        final before = tester.element(frontDetector);

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-40, 0));
        // 帧在拖拽中途落地：拖拽态重建若换掉 GestureDetector 类型，
        // 识别器会从 pointerRouter 摘除、后续 move/up 丢失（批次7 真机
        // 「滑不动」根因）。
        await tester.pump();
        expect(
          identical(tester.element(frontDetector), before),
          isTrue,
          reason: '拖拽态重建不得更换前卡 GestureDetector 实例',
        );

        await gesture.moveBy(const Offset(-400, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('乙'), findsOneWidget,
            reason: '识别器全程存活，抬手应正常 dismiss');
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('滑走最后一张后自动补货：游标请求回放空时兜底不带游标拿到新一批',
        (tester) async {
      final pagination = _FmPaginationAdapter();
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester, adapterOverride: pagination);
      try {
        expect(kugou.personalFmSongs.length, 2);
        expect(find.text('甲'), findsOneWidget);

        // 滑走甲：视觉指针 1，build 内触发补货——游标请求回放空 →
        // 兜底不带游标再要一批（丙/丁）→ append 后新层出现
        await tester.drag(find.text('甲'), const Offset(-500, 0));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(pagination.cursorRequests, 1,
            reason: '补货先带上一批最后一首的游标');
        expect(pagination.noCursorNormalRequests, 2,
            reason: '游标批次为空 → 兜底不带游标请求（首刷 + 兜底共 2 次）');
        expect(kugou.personalFmSongs.length, 4, reason: '兜底批次应追加 丙/丁');
        expect(find.text('乙'), findsOneWidget, reason: '前卡前移到乙');
        expect(find.text('丙'), findsOneWidget, reason: '补货的新歌应出现在下方层');

        // 继续滑走 乙、丙：前卡到丁（最后一张）时再次触发补货 → 追加戊
        await tester.drag(find.text('乙'), const Offset(-500, 0));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.drag(find.text('丙'), const Offset(-500, 0));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(pagination.cursorRequests, 2);
        expect(pagination.noCursorNormalRequests, 3);
        expect(kugou.personalFmSongs.length, 5);
        expect(find.text('丁'), findsOneWidget, reason: '前卡 = 列表最后一张');
        expect(find.text('戊'), findsOneWidget,
            reason: '滑到列表末尾时应自动补上新层，而非空白');
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('FM 卡与「最近播放」标题之间保留分区间隔（bottom=md）',
        (tester) async {
      final (kugou, player, favorites, localFavorites, _) =
          await _pumpCard(tester);
      try {
        final padding = tester.widget<Padding>(
          find.descendant(
            of: find.byType(DiscoverFmStackCard),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Padding &&
                  w.padding ==
                      const EdgeInsets.fromLTRB(
                        SonifySpacing.titleMargin, AppSpacing.sm,
                        SonifySpacing.titleMargin, AppSpacing.md,
                      ),
            ),
          ),
        ).padding as EdgeInsets;
        expect(padding.bottom, AppSpacing.md,
            reason: 'bottom=md（12）+ 最近播放标题 top=sm（8）+ 标题行纵向 xs（4）'
                '合计 24dp 分区间隔');
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

  group('首页最近播放卡片', () {
    Future<(PlayerProvider, LocalFavoritesProvider)> _pumpNowPlaying(
      WidgetTester tester, {
      Song? song,
      bool isPlaying = false,
    }) async {
      SharedPreferences.setMockInitialValues({});
      installFakeSecureStorage();
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
      AudioServiceLoader.setTestOverride(() async => _FakeAudioService());
      final player = _TestPlayerProvider();
      player.setTestPlaybackState(currentSong: song, isPlaying: isPlaying);
      final localFavorites = LocalFavoritesProvider();
      await tester.pumpWidget(
        // Provider 必须挂在 MaterialApp 之外：本组用例会 push 播放历史页
        // （新路由不在 home 子树里，挂在 home 内会让目标页读不到 Provider）
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            // 跳转目标 PlayHistoryPage 的顶栏常驻头像读取 KugouProvider
            ChangeNotifierProvider<KugouProvider>(
              create: (_) => KugouProvider(registerDeviceOnStart: false),
            ),
          ],
          child: MaterialApp(
            theme: _testTheme,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [DiscoverNowPlayingCard()],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return (player, localFavorites);
    }

    testWidgets('有当前曲目：标题行「最近播放」+ 右箭头 + 歌曲信息在场',
        (tester) async {
      final (player, localFavorites) = await _pumpNowPlaying(
        tester,
        song: const Song(
          id: 'np-1',
          title: '正在播的这首歌',
          artist: '测试歌手',
          album: '测试专辑',
          duration: Duration(minutes: 3),
        ),
      );
      try {
        expect(find.text('最近播放'), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right), findsOneWidget);
        expect(find.text('正在播的这首歌'), findsOneWidget);
        expect(find.text('测试歌手'), findsOneWidget);
      } finally {
        player.dispose();
        localFavorites.dispose();
        AudioServiceLoader.setTestOverride(null);
        uninstallFakeSecureStorage();
      }
    });

    testWidgets('点右箭头跳转播放历史页（复用既有 MaterialPageRoute push）',
        (tester) async {
      final (player, localFavorites) = await _pumpNowPlaying(
        tester,
        song: const Song(
          id: 'np-1',
          title: '正在播的这首歌',
          artist: '测试歌手',
          album: '测试专辑',
          duration: Duration(minutes: 3),
        ),
      );
      try {
        await tester.tap(find.byIcon(Icons.chevron_right));
        await tester.pumpAndSettle();
        expect(find.byType(PlayHistoryPage), findsOneWidget);
      } finally {
        player.dispose();
        localFavorites.dispose();
        AudioServiceLoader.setTestOverride(null);
        uninstallFakeSecureStorage();
      }
    });

    testWidgets('无当前曲目：整块隐藏（不占列表位）', (tester) async {
      final (player, localFavorites) = await _pumpNowPlaying(tester);
      try {
        expect(find.text('最近播放'), findsNothing);
        expect(find.byIcon(Icons.chevron_right), findsNothing);
      } finally {
        player.dispose();
        localFavorites.dispose();
        AudioServiceLoader.setTestOverride(null);
        uninstallFakeSecureStorage();
      }
    });
  });
}

/// 批次31：FM 播放路径测试播放器——currentSong/isPlaying 走测试态，
/// next() 延迟 [nextDelay] 后切到 [nextTarget] 并 notifyListeners，
/// 模拟真机 player.next() 的异步耗时窗口（该窗口内被划走的卡必须保持
/// 不可见，不得闪回；真实 PlayerProvider 在假音频服务下不可驱动）。
class _FmTestPlayerProvider extends PlayerProvider {
  _FmTestPlayerProvider({required this.nextDelay});

  final Duration nextDelay;
  Song? _testCurrentSong;
  bool _testIsPlaying = false;

  /// next() 被调用次数（播放跟随契约断言）。
  int nextCallCount = 0;

  /// next() 完成后切换到的曲目（id 需与列表某首 hash 对齐）。
  Song? nextTarget;

  @override
  Song? get currentSong => _testCurrentSong;

  @override
  bool get isPlaying => _testIsPlaying;

  void setTestPlaybackState({Song? currentSong, required bool isPlaying}) {
    _testCurrentSong = currentSong;
    _testIsPlaying = isPlaying;
    notifyListeners();
  }

  @override
  Future<void> next({bool autoPlay = true}) async {
    nextCallCount++;
    if (nextDelay > Duration.zero) {
      await Future.delayed(nextDelay);
    }
    final target = nextTarget;
    if (target != null) {
      _testCurrentSong = target;
      notifyListeners();
    }
  }
}

/// 测试播放器：覆写 currentSong/isPlaying 为测试态（_pumpNowPlaying 注入），
/// 其余构造/释放行为与真 PlayerProvider 一致（假音频服务已装）。
class _TestPlayerProvider extends PlayerProvider {
  Song? _testCurrentSong;
  bool _testIsPlaying = false;

  @override
  Song? get currentSong => _testCurrentSong;

  @override
  bool get isPlaying => _testIsPlaying;

  void setTestPlaybackState({Song? currentSong, required bool isPlaying}) {
    _testCurrentSong = currentSong;
    _testIsPlaying = isPlaying;
    notifyListeners();
  }
}

void _markLocalServerReady() {
  final generation = KugouApiClient.markServerStarting();
  KugouApiClient.markServerReady(generation);
}
