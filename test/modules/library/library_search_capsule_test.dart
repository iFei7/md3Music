/// 音乐库搜索栏玻璃胶囊化回归测试（UI 重设计批次 8 补项）+ 顶栏搜索钮聚焦。
///
/// 用户反馈「搜索框保持主页一致的胶囊形状」的音乐库闭环：
/// 搜索栏外壳由 squircle 9dp 卡底改为首页同款
/// [LiquidGlassSurface] + [GlassShape.pill]，高度对齐首页 44dp 基准；
/// **交互语义不变**——仍是可输入实时过滤框（TextField 在场、占位文案
/// 与搜索图标保留），不是首页「点击跳搜索页」的不可输入入口。
///
/// 去快捷宫格改版后新增：顶栏常驻搜索玻璃圆钮（trailing）只负责**聚焦**
/// 面板搜索框（FocusNode 传递链：LibraryPage._localSearchFocusNode →
/// LibraryMusicPanel.searchFocusNode → TextField.focusNode），不改面板
/// 本身的形态与交互；空库时搜索框未渲染，点顶栏钮给 SnackBar 提示。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/common/liquid_glass_surface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 顶栏常驻搜索钮定位 key（library_page.dart 内注入）。
const _kSearchButtonKey = ValueKey('library-local-search');

/// 种子本地音乐缓存：LibraryMusicPanel.initState 的 postFrame 回调走
/// loadSavedSongs 从 SharedPreferences 恢复 → hasMusic → 搜索栏渲染
/// （空库态搜索栏不显示，与线上同口径）。
void _seedLocalMusic() {
  SharedPreferences.setMockInitialValues({
    'local_music_cached_songs': jsonEncode([
      {
        'id': 'local-1',
        'title': '本地歌曲甲',
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

  testWidgets('有库时搜索栏为玻璃胶囊（首页同款 pill + 44dp），TextField 交互保留',
      (tester) async {
    _seedLocalMusic();
    await _pumpLibraryPage(tester);
    await _settleMusicRestore(tester);

    // 玻璃胶囊材质：LiquidGlassSurface + GlassShape.pill（首页
    // _buildSearchFieldItem 同款外壳）。此时场内共有两个
    // LiquidGlassSurface：面板搜索胶囊（.first）与顶栏常驻搜索玻璃
    // 圆钮（.last，42dp 圆形）——顶栏钮只聚焦、不改面板形态。
    final glass = tester.widget<LiquidGlassSurface>(
      find.byType(LiquidGlassSurface).first,
    );
    expect(glass.shape, GlassShape.pill);
    // 高度对齐首页基准 44dp（SizedBox 固定高，pill 圆角取半高 = 完美胶囊）
    expect(tester.getSize(find.byType(LiquidGlassSurface).first).height, 44);
    // 顶栏搜索钮为 42dp 玻璃圆钮（借用 hub 页规格）
    final topBarGlass = tester.widget<LiquidGlassSurface>(
      find.byType(LiquidGlassSurface).last,
    );
    expect(topBarGlass.shape, GlassShape.circle);
    expect(tester.getSize(find.byType(LiquidGlassSurface).last).height, 42);

    // 交互语义不变：可输入 TextField + 占位文案 + 20dp 搜索图标在场
    // （面板前缀图标；顶栏常驻搜索钮同用 Icons.search → findsWidgets）
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('搜索本地音乐'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsWidgets);
  });

  testWidgets('顶栏常驻搜索钮聚焦面板搜索框（FocusNode 传递链）', (tester) async {
    _seedLocalMusic();
    await _pumpLibraryPage(tester);
    // 首帧 + 面板 postFrame（先 unfocus 再做缓存恢复）
    await tester.pump();
    await _settleMusicRestore(tester);

    // 宿主（LibraryPage）创建的 FocusNode 经 searchFocusNode 参数 attach
    // 到了面板的搜索 TextField 上
    final textField = tester.widget<TextField>(find.byType(TextField));
    final focusNode = textField.focusNode;
    expect(focusNode, isNotNull);
    // 未点顶栏钮前不聚焦（面板 postFrame 主动 unfocus 过）
    expect(focusNode!.hasFocus, isFalse);

    // 点顶栏搜索钮（trailing 常驻，无需滚动即可点）
    await tester.tap(find.byKey(_kSearchButtonKey));
    await tester.pump();

    // 聚焦生效：面板搜索 TextField 获得焦点
    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('空库时点顶栏搜索钮给 SnackBar 提示（搜索框未渲染，不静默）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpLibraryPage(tester);
    await tester.pump();
    await tester.pump();

    // 空库：面板不渲染搜索栏（与线上同口径）
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byKey(_kSearchButtonKey));
    await tester.pump();

    // 不做静默 no-op：一次性 SnackBar 引导去空态「扫描音乐」按钮
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('还没有本地音乐，先扫描音乐吧'), findsOneWidget);
  });
}
