/// 主页管理（Tab 管理 UI）枚举测试（v6：音乐库 9 项子页面全量化）。
///
/// 校验「主页管理」列表枚举 v6 新增的 7 个音乐库子页面可选 Tab，
/// 且默认隐藏（副标题「未显示」）——用户可在主页管理决策去留。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/settings/home_tab_manager.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('主页管理列表枚举音乐库子页面可选 Tab 且默认隐藏', (tester) async {
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

    // v6 新增 7 个音乐库子页面 Tab 均可在主页管理枚举
    for (final label in ['歌单', '专辑', '歌手', '最近播放', '文件夹', '扫描状态', '本地收藏']) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: '主页管理应枚举「$label」可选 Tab',
      );
    }
    // 可选 Tab 默认隐藏（副标题「未显示」）
    expect(
      find.text('未显示'),
      findsWidgets,
      reason: '可选 Tab 默认隐藏',
    );
    // 「我的」必显示不可隐藏
    expect(find.text('必显示'), findsOneWidget);
  });
}
