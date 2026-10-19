/// 本地音乐页结构测试（去快捷宫格改版后）。
///
/// 改版契约：原「音乐库入口区」两行三列快捷宫格（我的收藏/歌单/专辑/
/// 歌手/最近播放/扫描状态）整类移除；扫描入口收敛为顶栏扫描钮（进扫描
/// 状态页）+ 面板空态「扫描音乐」按钮；搜索入口为顶栏常驻玻璃圆钮
/// （聚焦面板搜索框，聚焦行为见 library_search_capsule_test.dart）。
/// 5 tab 面板 / 空态 / initialTab 契约保持不变。
library;

// material_ui re-export 了 MaterialApp 等组件；LibraryPage 的 Scaffold/AppBar
// 消费的是 material_ui 的类型体系，其 MaterialLocalizations 仅由 material_ui
// 的 MaterialApp 自动注入（DefaultMaterialLocalizations.delegate）。harness
// 若用 flutter 的 MaterialApp，只提供 flutter 版 MaterialLocalizations（类型
// 不匹配），AppBar 的 debugCheckHasMaterialLocalizations 断言会失败。
// 与 playlist_page_multi_select_baseline_test.dart 同一套组件体系约定。
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/modules/library/scan_status_page.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/common/sonify_title_scaffold.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 顶栏常驻搜索钮 / 扫描钮的定位 key（library_page.dart 内注入，样式
/// 借用 library_hub_page 顶栏玻璃圆钮规格）。
const _kSearchButtonKey = ValueKey('library-local-search');
const _kScanButtonKey = ValueKey('library-scan');

/// 种子本地音乐缓存：LibraryMusicPanel initState 的 postFrame 回调走
/// loadSavedSongs 从 SharedPreferences 恢复 → hasMusic → 面板搜索栏与
/// 5 tab 渲染（与 library_search_capsule_test 同口径注入）。
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

Future<void> _pumpLibraryPage(WidgetTester tester, {int initialTab = 0}) async {
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
      child: MaterialApp(home: LibraryPage(initialTab: initialTab)),
    ),
  );
  // 面板 initState 的缓存/目录恢复 + SongsPage 排序偏好读取均走
  // SharedPreferences mock，两帧内 settle
  await tester.pump();
  await tester.pump();
}

/// 多推几帧让面板 postFrame 的缓存恢复（异步 prefs）走完。
Future<void> _settleMusicRestore(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 让顶栏 actions 区（扫描钮，随栏体 120ms 淡入且未滚动时 IgnorePointer）
/// 可点击：拖动列表使 showBarBackground 置真。
Future<void> _revealTopBarActions(WidgetTester tester) async {
  await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('本地音乐页移除上方快捷宫格，顶栏常驻搜索钮 + 扫描钮，空态保留',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpLibraryPage(tester);

    // 快捷宫格整类移除：原 6 项文案一处都不到
    for (final label in ['我的收藏', '歌单', '专辑', '歌手', '最近播放', '扫描状态']) {
      expect(
        find.text(label),
        findsNothing,
        reason: '快捷宫格已移除：「$label」不应再出现',
      );
    }
    // SonifyTitleScaffold 骨架与固定大标题「本地音乐」保留
    expect(find.byType(SonifyTitleScaffold), findsOneWidget);
    expect(find.text('本地音乐'), findsWidgets);
    // 顶栏常驻搜索玻璃圆钮（trailing；空库下面板无搜索栏，
    // Icons.search 仅此一处）
    expect(find.byKey(_kSearchButtonKey), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
    // 扫描钮（顶栏 actions；页面级 FAB 与面板尾部钮已删，
    // 全页 Icons.add 仅此一处）
    expect(find.byIcon(Icons.add), findsOneWidget);
    // 空态与空态「扫描音乐」按钮保留
    expect(find.text('还没有本地音乐'), findsOneWidget);
    expect(find.text('扫描音乐'), findsOneWidget);
  });

  testWidgets('扫描钮点击进入扫描状态页（替代原 FAB 扫描菜单直调）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpLibraryPage(tester);

    // actions 随栏体淡入，先滚动露出（解除 IgnorePointer）再点
    await _revealTopBarActions(tester);
    await tester.tap(find.byKey(_kScanButtonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ScanStatusPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('注入本地音乐后渲染 5 个分类 tab（曲目/专辑/艺术家/文件夹/收藏）',
      (tester) async {
    _seedLocalMusic();
    await _pumpLibraryPage(tester);
    await _settleMusicRestore(tester);

    // 空态消失、TabBar 在场
    expect(find.text('还没有本地音乐'), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);
    // 5 tab 标题齐备（与原来一致）
    for (final label in ['曲目', '专辑', '艺术家', '文件夹', '收藏']) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: '5 tab 面板应包含「$label」',
      );
    }
    // 顶栏搜索钮常驻；有库时面板搜索栏前缀图标同为 Icons.search
    // → findsWidgets（顶栏钮 + 面板前缀，共两处）
    expect(find.byIcon(Icons.search), findsWidgets);
    // 空态「扫描音乐」按钮随空态一起消失
    expect(find.text('还没有本地音乐'), findsNothing);
  });

  testWidgets('initialTab=3（文件夹）复用本页时预选对应分类', (tester) async {
    _seedLocalMusic();
    await _pumpLibraryPage(tester, initialTab: 3);
    await _settleMusicRestore(tester);

    // initialTab 契约不变：TabController 预选 3（文件夹）
    final controller = tester
        .widget<TabBar>(find.byType(TabBar))
        .controller;
    expect(controller?.index, 3);
    expect(tester.takeException(), isNull);
  });
}
