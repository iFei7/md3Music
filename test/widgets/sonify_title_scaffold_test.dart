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
      // 总 item = 大标题 + 3 业务 item（主列表为 CustomScrollView +
      // 单 SliverToBoxAdapter 包裹的整列，列内 children 数即 item 数）
      final columns = tester.widgetList<Column>(find.byType(Column));
      final mainColumn = columns.firstWhere(
        (c) => c.children.length == 4,
        orElse: () => throw StateError('未找到含 4 个 item 的主列表 Column'),
      );
      expect(mainColumn.children.length, 4);
    });

    testWidgets('内容不足一屏时仍可上滑折叠大标题（minHeight 兜底）',
        (tester) async {
      // 2 个 100dp item：内容 252dp << 600dp 视口——历史上这种短内容态
      // maxScrollExtent == 0，上滑零位移（首页冷启动的真实反馈）。
      final (widget, controller) = _host(title: '发现', itemCount: 2);
      await tester.pumpWidget(widget);
      await tester.pump();

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();

      // 折叠区高度（zone = 首item高 − 状态栏0）内滚动必然产生位移
      expect(controller.offset, greaterThan(0));
      // 拖到折叠端：大标题完全没入、小标题浮现
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

    testWidgets('渐变模糊带自屏幕最顶开始（覆盖状态栏 + 栏体）', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(top: 24)),
          child: MaterialApp(
            theme: _testTheme,
            home: SonifyTitleScaffold(
              title: '发现',
              itemCount: 3,
              controller: controller,
              itemBuilder: (context, index) => SizedBox(
                height: 100,
                child: ListTile(title: Text('item $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final h = _titleItemHeight(tester);

      controller.jumpTo(h * 0.1);
      await tester.pump();

      // 带体（ShaderMask 所在层）高度 = 状态栏 24 + 栏体 54 = 78：
      // 曾只覆盖 54dp 栏体，状态栏区域透明导致内容从状态栏透出。
      final bandSize = tester.getSize(find.byType(ShaderMask));
      expect(bandSize.height, 24 + SonifySpacing.topBar);
      expect(
        find.ancestor(
          of: find.byType(BackdropFilter),
          matching: find.byType(ShaderMask),
        ),
        findsWidgets,
      );
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

    testWidgets('大标题规格：20sp Bold、行高 36dp（与 36dp 头像等高）',
        (tester) async {
      final (widget, _) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();

      final largeText = tester.widget<Text>(find.text('发现').first);
      expect(largeText.style?.fontSize, 20);
      expect(largeText.style?.fontWeight, FontWeight.w700);
      // 测试字体下行高 = fontSize × height = 20 × 1.8 = 36dp
      expect(tester.getSize(find.text('发现').first).height, 36);
    });

    testWidgets('上滑后顶栏渐变模糊带出现（ShaderMask 渐变包裹 BackdropFilter）',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      // 栏背景 AnimatedOpacity 门控（渐变模糊带整体挂在它下面）
      AnimatedOpacity barAnimated(WidgetTester tester) =>
          tester.widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.byType(BackdropFilter),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          );

      // 初始态：栏背景目标透明度 0（渐变带不可见）
      expect(barAnimated(tester).opacity, 0);

      // 上滑任意距离：栏背景激活 → 渐变模糊带在场
      controller.jumpTo(h * 0.1);
      await tester.pump();

      final shaderMask = tester.widget<ShaderMask>(find.byType(ShaderMask));
      // dstIn 混合：渐变 alpha 自上而下衰减整层（模糊 + 叠色）
      expect(shaderMask.blendMode, BlendMode.dstIn);
      // 渐变回调产出竖向（上→下）线性渐变着色器
      final shader = shaderMask.shaderCallback(
        const Rect.fromLTWH(0, 0, 100, 54),
      );
      expect(shader, isNotNull);

      // 磨砂层（blur 14dp BackdropFilter）位于 ShaderMask 之内、栏背景
      // 透明度门控之下（目标值 1）
      expect(barAnimated(tester).opacity, 1);
      expect(
        find.ancestor(
          of: find.byType(BackdropFilter),
          matching: find.byType(ShaderMask),
        ),
        findsWidgets,
      );
    });
  });
}
