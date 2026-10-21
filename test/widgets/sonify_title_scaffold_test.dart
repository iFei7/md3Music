import 'dart:ui' as ui show ImageFilter;

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

/// 逐元素 closeTo 断言渐变 stops（浮点相等不敏感）。
void _expectStops(List<double>? stops, List<double> expected) {
  expect(stops, isNotNull, reason: '渐变必须显式提供 stops');
  expect(stops!.length, expected.length, reason: 'stops 数量一致');
  for (var i = 0; i < expected.length; i++) {
    expect(stops[i], closeTo(expected[i], 1e-9));
  }
}

/// 带内 tint 叠色渐变：模糊层（ClipRect → BackdropFilter →
/// SizedBox.expand）不含 DecoratedBox，故整条带内唯一的
/// DecoratedBox 即 tint 兄弟层（本函数自带断言，结构一旦回退会立刻失败）。
LinearGradient _tintGradient(WidgetTester tester) {
  final backdrops = find.byType(BackdropFilter);
  final band = find
      .ancestor(of: backdrops.first, matching: find.byType(ClipRect))
      .last;
  final tint = find.descendant(of: band, matching: find.byType(DecoratedBox));
  expect(tint, findsOneWidget,
      reason: '带内仅 tint 一层 DecoratedBox（模糊层只包 BackdropFilter）');
  return (tester.widget<DecoratedBox>(tint).decoration as BoxDecoration)
      .gradient! as LinearGradient;
}

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

      // 带体高度 = 状态栏 24 + 栏体 54 = 78（单片模糊带覆盖）：
      // 曾只覆盖 54dp 栏体，状态栏区域透明导致内容从状态栏透出。
      const bandHeight = 24 + SonifySpacing.topBar;
      final backdrops = find.byType(BackdropFilter);
      expect(
        backdrops,
        findsOneWidget,
        reason: '单片均匀模糊：全带仅 1 个 BackdropFilter（批次 17 退化为单片）',
      );
      // 图层纪律：BackdropFilter 不被 ShaderMask 包裹（saveLayer 内嵌
      // 模糊失效，flutter/flutter#164079、#175537）
      expect(
        find.ancestor(
          of: find.byType(BackdropFilter),
          matching: find.byType(ShaderMask),
        ),
        findsNothing,
      );
      // 外层带裁剪壳：覆盖「状态栏 + 栏体」全带
      final bandClip = find
          .ancestor(of: backdrops.first, matching: find.byType(ClipRect))
          .last;
      expect(tester.getSize(bandClip).height, bandHeight);
      // 单片模糊铺满整带：BackdropFilter 与裁剪壳同尺寸（横向铺满、
      // 竖向覆盖「状态栏 + 栏体」）；child 必须非 null——
      // const SizedBox.expand()，child 缺失时框架不生成滤镜层，
      // 真机表现为无模糊
      final blurSize = tester.getSize(backdrops.first);
      expect(blurSize.height, bandHeight,
          reason: '单片模糊竖向铺满「状态栏 + 栏体」全带');
      expect(blurSize.width, tester.getSize(bandClip).width,
          reason: '单片模糊横向铺满整带');
      expect(
        tester.widget<BackdropFilter>(backdrops.first).child,
        isA<SizedBox>(),
        reason: 'BackdropFilter child 非 null（SizedBox.expand）',
      );
      // sigma = kSonifyBarBlurSigma（单片第三档 3；ImageFilter.blur 重写 ==）
      expect(
        tester.widget<BackdropFilter>(backdrops.first).filter,
        ui.ImageFilter.blur(
            sigmaX: kSonifyBarBlurSigma, sigmaY: kSonifyBarBlurSigma),
      );

      // tint 叠色层（模糊兄弟层，普通 srcOver）：状态栏锚定，
      // 本用例 sb=24 → stops [0, 24/78, 1]，
      // surface@0.42 → surface@0.42 → surface@0
      final tintGradient = _tintGradient(tester);
      final surface =
          Theme.of(tester.element(backdrops.first)).colorScheme.surface;

      expect(tintGradient.begin, Alignment.topCenter);
      expect(tintGradient.end, Alignment.bottomCenter);
      _expectStops(tintGradient.stops, const [0, 24 / 78, 1]);
      expect(
        tintGradient.colors.first,
        surface.withValues(alpha: kSonifyBarTopAlpha),
      );
      expect(
        tintGradient.colors[1],
        surface.withValues(alpha: kSonifyBarTopAlpha),
      );
      expect(tintGradient.colors.last, surface.withValues(alpha: 0));
    });

    testWidgets('渐变模糊带 blur sigma 18（dock 配方）且叠色为 surface 系',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);
      controller.jumpTo(h * 0.1);
      await tester.pump();

      // 材质来源：LiquidGlassSurface dock 配方（blurSigma 18 + cs.surface
      // 叠色）；批次 17 退化为单片（σ3），批次 25 因不透明白卡内容滚过时
      // σ3 糊不出磨砂结构（顶栏观感=实色条）回归 dock 同档 18
      expect(kSonifyBarBlurSigma, 18);
      // 单带收敛后的状态栏区域叠色单值（双带合并，反馈③）
      expect(kSonifyBarTopAlpha, 0.42);

      // 本宿主无系统 inset（sb=0，H=54）：单片均匀模糊，同样仅 1 个
      final backdrops = find.byType(BackdropFilter);
      expect(
        backdrops,
        findsOneWidget,
        reason: '单片模糊：sb=0 无退化分支，全带仅 1 个 BackdropFilter',
      );
      expect(
        tester.widget<BackdropFilter>(backdrops.first).filter,
        ui.ImageFilter.blur(
            sigmaX: kSonifyBarBlurSigma, sigmaY: kSonifyBarBlurSigma),
        reason: '运行时滤镜 sigma == kSonifyBarBlurSigma',
      );

      // 带叠色为 cs.surface 系（dock 同色系）：状态栏区域全强度
      // kSonifyBarTopAlpha，底缘衰减到全透明；高于 dock 0.12：全宽
      // 可读性带，见类文档
      final surface =
          Theme.of(tester.element(backdrops.first)).colorScheme.surface;
      final tintGradient = _tintGradient(tester);
      expect(
        tintGradient.colors.first,
        surface.withValues(alpha: kSonifyBarTopAlpha),
      );
      expect(tintGradient.colors.last, surface.withValues(alpha: 0));
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
      expect(largeText.style?.fontWeight, FontWeight.w800);
      // 测试字体下行高 = fontSize × height = 20 × 1.8 = 36dp
      expect(tester.getSize(find.text('发现').last).height, 36);
    });

    testWidgets('上滑后顶栏渐变模糊带出现（单片均匀模糊 + tint 兄弟层，BackdropFilter 无图层包裹）',
        (tester) async {
      final (widget, controller) = _host(title: '发现');
      await tester.pumpWidget(widget);
      await tester.pump();
      final h = _titleItemHeight(tester);

      // 栏背景 AnimatedOpacity 门控（渐变带整体挂在它下面）
      expect(_barOpacity(tester), 0);

      // 上滑任意距离：栏背景激活 → 渐变模糊带在场
      controller.jumpTo(h * 0.1);
      await tester.pump();

      // 渐变带 = 单片（sb=0 同为 1 个 BackdropFilter，均匀模糊）
      final backdrops = find.byType(BackdropFilter);
      expect(backdrops, findsOneWidget);
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

      // tint（模糊兄弟层，本宿主无系统 inset → 退化 stops [0, 1]）：
      // surface@0.42 → surface@0。状态栏锚定三 stops [0, 24/78, 1]
      // 由上面注入 sb=24 的用例覆盖。
      final tintGradient = _tintGradient(tester);
      final surface =
          Theme.of(tester.element(backdrops.first)).colorScheme.surface;

      expect(tintGradient.begin, Alignment.topCenter);
      expect(tintGradient.end, Alignment.bottomCenter);
      _expectStops(tintGradient.stops, const [0, 1]);
      // 顶缘全强度页面色 α0.42（kSonifyBarTopAlpha），底缘衰减到全透明
      expect(
        tintGradient.colors.first,
        surface.withValues(alpha: kSonifyBarTopAlpha),
      );
      expect(tintGradient.colors.last, surface.withValues(alpha: 0));
    });
  });
}
