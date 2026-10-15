/// 扫描状态页基础测试（v6 音乐库 9 项子页面之一）。
///
/// 最小实现校验：头部走 SonifyTitleScaffold 渲染「扫描状态」标题；
/// 空闲态展示统计/操作/扫描目录/排除目录各区块；不触发真实扫描
/// （不点「扫描音乐」，避免 requestStoragePermission 平台通道）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/library/scan_status_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('扫描状态页渲染标题与空闲态各区块', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => LibraryProvider(),
        child: const MaterialApp(home: ScanStatusPage()),
      ),
    );
    // initState 的 postFrameCallback 走 SharedPreferences mock 恢复缓存
    await tester.pump();
    await tester.pump();

    // 大标题（折叠骨架，与首页同构）
    expect(find.text('扫描状态'), findsWidgets);
    // 空闲态状态卡
    expect(find.text('扫描空闲'), findsOneWidget);
    // 操作行：扫描音乐 / 扫描选项（复用面板既有链路）
    expect(find.text('扫描音乐'), findsOneWidget);
    expect(find.text('扫描选项'), findsOneWidget);
    // 统计卡四类计数标签
    for (final label in ['歌曲', '专辑', '艺术家', '文件夹']) {
      expect(find.text(label), findsWidgets, reason: '统计卡应包含「$label」');
    }
    // 目录分区标题与空态提示
    expect(find.text('扫描目录'), findsOneWidget);
    expect(find.text('排除目录'), findsOneWidget);
    expect(
      find.text('尚未配置扫描目录，点击「扫描音乐」按默认目录扫描'),
      findsOneWidget,
    );
  });

  testWidgets('扫描状态页底部提供目录管理入口（复用 provider 增删 API）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => LibraryProvider(),
        child: const MaterialApp(home: ScanStatusPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('添加扫描目录'), findsOneWidget);
    expect(find.text('添加排除目录'), findsOneWidget);
  });
}
