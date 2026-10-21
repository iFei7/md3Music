import 'package:material_ui/material_ui.dart';

import 'liquid_glass_surface.dart';

/// 顶栏圆形液态玻璃按钮（42dp 圆 + 20dp 图标）。
///
/// 批次 21 首页首次引入（原 discover_page._buildGlassCircleButton），
/// 批次 23 抽为公共组件：听书页顶栏常驻搜索钮、搜索页坍缩态搜索钮、
/// 本地音乐页顶栏搜索钮、首页搜索/识曲双钮共用同一份配方，保证
/// 「主页管理各页搜索圆钮完全同款」（用户反馈口径：样式与主页一致）。
///
/// 配方（一字不可改，改动=视觉分裂）：
/// - [LiquidGlassSurface] + [GlassShape.circle]；
/// - 42×42 容器 + [IconButton] 约束顶满（默认 48dp 会溢出圆钮）；
/// - padding 0、iconSize 20。
class GlassCircleButton extends StatelessWidget {
  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// 无障碍提示（null 时按钮无语义标签，仅图标）。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      shape: GlassShape.circle,
      child: SizedBox(
        width: kGlassCircleButtonSize,
        height: kGlassCircleButtonSize,
        child: IconButton(
          // 顶满玻璃圆钮（默认 48dp 会溢出 42dp 容器）
          constraints: BoxConstraints.tightFor(
            width: kGlassCircleButtonSize,
            height: kGlassCircleButtonSize,
          ),
          padding: EdgeInsets.zero,
          tooltip: tooltip,
          icon: Icon(icon, size: kGlassCircleButtonIconSize),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// 圆钮直径（sonify Title.kt:849-873 材质规格）。
const double kGlassCircleButtonSize = 42;

/// 圆钮图标尺寸。
const double kGlassCircleButtonIconSize = 20;
