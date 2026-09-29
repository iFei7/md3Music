import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:md3music/core/utils/app_toast.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';

/// 歌词动画调节子页面。
///
/// 集中调节歌词的逐行动画参数与歌词效果强度，全部为**无极**滑块（无档位小圆点）：
/// - 当前行细节：已播字上浮高度
/// - 歌词非当前行缩放
/// - 歌词当前行位置（滚动锚位）
/// - 歌词效果：辉光触发阈值
///
/// AppBar 的重置按钮可**二次确认后**把本页全部参数恢复默认——
/// 注意只重置本页 4 个参数，绝不调用 [LyricPreferences.reset]
/// （那会把字号/行距/动态颜色等不在本页的设置一并清掉）。
///
/// 监听 [LyricPreferences] 实时刷新；拖动中只刷新标签（onChanged），
/// 松手写入偏好（onChangeEnd），避免拖动过程反复触发歌词组件重渲染。
class LyricAnimationSettingsPage extends StatelessWidget {
  const LyricAnimationSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = LyricPreferences.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('歌词动画'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: '恢复本页默认',
            onPressed: () => _confirmResetAll(context, prefs),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: prefs,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _buildSliderTile<double>(
                prefs: prefs,
                title: '歌词非当前行缩放',
                value: prefs.inactiveScale,
                min: LyricPreferences.minInactiveScale,
                max: LyricPreferences.maxInactiveScale,
                label: prefs.inactiveScale.toStringAsFixed(3),
                onChanged: (v) => prefs.setInactiveScale(v),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '歌词当前行位置',
                value: prefs.alignPosition,
                min: LyricPreferences.minAlignPosition,
                max: LyricPreferences.maxAlignPosition,
                label: prefs.alignPosition.toStringAsFixed(2),
                onChanged: (v) => prefs.setAlignPosition(v),
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('当前行细节',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '已播字上浮高度',
                subtitle: '当前行已唱过的字向上浮起的高度（0 = 不上浮）',
                value: prefs.liftHeightPx,
                min: LyricPreferences.minLiftHeightPx,
                max: LyricPreferences.maxLiftHeightPx,
                label: '${prefs.liftHeightPx.toStringAsFixed(1)} px',
                onChanged: (v) => prefs.setLiftHeightPx(v),
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('歌词效果',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              _buildSliderTile<double>(
                prefs: prefs,
                title: '辉光触发阈值',
                subtitle: '触发阈值 = 歌词字长中位数 × 该系数（越小越易触发）',
                value: prefs.glowThresholdFactor,
                min: LyricPreferences.minGlowThresholdFactor,
                max: LyricPreferences.maxGlowThresholdFactor,
                label: prefs.glowThresholdFactor.toStringAsFixed(1),
                onChanged: (v) => prefs.setGlowThresholdFactor(v),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 二次确认后把本页全部参数恢复默认。
  ///
  /// **只重置本页 4 个参数**，绝不调用 [LyricPreferences.reset]
  /// （那会把字号/行距/动态颜色等不在本页的设置一并清掉）。
  Future<void> _confirmResetAll(
    BuildContext context,
    LyricPreferences prefs,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('恢复本页默认值'),
          content: const Text(
            '将把本页全部参数（非当前行缩放、当前行位置、已播字上浮高度、'
            '辉光触发阈值）恢复为默认值，确定继续吗？',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('恢复默认'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    HapticFeedback.mediumImpact();
    await prefs.setInactiveScale(LyricPreferences.defaultInactiveScale);
    await prefs.setAlignPosition(LyricPreferences.defaultAlignPosition);
    await prefs.setLiftHeightPx(LyricPreferences.defaultLiftHeightPx);
    await prefs.setGlowThresholdFactor(LyricPreferences.defaultGlowThresholdFactor);
    showToast('已恢复本页全部默认值');
  }

  /// 构建一个"M3ESlider + 标题/副标题"的无极滑块 tile。
  Widget _buildSliderTile<T extends num>({
    required LyricPreferences prefs,
    required String title,
    String? subtitle,
    required double value,
    required double min,
    required double max,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: Text(label),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: M3ESlider(
            decoration: const M3ESliderDecoration(
                haptic: M3EHapticFeedback.medium),
            // 不传 divisions → 无极连续滑块（无档位小圆点）
            value: value,
            min: min,
            max: max,
            label: label,
            onChanged: onChanged,
            onChangeEnd: onChanged,
          ),
        ),
      ],
    );
  }
}