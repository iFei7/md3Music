/// Dock 导航「本地音乐」（音乐库）一级项测试：
///
/// 默认 Tab 配置（v5：主页/收藏/本地音乐/我的）下，玻璃 Dock 展开态
/// 应渲染 library 导航项（library_music 图标 + 「本地音乐」语义标签），
/// 点击触发 onSelectTab('library')；选中态呈现 filled 图标
/// （与其他 Dock 项同一选中样式，见 _DockNavItem）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/glass_dock_player.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpDock(
  WidgetTester tester, {
  required String selectedTabId,
  required ValueChanged<String> onSelectTab,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
        ChangeNotifierProvider<TabConfigProvider>(
          create: (_) => TabConfigProvider(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: GlassDockPlayer(
              selectedTabId: selectedTabId,
              onSelectTab: onSelectTab,
              navExpanded: ValueNotifier<bool>(true),
              onNavExpandedChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  // TabConfigProvider 异步加载（SharedPreferences mock）settle
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('默认配置下 Dock 展开态含「音乐库」导航项，点击可切换', (tester) async {
    String? selected;
    await _pumpDock(
      tester,
      selectedTabId: 'discover',
      onSelectTab: (id) => selected = id,
    );

    // 音乐库导航项存在：outlined 图标 + 语义标签
    // （音乐库改版：library 标签由「本地音乐」升级为「音乐库」）
    expect(find.byIcon(Icons.library_music_outlined), findsOneWidget,
        reason: '默认 Tab 配置下 Dock 应渲染 library 导航项');
    expect(find.bySemanticsLabel('音乐库'), findsOneWidget,
        reason: 'library 导航项应带「音乐库」无障碍标签');

    // 点击导航项 → 回调携带 library tab id（可切换）
    await tester.tap(find.byIcon(Icons.library_music_outlined));
    // AppHaptics.tick（_DockNavItem 点击反馈）fire-and-forget 注册 300ms
    // 超时 Timer，必须推进 fake 时间到期，否则测试结束时 pending timer 断言失败
    await tester.pump(const Duration(milliseconds: 300));
    expect(selected, 'library', reason: '点击「音乐库」应回调 onSelectTab(library)');
  });

  testWidgets('选中 library 时导航项呈现选中态（filled 图标）', (tester) async {
    await _pumpDock(
      tester,
      selectedTabId: 'library',
      onSelectTab: (_) {},
    );

    expect(find.byIcon(Icons.library_music), findsOneWidget,
        reason: '选中态应显示 filled 图标');
    expect(find.byIcon(Icons.library_music_outlined), findsNothing,
        reason: '选中态不应再显示 outlined 图标');
  });

  testWidgets('v6：开启「最近播放」可选 Tab 后 Dock 渲染对应导航项，点击可切换', (tester) async {
    // 音乐库子页面（v6）注册为可选 Tab：默认隐藏不进 Dock；经主页管理
    // 手动开启后，Dock 导航项跟随 TabConfigProvider.visibleTabs 实时渲染。
    SharedPreferences.setMockInitialValues({});
    final tabConfig = TabConfigProvider();
    String? selected;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
          ChangeNotifierProvider<TabConfigProvider>.value(value: tabConfig),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: GlassDockPlayer(
                selectedTabId: 'discover',
                onSelectTab: (id) => selected = id,
                navExpanded: ValueNotifier<bool>(true),
                onNavExpandedChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 默认配置下不渲染（可选 Tab 默认隐藏）
    expect(find.byIcon(Icons.history_outlined), findsNothing,
        reason: '可选 Tab 默认隐藏，Dock 不应渲染');
    expect(find.bySemanticsLabel('最近播放'), findsNothing);

    // 主页管理开启后 Dock 实时渲染
    await tabConfig.toggleTabVisibility('recent');
    await tester.pump();

    expect(find.byIcon(Icons.history_outlined), findsOneWidget,
        reason: '开启后 Dock 应渲染「最近播放」导航项');
    expect(find.bySemanticsLabel('最近播放'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.history_outlined));
    // AppHaptics.tick（_DockNavItem 点击反馈）fire-and-forget 注册 300ms
    // 超时 Timer，必须推进 fake 时间到期，否则测试结束时 pending timer 断言失败
    await tester.pump(const Duration(milliseconds: 300));
    expect(selected, 'recent', reason: '点击「最近播放」应回调 onSelectTab(recent)');
  });
}
