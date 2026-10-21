/// 本地音乐页顶栏契约测试（用户反馈：「上滑看不到搜索框后顶栏
/// 显示圆形搜索按钮，常驻显示扫描按钮」）。
///
/// 改版契约（本页外层 SonifyTitleScaffold 为单固定高 item、本身不可
/// 滚动，actions 的既有 offset>0 淡入条件永不满足）：
/// - **扫描钮常驻** trailing：无需滚动即可点（进扫描状态页）；
/// - **搜索圆钮常驻** trailing（批次 23；此前随面板内列表滚动浮现，
///   真机上按钮与不滚动的顶栏背景脱节、入口不可靠）：配方为公共组件
///   [GlassCircleButton]（42dp 圆形液态玻璃 + 20dp 图标，与主页/
///   听书/搜索页顶栏同款），点击聚焦面板内本地音乐搜索框。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/modules/library/scan_status_page.dart';
import 'package:md3music/widgets/common/glass_circle_button.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 顶栏搜索圆钮 / 扫描钮的定位 key（library_page.dart 内注入）。
const _kSearchButtonKey = ValueKey('library-local-search');
const _kScanButtonKey = ValueKey('library-scan');

/// 种子 N 首本地歌曲：供内层曲目列表/搜索框 FocusNode 链渲染。
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
    MultiProvider(
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
  );
}

/// loadSavedSongs 为 postFrame + 异步 prefs 读，多推几帧让恢复完成。
Future<void> _settleMusicRestore(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('搜索圆钮常驻（GlassCircleButton），扫描钮常驻可点',
      (tester) async {
    _seedLocalMusic(30);
    await _pumpLibraryPage(tester);
    await _settleMusicRestore(tester);

    // 搜索钮常驻：不做任何滚动即在树中、未被 AnimatedOpacity 隐藏
    expect(find.byKey(_kSearchButtonKey), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(_kSearchButtonKey),
        matching: find.byType(AnimatedOpacity),
      ),
      findsNothing,
      reason: '批次 23 起搜索圆钮不随滚动淡入，常驻可见',
    );
    // 样式=公共圆钮组件（42dp 圆形液态玻璃，与主页/听书/搜索页同款）
    expect(
      tester.widget<GlassCircleButton>(find.byKey(_kSearchButtonKey)),
      isA<GlassCircleButton>(),
      reason: '搜索圆钮应为 GlassCircleButton 公共组件',
    );

    // 扫描钮常驻 trailing：不做任何滚动直接可点 → 进扫描状态页
    await tester.tap(find.byKey(_kScanButtonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ScanStatusPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索圆钮点击聚焦面板内本地音乐搜索框（无需先滚动列表）',
      (tester) async {
    _seedLocalMusic(30);
    await _pumpLibraryPage(tester);
    await _settleMusicRestore(tester);

    // 直接点击（此前必须先把内层列表滚起来钮才浮现）
    await tester.tap(find.byKey(_kSearchButtonKey));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: '常驻搜索钮点击聚焦面板内本地音乐搜索框',
    );
  });

  testWidgets('滚动内层列表不再影响搜索圆钮可见性', (tester) async {
    _seedLocalMusic(30);
    await _pumpLibraryPage(tester);
    await _settleMusicRestore(tester);

    // 上滑内层歌曲列表：钮始终在场（批次 21 的 actionsVisible 链已拆除）
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(_kSearchButtonKey), findsOneWidget);

    // 回顶：钮依然在场
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(_kSearchButtonKey), findsOneWidget);
  });

  testWidgets('空库：搜索圆钮仍常驻，点后走无本地音乐提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpLibraryPage(tester);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(_kSearchButtonKey), findsOneWidget);
    expect(find.text('还没有本地音乐'), findsOneWidget);

    await tester.tap(find.byKey(_kSearchButtonKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
