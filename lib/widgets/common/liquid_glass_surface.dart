import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../../core/theme/squircle.dart';

/// 玻璃容器外形。
///
/// sonify 重设计批次 0 从 `LiquidGlassContainer` 抽出参数化通用玻璃面时，
/// 本枚举迁移至此处；`liquid_glass_container.dart` 通过 export 继续对外提供，
/// 既有 import 方（GlassDockPlayer）无需改动。
enum GlassShape { pill, circle, roundedRect, smoothRect }

/// 参数化通用液态玻璃面（UI 重设计批次 0，方案 §0.3 玻璃材质）。
///
/// 从 [LiquidGlassContainer] 抽出的通用实现，供顶栏、设置分组卡、弹层等
/// 新场景复用；**默认参数 = Dock 现值**，`LiquidGlassContainer` 直接委托到
/// 本组件（默认形状/模糊/叠色/描边逐项对齐），Dock 视觉与行为不变。
///
/// 视觉分层（自下而上）：
/// 1. [BackdropFilter] 背景模糊（sigma 可调，默认 18），只覆盖容器自身区域；
/// 2. 半透明 surface 叠色（alpha 可调，默认 0.12，跟随主题 colorScheme）；
/// 3. 1px 渐变描边 + 顶部内侧高光线（[showHighlightBorder] 可关）；
/// 4. 可选外投影（[showShadow]，sonify 播放壳玻璃「投影环」的简化等价物，
///    GlassProbe.kt:39-51；默认关，Dock 不受影响）。
///
/// sonify 参数对照（供后续批次调参）：导航容器玻璃 blur 4dp + lens(16,32)
/// （GlassProbe.kt:106）；顶栏回退磨砂 blur 14dp + 页面色 α0.7
/// （Title.kt:976-977）。
///
/// **静态组件、零动画**：动效一律由外层（如 GlassDockPlayer 的收敛型动画）
/// 驱动，本组件只负责一次绘制。
class LiquidGlassSurface extends StatelessWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.shape = GlassShape.pill,
    this.borderRadius = 0,
    this.padding = EdgeInsets.zero,
    this.blurSigma = 18,
    this.fillAlpha = 0.12,
    this.showHighlightBorder = true,
    this.showShadow = false,
    this.shadow = const BoxShadow(
      color: Color(0x40000000),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  });

  /// 容器内容。
  final Widget child;

  /// 外形（胶囊 / 圆形 / 圆角矩形 / 连续曲率圆角矩形）。
  final GlassShape shape;

  /// 圆角半径（仅 roundedRect / smoothRect 时生效）。
  final double borderRadius;

  /// 内容内边距。
  final EdgeInsetsGeometry padding;

  /// 背景模糊强度。
  final double blurSigma;

  /// 叠色不透明度（0.10–0.15 推荐区间，保证内容可读）。
  final double fillAlpha;

  /// 是否绘制 1px 渐变高光描边 + 顶部内侧高光线。
  final bool showHighlightBorder;

  /// 是否绘制外投影（画在裁剪层之外，不会被模糊/叠色裁掉）。
  final bool showShadow;

  /// 外投影参数（仅 [showShadow] 为 true 时生效）。
  final BoxShadow shadow;

  /// 按外形裁剪（同时裁掉模糊层与描边的溢出）。
  ///
  /// 胶囊形的圆角取**实际渲染高度**的一半（StadiumBorder 语义），由
  /// [ClipRRect.clipper] 在布局完成后按真实尺寸计算。不能用
  /// `LayoutBuilder` 的 `constraints.maxHeight`：Dock 场景
  /// （`Positioned(bottom)` → `Align` → `Row`）传下来的是**无界高度（∞）**，
  /// `BorderRadius.circular(∞)` 会让 ClipRRect 退化为矩形裁剪，
  /// 叠色 / 模糊按矩形漏出（装机实测 bug）。
  Widget _clip(Widget child) {
    switch (shape) {
      case GlassShape.circle:
        return ClipOval(child: child);
      case GlassShape.pill:
        return ClipRRect(
          clipper: const _StadiumClipper(),
          child: child,
        );
      case GlassShape.roundedRect:
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: child,
        );
      case GlassShape.smoothRect:
        // sonify 连续曲率（squircle）外形，算法见 squircle.dart
        return SmoothClipRRect(
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

    final glass = _clip(
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
          if (showHighlightBorder)
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

    if (!showShadow) return glass;

    // 外投影：画在裁剪层之外。胶囊用超大圆角近似 Stadium（Skia 对超界
    // 圆角会等比收缩，结果即胶囊）；连续曲率外形用普通圆角近似投影（软阴影
    // 对形状差异不敏感，避免为投影再引入 CustomPainter）。
    final BoxDecoration shadowDecoration;
    switch (shape) {
      case GlassShape.circle:
        shadowDecoration = const BoxDecoration(shape: BoxShape.circle);
      case GlassShape.pill:
        shadowDecoration = BoxDecoration(
          borderRadius: BorderRadius.circular(999),
        );
      case GlassShape.roundedRect:
      case GlassShape.smoothRect:
        shadowDecoration = BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
        );
    }
    return DecoratedBox(
      decoration: shadowDecoration.copyWith(boxShadow: [shadow]),
      child: glass,
    );
  }
}

/// 胶囊形（Stadium）裁剪器：按实际渲染尺寸取圆角（高度一半），
/// 不依赖布局约束，无界高度下也不会退化。
class _StadiumClipper extends CustomClipper<RRect> {
  const _StadiumClipper();

  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(size.height / 2),
      );

  @override
  bool shouldReclip(_StadiumClipper oldClipper) => false;
}

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
    } else if (shape == GlassShape.smoothRect) {
      // 连续曲率外形：沿 squircle 路径描边
      canvas.drawPath(
        smoothCornerPath(
          rect.deflate(0.5),
          topLeft: radius,
          topRight: radius,
          bottomRight: radius,
          bottomLeft: radius,
        ),
        borderPaint,
      );
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
