import 'dart:io';

// 批次36：断言必须与实现同源——full_player.dart 由 package:material_ui 构建，
// 其 TabBarView / IconButton 是 material_ui 的独立类（与 flutter/material 的
// 同名类不是同一类型，find.byType 会 0 命中）。故测试宿主与 Finder 一律用
// material_ui；flutter/widgets 的基础类型（SizedBox/Padding/Text…）两者共享。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/modules/player/apple_music_lyrics_view.dart';
import 'package:md3music/modules/player/comments_view.dart';
import 'package:md3music/modules/player/full_player.dart';
import 'package:md3music/modules/player/full_player_route.dart';
import 'package:md3music/modules/player/lyrics_view.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/md3e_transport_row.dart';
import 'package:md3music/widgets/player_artwork_image.dart';
import 'package:md3music/widgets/player_seek_bar.dart';
import 'package:md3music/widgets/player_playlist_view.dart';
import 'package:md3music/widgets/player_tab_strip.dart';
import 'package:md3music/widgets/playback_status_feedback.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/controlled_audio_service.dart';

// 批次36：播放页横屏双栏分栏（方案 P1-P）测试。
// 装配方式学自 test/widgets/full_player_narrow_layout_test.dart：
//  ControlledAudioService + PlayerProvider + KugouProvider + 各 Provider 宿主。
Song _song({String? artworkUri}) => Song(
  id: 'landscape-split-target',
  title: 'Landscape Split Target',
  artist: 'Layout Artist',
  album: 'Layout Album',
  duration: const Duration(minutes: 3),
  url: 'https://audio.invalid/track.mp3',
  artworkUri: artworkUri,
  isOnline: true,
);

void _mockPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockStreamHandler(
    const services.EventChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    ),
    MockStreamHandler.inline(
      onListen: (_, events) => events.success(<String>['wifi']),
    ),
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('com.md3music.md3music/home_widget'),
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    services.SystemChannels.platform,
    (_) async => null,
  );
  messenger.setMockMethodCallHandler(
    const services.MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => switch (call.method) {
      'getTemporaryDirectory' ||
      'getApplicationSupportDirectory' ||
      'getApplicationDocumentsDirectory' ||
      'getDownloadsDirectory' => Directory.systemTemp.path,
      _ => null,
    },
  );
}

/// 评论接口桩（批次36）：评论 tab 首帧会 `KugouProvider.getComments`，
/// 真实实现要经 LocalServerLifecycle + HTTP，测试环境无网络只能等 8s 超时，
/// 期间残留 Timer 会让测试框架在 dispose 后报 "A Timer is still pending"。
/// 只桩这一个方法，其余（歌词 restoreLyric 等）保持既有装配。
class _StubKugouProvider extends KugouProvider {
  _StubKugouProvider() : super(registerDeviceOnStart: false);

  @override
  Future<KugouCommentList?> getComments(
    String hash, {
    String? albumAudioId,
    int page = 1,
  }) async => const KugouCommentList();
}

Widget _host(PlayerProvider player, KugouProvider kugou, Widget page) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<KugouProvider>.value(value: kugou),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider(syncOnStart: false)),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
      ],
      child: MaterialApp(home: page),
    );

/// 在指定视口装配并渲染 FullPlayer，回调内执行断言；finally 统一清理。
///
/// [viaRoute]（批次37）：不直接渲染 FullPlayer，而是经 [fullPlayerRoute]
/// push 到根 Navigator——用于验证「点击打开 / 上滑展开」两条真实打开路径。
/// [dragMode] 仅在 viaRoute 下生效：dragOriginTop 模式 push（路由跳过自动
/// 入场动画、由手势接管）并在 push 后调 [DraggablePlayerRoute.settleToFull]，
/// 模拟「悬浮播放器上滑松手展开」全链路。
Future<void> _withPlayer(
  WidgetTester tester, {
  required Size viewport,
  double textScale = 1.0,
  bool viaRoute = false,
  bool dragMode = false,
  required Future<void> Function(WidgetTester tester) body,
}) async {
  final originalPhysicalSize = tester.view.physicalSize;
  final originalDevicePixelRatio = tester.view.devicePixelRatio;
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  SharedPreferences.setMockInitialValues({});
  _mockPlatformChannels();
  KugouProvider.restoreLyric = (_) async => const KugouLyric(
    content: '[00:00.00]test lyric',
    decodedContent: '[00:00.00]test lyric',
  );
  final audio = ControlledAudioService();
  AudioServiceLoader.setTestOverride(() async => audio);
  final kugou = _StubKugouProvider();
  PlayerProvider? player;
  DraggablePlayerRoute<void>? pushedRoute;
  try {
    await tester.runAsync(() async {
      final activePlayer = PlayerProvider();
      player = activePlayer;
      await activePlayer.audioReady.timeout(const Duration(seconds: 10));
      final load = activePlayer.playPlaylist([_song()], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await load;
      audio.emitPlaying(true);
    });

    await tester.pumpWidget(
      _host(
        player!,
        kugou,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: viaRoute
                ? _RouteLauncher(
                    onLaunch: (ctx) {
                      pushedRoute = fullPlayerRoute(
                        ctx,
                        dragOriginTop: dragMode ? 200.0 : null,
                        screenHeight: dragMode ? viewport.height : null,
                      );
                      return Navigator.of(ctx, rootNavigator: true)
                          .push(pushedRoute!);
                    },
                  )
                : const FullPlayer(),
          ),
        ),
      ),
    );
    if (viaRoute) {
      // 点击触发 push（tap 模式：路由自动播放入场动画；drag 模式：didPush
      // 跳过动画、controller 停在 0，随后 settleToFull 模拟松手展开）
      await tester.tap(find.text('OPEN_PLAYER'));
      await tester.pump();
      if (dragMode) {
        pushedRoute!.settleToFull();
      }
      // 批次 39：横屏默认落歌词 tab，歌词 AM 扫色视图自带自驱动 Ticker
      // （逐帧内插永不收敛）——pumpAndSettle 会超时，改有界 pump 推进
      // 路由入场/settle 动画（300ms 上限 + 余量）。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }
    // 同上：默认歌词 tab 的自驱动 Ticker 禁用 pumpAndSettle，用有界
    // pump 推进入场动画（入场 300ms + tap 路径淡入，400ms 覆盖）。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    await body(tester);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  } finally {
    // 路由测试会同步 playerExpansion（settle 终态短路置 1），清零避免跨用例残留
    playerExpansion.value = 0.0;
    await tester.pumpWidget(const SizedBox.shrink());
    player?.dispose();
    kugou.dispose();
    await tester.runAsync(() => HistoryRepository().flush());
    await audio.dispose();
    AudioServiceLoader.setTestOverride(null);
    KugouProvider.restoreLyric = null;
    tester.view.physicalSize = originalPhysicalSize;
    tester.view.devicePixelRatio = originalDevicePixelRatio;
  }
}

/// 路由宿主页（批次37）：提供 Navigator 上下文，点击后 push 播放页路由。
class _RouteLauncher extends StatelessWidget {
  const _RouteLauncher({required this.onLaunch});

  final Future<dynamic> Function(BuildContext context) onLaunch;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => onLaunch(context),
          child: const Text('OPEN_PLAYER'),
        ),
      ),
    );
  }
}

/// 左栏封面图：播放页内 PlayerArtworkImage 可能有多份（右栏播放列表缩略图），
/// 取中心 x 位于屏幕左半（批次38 分栏 flex 4/6，右栏从 40% 起；阈值放宽到
/// 50% 仍能无歧义命中左栏那份）的那一份。
Finder _leftCoverArtwork(WidgetTester tester, Size viewport) {
  final matches = tester
      .widgetList<PlayerArtworkImage>(find.byType(PlayerArtworkImage))
      .where((w) {
        final rect = tester.getRect(find.byWidget(w));
        return rect.center.dx < viewport.width * 0.5;
      })
      .toList();
  expect(matches, isNotEmpty, reason: '左栏应渲染封面图');
  return find.byWidget(matches.first);
}

/// 封面布局盒：封面图最近的 SizedBox 祖先（_buildSplitArtworkColumn 的
/// SizedBox(width: boxSize, height: boxSize)，其与标题块同宽）。
/// 封面图在盒内是 Positioned.fill，故该盒边长 == 封面图 rect 边长。
Finder _artworkBox(WidgetTester tester, Size viewport) => find
    .ancestor(of: _leftCoverArtwork(tester, viewport), matching: find.byType(SizedBox))
    .first;

/// 左栏容器：_buildSplitArtworkColumn 里 g=16 的那层 Padding。
///
/// 不能用「最近的 Padding 祖先」（批次36 修复）：PlayerArtworkImage 自身
/// build 内就有一层边长等于封面的 Padding，最近的会命中它，测出的「左栏宽高」
/// 恒等于封面本身，把 clamp 公式算成 136/120 这类假期望值（实测封面 240/224）。
/// 这里取**同时包含标题文本**的那层 Padding——封面与标题在同一个 Column 内，
/// 只有左栏容器满足该条件。
Finder _leftColumn(WidgetTester tester, Size viewport) {
  final cover = _leftCoverArtwork(tester, viewport);
  final paddings = find
      .ancestor(of: cover, matching: find.byType(Padding))
      .evaluate();
  for (final candidate in paddings) {
    final self = find.byElementPredicate((e) => identical(e, candidate));
    if (find
        .descendant(of: self, matching: find.text('LANDSCAPE SPLIT TARGET'))
        .evaluate()
        .isNotEmpty) {
      return self;
    }
  }
  fail('未找到同时包含封面与标题的左栏 Padding');
}

/// 与实现同源的封面边长公式（批次37 _buildSplitArtworkColumn）：
/// 封面在 Expanded 内吃掉左栏扣掉固定块（标题+播控）后的剩余高度，
/// 边长 = min(可用宽 - widthInset, cap, 剩余高)，medium 另有 120 下限。
/// [fixedBlockHeight] 用实测几何推得（标题 top 与播控 bottom 之间 + 上间距 10），
/// 避免在测试里复刻字体度量。
double _expectedArtworkSize({
  required Rect column,
  required double fixedBlockHeight,
  required bool expanded,
}) {
  const g = 16.0;
  final cap = expanded ? 380.0 : 300.0;
  final minSize = expanded ? 0.0 : 120.0;
  final widthInset = expanded ? 32.0 : 0.0;
  final widthBudget = column.width - g - widthInset;
  final heightBudget = column.height - 2 * 12 - fixedBlockHeight;
  var size = widthBudget.clamp(0.0, cap).clamp(
    0.0,
    heightBudget.clamp(0.0, double.infinity),
  );
  if (minSize > 0) size = size.clamp(minSize, cap);
  return size;
}

/// 实测左栏固定块高度（封面之下：间距 10 + 标题块 + 间距 8 + 播控块）。
/// 传输行 bottom 即播控块底（= 左栏内容区底部），由传输行/标题实测几何反推，
/// 不含左栏自身上下 padding 12。
double _measuredFixedBlockHeight(WidgetTester tester) {
  final titleTop = tester.getRect(find.text('LANDSCAPE SPLIT TARGET')).top;
  final transportBottom = tester.getRect(find.byType(MD3ETransportRow)).bottom;
  return transportBottom - titleTop + 10;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('批次38 横屏分栏（medium：600≤宽<900）', () {
    testWidgets('800x400：左栏封面+标题+播控，右栏 Tab+tabstrip，播控在封面下方', (
      tester,
    ) async {
      const viewport = Size(800, 400);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          expect(tester.takeException(), isNull);

          // ── 右栏（批次38 flex 6）：TabBarView 全高 + 底部 tab 导航条 ──
          final tabBarView = find.byType(TabBarView);
          expect(tabBarView, findsOneWidget);
          final tabRect = tester.getRect(tabBarView);
          expect(tabRect.center.dx, greaterThan(viewport.width * 0.5));
          // 批次38：分栏比例恢复 4/6，右栏占约 60% 屏宽
          expect(tabRect.width, closeTo(viewport.width * 0.6, 1));
          // 批次 39：右栏默认落歌词 tab（用户口径「右侧栏默认歌词」），
          // TabBarView 惰性渲染只建当前页——播放列表视图不在树
          expect(
            find.descendant(
              of: tabBarView,
              matching: find.byType(PlayerPlaylistView),
            ),
            findsNothing,
          );
          expect(
            find.descendant(of: tabBarView, matching: find.byType(LyricsView))
                    .evaluate()
                    .length +
                find
                    .descendant(
                      of: tabBarView,
                      matching: find.byType(AppleMusicLyricsView),
                    )
                    .evaluate()
                    .length,
            1,
            reason: '右栏默认渲染歌词视图',
          );
          // tab 导航条仍在右栏（播控移走后右栏底部只留 tabstrip）
          final tabStrip = find.byType(PlayerTabStrip);
          expect(tabStrip, findsOneWidget);
          expect(
            tester.getRect(tabStrip).center.dx,
            greaterThan(viewport.width * 0.5),
          );

          // ── 左栏（批次38 flex 4）：封面 + 标题 + 播控（进度条 + 三键传输行） ──
          final cover = _leftCoverArtwork(tester, viewport);
          final coverRect = tester.getRect(cover);
          expect(coverRect.center.dx, lessThan(viewport.width * 0.5));
          final title = find.text('LANDSCAPE SPLIT TARGET');
          expect(title, findsOneWidget);
          // 批次 39：封面在左栏内**水平居中**（用户口径「封面栏封面居中」
          // ——批次 38 前为 centerLeft、标题与封面左缘对齐）；标题块仍
          // 占满左栏（stretch），左缘 = 栏左缘 16dp，不再与封面左缘对齐
          expect(tester.getRect(title).left, closeTo(16, 0.5));
          expect(
            coverRect.center.dx,
            closeTo(168, 1),
            reason: '封面中心 = 左栏内容区中心（左栏 320 − 左内缩 16 → 16+152）',
          );

          // ── 批次37 核心：播控/进度条在封面下方（几何断言） ──
          final seekBar = find.byType(PlayerSeekBar);
          expect(seekBar, findsOneWidget);
          final transport = find.byType(MD3ETransportRow);
          expect(transport, findsOneWidget);
          final seekRect = tester.getRect(seekBar);
          final transportRect = tester.getRect(transport);
          expect(seekRect.top, greaterThan(coverRect.bottom),
              reason: '进度条应位于封面下方');
          expect(transportRect.top, greaterThan(coverRect.bottom),
              reason: '传输行应位于封面下方');
          // 播控在左栏（批次36 时在右栏）
          expect(transportRect.center.dx, lessThan(viewport.width * 0.4));
          // 纵向顺序：进度条 → 传输行（进度条在下、传输行最下）
          expect(transportRect.bottom, greaterThan(seekRect.bottom));
          expect(find.byType(PlaybackStatusFeedback), findsOneWidget);

          // ── 批次38 核心：播控块高度压缩 ──
          // 进度条 38→30、与传输行间距 8→4、传输键 56→48：
          // 无状态提示时播控块高 30+4+48=82（旧 38+8+56=102）
          expect(seekRect.height, closeTo(30, 0.5),
              reason: '批次38 横屏进度条应压缩到 30');
          expect(transportRect.height, closeTo(48, 0.5),
              reason: '批次38 横屏传输键应压缩到 48');
          expect(transportRect.top - seekRect.bottom, closeTo(4, 0.5),
              reason: '批次38 进度条与传输行间距应收紧到 4');
          expect(transportRect.bottom - seekRect.top, closeTo(82, 0.5),
              reason: '播控块整体高 30+4+48=82（旧 102）');

          // ── 返回按钮在最外层 Column：屏幕最左上角，且在左栏封面之上 ──
          final backButton = find.ancestor(
            of: find.byIcon(Icons.keyboard_arrow_down),
            matching: find.byType(IconButton),
          );
          expect(backButton, findsOneWidget);
          final backRect = tester.getRect(backButton);
          expect(backRect.left, lessThanOrEqualTo(16));
          expect(backRect.top, lessThanOrEqualTo(16));
          expect(
            backRect.bottom,
            lessThanOrEqualTo(coverRect.top),
            reason: '返回钮应位于左栏封面上方（顶栏占整行）',
          );

          // 无溢出：关键控件在视口内
          for (final target in <Finder>[transport, tabBarView, seekBar]) {
            final bounds = tester.getRect(target);
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(viewport.width));
            expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
          }
        },
      );
    });

    testWidgets('封面尺寸：高度受限吃满 Expanded 剩余高（800x400）', (tester) async {
      const viewport = Size(800, 400);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          final box = _artworkBox(tester, viewport);
          final size = tester.getSize(box);
          final column = tester.getRect(_leftColumn(tester, viewport));
          final coverRect = tester.getRect(_leftCoverArtwork(tester, viewport));
          final titleRect = tester.getRect(
            find.text('LANDSCAPE SPLIT TARGET'),
          );
          // 高度受限：封面撑满 Expanded（顶边贴左栏内容区顶），标题紧随封面
          expect(
            coverRect.top,
            closeTo(column.top + 12, 0.5),
            reason: '高度受限时封面应吃满 Expanded（顶边贴内容区顶）',
          );
          expect(
            titleRect.top,
            closeTo(coverRect.bottom + 10, 0.5),
            reason: '标题应紧随封面（间距 10）',
          );
          // 且确实由高度约束主导（未触 300 上限、未触宽度预算）
          expect(size.width, closeTo(size.height, 0.5), reason: '正方形');
          expect(size.width, lessThan(300.0), reason: '未触 300 上限');
          expect(size.width, lessThan(column.width - 16),
              reason: '未触宽度预算');
          // 封面落在钳制区间内
          expect(size.width, greaterThanOrEqualTo(120));
          final expected = _expectedArtworkSize(
            column: column,
            fixedBlockHeight: _measuredFixedBlockHeight(tester),
            expanded: false,
          );
          expect(size.width, closeTo(expected, 1.5));
        },
      );
    });

    testWidgets('封面尺寸：宽度受限取可用宽度（600x900，未触 300 上限）', (
      tester,
    ) async {
      const viewport = Size(600, 900);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          final box = _artworkBox(tester, viewport);
          final size = tester.getSize(box);
          final column = tester.getRect(_leftColumn(tester, viewport));
          // 宽度受限：封面边长 = 左栏可用宽（列宽 - 左 padding 16），高度充裕
          expect(size.width, closeTo(column.width - 16, 0.5));
          expect(size.height, closeTo(size.width, 0.5));
          expect(size.width, lessThan(300), reason: '未触 300 上限');
          expect(size.width, greaterThan(120), reason: '未触 120 下限');
        },
      );
    });

    testWidgets('封面尺寸：触顶 300 上限（899x900）', (tester) async {
      const viewport = Size(899, 900);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          final box = _artworkBox(tester, viewport);
          final size = tester.getSize(box);
          expect(size.width, closeTo(300, 0.5));
          expect(size.height, closeTo(300, 0.5));
        },
      );
    });

    testWidgets('矮视口紧凑化：800x360 + 1.3 倍字无溢出、控件可见', (tester) async {
      const viewport = Size(800, 360);
      await _withPlayer(
        tester,
        viewport: viewport,
        textScale: 1.3,
        body: (tester) async {
          expect(tester.takeException(), isNull);
          // 批次37：传输行在左栏封面下方
          final transport = find.byType(MD3ETransportRow);
          expect(transport, findsOneWidget);
          final bounds = tester.getRect(transport);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(viewport.width));
          expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
          final coverRect = tester.getRect(_leftCoverArtwork(tester, viewport));
          expect(bounds.top, greaterThan(coverRect.bottom),
              reason: '1.3 倍字下播控仍在封面下方');
          // 横屏传输键紧凑化（批次38 播控压缩：sideButtonSize/playButtonSize 48）
          expect(
            tester.getSize(find.byType(MD3ETransportRow)).height,
            lessThanOrEqualTo(48),
          );
        },
      );
    });
  });

  group('批次38 横屏分栏（expanded：宽≥900）', () {
    testWidgets('封面尺寸：1000x500 高度受限吃满 Expanded（宽预算内缩 32 仍生效）', (
      tester,
    ) async {
      const viewport = Size(1000, 500);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          final box = _artworkBox(tester, viewport);
          final size = tester.getSize(box);
          final column = tester.getRect(_leftColumn(tester, viewport));
          final coverRect = tester.getRect(_leftCoverArtwork(tester, viewport));
          // 批次38：左栏 flex 4（宽 400），宽度预算 = 400-16-32 = 352，
          // 未触 380 上限；本视口仍由高度预算决定
          final widthBudget = 352.0; // (400-16-32)
          expect(size.width, closeTo(size.height, 0.5), reason: '正方形');
          expect(size.width, lessThanOrEqualTo(widthBudget),
              reason: '宽度预算 = 352，未触 380 上限');
          // 高度受限：封面撑满 Expanded（顶边贴左栏内容区顶）
          expect(coverRect.top, closeTo(column.top + 12, 0.5));
          final titleTop = tester
              .getRect(find.text('LANDSCAPE SPLIT TARGET'))
              .top;
          expect(titleTop, closeTo(coverRect.bottom + 10, 0.5));
          expect(size.width, greaterThanOrEqualTo(120));
          // 右栏 flex 6（批次38 恢复 4/6：内容侧约 60% 屏宽）
          final tabRect = tester.getRect(find.byType(TabBarView));
          expect(tabRect.width, closeTo(viewport.width * 0.6, 1));
        },
      );
    });

    testWidgets('封面尺寸：触顶 380 上限（1100x900，左栏 flex4 宽预算 392>380）', (
      tester,
    ) async {
      const viewport = Size(1100, 900);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          final box = _artworkBox(tester, viewport);
          final size = tester.getSize(box);
          // 批次38：左栏 flex 4（宽 440）→ 宽预算 440-16-32=392，
          // 被 cap 380 钳制触顶（1000 宽时预算仅 352，不再触顶，故本用例
          // 从 1000x900 改为 1100x900 以保留「380 上限生效」的覆盖）
          expect(size.width, closeTo(380, 0.5));
          expect(size.height, closeTo(380, 0.5));
        },
      );
    });

    testWidgets('封面尺寸：触顶 380 上限（1400x900）', (tester) async {
      const viewport = Size(1400, 900);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          final box = _artworkBox(tester, viewport);
          final size = tester.getSize(box);
          expect(size.width, closeTo(380, 0.5));
          expect(size.height, closeTo(380, 0.5));
        },
      );
    });
  });

  group('批次37 isWideLayout 与竖屏零影响', () {
    testWidgets('横屏 isWideLayout=true：无封面 tab，歌词/评论进右栏 tab', (
      tester,
    ) async {
      const viewport = Size(800, 400);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          expect(tester.takeException(), isNull);
          // 底部导航条无封面段（player_tab_layout 的 hasCover: !isWideLayout）
          final strip = find.byType(PlayerTabStrip);
          expect(strip, findsOneWidget);
          expect(
            find.descendant(of: strip, matching: find.byIcon(Icons.album)),
            findsNothing,
          );
          expect(
            find.descendant(
              of: strip,
              matching: find.byIcon(Icons.queue_music),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: strip,
              matching: find.byIcon(Icons.comment_outlined),
            ),
            findsOneWidget,
            reason: '在线歌曲评论 tab 仍在',
          );

          // 封面不在任何 tab 内：左栏封面的祖先链上没有 TabBarView
          // （右栏播放列表里的缩略图属于播放列表 tab，不是封面 tab）。
          final cover = _leftCoverArtwork(tester, viewport);
          expect(
            find.ancestor(of: cover, matching: find.byType(TabBarView)),
            findsNothing,
            reason: '封面常驻左栏，不是 tab 内容',
          );
          expect(
            tester.getRect(cover).center.dx,
            lessThan(viewport.width * 0.5),
          );

          // 右栏 tab 顺序 = [播放列表, 歌词, 评论]：批次 39 起默认即歌词
          // tab（用户口径「右侧栏默认歌词」），无需拖拽——直接断言。
          // 歌词视图带自驱动 Ticker（播放中常驻逐帧），全程禁用
          // pumpAndSettle。
          final tabBarView = find.byType(TabBarView);
          expect(tester.takeException(), isNull);
          final lyrics = find
              .byType(AppleMusicLyricsView)
              .evaluate()
              .length +
              find.byType(LyricsView).evaluate().length;
          expect(lyrics, 1, reason: '歌词 tab 应渲染歌词视图');
          expect(
            tester
                .getRect(
                  find.byType(AppleMusicLyricsView).evaluate().isNotEmpty
                      ? find.byType(AppleMusicLyricsView)
                      : find.byType(LyricsView),
                )
                .center
                .dx,
            greaterThan(viewport.width / 2),
            reason: '歌词 tab 在右栏',
          );

          // 再左滑到评论 tab（在线歌曲有评论 tab）
          await tester.drag(tabBarView, const Offset(-400, 0));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull);
          expect(
            find.descendant(of: tabBarView, matching: find.byType(CommentsView)),
            findsOneWidget,
          );

          // 批次36：横向翻页会让歌词视图收到用户滚动通知，排一个 3s
          // 「恢复自动跟随」Timer（apple_music_lyrics_view / lyrics_view 同款，
          // dispose 时取消）。收尾前把假时钟推过该窗口，避免测试框架在
          // dispose 后报 "A Timer is still pending"。评论请求已由
          // _StubKugouProvider 短路，这里不再有网络定时器。
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(seconds: 1));
          }
        },
      );
    });

    testWidgets('竖屏 400x800：仍走 compact 单列，分栏不生效、封面 tab 在', (
      tester,
    ) async {
      const viewport = Size(400, 800);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          expect(tester.takeException(), isNull);

          // compact：TabBarView 占满全宽（非 60% 分栏）
          final tabBarView = find.byType(TabBarView);
          expect(tabBarView, findsOneWidget);
          final tabRect = tester.getRect(tabBarView);
          expect(tabRect.width, closeTo(viewport.width, 1));
          expect(tabRect.center.dx, closeTo(viewport.width / 2, 1));

          // compact 竖屏含封面 tab：底部导航条有 album 段（既有断言照抄）
          final coverTab = find.descendant(
            of: find.byType(PlayerTabStrip),
            matching: find.byIcon(Icons.album),
          );
          expect(coverTab, findsOneWidget);
          await tester.tap(coverTab);
          await tester.pump(const Duration(milliseconds: 600));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));

          expect(tester.takeException(), isNull);
          // 封面 tab 内容（竖屏路径）：封面图 + 传输控件 + 播放状态提示
          expect(find.byType(PlayerArtworkImage), findsWidgets);
          expect(find.byType(MD3ETransportRow), findsOneWidget);
          expect(find.byType(PlaybackStatusFeedback), findsOneWidget);

          // 无溢出：传输控件在视口内
          final bounds = tester.getRect(find.byType(MD3ETransportRow));
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(viewport.width));
          expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
        },
      );
    });
  });

  group('批次37 两条打开路径终态一致（普通 push vs dragOriginTop settle）', () {
    /// 提取当前播放页关键布局几何（封面盒 rect / 进度条 rect / 传输行 rect）。
    Map<String, Rect> _layoutSnapshot(WidgetTester tester, Size viewport) {
      final coverRect = tester.getRect(_artworkBox(tester, viewport));
      final seekRect = tester.getRect(find.byType(PlayerSeekBar));
      final transportRect = tester.getRect(find.byType(MD3ETransportRow));
      return {
        'cover': coverRect,
        'seek': seekRect,
        'transport': transportRect,
      };
    }

    testWidgets('800x400：点击打开与上滑展开（settle 后）封面/播控逐像素一致', (
      tester,
    ) async {
      const viewport = Size(800, 400);
      late Map<String, Rect> tapLayout;
      await _withPlayer(
        tester,
        viewport: viewport,
        viaRoute: true,
        body: (tester) async {
          expect(tester.takeException(), isNull);
          tapLayout = _layoutSnapshot(tester, viewport);
          // 点击路径 settle 后为裸 child（批次37 终态短路），布局必须就绪
          expect(tapLayout['cover']!.width, greaterThan(120));
        },
      );
      late Map<String, Rect> dragLayout;
      await _withPlayer(
        tester,
        viewport: viewport,
        viaRoute: true,
        dragMode: true,
        body: (tester) async {
          expect(tester.takeException(), isNull);
          dragLayout = _layoutSnapshot(tester, viewport);
        },
      );
      // 逐像素相等：同一横屏视口下，两条路径（tap 模式 settle 后 vs
      // dragOriginTop 模式 settleToFull 后）的封面边长与播控位置完全一致
      expect(dragLayout['cover'], tapLayout['cover'],
          reason: '两条打开路径的封面 rect 应逐像素一致');
      expect(dragLayout['seek'], tapLayout['seek'],
          reason: '两条打开路径的进度条 rect 应逐像素一致');
      expect(dragLayout['transport'], tapLayout['transport'],
          reason: '两条打开路径的传输行 rect 应逐像素一致');
    });

    testWidgets('dragOriginTop settle 后：播控/进度条在封面下方（几何断言）', (
      tester,
    ) async {
      const viewport = Size(800, 400);
      await _withPlayer(
        tester,
        viewport: viewport,
        viaRoute: true,
        dragMode: true,
        body: (tester) async {
          expect(tester.takeException(), isNull);
          final coverRect = tester.getRect(_artworkBox(tester, viewport));
          final seekRect = tester.getRect(find.byType(PlayerSeekBar));
          final transportRect = tester.getRect(find.byType(MD3ETransportRow));
          expect(
            seekRect.top,
            greaterThan(coverRect.bottom),
            reason: '上滑展开 settle 后进度条应位于封面下方',
          );
          expect(
            transportRect.top,
            greaterThan(coverRect.bottom),
            reason: '上滑展开 settle 后传输行应位于封面下方',
          );
          // 播控在左栏
          expect(transportRect.center.dx, lessThan(viewport.width / 2));
        },
      );
    });

    testWidgets('竖屏 400x800 对照：两路径一致且仍走 compact 单列（drag 路径）', (
      tester,
    ) async {
      const viewport = Size(400, 800);
      late Rect tapTransport;
      await _withPlayer(
        tester,
        viewport: viewport,
        viaRoute: true,
        body: (tester) async {
          expect(tester.takeException(), isNull);
          // tap 路径竖屏走 compact：TabBarView 全宽（无分栏）
          final tabRect = tester.getRect(find.byType(TabBarView));
          expect(tabRect.width, closeTo(viewport.width, 1));
          tapTransport = tester.getRect(find.byType(MD3ETransportRow));
        },
      );
      late Rect dragTransport;
      await _withPlayer(
        tester,
        viewport: viewport,
        viaRoute: true,
        dragMode: true,
        body: (tester) async {
          expect(tester.takeException(), isNull);
          final tabRect = tester.getRect(find.byType(TabBarView));
          expect(tabRect.width, closeTo(viewport.width, 1),
              reason: 'drag 路径竖屏同样走 compact 单列');
          dragTransport = tester.getRect(find.byType(MD3ETransportRow));
        },
      );
      // 竖屏两条路径播控行逐像素一致（compact 未受批次37 分栏改造影响）
      expect(dragTransport, tapTransport,
          reason: '竖屏两条打开路径的传输行 rect 应逐像素一致');
    });
  });
}
