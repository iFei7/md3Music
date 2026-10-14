import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';

/// 横滑封面卡 Rail（方案 §1.2/§1.3，供首页/搜索空白态横滑分区消费）。
///
/// 布局规格（sonify 出处）：
/// - 横滑列表边缘内边距 18dp（Title.kt:419-420）；
/// - 卡片间距 15dp（网格列间距，Title.kt:416-417）；
/// - 封面尺寸默认 [SonifySpacing.coverRailMin] 150dp，squircle 10dp 圆角
///   （ShadowImage.kt:65），封面阴影 α0.23（ShadowImage.kt:62-65）；
/// - 卡下标题 13sp、副标 13sp 次级灰 #88878E（方案 §1.3）。
///
/// sonify 的「自适应 min 150dp 网格」（AdaptiveImageLayout.kt:9）在横滑 Rail
/// 场景表现为：每个 item 至少 150dp 宽，宽屏消费方可通过传入更大的
/// [itemWidth] 实现自适应放宽（网格版自适应网格由批次 1/4 的分区组件处理）。
class CoverRail extends StatelessWidget {
  const CoverRail({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemWidth = SonifySpacing.coverRailMin,
    this.controller,
  });

  /// 封面卡数量。
  final int itemCount;

  /// 构建 [CoverRailCard]（或任意封面卡 widget）。
  final IndexedWidgetBuilder itemBuilder;

  /// 单卡宽度（默认 150dp，sonify 自适应网格最小图尺寸）。
  final double itemWidth;

  /// 横向滚动控制器（可选）。
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _railHeight(itemWidth),
      child: ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          // 网格边缘内边距 18dp（Title.kt:419-420）
          horizontal: SonifySpacing.gridEdge,
        ),
        itemCount: itemCount,
        // 卡片间距 15dp（网格列间距，Title.kt:416-417）
        separatorBuilder: (_, _) => const SizedBox(width: SonifySpacing.gridH),
        itemBuilder: (context, index) => SizedBox(
          width: itemWidth,
          child: itemBuilder(context, index),
        ),
      ),
    );
  }

  /// Rail 高度 = 封面宽 + 标题区（间距 8 + 13sp 标题单行 + 13sp 副标单行）。
  /// 文本行高按 1.35 估算并留少量余量，保证单行省略时不溢出。
  static double _railHeight(double coverSize) {
    const textBlock = 8.0 + 13 * 1.35 + 13 * 1.35;
    return coverSize + textBlock + 4;
  }
}

/// 单张封面卡：封面（squircle 10dp + 阴影 α0.23 + 1px 白 10% 内描边）
/// + 标题 + 副标。
class CoverRailCard extends StatelessWidget {
  const CoverRailCard({
    super.key,
    required this.cover,
    required this.title,
    this.subtitle,
    this.onTap,
    this.innerBorder = true,
  });

  /// 封面内容（图片 widget，会被裁剪为 1:1 squircle）。
  final Widget cover;

  /// 标题（13sp，单行省略）。
  final String title;

  /// 副标（13sp，次级灰，单行省略，可空）。
  final String? subtitle;

  /// 点击回调（进详情页等）。
  final VoidCallback? onTap;

  /// 是否绘制 1px 白 10% 内描边（lite 既有封面惯例，full_player.dart:1444）。
  final bool innerBorder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sonify = SonifyColors.of(context);
    final coverWidget = SmoothClipRRect(
      borderRadius: BorderRadius.circular(SonifyRadius.cover),
      child: Stack(
        fit: StackFit.expand,
        children: [
          cover,
          if (innerBorder)
            // 1px 白 10% 内描边：浅色封面与浅色背景的轮廓线（lite 惯例）
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(SonifyRadius.cover),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Semantics(
      button: true,
      label: title,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面：静态阴影 α0.23（ShadowImage.kt:62-65）
            AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x3B000000), // 黑 α0.23
                      blurRadius: 12,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: coverWidget,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SonifyTextStyles.listItem.copyWith(color: cs.onSurface),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SonifyTextStyles.listItem
                    .copyWith(color: sonify.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
