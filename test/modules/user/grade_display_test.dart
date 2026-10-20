import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/modules/user/grade_display.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 共享等级展示组件（grade_display.dart）测试：
/// - formatGradeSeconds 纯函数格式（与 user_center_page 原实现逐字一致）；
/// - GradeBriefChip 有数据 / 无数据两种形态。
void main() {
  group('formatGradeSeconds', () {
    test('null / 非正值 → 0分钟', () {
      expect(formatGradeSeconds(null), '0分钟');
      expect(formatGradeSeconds(0), '0分钟');
      expect(formatGradeSeconds(-5), '0分钟');
    });

    test('不足 1 分钟按 0 分钟计（向下取整到分）', () {
      expect(formatGradeSeconds(59), '0分钟');
    });

    test('分钟档：X分钟', () {
      expect(formatGradeSeconds(60), '1分钟');
      expect(formatGradeSeconds(3599), '59分钟');
    });

    test('小时档：X小时Y分', () {
      expect(formatGradeSeconds(3600), '1小时0分');
      expect(formatGradeSeconds(7500), '2小时5分');
    });

    test('天档：X天Y小时Z分', () {
      expect(formatGradeSeconds(86400), '1天0小时0分');
      expect(formatGradeSeconds(90000), '1天1小时0分');
      expect(formatGradeSeconds(90060), '1天1小时1分');
    });
  });

  group('GradeBriefChip', () {
    testWidgets('有 gradeInfo → 「Lv.{等级} · 听歌 {时长}」一行', (tester) async {
      const grade = KugouGradeInfo(dSec: 7500, pGrade: 3);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GradeBriefChip(grade: grade),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Lv.3 · 听歌 2小时5分'), findsOneWidget);
    });

    testWidgets('dSec 缺失时退回 duration 字段', (tester) async {
      const grade = KugouGradeInfo(duration: 3600, pGrade: 7);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GradeBriefChip(grade: grade),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Lv.7 · 听歌 1小时0分'), findsOneWidget);
    });

    testWidgets('无 gradeInfo → 占位文案', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GradeBriefChip(grade: null),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('登录后查看等级与听歌时长'), findsOneWidget);
      expect(find.textContaining('Lv.'), findsNothing);
    });
  });
}
