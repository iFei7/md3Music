import 'package:material_ui/material_ui.dart';

import '../../widgets/common/liquid_glass_surface.dart';

export '../../widgets/common/liquid_glass_surface.dart'
    show GlassShape, LiquidGlassSurface;

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
///
/// sonify 重设计批次 0：实现已抽到参数化的 [LiquidGlassSurface]
/// （lib/widgets/common/liquid_glass_surface.dart），本组件保留原有构造签名
/// 并以**默认参数**委托——blur 18 / fillAlpha 0.12 / 高光描边开 / 投影关，
/// 与抽取前逐项一致，Dock 视觉与行为不变（坍缩球几何/进度环/28% 遮罩等
/// 近期打磨不回退）。
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

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      shape: shape,
      borderRadius: borderRadius,
      padding: padding,
      blurSigma: blurSigma,
      fillAlpha: fillAlpha,
      showHighlightBorder: true,
      showShadow: false,
      child: child,
    );
  }
}
