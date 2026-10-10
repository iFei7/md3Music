import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

/// 液态玻璃容器（悬浮 Dock 底座）。
///
/// 视觉分层（自下而上）：
/// 1. [BackdropFilter] 背景模糊（sigma ≈ 18），只覆盖容器自身区域，绝不全屏；
/// 2. 半透明 surface 叠色（alpha 0.10–0.15，跟随主题 colorScheme），
///    保证亮/暗主题下内容可读；
/// 3. 1px 渐变描边：左上白色高光（alpha ≈ 0.35）渐隐到右下，
///    模拟玻璃边缘的受光面；
/// 4. 顶部内侧高光线：玻璃上缘的一条细亮线。
///
/// **静态组件、零动画**：所有动效（展开/坍缩/形变）由外层
/// [GlassDockPlayer] 用收敛型动画驱动，本组件只负责一次绘制。
/// 支持胶囊（pill）/ 圆形（circle）/ 圆角矩形三种外形。
class LiquidGlassContainer extends StatelessWidget {
  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.shape = GlassShape.pill,
    this.borderRadius = 0,
    this.padding = EdgeInsets.zero,
    this.blurSigma = 18,
    this.fillAlpha = 0.12,
  });

  /// 容器内容。
  final Widget child;

  /// 外形（胶囊 / 圆形 / 圆角矩形）。
  final GlassShape shape;

  /// 圆角矩形的圆角半径（仅 [GlassShape.roundedRect] 时生效）。
  final double borderRadius;

  /// 内容内边距。
  final EdgeInsetsGeometry padding;

  /// 背景模糊强度。
  final double blurSigma;

  /// 叠色不透明度（0.10–0.15 推荐区间，保证内容可读）。
  final double fillAlpha;

  /// 按外形裁剪（同时裁掉模糊层与描边的溢出）。
  ///
  /// 胶囊形的圆角取容器实际高度的一半（StadiumBorder 语义），需经
  /// [LayoutBuilder] 测量，避免 `BorderRadius.circular(∞)` 的断言失败。
  Widget _clip(Widget child) {
    switch (shape) {
      case GlassShape.circle:
        return ClipOval(child: child);
      case GlassShape.pill:
        return LayoutBuilder(
          builder: (context, constraints) => ClipRRect(
            borderRadius: BorderRadius.circular(constraints.maxHeight / 2),
            child: child,
          ),
        );
      case GlassShape.roundedRect:
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: child,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fill = cs.surface.withValues(alpha: fillAlpha);
    final borderColor = cs.onSurface;

    return _clip(
      Stack(
        children: [
          // 背景模糊：只作用于被 Clip 裁剪的容器区域。
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: const SizedBox.expand(),
            ),
          ),
          // 半透明叠色：玻璃的"体色"。
          Positioned.fill(child: ColoredBox(color: fill)),
          // 1px 渐变描边 + 顶部内侧高光线。
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GlassBorderPainter(
                  shape: shape,
                  borderRadius: borderRadius,
                  borderColor: borderColor,
                ),
              ),
            ),
          ),
          // 内容。
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// 玻璃容器外形。
enum GlassShape { pill, circle, roundedRect }

/// 玻璃描边绘制器：
/// - 外缘 1px 线性渐变描边（左上高光 → 右下渐隐）；
/// - 顶部内侧高光线（上缘细亮线，左右渐隐）。
class _GlassBorderPainter extends CustomPainter {
  _GlassBorderPainter({
    required this.shape,
    required this.borderRadius,
    required this.borderColor,
  });

  final GlassShape shape;
  final double borderRadius;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final isCircle = shape == GlassShape.circle;
    final radius = isCircle
        ? size.height / 2
        : (shape == GlassShape.pill ? size.height / 2 : borderRadius);

    // 描边渐变：左上白高光 → 右下渐隐（混入 onSurface 保证暗色主题可感知）。
    final shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: 0.35),
        borderColor.withValues(alpha: 0.06),
      ],
    ).createShader(rect);

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = shader;

    if (isCircle) {
      canvas.drawOval(rect.deflate(0.5), borderPaint);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius)),
        borderPaint,
      );
    }

    // 顶部内侧高光线：上缘 1px 细线，左右向内收进后渐隐。
    final highlightShader = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        Colors.transparent,
        Colors.white.withValues(alpha: 0.28),
        Colors.transparent,
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(rect);

    final highlightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = highlightShader;

    final inset = isCircle ? size.width / 4 : radius * 0.8;
    canvas.drawLine(
      Offset(inset, 1),
      Offset(size.width - inset, 1),
      highlightPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GlassBorderPainter oldDelegate) {
    return oldDelegate.shape != shape ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.borderColor != borderColor;
  }
}
