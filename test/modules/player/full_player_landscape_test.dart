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
Future<void> _withPlayer(
  WidgetTester tester, {
  required Size viewport,
  double textScale = 1.0,
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
            child: const FullPlayer(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
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

/// 左栏封面图：播放页内 PlayerArtworkImage 可能有多份（右栏播放列表缩略图），
/// 取中心 x 位于屏幕左 40%（分栏左栏 flex 4）的那一份。
Finder _leftCoverArtwork(WidgetTester tester, Size viewport) {
  final matches = tester
      .widgetList<PlayerArtworkImage>(find.byType(PlayerArtworkImage))
      .where((w) {
        final rect = tester.getRect(find.byWidget(w));
        return rect.center.dx < viewport.width * 0.4;
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

/// 与实现同源的封面边长公式（_buildSplitArtworkColumn）：
/// medium = min(可用宽, 可用高-72).clamp(120, 300)；
/// expanded = (可用宽-32).clamp(0, 380) 再受可用高度约束（无 120 下限）。
double _expectedArtworkSize(
  Rect column, {
  required bool expanded,
}) {
  const g = 16.0;
  final cap = expanded ? 380.0 : 300.0;
  final minSize = expanded ? 0.0 : 120.0;
  final widthInset = expanded ? 32.0 : 0.0;
  final maxWidth = column.width - g; // 左 padding g，无右 padding
  final availableHeight = column.height - 2 * g - 72; // 标题块预留 72
  var size = (maxWidth - widthInset)
      .clamp(0.0, cap)
      .clamp(0.0, availableHeight.clamp(0.0, double.infinity));
  if (minSize > 0) size = size.clamp(minSize, cap);
  return size;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('批次36 横屏双栏分栏（medium：600≤宽<900）', () {
    testWidgets('800x400：Row 左右分栏，左栏封面+标题，右栏 Tab+控件，返回钮最外层左上', (
      tester,
    ) async {
      const viewport = Size(800, 400);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          expect(tester.takeException(), isNull);

          // ── 右栏（flex 6）：TabBarView + 传输控件 + 底部导航条 ──
          final tabBarView = find.byType(TabBarView);
          expect(tabBarView, findsOneWidget);
          final tabRect = tester.getRect(tabBarView);
          expect(tabRect.center.dx, greaterThan(viewport.width / 2));
          expect(tabRect.width, closeTo(viewport.width * 0.6, 1));
          expect(
            find.descendant(
              of: tabBarView,
              matching: find.byType(PlayerPlaylistView),
            ),
            findsOneWidget,
          );
          final transport = find.byType(MD3ETransportRow);
          expect(transport, findsOneWidget);
          expect(
            tester.getRect(transport).center.dx,
            greaterThan(viewport.width / 2),
          );
          expect(find.byType(PlaybackStatusFeedback), findsOneWidget);

          // ── 左栏（flex 4）：封面 + 标题，均在屏幕左 40% ──
          final cover = _leftCoverArtwork(tester, viewport);
          final coverRect = tester.getRect(cover);
          expect(coverRect.center.dx, lessThan(viewport.width * 0.4));
          final title = find.text('LANDSCAPE SPLIT TARGET');
          expect(title, findsOneWidget);
          // 标题左缘与封面左缘对齐（移植自默认分支 26a043f）
          expect(
            tester.getRect(title).left,
            closeTo(coverRect.left, 0.5),
          );

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
            lessThanOrEqualTo(tester.getRect(cover).top),
            reason: '返回钮应位于左栏封面上方（顶栏占整行）',
          );

          // 无溢出：关键控件在视口内
          for (final target in <Finder>[transport, tabBarView]) {
            final bounds = tester.getRect(target);
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(viewport.width));
            expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
          }
        },
      );
    });

    testWidgets('封面尺寸 clamp：高度受限取可用高度（800x400）', (tester) async {
      const viewport = Size(800, 400);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          final box = _artworkBox(tester, viewport);
          final size = tester.getSize(box);
          final column = tester.getRect(_leftColumn(tester, viewport));
          final expected = _expectedArtworkSize(
            column,
            expanded: false,
          );
          expect(size.width, closeTo(expected, 0.5));
          expect(size.height, closeTo(expected, 0.5), reason: '封面为正方形');
          // 高度受限区间：等于可用高度（colH - 2g - 72 标题预留），
          // 且落在 [120, 300] 钳制区间内
          expect(expected, closeTo(column.height - 104, 0.5));
          expect(size.width, greaterThanOrEqualTo(120));
          expect(size.width, lessThanOrEqualTo(300));
        },
      );
    });

    testWidgets('封面尺寸 clamp：宽度受限取可用宽度（600x900，未触 300 上限）', (
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
          final expected = _expectedArtworkSize(column, expanded: false);
          expect(size.width, closeTo(expected, 0.5));
          expect(size.height, closeTo(expected, 0.5));
          // 宽度受限区间：等于左栏可用宽度（colW-16）
          expect(expected, closeTo(column.width - 16, 0.5));
          expect(size.width, lessThan(300), reason: '未触 300 上限');
          expect(size.width, greaterThan(120), reason: '未触 120 下限');
        },
      );
    });

    testWidgets('封面尺寸 clamp：触顶 300 上限（899x900）', (tester) async {
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
          final transport = find.byType(MD3ETransportRow);
          expect(transport, findsOneWidget);
          final bounds = tester.getRect(transport);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(viewport.width));
          expect(bounds.bottom, lessThanOrEqualTo(viewport.height));
          // 横屏传输键紧凑化（sideButtonSize/playButtonSize 56）保留
          expect(
            tester.getSize(find.byType(MD3ETransportRow)).height,
            lessThanOrEqualTo(56),
          );
        },
      );
    });
  });

  group('批次36 横屏双栏分栏（expanded：宽≥900）', () {
    testWidgets('封面尺寸 clamp：1000x500 高度先触顶（宽预算内缩 32 仍生效）', (
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
          final expected = _expectedArtworkSize(column, expanded: true);
          expect(size.width, closeTo(expected, 0.5));
          expect(size.height, closeTo(expected, 0.5));
          // 批次36 修正：两条预算同时参与，500 高时 height 预算（colH-104）先触顶，
          // width 预算（colW-48 = 左栏宽 - 内边距 16 - 内缩 32）并非本次约束。
          final widthBudget = column.width - 48;
          final heightBudget = column.height - 104;
          expect(widthBudget, greaterThan(heightBudget), reason: '本视口由高度决定');
          expect(size.width, closeTo(heightBudget, 0.5));
          expect(size.width, lessThan(widthBudget), reason: '宽度预算未被触顶');
          // 与 medium 的差异：宽度先内缩 32 再钳制，上限 380（宽度侧不越界）
          expect(widthBudget, lessThanOrEqualTo(380));
          // 仍为 4/6 分栏
          final tabRect = tester.getRect(find.byType(TabBarView));
          expect(tabRect.width, closeTo(viewport.width * 0.6, 1));
        },
      );
    });

    testWidgets('封面尺寸 clamp：宽受限取宽度预算（1000x900，内缩 32、未触 380）', (
      tester,
    ) async {
      const viewport = Size(1000, 900);
      await _withPlayer(
        tester,
        viewport: viewport,
        body: (tester) async {
          final box = _artworkBox(tester, viewport);
          final size = tester.getSize(box);
          final column = tester.getRect(_leftColumn(tester, viewport));
          final expected = _expectedArtworkSize(column, expanded: true);
          expect(size.width, closeTo(expected, 0.5));
          expect(size.height, closeTo(expected, 0.5));
          // 足够高：宽度预算（内缩 32）成为唯一约束
          expect(expected, closeTo(column.width - 48, 0.5));
          expect(size.width, lessThan(380), reason: '未触 380 上限');
          expect(size.width, greaterThan(120));
        },
      );
    });

    testWidgets('封面尺寸 clamp：触顶 380 上限（1400x900）', (tester) async {
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

  group('批次36 isWideLayout 与竖屏零影响', () {
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
            lessThan(viewport.width * 0.4),
          );

          // 右栏 tab 顺序 = [播放列表, 歌词, 评论]：左滑到歌词 tab。
          // 歌词 tab 的 AM 扫色视图带 Ticker 自驱动内插（播放中常驻逐帧），
          // 不能用 pumpAndSettle（会超时），用 pump 序列推进翻页动画即可。
          final tabBarView = find.byType(TabBarView);
          await tester.drag(tabBarView, const Offset(-400, 0));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 600));
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
}
