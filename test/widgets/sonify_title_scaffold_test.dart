import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';


import 'package:md3music/widgets/common/sonify_title_scaffold.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

/// 构建测试宿主：无系统 inset（测试环境 status bar = 0）、AppTheme 主题。
/// 返回外部 ScrollController 供滚动注入。
(Widget, ScrollController) _host({
  int itemCount = 30,
  required String title,
}) {
  final controller = ScrollController();
  final widget = MaterialApp(
    theme: _testTheme,
    home: SonifyTitleScaffold(
      title: title,
      itemCount: itemCount,
      controller: controller,
      itemBuilder: (context, index) => SizedBox(
        height: 100,
        child: ListTile(title: Text('item $index')),
      ),
    ),
  );
  return (widget, controller);
}

/// 大标题（列表首 item）的透明度值。
double _largeTitleOpacity(WidgetTester tester) {
  final opacity = tester.widget<Opacity>(
    find
        .ancestor(
          of: find.text('发现').first,
          matching: find.byType(Opacity),
        )
        .first,
  );
  return opacity.opacity;
}

/// 大标题 item 总高度（状态栏占位 0 + 顶距 8 + 文本行高 + 底距 8）。
double _titleItemHeight(WidgetTester tester) {
  // 文本实测行高（测试字体下 = fontSize × height）
  final text = tester.getSize(find.text('发现').first).height;
  return 8 + text + 8;
}

void main() {
  group('SonifyTitleScaffold 大标题折叠', () {
    testWidgets('初始态：大标题不透明、无小标题、无栏背景', (tester) async {
      final (widget, _) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();

      expect(_largeTitleOpacity(tester), 1);
      // 小标题（最后一个『发现』文本）目标透明度 0
      final smallAnimated = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.text('发现').last,
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(smallAnimated.opacity, 0);
      // 栏背景目标透明度 0
      final barAnimated = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(BackdropFilter),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(barAnimated.opacity, 0);
    });

    testWidgets('滚动中：大标题按 1 + offset/height × 1.8 溶解，栏背景浮现',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      // 滚动 0.1 × height：alpha = 1 − 1.8 × 0.1 = 0.82
      controller.jumpTo(h * 0.1);
      await tester.pump();
      expect(_largeTitleOpacity(tester), closeTo(0.82, 0.01));

      // 栏背景出现（目标透明度 1）
      final barAnimated = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(BackdropFilter),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(barAnimated.opacity, 1);

      // 完全滚出（≥ height/1.8）后 alpha = 0，小标题浮现。
      // 取 h/1.8 + 2：alpha 已为 0，且首 item 尚未滑出 ListView 缓存区
      //（不取 h 端点：恰好等于 item 高度时 item 会被裁剪出元素树）。
      controller.jumpTo(h / 1.8 + 2);
      await tester.pump();
      expect(_largeTitleOpacity(tester), 0);
      final smallAnimated = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.text('发现').last,
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(smallAnimated.opacity, 1);
    });

    testWidgets('两标题互斥：小标题只在大标题完全没入后出现', (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      // 过渡区中段：大标题半透明，小标题仍隐藏
      controller.jumpTo(h * 0.3);
      await tester.pump();
      expect(_largeTitleOpacity(tester), greaterThan(0));
      final smallDuringTransition = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.text('发现').last,
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(smallDuringTransition.opacity, 0);
    });

    testWidgets('吸附：停在过渡区上半段弹回展开端（180ms EaseOutCubic）',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      controller.jumpTo(h * 0.1); // raw = 0.1 < 0.5 → 吸回 0
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(0, 0.5));
    });

    testWidgets('吸附：停在过渡区下半段收进折叠端', (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      controller.jumpTo(h * 0.9); // raw = 0.9 ≥ 0.5 → 吸到 zone（= h − statusBar 0）
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(h, 0.5));
    });

    testWidgets('回到顶部：大标题恢复、栏背景与小标题隐藏', (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      controller.jumpTo(h * 0.9);
      await tester.pumpAndSettle(); // 吸附到折叠端
      controller.jumpTo(0);
      await tester.pump();
      expect(_largeTitleOpacity(tester), 1);
      final barAnimated = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(BackdropFilter),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(barAnimated.opacity, 0);
    });

    testWidgets('业务 item 索引从 0 映射（大标题不占业务索引）', (tester) async {
      final (widget, _) = _host(title: '发现', itemCount: 3);
      await tester.pumpWidget(widget);
      await tester.pump();
      expect(find.text('item 0'), findsOneWidget);
      expect(find.text('item 2'), findsOneWidget);
      // 总 item = 大标题 + 3 业务 item
      final list = tester.widget<ListView>(find.byType(ListView));
      final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
      expect(delegate.childCount, 4);
    });

    testWidgets('顶栏 trailing 内容渲染在栏体内', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(MaterialApp(
        theme: _testTheme,
        home: SonifyTitleScaffold(
          title: '发现',
          itemCount: 3,
          controller: controller,
          trailing: const Icon(Icons.search),
          itemBuilder: (context, index) =>
              SizedBox(height: 100, child: ListTile(title: Text('item $index'))),
        ),
      ));
      await tester.pump();
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('顶栏 actions 仅折叠后浮现，trailing 常驻不同拍', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(MaterialApp(
        theme: _testTheme,
        home: SonifyTitleScaffold(
          title: '发现',
          itemCount: 3,
          controller: controller,
          trailing: const Icon(Icons.person),
          actions: const [Icon(Icons.mic_none)],
          itemBuilder: (context, index) =>
              SizedBox(height: 100, child: ListTile(title: Text('item $index'))),
        ),
      ));
      await tester.pump();

      // 展开态：actions 目标透明度 0（隐藏），trailing 无透明度门控常驻
      AnimatedOpacity actionsAnimated(WidgetTester tester) =>
          tester.widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.byIcon(Icons.mic_none),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          );
      expect(actionsAnimated(tester).opacity, 0);
      expect(find.byIcon(Icons.person), findsOneWidget);

      // 完全折叠（alpha = 0，小标题浮现）后：actions 目标透明度 1
      final h = _titleItemHeight(tester);
      controller.jumpTo(h / 1.8 + 2);
      await tester.pump();
      expect(actionsAnimated(tester).opacity, 1);
      // trailing 依旧在场（固定头像不随折叠消失）
      expect(find.byIcon(Icons.person), findsOneWidget);
    });
  });
}
