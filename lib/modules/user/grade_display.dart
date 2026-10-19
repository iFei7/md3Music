import 'package:material_ui/material_ui.dart';

import '../../services/kugou_api/kugou_models.dart';

/// 秒数 → 可读时长，精确到分钟：X天Y小时Z分 / X小时Y分 / X分钟。
///
/// 从 user_center_page._formatGradeSeconds 抽取为共享纯函数（原实现逐字迁移，
/// 格式保持不变），供用户中心等级区块与设置页账号卡迷你等级行共用，
/// 避免两处格式漂移。null / 非正值按 0 处理（显示「0分钟」）。
String formatGradeSeconds(int? seconds) {
  final sec = seconds ?? 0;
  if (sec <= 0) return '0分钟';
  final d = sec ~/ 86400;
  final h = (sec % 86400) ~/ 3600;
  final m = (sec % 3600) ~/ 60;
  if (d > 0) return '$d天$h小时$m分';
  if (h > 0) return '$h小时$m分';
  return '$m分钟';
}

/// 迷你等级行（一行）：`Lv.{等级} · 听歌 {累计时长}`。
///
/// 供设置页账号卡等紧凑位复用；无等级数据（未登录 / 冷启动尚未拉到
/// gradeInfo）时显示 [placeholder] 占位文案。文字样式由调用方通过
/// [style] 传入（设置页传 sonify 次级灰，用户中心可传主题样式）。
class GradeBriefChip extends StatelessWidget {
  const GradeBriefChip({
    super.key,
    required this.grade,
    this.placeholder = '登录后查看等级与听歌时长',
    this.style,
  });

  /// 听歌等级信息；null 表示未登录或无数据。
  final KugouGradeInfo? grade;

  /// 无数据时的占位文案。
  final String placeholder;

  /// 文字样式（由调用方按所在页面风格传入）。
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final g = grade;
    if (g == null) {
      return Text(
        placeholder,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    // 累计听歌秒：优先服务器权威 d_sec，缺失时退回近似 duration
    final sec = g.dSec ?? g.duration ?? 0;
    return Text(
      'Lv.${g.pGrade ?? 0} · 听歌 ${formatGradeSeconds(sec)}',
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
