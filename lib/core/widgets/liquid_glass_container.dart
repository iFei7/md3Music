import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../theme/app_dimens.dart';

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
/// 视觉参数已全部收编到 [AppGlass] token（UI 重设计·批次 1）：描边参数在
/// paint 路径按深浅色引用 token 组，构造默认值为与 [AppGlass.dark] 逐项
/// 相等的字面量（Dart 构造默认值无法引用实例字段，见参数处注释），
/// 现有渲染零变化；深浅色参数组见 [AppGlass.dark] / [AppGlass.light]
/// （当前取值相同，等价基线）。
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
    // 默认值与 AppGlass.dark token 逐项相等（构造默认值必须是常量字面量，
    // 无法直接引用实例字段；改 token 时需同步这里，AppGlass 注释已标注）。
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
          // 1px 渐变描边 + 顶部内侧高光线（参数按深浅色取 token 组，
          // 当前两组等价，渲染与收编前逐项一致）。
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _GlassBorderPainter(
                  shape: shape,
                  borderRadius: borderRadius,
                  borderColor: borderColor,
                  params: AppGlass.of(cs.brightness),
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
    required this.params,
  });

  final GlassShape shape;
  final double borderRadius;
  final Color borderColor;

  /// 玻璃描边参数（来自 [AppGlass] token，深浅色各一组）。
  final GlassParams params;

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
        Colors.white.withValues(alpha: params.borderHighlightAlpha),
        borderColor.withValues(alpha: params.borderFadeAlpha),
      ],
    ).createShader(rect);

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppGlass.borderStrokeWidth
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
        Colors.white.withValues(alpha: params.topHighlightAlpha),
        Colors.transparent,
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(rect);

    final highlightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppGlass.borderStrokeWidth
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
        oldDelegate.borderColor != borderColor ||
        oldDelegate.params != params;
  }
}
