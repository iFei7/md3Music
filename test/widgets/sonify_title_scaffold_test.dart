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

/// 固定悬浮大标题（可见标题 = 树中最后一个标题文本；列表首项是
/// 不可见占位，`find.text` 仍能匹配但它排在前面）。
Finder _pinnedTitle(String text) => find.text(text).last;

/// 固定标题的屏幕矩形（位置 + 尺寸）。
Rect _titleRect(WidgetTester tester, String text) =>
    tester.getRect(_pinnedTitle(text));

/// 栏背景（渐变带组整体）的 AnimatedOpacity 目标值。
double _barOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byType(BackdropFilter),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

/// 大标题 item 总高度（状态栏占位 0 + 顶距 8 + 文本行高 + 底距 8）。
double _titleItemHeight(WidgetTester tester) {
  // 文本实测行高（测试字体下 = fontSize × height）；不可见占位与可见
  // 悬浮标题同款样式，取第一个（占位）测量等价
  final text = tester.getSize(find.text('发现').first).height;
  return 8 + text + 8;
}

void main() {
  group('SonifyTitleScaffold 大标题固定悬浮', () {
    testWidgets('初始态：大标题固定可见、无栏背景', (tester) async {
      final (widget, _) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();

      // 可见标题在场（固定悬浮项）
      expect(_pinnedTitle('发现'), findsOneWidget);
      // 栏背景目标透明度 0（渐变带组不可见）
      expect(_barOpacity(tester), 0);
    });

    testWidgets('滚动中：标题位置与尺寸固定不变（不位移/不缩放/不溶解），栏背景浮现',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      final before = _titleRect(tester, '发现');
      // 上滑到过渡区中段：旧实现会在此折叠为小标题（位置/尺寸变化）
      controller.jumpTo(h * 0.5);
      await tester.pump();
      final after = _titleRect(tester, '发现');

      expect(after, before,
          reason: '上滑过程中标题不位移、不缩放（反馈①）');
      // 标题始终完整可见：无溶解、无互斥小标题
      expect(_pinnedTitle('发现'), findsOneWidget);
      // 栏背景出现（目标透明度 1）：滚过内容时标题可读性由渐变带保证
      expect(_barOpacity(tester), 1);
    });

    testWidgets('深度滚动（越过标题区）：标题仍固定在顶部，内容从其下方滚过',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      final before = _titleRect(tester, '发现');
      controller.jumpTo(h * 2); // 占位 item 完全滚出视口
      await tester.pump();

      expect(_titleRect(tester, '发现'), before,
          reason: '标题不随内容滚走');
      expect(_pinnedTitle('发现'), findsOneWidget);
      expect(_barOpacity(tester), 1);
    });

    testWidgets('无吸附：拖到过渡区上半段原地停留（固定标题无需端点吸附）',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      controller.jumpTo(h * 0.4);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(h * 0.4, 0.5),
          reason: '旧实现会 180ms 吸附回展开端；固定标题无端点可吸附');
    });

    testWidgets('无吸附：拖到过渡区下半段原地停留（不自动收起）', (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      controller.jumpTo(h * 0.9);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(h * 0.9, 0.5),
          reason: '旧实现会 180ms 吸附到折叠端；固定标题无端点可吸附');
    });

    testWidgets('回到顶部：栏背景隐藏、标题位置不变', (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);
      final initial = _titleRect(tester, '发现');

      controller.jumpTo(h * 0.9);
      await tester.pump();
      expect(_barOpacity(tester), 1);

      controller.jumpTo(0);
      await tester.pump();
      expect(_barOpacity(tester), 0);
      expect(_titleRect(tester, '发现'), initial,
          reason: '回到顶部标题回到初始坐标（本就未动过）');
    });

    testWidgets('业务 item 索引从 0 映射（大标题不占业务索引）', (tester) async {
      final (widget, _) = _host(title: '发现', itemCount: 3);
      await tester.pumpWidget(widget);
      await tester.pump();
      expect(find.text('item 0'), findsOneWidget);
      expect(find.text('item 2'), findsOneWidget);
      // 总 item = 大标题占位 + 3 业务 item（主列表为 CustomScrollView +
      // 单 SliverToBoxAdapter 包裹的整列，列内 children 数即 item 数）
      final columns = tester.widgetList<Column>(find.byType(Column));
      final mainColumn = columns.firstWhere(
        (c) => c.children.length == 4,
        orElse: () => throw StateError('未找到含 4 个 item 的主列表 Column'),
      );
      expect(mainColumn.children.length, 4);
    });

    testWidgets('内容不足一屏时仍可滚动（minHeight 兜底），标题不随之移动',
        (tester) async {
      // 2 个 100dp item：内容 252dp << 600dp 视口——历史上这种短内容态
      // maxScrollExtent == 0，上滑零位移（首页冷启动的真实反馈）。
      final (widget, controller) = _host(title: '发现', itemCount: 2);
      await tester.pumpWidget(widget);
      await tester.pump();
      final before = _titleRect(tester, '发现');

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();

      // 折叠区高度（zone = 首item高 − 状态栏0）内滚动必然产生位移
      expect(controller.offset, greaterThan(0));
      // 标题固定悬浮：滚动只挪内容，不挪标题
      expect(_titleRect(tester, '发现'), before);
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

      // 带体高度 = 状态栏 24 + 栏体 54 = 78（磨砂带 + 加深带两层同尺寸）：
      // 曾只覆盖 54dp 栏体，状态栏区域透明导致内容从状态栏透出。
      final backdrops = find.byType(BackdropFilter);
      expect(backdrops, findsNWidgets(2));
      expect(tester.getSize(backdrops.first).height, 24 + SonifySpacing.topBar);
      expect(tester.getSize(backdrops.last).height, 24 + SonifySpacing.topBar);
      // 图层纪律：BackdropFilter 不被 ShaderMask 包裹（saveLayer 内嵌
      // 模糊失效，flutter/flutter#164079、#175537）
      expect(
        find.ancestor(
          of: find.byType(BackdropFilter),
          matching: find.byType(ShaderMask),
        ),
        findsNothing,
      );
      // ClipRect 裁剪保留（clip 非 saveLayer，不影响模糊）
      expect(
        find.ancestor(
          of: find.byType(BackdropFilter),
          matching: find.byType(ClipRect),
        ),
        findsNWidgets(2),
      );
    });

    testWidgets('加深带：文字区域更浓（surface 高 alpha + 强模糊）且 stops 非线性分布',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);
      controller.jumpTo(h * 0.1);
      await tester.pump();

      // ① 两层带：磨砂带（blur 18 + surface α0.7）+ 加深带（树中第二个
      //    BackdropFilter）——加深带即"文字上方区域更浓"的那层（反馈②）
      final backdrops = find.byType(BackdropFilter);
      expect(backdrops, findsNWidgets(2));

      // ② 加深带着色走 cs.surface 系高 alpha（0.85）：亮=浅带/暗=深带，
      //    跟随主题；非 scrim 黑白蒙层（亮=黑/暗=白，会主题色翻转——
      //    构建号 104 真机回归根源）、非硬编码颜色
      final surface =
          Theme.of(tester.element(backdrops.last)).colorScheme.surface;
      final deepenGradient = tester
          .widget<DecoratedBox>(
            find
                .descendant(
                  of: backdrops.last,
                  matching: find.byType(DecoratedBox),
                )
                .first,
          )
          .decoration as BoxDecoration;
      final deepenLinear = deepenGradient.gradient! as LinearGradient;
      // 顶缘全强度 surface α0.85，底缘衰减到全透明
      expect(deepenLinear.colors.first, surface.withValues(alpha: 0.85));
      expect(deepenLinear.colors.last, surface.withValues(alpha: 0));

      // ③ 渐变 stops 非线性分布（禁线性均分）：差分不全等
      final stops = kSonifyBarDeepenStops;
      expect(deepenLinear.stops, stops);
      expect(stops.first, 0.0);
      expect(stops.last, 1.0);
      final diffs = <double>[
        for (var i = 1; i < stops.length; i++) stops[i] - stops[i - 1],
      ];
      expect(diffs.toSet().length, greaterThan(1),
          reason: 'stops 差分不全等 = 非线性渐变曲线');
      // 顶部保持全强度覆盖标题文字区（0.85 之前不衰减）
      expect(stops[1], greaterThanOrEqualTo(0.8));
    });

    testWidgets('两条带 blur sigma 统一 18（对齐 dock 材质）且叠色均为 surface 系',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);
      controller.jumpTo(h * 0.1);
      await tester.pump();

      // 材质来源：LiquidGlassSurface dock 配方（blurSigma 18 + cs.surface
      // 叠色）——两条带 sigma 统一 18（原 14/22 双强度取消，浓淡层级完全
      // 由叠色 alpha 承担）
      expect(kSonifyBarBlurSigma, 18);

      final backdrops = find.byType(BackdropFilter);
      expect(backdrops, findsNWidgets(2));

      // 两条带叠色均为 cs.surface 系（dock 同色系）：磨砂带顶缘 α0.7、
      // 加深带顶缘 α0.85（高于 dock 0.12：全宽可读性带，见类文档）
      final surface =
          Theme.of(tester.element(backdrops.first)).colorScheme.surface;
      LinearGradient bandGradient(Finder band) => (tester
              .widget<DecoratedBox>(
                find
                    .descendant(
                      of: band,
                      matching: find.byType(DecoratedBox),
                    )
                    .first,
              )
              .decoration as BoxDecoration)
          .gradient! as LinearGradient;
      final frosted = bandGradient(backdrops.first);
      final deepen = bandGradient(backdrops.last);
      expect(frosted.colors.first, surface.withValues(alpha: 0.7));
      expect(deepen.colors.first, surface.withValues(alpha: 0.85));
      // 两带底缘均衰减到全透明（顶部浓→底部渐隐结构保持）
      expect(frosted.colors.last, surface.withValues(alpha: 0));
      expect(deepen.colors.last, surface.withValues(alpha: 0));
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

    testWidgets('顶栏 actions 滚动后浮现，trailing 常驻不同拍', (tester) async {
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

      // 任意滚动后（不再需要完全折叠）：actions 目标透明度 1
      final h = _titleItemHeight(tester);
      controller.jumpTo(h * 0.1);
      await tester.pump();
      expect(actionsAnimated(tester).opacity, 1);
      // trailing 依旧在场（固定头像不随滚动消失）
      expect(find.byIcon(Icons.person), findsOneWidget);
    });

    testWidgets('大标题规格：20sp Bold、行高 36dp（与 36dp 头像等高）',
        (tester) async {
      final (widget, _) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();

      // 取可见的固定悬浮标题（树中最后一个）
      final largeText = tester.widget<Text>(find.text('发现').last);
      expect(largeText.style?.fontSize, 20);
      expect(largeText.style?.fontWeight, FontWeight.w700);
      // 测试字体下行高 = fontSize × height = 20 × 1.8 = 36dp
      expect(tester.getSize(find.text('发现').last).height, 36);
    });

    testWidgets('上滑后顶栏渐变模糊带出现（渐变叠色层承载衰减，BackdropFilter 无图层包裹）',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      // 栏背景 AnimatedOpacity 门控（渐变带组整体挂在它下面）
      expect(_barOpacity(tester), 0);

      // 上滑任意距离：栏背景激活 → 渐变模糊带组在场
      controller.jumpTo(h * 0.1);
      await tester.pump();

      // 磨砂带 = 第一个 BackdropFilter（加深带在后）
      final backdrops = find.byType(BackdropFilter);
      expect(backdrops, findsNWidgets(2));
      expect(_barOpacity(tester), 1);

      // 图层纪律：BackdropFilter 不得被 ShaderMask / 裸 Opacity 包裹
      // （saveLayer 内嵌模糊失效，flutter/flutter#164079、#175537；
      // AnimatedOpacity 全显不产生 saveLayer，允许保留）
      expect(
        find.ancestor(of: backdrops, matching: find.byType(ShaderMask)),
        findsNothing,
      );
      expect(
        find.ancestor(of: backdrops, matching: find.byType(Opacity)),
        findsNothing,
      );

      // 磨砂带叠色 = surface α0.7，竖向（上→下）渐变 stops [0, 0.6, 1]
      final surface =
          Theme.of(tester.element(backdrops.first)).colorScheme.surface;
      final frostedGradient = (tester
              .widget<DecoratedBox>(
                find
                    .descendant(
                      of: backdrops.first,
                      matching: find.byType(DecoratedBox),
                    )
                    .first,
              )
              .decoration as BoxDecoration)
          .gradient! as LinearGradient;
      expect(frostedGradient.begin, Alignment.topCenter);
      expect(frostedGradient.end, Alignment.bottomCenter);
      expect(frostedGradient.stops, const [0, 0.6, 1]);
      // 顶缘全强度页面色 α0.7（Title.kt:977），底缘衰减到全透明
      expect(frostedGradient.colors.first, surface.withValues(alpha: 0.7));
      expect(frostedGradient.colors.last, surface.withValues(alpha: 0));
    });
  });
}
