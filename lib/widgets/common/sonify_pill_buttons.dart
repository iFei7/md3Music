import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/squircle.dart';

/// 详情页集中操作条胶囊按钮（方案 §5.3）：
/// - 播放全部：48dp 高胶囊、squircle 24dp（48/2，保留 sonify 连续曲率）、
///   primary 底、白字 16sp Medium；
/// - 随机播放/次级动作：同高描边胶囊、卡底色（[SonifyColors.surfaceCard]）。
///
/// 热区 ≥44dp：按钮本体 48dp 高（sonify 无 44dp 约束，48dp 为方案 §5.3 指定）。
class SonifyPrimaryPillButton extends StatelessWidget {
  const SonifyPrimaryPillButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _PillButton(
      onPressed: onPressed,
      background: cs.primary,
      foreground: cs.onPrimary,
      icon: icon,
      label: label,
    );
  }
}

class SonifySecondaryPillButton extends StatelessWidget {
  const SonifySecondaryPillButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final sonify = SonifyColors.of(context);
    final cs = Theme.of(context).colorScheme;
    return _PillButton(
      onPressed: onPressed,
      background: sonify.surfaceCard,
      foreground: cs.onSurface,
      // 描边款：1dp 边界线（sonify 卡片描边同语义，取 outlineVariant）
      border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      icon: icon,
      label: label,
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.onPressed,
    required this.background,
    required this.foreground,
    required this.icon,
    required this.label,
    this.border,
  });

  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;
  final IconData icon;
  final String label;
  final Border? border;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final effectiveForeground =
        disabled ? foreground.withValues(alpha: 0.38) : foreground;
    return SizedBox(
      height: 48,
      child: Material(
        // 胶囊 48dp 高：半径 24 的 squircle（方案 §5.3「squircle 24dp 胶囊」）
        shape: SmoothRectangleBorder(borderRadius: BorderRadius.circular(24)),
        color: disabled ? background.withValues(alpha: 0.38) : background,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: SmoothRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: border?.top ?? BorderSide.none,
            ),
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: effectiveForeground),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SonifyTextStyles.body.copyWith(
                        color: effectiveForeground,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
