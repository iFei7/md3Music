/// 主页管理（Tab 管理 UI）枚举测试（v7：默认 tab = 首页/音乐库/FM/搜索）。
///
/// 校验「主页管理」列表枚举 v7 全部 10 个可用 Tab；默认 4 项显示
/// （副标题「显示在底部导航栏」），6 个可选 Tab 默认隐藏（副标题
/// 「未显示」）；v7 起没有不可隐藏项，「必显示」与「我的」不再出现。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:md3music/modules/settings/home_tab_manager.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('主页管理列表枚举 v7 全部 10 个 Tab，默认 4 项显示、6 项隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TabConfigProvider(),
        child: const MaterialApp(
          home: Scaffold(
            // embedded 形态：与设置页一致，内嵌于可滚动父级
            body: SingleChildScrollView(
              child: HomeTabManagerList(embedded: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // v7 全部 10 个可用 Tab 均可在主页管理枚举
    for (final label in ['首页', '音乐库', 'FM', '搜索', '收藏', '听歌识曲', '听书', '设置', '最近播放', '扫描状态']) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: '主页管理应枚举「$label」Tab',
      );
    }
    // 默认 4 项显示在底部导航栏
    expect(
      find.text('显示在底部导航栏'),
      findsNWidgets(4),
      reason: '默认 Tab（首页/音乐库/FM/搜索）应显示',
    );
    // 6 个可选 Tab 默认隐藏（副标题「未显示」）
    expect(
      find.text('未显示'),
      findsNWidgets(6),
      reason: '可选 Tab（收藏/听歌识曲/听书/设置/最近播放/扫描状态）默认隐藏',
    );
    // v7 起没有不可隐藏项
    expect(
      find.text('必显示'),
      findsNothing,
      reason: 'v7 起所有 Tab 均可隐藏，「必显示」不应出现',
    );
    // 已下线的「我的」不应出现
    expect(
      find.text('我的'),
      findsNothing,
      reason: '「我的」tab 已下线，不应出现在主页管理',
    );
  });

  testWidgets('主页管理开关：开启收藏后副标题切换为「显示在底部导航栏」', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => TabConfigProvider(),
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HomeTabManagerList(embedded: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 收藏默认隐藏
    expect(find.text('未显示'), findsNWidgets(6));
    expect(find.text('显示在底部导航栏'), findsNWidgets(4));

    // 打开收藏的 Switch（第 5 行，索引 4）
    // 注意：主页管理列表用的是 material_ui 的 Switch（非 flutter/material），
    // 需按 mui.Switch 类型查找。
    final switches = find.byType(mui.Switch);
    expect(switches, findsNWidgets(10), reason: 'v7 起所有 Tab 均可移除，均应带开关');
    await tester.ensureVisible(switches.at(4));
    await tester.pump();
    await tester.tap(switches.at(4));
    await tester.pump();
    await tester.pump();

    // 收藏变为显示，未显示减少为 5
    expect(find.text('未显示'), findsNWidgets(5));
    expect(find.text('显示在底部导航栏'), findsNWidgets(5));
  });
}
