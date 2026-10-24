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

/// 批次32：读取前卡（[title]）祖先链上的 Opacity 叠乘值与 Transform
/// 水平平移量（遍历方式与 [_expectDismissedCardInFlight] 一致，单独取样）。
(double, double) _readFrontCard(WidgetTester tester, String title) {
  final element = tester.element(find.text(title));
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
  return (opacity, dx);
}

/// 批次32：读取下层卡（[title]）祖先链上 Transform.scale 的缩放与
/// Transform.translate 的纵向位移。下层卡祖先链上仅此两种 Transform
/// （scale 的 m11≠1、translate 的 m24≠0），前卡的 rotate 不在本链。
(double, double) _readLowerLayerCard(WidgetTester tester, String title) {
  final element = tester.element(find.text(title));
  var scale = 1.0;
  var dy = 0.0;
  element.visitAncestorElements((e) {
    final w = e.widget;
    if (w is Transform) {
      final s = w.transform.storage;
      if (s[0] != 1.0) scale = s[0]; // scale 矩阵 m11
      dy += s[13]; // 列主序：平移 y
    }
    return true; // 继续向上遍历
  });
  return (scale, dy);
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

        // 逐帧推进飞出（200ms）与收尾：每一帧里，被划走的甲只要还在
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

        // 飞出 200ms + next() 延迟 100ms：逐帧检查整个窗口无闪回。
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

    testWidgets('批次32：跟手渐隐——拖拽中前卡透明度随 |dx| 递减且不低于下限 0.35',
        (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        // 首 move 只触发 drag start（pending offset 被吸收，既有用例同款
        // 口径），次 move 起才产出 onHorizontalDragUpdate。
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-60, 0)); // _dragDx = -60
        await tester.pump();
        final (small, _) = _readFrontCard(tester, '甲');
        expect(small, lessThan(1.0), reason: '有位移即渐隐（不再不透明跟手）');
        expect(small, greaterThan(0.35), reason: '下限之上');

        await gesture.moveBy(const Offset(-240, 0)); // _dragDx = -300
        await tester.pump();
        final (mid, _) = _readFrontCard(tester, '甲');
        expect(mid, lessThan(small), reason: 'easeIn：|dx| 越大越透');
        expect(mid, greaterThan(0.35), reason: '下限之上');

        await gesture.moveBy(const Offset(-740, 0)); // |dx|=1040 > 容器宽
        await tester.pump();
        final (floorHit, _) = _readFrontCard(tester, '甲');
        expect(floorHit, closeTo(0.35, 0.001),
            reason: '归一化进度 clamp 到 1 → 命中下限');

        await gesture.up(); // 超阈值 → 飞出收尾
        await tester.pumpAndSettle();
        // 收尾补货请求带 zero-duration Timer，补 pump 排空
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('乙'), findsOneWidget, reason: '渐隐不影响 dismiss 契约');
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次32：飞出距离动态化——目标 dx 绝对值 > 容器宽度（LayoutBuilder 实测）',
        (tester) async {
      // 批次33：终点帧（t=1）取样走播放路径注入——非播放路径
      // _finishDismiss 的 setState 与动画完成同帧落地，甲在 208ms
      // 帧即被切走；播放路径 next() 延迟 100ms 让甲留在树里（与
      // 「飞出终点透明度 0」用例同款模式）。
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
        testPlayer.nextTarget = const Song(
          id: 'hb',
          title: '乙',
          artist: '测试歌手',
          album: '测试专辑',
          duration: Duration(minutes: 3),
        );
        await tester.pump();
        // 容器宽度走 LayoutBuilder 实测（分区宽 = 屏宽 − 2×titleMargin），
        // 不写死屏宽。
        final stackFinder = find.ancestor(
          of: find.text('甲'),
          matching: find.byType(LayoutBuilder),
        );
        final width = tester.getSize(stackFinder.first).width;
        expect(width, greaterThan(0));

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-40, 0));
        await gesture.moveBy(const Offset(-400, 0));
        await gesture.up();
        // 批次33：飞出改为「释放位置 → 界外目标」的连续插值——t=0 帧
        // 精确落在释放位置（-500，未出界；边界连续，防松手瞬移），
        // 飞出目标改在 t=1（200ms）达成，故逐帧推进到飞出完成再取样。
        await tester.pump();
        final (_, dxStart) = _readFrontCard(tester, '甲');
        expect(
          dxStart.abs(),
          lessThan(width),
          reason: 't=0 边界连续：起点=释放位置（尚未出界）',
        );

        for (var i = 0; i < 13; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final (_, dxEnd) = _readFrontCard(tester, '甲');
        expect(
          dxEnd.abs(),
          greaterThan(width),
          reason: '飞出目标 = 容器宽 + 余量，须真正滑出分区边界（旧值固定 480）',
        );

        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(testPlayer.nextCallCount, 1);
        expect(find.text('乙'), findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次32：飞出时长 ≤200ms——208ms 时前卡已收尾切走', (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-40, 0));
        await gesture.moveBy(const Offset(-400, 0));
        await gesture.up();
        // 首帧只立动画起点（value=0），先补零帧；随后逐帧推进飞出：
        // 192ms（12×16ms）时应仍在窗口内；208ms 应收尾完成。
        // 旧实现 220ms 在 208ms 帧后甲仍在飞出中 → 本断言红。
        await tester.pump();
        for (var i = 1; i <= 13; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (i == 10) {
            // 160ms（80% 时段）：前卡 easeIn 后段加速消失——opacity =
            // 释放帧渐隐值(≈0.675) × (1−easeIn(0.8))(≈0.31) ≈ 0.21；
            // 若误用 easeOut 曲线（前快后慢）此时已≈0.02，线性同期
            // ≈0.135，本断言均红。区间下限随公式修正由 0.2 调至 0.15
            // （叠乘释放帧渐隐值所致，easeIn 意图不变）。
            final (midOpacity, _) = _readFrontCard(tester, '甲');
            expect(midOpacity, inInclusiveRange(0.15, 0.5),
                reason: '前卡飞出须 easeIn（后段加速消失）');
          }
          if (i == 12) {
            expect(find.text('甲'), findsOneWidget, reason: '192ms 仍在飞出窗口');
          }
        }
        await tester.pump(); // 收尾 setState 落帧
        expect(find.text('甲'), findsNothing, reason: '208ms 应收尾完成（≤200ms）');
        expect(find.text('乙'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次32：飞出终点透明度 0——t=1 后、next() 返回前甲保持全透明',
        (tester) async {
      // 播放路径：200ms 飞出完成 → _finishDismiss await next()（延迟
      // 100ms）。该窗口内被划走的甲必须停在 t=1 的全透明态（终点收敛 0）。
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
        await gesture.moveBy(const Offset(-400, 0));
        await gesture.up();

        // 首帧只立动画起点（value=0），先补零帧；208ms（13×16ms）时
        // 飞出已完成（200ms）但 next() 未返回（100ms 延迟）
        await tester.pump();
        for (var i = 0; i < 13; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final (opacity, _) = _readFrontCard(tester, '甲');
        expect(find.text('甲'), findsOneWidget,
            reason: 'next() 未返回，甲仍在树（_flying 保持）');
        expect(opacity, closeTo(0.0, 0.001),
            reason: 't=1：透明度终点收敛到 0');
        expect(testPlayer.nextCallCount, 1,
            reason: '200ms 飞出完成即触发收尾（旧 220ms 此时尚未触发）');

        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(testPlayer.nextCallCount, 1);
        expect(find.text('甲'), findsNothing);
        expect(find.text('乙'), findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次32：下层 easeOut 前移——飞出前 1/3 时段已走过一半以上位移',
        (tester) async {
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-40, 0));
        await gesture.moveBy(const Offset(-400, 0));
        await gesture.up();
        // 前 1/3 时段（200ms ÷ 3 ≈ 66ms）：easeOutCubic(0.33)≈0.70 过半；
        // 线性插值同期仅 1/3（scale≈0.973 < 0.98、dy≈9.3 > 7）。该口径
        // 同时锁死下层不得误用前卡的 easeIn（前慢后快，同期仅 ~13%）。
        // 注：up() 后首帧 pump 只立动画起点（value=0），先补零帧再推时长。
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 66));
        final (scale, dy) = _readLowerLayerCard(tester, '乙');
        expect(scale, greaterThanOrEqualTo(0.98),
            reason: 'scale 变化量（0.96→1）已过半');
        expect(dy, lessThanOrEqualTo(7.0),
            reason: 'dy 变化量（14→0）已过半（线性同期仅 1/3）');

        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('乙'), findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次33：飞出方向修正——左划 -500 逐帧单调外出到界外，无回撤帧',
        (tester) async {
      // 旧公式 offset=_flyDx×(1−t) 方向反了：松手首帧卡片从释放位置
      // 瞬移到边界外、再滑回原位渐隐——用户反复反馈的「划走后往回闪
      // 一下」。批次33 改为「释放位置 → 界外目标」的连续插值，逐帧
      // 坐实单调外出、全程无回撤。
      // 终点帧（t=1）取样走播放路径注入：非播放路径 _finishDismiss 的
      // setState 与动画完成同帧落地，甲在 208ms 帧即被切走；播放路径
      // next() 延迟 100ms 让甲留在树里（与「飞出终点透明度 0」同款）。
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
        testPlayer.nextTarget = const Song(
          id: 'hb',
          title: '乙',
          artist: '测试歌手',
          album: '测试专辑',
          duration: Duration(minutes: 3),
        );
        await tester.pump();
        final stackFinder = find.ancestor(
          of: find.text('甲'),
          matching: find.byType(LayoutBuilder),
        );
        final width = tester.getSize(stackFinder.first).width;
        final target = width + 64; // _kFlyOutExtra

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        // 首 move 越过 slop 只触发 drag start（pending offset 被吸收、
        // 不发 update），次 move 的首个 update delta 从 down 点全额起算
        // ——两个 move 精确累积到 -500（三连会得 -560）。
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-440, 0)); // _dragDx = -500
        await tester.pump();
        final (releaseOpacity, releaseDx) = _readFrontCard(tester, '甲');
        expect(releaseDx, closeTo(-500, 1e-6),
            reason: '松手前跟手位移应为 -500');

        await gesture.up();
        await tester.pump(); // 飞出 t=0 帧：与释放帧连续
        var prevDx = releaseDx;
        // 逐帧推进飞出（200ms）：dx 必须从 -500 单调外出（更负）到
        // -(宽+64)；任何一帧回撤即闪回回归。
        for (var i = 0; i < 13; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          final (opacity, dx) = _readFrontCard(tester, '甲');
          expect(
            dx,
            lessThan(prevDx),
            reason: '第 ${i + 1} 帧回撤（dx=$dx, 上一帧=$prevDx）',
          );
          expect(dx, lessThanOrEqualTo(-500),
              reason: '飞出方向必须沿拖拽方向（左划往左走）');
          expect(opacity, lessThanOrEqualTo(releaseOpacity + 1e-9),
              reason: '透明度不得回升');
          // 闪回定义补强：任何一帧不得「位移≈0 且全不透明」
          _expectDismissedCardInFlight(tester, '甲');
          prevDx = dx;
        }
        expect(prevDx, closeTo(-target, 1e-6),
            reason: '飞出终点 = 容器宽 + 64 的界外');

        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(testPlayer.nextCallCount, 1);
        expect(find.text('甲'), findsNothing);
        expect(find.text('乙'), findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次33：飞出方向修正——右划 +500 对称（逐帧单调外出到界外）',
        (tester) async {
      // 左划修正的镜像验证：dir 沿拖拽方向取正，飞出目标 = +（宽+64）。
      // 同样走播放路径注入保终点帧可取样（见左划用例注释）。
      final testPlayer = _FmTestPlayerProvider(
        nextDelay: const Duration(milliseconds: 100),
      );
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester, playerOverride: testPlayer);
      try {
        testPlayer.setTestPlaybackState(
          currentSong: const Song(
            id: 'ha',
            title: '甲',
            artist: '测试歌手',
            album: '测试专辑',
            duration: Duration(minutes: 3),
          ),
          isPlaying: true,
        );
        testPlayer.nextTarget = const Song(
          id: 'hb',
          title: '乙',
          artist: '测试歌手',
          album: '测试专辑',
          duration: Duration(minutes: 3),
        );
        await tester.pump();
        final stackFinder = find.ancestor(
          of: find.text('甲'),
          matching: find.byType(LayoutBuilder),
        );
        final width = tester.getSize(stackFinder.first).width;
        final target = width + 64;

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        // 首 move 触发 drag start 不发 update，次 move 全额起算——两 move
        // 精确累积到 +500。
        await gesture.moveBy(const Offset(60, 0));
        await gesture.moveBy(const Offset(440, 0)); // _dragDx = +500
        await tester.pump();
        final (releaseOpacity, releaseDx) = _readFrontCard(tester, '甲');
        expect(releaseDx, closeTo(500, 1e-6),
            reason: '松手前跟手位移应为 +500');

        await gesture.up();
        await tester.pump();
        var prevDx = releaseDx;
        for (var i = 0; i < 13; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          final (opacity, dx) = _readFrontCard(tester, '甲');
          expect(
            dx,
            greaterThan(prevDx),
            reason: '第 ${i + 1} 帧回撤（dx=$dx, 上一帧=$prevDx）',
          );
          expect(dx, greaterThanOrEqualTo(500),
              reason: '飞出方向必须沿拖拽方向（右划往右走）');
          expect(opacity, lessThanOrEqualTo(releaseOpacity + 1e-9),
              reason: '透明度不得回升');
          _expectDismissedCardInFlight(tester, '甲');
          prevDx = dx;
        }
        expect(prevDx, closeTo(target, 1e-6),
            reason: '飞出终点 = 容器宽 + 64 的界外');

        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(testPlayer.nextCallCount, 1);
        expect(find.text('甲'), findsNothing);
        expect(find.text('乙'), findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次33：释放边界连续——松手前后两帧的前卡 dx/opacity 各自相等',
        (tester) async {
      // 闪回的另一半根因：旧公式 t=0 时 offset=_flyDx（界外）、opacity=1，
      // 与松手帧（释放位置 + 跟手渐隐值）双双不连续。批次33 飞出起点
      // 精确取释放位置与释放帧透明度，边界零跳变。
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-440, 0)); // _dragDx = -500
        await tester.pump();
        final (beforeOpacity, beforeDx) = _readFrontCard(tester, '甲');

        await gesture.up();
        await tester.pump(); // 松手后第一帧（飞出 t=0）
        final (afterOpacity, afterDx) = _readFrontCard(tester, '甲');

        expect(afterDx, closeTo(beforeDx, 1e-6),
            reason: '位移边界连续：飞出起点 = 释放位置');
        expect(afterOpacity, closeTo(beforeOpacity, 1e-6),
            reason: '透明度边界连续：飞出起点透明度 = 释放帧跟手渐隐值');

        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('乙'), findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次33：拖拽中下层卡随 |dx| 前移（scale 递增 / dy 递减，与手指成比例）',
        (tester) async {
      // 旧实现下层前移只挂 _flying，拖拽中完全冻结、松手后才动。
      // 批次33 统一 dismiss 进度 p=|视觉dx|/容器宽，与手指 1:1 耦合。
      final (kugou, player, favorites, localFavorites, adapter) =
          await _pumpCard(tester);
      try {
        final (scaleRest, dyRest) = _readLowerLayerCard(tester, '乙');
        expect(scaleRest, closeTo(0.96, 1e-6), reason: '静止时 layer1 缩小 4%');
        expect(dyRest, closeTo(14.0, 1e-6), reason: '静止时 layer1 下沉 14');

        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        // 首 move 触发 drag start 不发 update，次 move 全额起算：
        // 两 move 精确到 -150，再三 move 到 -300。
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-90, 0)); // _dragDx = -150
        await tester.pump();
        final (scale150, dy150) = _readLowerLayerCard(tester, '乙');

        await gesture.moveBy(const Offset(-150, 0)); // _dragDx = -300
        await tester.pump();
        final (scale300, dy300) = _readLowerLayerCard(tester, '乙');

        expect(scale150, greaterThan(scaleRest),
            reason: '一经拖拽下层即前移（不再冻结）');
        expect(dy150, lessThan(dyRest), reason: '下沉量随拖拽收敛');
        expect(scale300, greaterThan(scale150),
            reason: '拖得越深，下一张越趋向全尺寸');
        expect(dy300, lessThan(dy150), reason: '拖得越深，下一张前移越多');

        // 与手指进度成比例：p = 1 − shrink（shrink 由 scale 反推），
        // |dx| 翻倍 → p 翻倍（1:1 耦合）。
        final p150 = 1 - (1 - scale150) / 0.04;
        final p300 = 1 - (1 - scale300) / 0.04;
        expect(p300, closeTo(2 * p150, 1e-9),
            reason: 'dismiss 进度与拖拽位移成正比');

        await gesture.up(); // |dx|=300 > 90 → 飞出收尾
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('乙'), findsOneWidget);
      } finally {
        _teardown(kugou, player, favorites, localFavorites);
      }
    });

    testWidgets('批次33：飞出下层进度连续——松手瞬间 shrink 不变，随后 easeOutCubic 收敛到 0',
        (tester) async {
      // 下层进度改统一 dismiss 进度 p：拖拽中 = |dx|/宽；飞出中 = 从
      // 释放进度 _flyFromProgress 起 easeOutCubic 到 1。松手边界两层
      // 连续：前卡位移/透明度（见「释放边界连续」用例）与下层 shrink。
      // 终点帧（t=1）取样走播放路径注入：非播放路径 _finishDismiss 的
      // setState 与动画完成同帧落地，208ms 帧指针已前移、乙变成前卡，
      // 下层取样会失去语义；播放路径 next() 延迟 100ms 保住 layer 身份。
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
        testPlayer.nextTarget = const Song(
          id: 'hb',
          title: '乙',
          artist: '测试歌手',
          album: '测试专辑',
          duration: Duration(minutes: 3),
        );
        await tester.pump();
        final gesture =
            await tester.startGesture(tester.getCenter(find.text('甲')));
        await gesture.moveBy(const Offset(-60, 0));
        await gesture.moveBy(const Offset(-440, 0)); // _dragDx = -500
        await tester.pump();
        final (scaleRelease, dyRelease) = _readLowerLayerCard(tester, '乙');

        await gesture.up();
        await tester.pump(); // 飞出 t=0：下层进度 = 释放时拖拽进度
        final (scaleFly0, dyFly0) = _readLowerLayerCard(tester, '乙');
        expect(scaleFly0, closeTo(scaleRelease, 1e-6),
            reason: '松手瞬间下层 shrink 与松手前一致（进度边界连续）');
        expect(dyFly0, closeTo(dyRelease, 1e-6),
            reason: '松手瞬间下层 dy 与松手前一致');

        // 飞出推进：easeOutCubic 收敛到 1 → shrink→0（scale→1、dy→0）
        for (var i = 0; i < 13; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final (scaleEnd, dyEnd) = _readLowerLayerCard(tester, '乙');
        expect(scaleEnd, closeTo(1.0, 1e-6), reason: '飞出完成 shrink=0');
        expect(dyEnd, closeTo(0.0, 1e-6), reason: '飞出完成 dy=0');

        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(testPlayer.nextCallCount, 1);
        expect(find.text('乙'), findsOneWidget);
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
