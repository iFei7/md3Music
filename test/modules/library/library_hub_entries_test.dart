/// 本地音乐页音乐库入口区测试（v6：设计稿 9 项子页面全量化）。
///
/// 校验入口区渲染设计稿中跨云/本地的 6 个导航项，且与既有面板
/// （空态/分类 TabBar）共存不冲突；initialTab 预选供「文件夹」
/// 「本地收藏」可选 Tab 复用本页（不造重复页）。
library;

// material_ui re-export 了 MaterialApp 等组件；LibraryPage 的 Scaffold/AppBar
// 消费的是 material_ui 的类型体系，其 MaterialLocalizations 仅由 material_ui
// 的 MaterialApp 自动注入（DefaultMaterialLocalizations.delegate）。harness
// 若用 flutter 的 MaterialApp，只提供 flutter 版 MaterialLocalizations（类型
// 不匹配），AppBar 的 debugCheckHasMaterialLocalizations 断言会失败。
// 与 playlist_page_multi_select_baseline_test.dart 同一套组件体系约定。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('本地音乐页渲染音乐库入口区（我的收藏/歌单/专辑/歌手/最近播放/扫描状态）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => LibraryProvider()),
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: const MaterialApp(home: LibraryPage()),
      ),
    );
    // 面板 initState 的缓存/目录恢复 + SongsPage 排序偏好读取均走
    // SharedPreferences mock，两帧内 settle
    await tester.pump();
    await tester.pump();

    // 入口区 6 项（空库下「专辑」仅入口区一处；有库时与面板 TabBar 并存）
    for (final label in ['我的收藏', '歌单', '专辑', '歌手', '最近播放', '扫描状态']) {
      expect(
        find.text(label),
        findsWidgets,
        reason: '音乐库入口区应包含「$label」',
      );
    }
    // 入口区与既有面板共存：空库态提示照常渲染（页面结构未破坏）
    expect(find.text('还没有本地音乐'), findsOneWidget);
  });

  testWidgets('本地音乐页 initialTab 预选对应分类（文件夹/本地收藏复用本页）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => LibraryProvider()),
          ChangeNotifierProvider(create: (_) => PlayerProvider()),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        ],
        child: const MaterialApp(home: LibraryPage(initialTab: 3)),
      ),
    );
    await tester.pump();
    await tester.pump();

    // initialTab=3（文件夹）：空库时空态提示渲染，页面不报错
    expect(find.text('还没有本地音乐'), findsOneWidget);
    // 入口区仍渲染（与面板分类预选解耦）
    expect(find.text('扫描状态'), findsWidgets);
  });
}
