import 'dart:math' as math;

import 'package:flutter/material.dart';

/// sonify 连续曲率圆角（squircle）体系。
///
/// sonify 全应用使用 `YosRoundedCornerShape`（Kyant squircle 算法，n=0.5），
/// 而非普通圆角（见方案 §0.3 圆角表）：
/// - `ui/theme/YosRoundedCornerShape.kt:120-140`：坐标计算核心（纯数学，~20 行）
/// - `ui/theme/YosRoundedCornerShape.kt:59-118`：四角路径拼装
///
/// 本文件为该算法的 Flutter 自移植（不引入 figma_squircle 等第三方依赖）：
/// - [SmoothRectangleBorder]：Flutter [OutlinedBorder] 等价物，用于
///   `ShapeDecoration` / `Material(shape:)` 等需要 ShapeBorder 的场景；
/// - [SmoothClipRRect]：`ClipRRect` 等价物，用连续曲率路径裁剪子树；
/// - [smoothCornerPath]：单一路径构造函数，供自绘场景直接使用。
///
/// 半径 token（sonify 出处）：
/// - 卡片 9dp：`ui/widgets/basic/YosRoundColumn.kt:21`（defaultCorner）
/// - 封面 10dp：`ui/widgets/basic/ShadowImage.kt:65`（cornerRadius 默认）
/// - 胶囊/圆钮 50%（radiusPill）：sonify 全仓 `RoundedCornerShape(50)` 4 处——
///   **sonify 的胶囊就是普通圆形（Stadium），不适用 squircle**，Flutter 侧
///   直接用 [StadiumBorder] / [ClipOval]，勿用本文件处理胶囊形。
class SonifyRadius {
  SonifyRadius._();

  /// 分组卡 / 容器圆角：9dp squircle。
  /// 出处：YosRoundColumn.kt:21（defaultCorner）。
  static const double card = 9;

  /// 封面圆角：10dp squircle。
  /// 出处：ShadowImage.kt:65（cornerRadius 默认）。
  static const double cover = 10;
}

/// 曲率指数 n：0 = 纯圆角，1 = 纯直角内凹，sonify 固定 0.5
/// （YosRoundedCornerShape.kt 默认参数 `n: Float = 0.5f`）。
const double kSonifySquircleN = 0.5;

/// 计算单个圆角的 7 个控制坐标（Kyant 算法核心）。
///
/// 逐行对应 YosRoundedCornerShape.kt:120-140 的 `calcCoordinates`：
/// 返回的 7 个值依次对应 Kotlin 的
/// `(aa=p7, bb=p8, cc=p9, dd=p10, ee=p2, ff=p13, gg=p14)`。
({double a, double b, double c, double d, double e, double f, double g})
    _calcCoordinates(double rad, double n) {
  final x = n * rad * 2.0 / 3.0;
  final sq = math.sqrt(1.0 + n * n);
  final p1 = sq * x;
  final p2 = n * x / sq;
  final p3 = p2 * n;
  final p4 = p2 + rad / sq;
  final p5 = p4 * (1.0 - n);
  final p7 = p5 + p1 * 4.0;
  final p8 = p5 + p1 * 2.0;
  final p9 = p5 + p1;
  final p10 = p5 + p3;
  // p11/p12/p13/p14 与 handle 仅在 n != 1 时被消费（n=1 时 dx=0，Kotlin
  // 同样会除零，但对应 cubicTo 分支被 `if (n != 1f)` 跳过）。
  final dx = rad / sq * (1.0 - n);
  var p13 = 0.0;
  var p14 = 0.0;
  if (dx != 0) {
    final d = math.sqrt(rad * rad - dx * dx / 2.0);
    final handle = (rad - d) / dx * math.sqrt2 * 4.0 / 3.0;
    p13 = p2 + (rad / sq * n) * handle; // p11 = rad / sq * n
    p14 = p10 - (rad / sq) * handle; // p12 = rad / sq
  }
  return (a: p7, b: p8, c: p9, d: p10, e: p2, f: p13, g: p14);
}

/// 构造 sonify 风格连续曲率圆角矩形路径。
///
/// 四角半径自动收敛到 `min(width, height) / 2`（与 Compose
/// CornerBasedShape 的钳制语义一致），半径为 0 的角按直角处理。
///
/// 路径拼装顺序与 YosRoundedCornerShape.kt:76-116 一致：
/// 左上 → 左下 → 右下 → 右上，每角两段 cubic（n=1 时省略中段）。
Path smoothCornerPath(
  Rect rect, {
  double topLeft = 0,
  double topRight = 0,
  double bottomRight = 0,
  double bottomLeft = 0,
  double n = kSonifySquircleN,
}) {
  final maxR = math.min(rect.width, rect.height) / 2.0;
  final rTL = math.min(topLeft, maxR);
  final rTR = math.min(topRight, maxR);
  final rBR = math.min(bottomRight, maxR);
  final rBL = math.min(bottomLeft, maxR);

  final left = rect.left;
  final top = rect.top;
  final right = rect.right;
  final bottom = rect.bottom;

  // 与 Kotlin 顺序对齐：topStart → bottomStart → bottomEnd → topEnd
  final c1 = _calcCoordinates(rTL, n); // 左上 topStart
  final c2 = _calcCoordinates(rBL, n); // 左下 bottomStart
  final c3 = _calcCoordinates(rBR, n); // 右下 bottomEnd
  final c4 = _calcCoordinates(rTR, n); // 右上 topEnd

  final path = Path();

  // moveTo(aa1, 0) —— Kotlin 以左上角起点（顶部边）
  path.moveTo(left + c1.a, top);
  if (rTL != 0) {
    path.cubicTo(left + c1.b, top, left + c1.c, top, left + c1.d, top + c1.e);
    if (n != 1) {
      path.cubicTo(left + c1.g, top + c1.f, left + c1.f, top + c1.g,
          left + c1.e, top + c1.d);
    }
    path.cubicTo(left, top + c1.c, left, top + c1.b, left, top + c1.a);
  }

  // lineTo(0, height - aa2)
  path.lineTo(left, bottom - c2.a);
  if (rBL != 0) {
    path.cubicTo(left, bottom - c2.b, left, bottom - c2.c, left + c2.e,
        bottom - c2.d);
    if (n != 1) {
      path.cubicTo(left + c2.f, bottom - c2.g, left + c2.g, bottom - c2.f,
          left + c2.d, bottom - c2.e);
    }
    path.cubicTo(left + c2.c, bottom, left + c2.b, bottom, left + c2.a, bottom);
  }

  // lineTo(width - aa3, height)
  path.lineTo(right - c3.a, bottom);
  if (rBR != 0) {
    path.cubicTo(right - c3.b, bottom, right - c3.c, bottom, right - c3.d,
        bottom - c3.e);
    if (n != 1) {
      path.cubicTo(right - c3.g, bottom - c3.f, right - c3.f, bottom - c3.g,
          right - c3.e, bottom - c3.d);
    }
    path.cubicTo(right, bottom - c3.c, right, bottom - c3.b, right,
        bottom - c3.a);
  }

  // lineTo(width, aa4)
  path.lineTo(right, top + c4.a);
  if (rTR != 0) {
    path.cubicTo(right, top + c4.b, right, top + c4.c, right - c4.e,
        top + c4.d);
    if (n != 1) {
      path.cubicTo(right - c4.f, top + c4.g, right - c4.g, top + c4.f,
          right - c4.d, top + c4.e);
    }
    path.cubicTo(
        right - c4.c, top, right - c4.b, top, right - c4.a, top);
  }

  // lineTo(aa1, 0) + close
  path.lineTo(left + c1.a, top);
  path.close();
  return path;
}

/// sonify 连续曲率圆角边框（`YosRoundedCornerShape` 的 Flutter ShapeBorder 等价物）。
///
/// 用法与 [RoundedRectangleBorder] 一致：
/// ```dart
/// ShapeDecoration(shape: SmoothRectangleBorder(borderRadius: BorderRadius.circular(SonifyRadius.card)))
/// Material(shape: SmoothRectangleBorder(borderRadius: BorderRadius.circular(9)))
/// ```
class SmoothRectangleBorder extends OutlinedBorder {
  const SmoothRectangleBorder({
    super.side,
    this.borderRadius = BorderRadius.zero,
    this.n = kSonifySquircleN,
  });

  /// 四角半径（语义同 [RoundedRectangleBorder.borderRadius]）。
  final BorderRadius borderRadius;

  /// 曲率指数（sonify 固定 0.5）。
  final double n;

  Path _path(Rect rect, TextDirection? textDirection) {
    final resolved = borderRadius.resolve(textDirection);
    return smoothCornerPath(
      rect,
      topLeft: resolved.topLeft.x,
      topRight: resolved.topRight.x,
      bottomRight: resolved.bottomRight.x,
      bottomLeft: resolved.bottomLeft.x,
      n: n,
    );
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect, textDirection);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.width), textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    final paint = side.toPaint();
    // 描边中心线内缩半个线宽，保证整条边画在边界内（OutlinedBorder 惯例）
    canvas.drawPath(_path(rect.deflate(side.width / 2), textDirection), paint);
  }

  @override
  ShapeBorder scale(double t) => SmoothRectangleBorder(
        side: side.scale(t),
        borderRadius: borderRadius * t,
        n: n,
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is SmoothRectangleBorder) {
      return SmoothRectangleBorder(
        side: BorderSide.lerp(a.side, side, t),
        borderRadius:
            BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        n: n,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is SmoothRectangleBorder) {
      return SmoothRectangleBorder(
        side: BorderSide.lerp(side, b.side, t),
        borderRadius:
            BorderRadius.lerp(borderRadius, b.borderRadius, t)!,
        n: b.n,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  OutlinedBorder copyWith({BorderSide? side, BorderRadius? borderRadius}) {
    return SmoothRectangleBorder(
      side: side ?? this.side,
      borderRadius: borderRadius ?? this.borderRadius,
      n: n,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is SmoothRectangleBorder &&
        other.side == side &&
        other.borderRadius == borderRadius &&
        other.n == n;
  }

  @override
  int get hashCode => Object.hash(side, borderRadius, n);
}

/// 连续曲率裁剪容器（`ClipRRect` 的 squircle 等价物）。
///
/// 用法与 [ClipRRect] 一致：
/// ```dart
/// SmoothClipRRect(borderRadius: BorderRadius.circular(SonifyRadius.cover), child: cover)
/// ```
class SmoothClipRRect extends StatelessWidget {
  const SmoothClipRRect({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.n = kSonifySquircleN,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double n;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _SmoothPathClipper(borderRadius: borderRadius, n: n),
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}

class _SmoothPathClipper extends CustomClipper<Path> {
  const _SmoothPathClipper({required this.borderRadius, required this.n});

  final BorderRadius borderRadius;
  final double n;

  @override
  Path getClip(Size size) {
    return smoothCornerPath(
      Offset.zero & size,
      topLeft: borderRadius.topLeft.x,
      topRight: borderRadius.topRight.x,
      bottomRight: borderRadius.bottomRight.x,
      bottomLeft: borderRadius.bottomLeft.x,
      n: n,
    );
  }

  @override
  bool shouldReclip(_SmoothPathClipper oldClipper) =>
      oldClipper.borderRadius != borderRadius || oldClipper.n != n;
}
