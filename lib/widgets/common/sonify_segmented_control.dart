import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';
import 'liquid_glass_surface.dart';

/// iOS 风格通用分段控件（音乐库方案 §2.3，可反哺其他页面）。
///
/// 结构与规格：
/// - 容器：[LiquidGlassSurface]（smoothRect / squircle
///   [SonifyRadius.card] 9dp），高 44dp（内边距 [AppSpacing.xs] 4dp，
///   选中段胶囊高 36dp），水平铺满（外边距由调用方承担）；
/// - 分段：均分 [segments] 数量，选中段为反白胶囊浮层（
///   [SonifyColors.surfaceCard] 底 + onSurface 主文字色 w500），
///   未选中段 [SonifyColors.textSecondary]；文字 [SonifyTextStyles.body]；
/// - 动效：选中胶囊 150ms 位移（[SonifyMotion.glassAlpha] 同拍）；
/// - 触觉：切换时 [HapticFeedback.selectionClick]。
///
/// 静态受控组件：选中态由 [selectedIndex] 驱动，点按回调 [onChanged]。
class SonifySegmentedControl extends StatelessWidget {
  const SonifySegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
  });

  /// 分段文案（顺序即布局顺序）。
  final List<String> segments;

  /// 当前选中段下标。
  final int selectedIndex;

  /// 点按某段时回调（含重复点当前段）。
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final sonify = SonifyColors.of(context);
    return SizedBox(
      height: 44,
      child: LiquidGlassSurface(
        shape: GlassShape.smoothRect,
        borderRadius: SonifyRadius.card,
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final segmentWidth = width / segments.length;
            return Stack(
              children: [
                // 选中胶囊浮层：150ms 位移（SonifyMotion.glassAlpha 同拍）
                AnimatedPositioned(
                  duration: SonifyMotion.glassAlpha,
                  curve: Curves.easeOut,
                  left: selectedIndex * segmentWidth,
                  width: segmentWidth,
                  top: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: sonify.surfaceCard,
                      shape: SmoothRectangleBorder(
                        borderRadius: BorderRadius.circular(SonifyRadius.card),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < segments.length; i++)
                      Expanded(
                        child: InkWell(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            onChanged(i);
                          },
                          borderRadius: BorderRadius.circular(SonifyRadius.card),
                          child: Center(
                            child: Text(
                              segments[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: SonifyTextStyles.body.copyWith(
                                color: i == selectedIndex
                                    ? Theme.of(context).colorScheme.onSurface
                                    : sonify.textSecondary,
                                fontWeight: i == selectedIndex
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
