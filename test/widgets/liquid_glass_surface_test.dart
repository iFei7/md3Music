import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';


// 只 import container：GlassShape / LiquidGlassSurface 均由其 re-export
// （本测试同时验证 re-export 可用性）
import 'package:md3music/core/widgets/liquid_glass_container.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? _testTheme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 64,
            child: child,
          ),
        ),
      ),
    );

void main() {
  group('LiquidGlassSurface 参数化行为', () {
    testWidgets('默认参数：blur 18 / fillAlpha 0.12 / 高光描边开 / 投影关',
        (tester) async {
      await tester.pumpWidget(_host(
        LiquidGlassSurface(child: const SizedBox.expand()),
      ));
      expect(tester.takeException(), isNull);

      final surface =
          tester.widget<LiquidGlassSurface>(find.byType(LiquidGlassSurface));
      expect(surface.shape, GlassShape.pill);
      expect(surface.blurSigma, 18);
      expect(surface.fillAlpha, 0.12);
      expect(surface.showHighlightBorder, isTrue);
      expect(surface.showShadow, isFalse);

      // 模糊层就位（dart:ui 不暴露 sigma 字段，行为级断言存在性）
      expect(find.byType(BackdropFilter), findsOneWidget);

      // 高光描边绘制器存在（限定在玻璃面子树内，排除框架自绘的 CustomPaint）
      expect(
        find.descendant(
          of: find.byType(LiquidGlassSurface),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });

    testWidgets('showHighlightBorder=false 不再绘制描边', (tester) async {
      await tester.pumpWidget(_host(
        LiquidGlassSurface(
          showHighlightBorder: false,
          child: const SizedBox.expand(),
        ),
      ));
      expect(
        find.descendant(
          of: find.byType(LiquidGlassSurface),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    testWidgets('showShadow=true 增加外投影层', (tester) async {
      await tester.pumpWidget(_host(
        LiquidGlassSurface(
          showShadow: true,
          child: const SizedBox.expand(),
        ),
      ));
      final decorBoxes =
          tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
      final hasShadow = decorBoxes.any((d) =>
          d.decoration is BoxDecoration &&
          ((d.decoration as BoxDecoration).boxShadow?.isNotEmpty ?? false));
      expect(hasShadow, isTrue, reason: 'showShadow=true 应出现投影');
    });

    testWidgets('showShadow=false 无外投影层（Dock 默认形态）', (tester) async {
      await tester.pumpWidget(_host(
        LiquidGlassSurface(child: const SizedBox.expand()),
      ));
      // 全部 DecoratedBox 均无 boxShadow（含 Material 内部的）
      final all = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
      for (final d in all) {
        final decor = d.decoration;
        if (decor is BoxDecoration) {
          expect(
            decor.boxShadow,
            anyOf(isNull, isEmpty),
            reason: 'showShadow=false 不应有投影',
          );
        }
      }
    });

    testWidgets('smoothRect 外形使用连续曲率裁剪', (tester) async {
      await tester.pumpWidget(_host(
        LiquidGlassSurface(
          shape: GlassShape.smoothRect,
          borderRadius: 9,
          child: const SizedBox.expand(),
        ),
      ));
      expect(tester.takeException(), isNull);
      // smoothRect 走 SmoothClipRRect → ClipPath（连续曲率路径裁剪）
      expect(find.byType(ClipPath), findsOneWidget);
    });
  });

  group('LiquidGlassContainer 委托兼容（Dock 行为不变量）', () {
    testWidgets('默认构造仍为 pill + blur 18 + fillAlpha 0.12 + 无投影',
        (tester) async {
      await tester.pumpWidget(_host(
        LiquidGlassContainer(child: const SizedBox.expand()),
      ));
      expect(tester.takeException(), isNull);

      final surface =
          tester.widget<LiquidGlassSurface>(find.byType(LiquidGlassSurface));
      expect(surface.shape, GlassShape.pill);
      expect(surface.blurSigma, 18);
      expect(surface.fillAlpha, 0.12);
      expect(surface.showHighlightBorder, isTrue);
      expect(surface.showShadow, isFalse);
      expect(surface.padding, EdgeInsets.zero);

      // 旧参数透传
      await tester.pumpWidget(_host(
        LiquidGlassContainer(
          shape: GlassShape.roundedRect,
          borderRadius: 12,
          blurSigma: 30,
          fillAlpha: 0.2,
          padding: const EdgeInsets.all(8),
          child: const SizedBox.expand(),
        ),
      ));
      final passed =
          tester.widget<LiquidGlassSurface>(find.byType(LiquidGlassSurface));
      expect(passed.shape, GlassShape.roundedRect);
      expect(passed.borderRadius, 12);
      expect(passed.blurSigma, 30);
      expect(passed.fillAlpha, 0.2);
      expect(passed.padding, const EdgeInsets.all(8));
    });

    test('GlassShape 仍可从 liquid_glass_container.dart 导入（re-export）', () {
      // 编译期即验证：本文件 import 的是 liquid_glass_container.dart
      expect(GlassShape.values.length, 4);
    });
  });
}
