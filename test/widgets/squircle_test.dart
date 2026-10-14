import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/theme/squircle.dart';

void main() {
  group('smoothCornerPath（Kyant 算法移植）', () {
    const rect = Rect.fromLTWH(0, 0, 200, 100);

    test('路径边界不超出目标矩形', () {
      final path = smoothCornerPath(rect, topLeft: 9, topRight: 9, bottomRight: 9, bottomLeft: 9);
      final bounds = path.getBounds();
      expect(bounds.left, closeTo(rect.left, 0.5));
      expect(bounds.top, closeTo(rect.top, 0.5));
      expect(bounds.right, closeTo(rect.right, 0.5));
      expect(bounds.bottom, closeTo(rect.bottom, 0.5));
    });

    test('圆角处圆点被裁掉、中心与边中点在路径内', () {
      final path = smoothCornerPath(rect, topLeft: 9, topRight: 9, bottomRight: 9, bottomLeft: 9);
      expect(path.contains(const Offset(100, 50)), isTrue, reason: '中心在内');
      expect(path.contains(const Offset(5, 50)), isTrue, reason: '左边内部在内');
      // 左上角尖角点：squircle 连续曲率会把尖角内收
      expect(path.contains(const Offset(0.5, 0.5)), isFalse, reason: '尖角在外');
      expect(path.contains(const Offset(199.5, 99.5)), isFalse, reason: '右下尖角在外');
    });

    test('半径 0 退化为直角矩形（尖角在内）', () {
      final path = smoothCornerPath(rect);
      expect(path.contains(const Offset(0.5, 0.5)), isTrue);
      expect(path.contains(const Offset(100, 50)), isTrue);
    });

    test('半径超过短边一半时收敛（不抛异常、路径近似有效）', () {
      final path = smoothCornerPath(
        const Rect.fromLTWH(0, 0, 10, 10),
        topLeft: 999,
        topRight: 999,
        bottomRight: 999,
        bottomLeft: 999,
      );
      // 注：半径钳制到短边一半后，Kyant n=0.5 曲线的贝塞尔控制点会带
      // ~0.1px 的越界（getBounds 含控制点），为算法固有特性；实际消费
      // （卡片 9dp / 封面 10dp）远小于半边长，不出现该现象。
      final bounds = path.getBounds();
      expect(bounds.left, closeTo(0, 0.25));
      expect(bounds.top, closeTo(0, 0.25));
      expect(bounds.right, closeTo(10, 0.25));
      expect(bounds.bottom, closeTo(10, 0.25));
      expect(path.contains(const Offset(5, 5)), isTrue);
    });

    test('n = 1（省略中段分支）不产生 NaN 路径', () {
      final path = smoothCornerPath(rect, topLeft: 12, n: 1);
      expect(path.getBounds(), rect);
      expect(path.contains(const Offset(100, 50)), isTrue);
    });

    test('与普通圆角对比：squircle 在对角方向更外凸（连续曲率特征）', () {
      // 沿 45° 对角线从角点向内采样，找形状边界（第一个落在路径内的采样点）：
      // squircle 削角更少 → 边界离角点更远。
      final smooth = smoothCornerPath(rect, topLeft: 20);
      final circular = Path()
        ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(20)));
      double? smoothEntry;
      double? circularEntry;
      for (var t = 0.0; t <= 1.0; t += 0.002) {
        final p = Offset(t * 20, t * 20);
        final dist = t * 20 * math.sqrt2;
        if (smoothEntry == null && smooth.contains(p)) smoothEntry = dist;
        if (circularEntry == null && circular.contains(p)) circularEntry = dist;
      }
      expect(smoothEntry, isNotNull);
      expect(circularEntry, isNotNull);
      // 圆弧在对角线方向的边界 = r√2 − r ≈ 8.284；squircle 应更远
      expect(circularEntry!, closeTo(20 * math.sqrt2 - 20, 0.3));
      expect(smoothEntry!, greaterThan(circularEntry + 0.5));
    });
  });

  group('SmoothRectangleBorder', () {
    test('getOuterPath 与 smoothCornerPath 行为一致', () {
      const border = SmoothRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(9)),
      );
      final path = border.getOuterPath(const Rect.fromLTWH(0, 0, 100, 100));
      final reference = smoothCornerPath(
        const Rect.fromLTWH(0, 0, 100, 100),
        topLeft: 9,
        topRight: 9,
        bottomRight: 9,
        bottomLeft: 9,
      );
      // 以 PathMetrics 长度做行为级对照（同算法应生成等长轮廓）
      final lenA = path.computeMetrics().first.length;
      final lenB = reference.computeMetrics().first.length;
      expect(lenA, closeTo(lenB, 0.01));
    });

    test('getInnerPath 按 side.width 收缩', () {
      const border = SmoothRectangleBorder(
        side: BorderSide(width: 4),
        borderRadius: BorderRadius.all(Radius.circular(9)),
      );
      final inner = border.getInnerPath(const Rect.fromLTWH(0, 0, 100, 100));
      expect(inner.getBounds().left, closeTo(4, 0.1));
      expect(inner.getBounds().top, closeTo(4, 0.1));
    });

    test('scale / lerp / copyWith / 相等性', () {
      const a = SmoothRectangleBorder(
        side: BorderSide(width: 1),
        borderRadius: BorderRadius.all(Radius.circular(9)),
      );
      final scaled = a.scale(2) as SmoothRectangleBorder;
      expect(scaled.borderRadius.topLeft.x, 18);
      expect(scaled.side.width, 2);

      const b = SmoothRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(17)),
      );
      final lerp = a.lerpTo(b, 0.5) as SmoothRectangleBorder?;
      expect(lerp!.borderRadius.topLeft.x, closeTo(13, 0.001));

      expect(a.copyWith(side: const BorderSide(width: 3)).side.width, 3);
      expect(a == const SmoothRectangleBorder(
        side: BorderSide(width: 1),
        borderRadius: BorderRadius.all(Radius.circular(9)),
      ), isTrue);
      expect(a.hashCode,
          const SmoothRectangleBorder(
            side: BorderSide(width: 1),
            borderRadius: BorderRadius.all(Radius.circular(9)),
          ).hashCode);
    });

    testWidgets('Material(shape: SmoothRectangleBorder) 正常绘制', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Material(
                shape: const SmoothRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(9)),
                ),
                child: const SizedBox(width: 80, height: 48),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('SmoothClipRRect', () {
    testWidgets('以连续曲率路径裁剪子树', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SmoothClipRRect(
                borderRadius: BorderRadius.circular(SonifyRadius.cover),
                child: Container(
                  width: 100,
                  height: 100,
                  color: Colors.red,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // 裁剪器就位
      final clip = tester.widget<ClipPath>(find.byType(ClipPath));
      expect(clip.clipper, isA<CustomClipper<Path>>());
    });
  });

  group('SonifyRadius', () {
    test('radiusCard 9 / radiusCover 10', () {
      expect(SonifyRadius.card, 9);
      expect(SonifyRadius.cover, 10);
    });
  });
}
