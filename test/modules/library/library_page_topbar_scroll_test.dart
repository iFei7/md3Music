/// 本地音乐页顶栏语义修正测试（用户反馈：「上滑看不到搜索框后顶栏
/// 显示圆形搜索按钮，常驻显示扫描按钮」）。
///
/// 改版契约（本页外层 SonifyTitleScaffold 为单固定高 item、本身不可
/// 滚动，actions 的既有 offset>0 淡入条件永不满足）：
/// - **扫描钮常驻** trailing：无需滚动即可点（进扫描状态页）；
/// - **搜索圆钮随内层歌曲列表滚动浮现**（用户口径「参考搜索页」）：
///   面板内列表滚动信号经 [LibraryMusicPanel.listScrolled] 上传，
///   驱动 SonifyTitleScaffold 的 actionsVisible；列表在顶部/空库
///   （无列表可滚）时搜索钮不浮现。
/// - **顶栏渐变模糊带同拍浮现**（批次 24）：同一信号另注入
///   barBackgroundVisible——外侧骨架不滚，不接外部信号时栏体
///   背景永不浮现（与首页不一致）。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/modules/library/scan_status_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 顶栏搜索圆钮 / 扫描钮的定位 key（library_page.dart 内注入）。
const _kSearchButtonKey = ValueKey('library-local-search');
const _kScanButtonKey = ValueKey('library-scan');

/// 种子 N 首本地歌曲：内层曲目 ListView 需要足够内容才可滚动
/// （搜索钮浮现的内层滚动信号来源）。
void _seedLocalMusic(int count) {
  SharedPreferences.setMockInitialValues({
    'local_music_cached_songs': jsonEncode([
      for (var i = 0; i < count; i++)
        {
          'id': 'local-$i',
          'title': '本地歌曲甲$i',
          'artist': '本地歌手',
          'album': '本地专辑',
          'duration': 180000,
        },
    ]),
  });
}

Future<void> _pumpLibraryPage(WidgetTester tester) async {
  await tester.pumpWidget(
    // 批次 35：钉死竖屏——flutter test 默认窗口 800×600 即横屏，横屏
    // 下顶栏随滚动整体上滑隐藏（新特性，见
    // test/widgets/sonify_title_scaffold_landscape_test.dart）；本文件
    // 断言竖屏「搜索圆钮随内层列表滚动浮现 / 点击聚焦」既有路径，
    // 故注入竖屏 MediaQuery（400×800）。
    MediaQuery(
      data: const MediaQueryData(size: Size(400, 800)),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => LibraryProvider()),
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(
            create: (_) => FavoritesProvider(syncOnStart: false),
          ),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: const MaterialApp(home: LibraryPage()),
      ),
    ),
  );
}

/// loadSavedSongs 为 postFrame + 异步 prefs 读，多推几帧让恢复完成。
Future<void> _settleMusicRestore(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 搜索圆钮（actions 区）AnimatedOpacity 的目标透明度：0 = 未浮现，
/// 1 = 浮现（120ms 淡入的目标值，重建后即更新，无需等动画结束）。
double _searchButtonOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byKey(_kSearchButtonKey),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

/// 顶栏渐变模糊带的 AnimatedOpacity 目标透明度：0 = 未浮现，1 = 浮现
/// （批次 24：barBackgroundVisible 外部信号驱动，重建后即更新目标值）。
double _barBackgroundOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byType(BackdropFilter),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('初始态：搜索圆钮不浮现（列表在顶部），扫描钮常驻可点',
      (tester) async {
    _seedLocalMusic(30);
    await _pumpLibraryPage(tester);
    await _settleMusicRestore(tester);

    // 搜索钮在 actions 区、初始隐藏（_listScrolled=false）
    expect(find.byKey(_kSearchButtonKey), findsOneWidget);
    expect(_searchButtonOpacity(tester), 0);

    // 扫描钮常驻 trailing：不做任何滚动直接可点 → 进扫描状态页
    await tester.tap(find.byKey(_kScanButtonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ScanStatusPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('上滑内层歌曲列表：搜索圆钮浮现；回顶消失', (tester) async {
    _seedLocalMusic(30);
    await _pumpLibraryPage(tester);
    await _settleMusicRestore(tester);

    expect(_searchButtonOpacity(tester), 0);

    // 内层曲目 ListView（TabBarView 页面内）上滑：滚动通知经面板
    // NotificationListener 上传 → actionsVisible → 搜索钮浮现
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_searchButtonOpacity(tester), 1);

    // 浮现后即可点击（IgnorePointer 随 notifier 解除）
    await tester.tap(find.byKey(_kSearchButtonKey));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: '浮现后的搜索钮点击聚焦面板内本地音乐搜索框',
    );

    // 批次 24：栏体渐变带随同一信号浮现（外侧骨架不滚动，外部信号
    // 驱动），与搜索页坍缩态形态一致
    expect(_barBackgroundOpacity(tester), 1,
        reason: '内层列表滚离顶部后顶栏渐变带应浮现');

    // 回顶（pixels <= 0）→ 搜索钮收起
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_searchButtonOpacity(tester), 0);
    expect(_barBackgroundOpacity(tester), 0,
        reason: '回顶后渐变带应收敛消失');
  });

  testWidgets('空库：无列表可滚，搜索圆钮保持不浮现', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpLibraryPage(tester);
    await tester.pump();
    await tester.pump();

    // 空库渲染空态（非 TabBarView）：没有任何可滚列表，滚动信号
    // 无从产生 → _listScrolled 保持 false → 搜索钮不浮现
    expect(find.byKey(_kSearchButtonKey), findsOneWidget);
    expect(_searchButtonOpacity(tester), 0);
    expect(find.text('还没有本地音乐'), findsOneWidget);
  });
}
