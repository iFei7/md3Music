import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/app_theme.dart';


import 'package:md3music/core/theme/squircle.dart';
import 'package:md3music/widgets/common/cover_rail.dart';

/// AppTheme 主题但清除页面过渡 builder（其内嵌 AppBackground 需要
/// ThemeProvider，组件级测试无 Provider 树），避免测试环境异常。
final _testTheme = AppTheme.lightTheme.copyWith(
  pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
);

Widget _host({
  required int itemCount,
  required ValueChanged<int> onItemTap,
  ScrollController? controller,
}) {
  return MaterialApp(
    theme: _testTheme,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: CoverRail(
          itemCount: itemCount,
          controller: controller,
          itemBuilder: (context, index) => CoverRailCard(
            cover: ColoredBox(color: Colors.primaries[index % 8]),
            title: '封面 $index',
            subtitle: '副标 $index',
            onTap: () => onItemTap(index),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('CoverRail 横滑封面 Rail', () {
    testWidgets('横向滚动布局：水平 ListView + 边缘 18dp', (tester) async {
      await tester.pumpWidget(_host(itemCount: 8, onItemTap: (_) {}));
      await tester.pump();

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.scrollDirection, Axis.horizontal);
      final pad = list.padding! as EdgeInsets;
      expect(pad.left, SonifySpacing.gridEdge); // 18dp
      expect(pad.right, SonifySpacing.gridEdge);
    });

    testWidgets('卡片宽度 = 150dp（sonify 自适应网格最小图尺寸），间距 15dp',
        (tester) async {
      await tester.pumpWidget(_host(itemCount: 8, onItemTap: (_) {}));
      await tester.pump();

      final first = tester.getSize(find.byType(CoverRailCard).first);
      expect(first.width, SonifySpacing.coverRailMin);

      // 卡 0 右缘到卡 1 左缘的水平距离 = 15dp（网格列间距）
      final card0 = tester.getTopLeft(find.byType(CoverRailCard).at(0));
      final card1 = tester.getTopLeft(find.byType(CoverRailCard).at(1));
      final gap = card1.dx - (card0.dx + SonifySpacing.coverRailMin);
      expect(gap, SonifySpacing.gridH);
    });

    testWidgets('卡下标题 13sp / 副标 13sp 次级灰（#88878E 浅色）',
        (tester) async {
      await tester.pumpWidget(_host(itemCount: 4, onItemTap: (_) {}));
      await tester.pump();

      final titleStyle = tester.widget<Text>(find.text('封面 0')).style!;
      expect(titleStyle.fontSize, 13);
      expect(titleStyle.color, Theme.of(tester.element(find.text('封面 0'))).colorScheme.onSurface);

      final subtitleStyle = tester.widget<Text>(find.text('副标 0')).style!;
      expect(subtitleStyle.fontSize, 13);
      expect(
        subtitleStyle.color,
        SonifyColors.of(tester.element(find.text('副标 0'))).textSecondary,
      );
      expect(subtitleStyle.color, const Color(0xFF88878E));
    });

    testWidgets('封面 squircle 10dp 裁剪 + 1px 白 10% 内描边', (tester) async {
      await tester.pumpWidget(_host(itemCount: 2, onItemTap: (_) {}));
      await tester.pump();

      // 封面被 SmoothClipRRect 裁剪（连续曲率）
      final clip = tester.widget<SmoothClipRRect>(find.byType(SmoothClipRRect).first);
      expect(clip.borderRadius.topLeft.x, SonifyRadius.cover);

      // 内描边：白 α0.10
      final borders = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(CoverRailCard),
          matching: find.byType(DecoratedBox),
        ),
      );
      final borderDecoration = borders
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.border != null)
          .toList();
      expect(borderDecoration, isNotEmpty);
      expect(
        (borderDecoration.first.border as Border).top.color,
        Colors.white.withValues(alpha: 0.10),
      );
    });

    testWidgets('点击封面卡触发回调', (tester) async {
      var tapped = -1;
      await tester.pumpWidget(_host(itemCount: 4, onItemTap: (i) => tapped = i));
      await tester.pump();

      await tester.tap(find.byType(CoverRailCard).at(2));
      await tester.pump();
      expect(tapped, 2);
    });

    testWidgets('itemWidth 可放宽（自适应网格 min 150dp 语义）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: _testTheme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: CoverRail(
              itemCount: 2,
              itemWidth: 180,
              itemBuilder: (context, index) => CoverRailCard(
                cover: const ColoredBox(color: Colors.blue),
                title: '卡 $index',
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      final card = tester.getSize(find.byType(CoverRailCard).first);
      expect(card.width, 180);
    });

    testWidgets('无副标时不渲染副标文本', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: _testTheme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: CoverRail(
              itemCount: 1,
              itemBuilder: (context, index) => CoverRailCard(
                cover: const ColoredBox(color: Colors.blue),
                title: '只有标题',
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('只有标题'), findsOneWidget);
      expect(find.text('副标 0'), findsNothing);
    });
  });
}
