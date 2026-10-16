/// 音乐库搜索栏玻璃胶囊化回归测试（UI 重设计批次 8 补项）。
///
/// 用户反馈「搜索框保持主页一致的胶囊形状」的音乐库闭环：
/// 搜索栏外壳由 squircle 9dp 卡底改为首页同款
/// [LiquidGlassSurface] + [GlassShape.pill]，高度对齐首页 44dp 基准；
/// **交互语义不变**——仍是可输入实时过滤框（TextField 在场、占位文案
/// 与搜索图标保留），不是首页「点击跳搜索页」的不可输入入口。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('有库时搜索栏为玻璃胶囊（首页同款 pill + 44dp），TextField 交互保留',
      (tester) async {
    // 种子缓存歌曲：LibraryMusicPanel.initState 的 postFrame 回调走
    // loadSavedSongs 从 SharedPreferences 恢复 → hasMusic → 搜索栏渲染
    // （空库态搜索栏不显示，与线上同口径）
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
    await tester.pump();
    // loadSavedSongs 为 postFrame + 异步 prefs 读，多推几帧让恢复完成
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 玻璃胶囊材质：LiquidGlassSurface + GlassShape.pill（首页
    // _buildSearchFieldItem 同款外壳）
    final glass = tester.widget<LiquidGlassSurface>(
      find.byType(LiquidGlassSurface),
    );
    expect(glass.shape, GlassShape.pill);
    // 高度对齐首页基准 44dp（SizedBox 固定高，pill 圆角取半高 = 完美胶囊）
    expect(tester.getSize(find.byType(LiquidGlassSurface)).height, 44);

    // 交互语义不变：可输入 TextField + 占位文案 + 20dp 搜索图标在场
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('搜索本地音乐'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
  });
}
