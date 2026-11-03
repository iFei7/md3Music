import 'package:flutter/widgets.dart';

/// tv: 设计稿像素换算作用域（批次43 契约文件，T2 会扩展）。
///
/// **最小实现**：本文件由批次43 主控先创建以满足 tv_shell.dart 的编译
/// 依赖，仅包含 [TvLayoutScale] 契约类；设计 token、颜色、字号体系由
/// T2 并行扩展（`lib/tv/design/` 归 T2 所有）。
///
/// 契约（与 tv_shell.dart 的接口，不得破坏）：
/// - [TvLayoutScale] 是 StatelessWidget：LayoutBuilder 按
///   `constraints.maxWidth / 1920` 计算 scale 并 clamp(0.5, 2.0)；
/// - `TvLayoutScale.of(context)`：取最近作用域的 scale，不在作用域内时
///   兜底返回 1.0（单测裸挂载 / 未包壳时布局不炸）；
/// - child 树内用 `TvLayoutScale.of(context) * 设计px` 换算。
class TvLayoutScale extends StatelessWidget {
  const TvLayoutScale({super.key, required this.child});

  /// 设计稿基准宽度（TV 1080p 横屏）。
  static const double kDesignWidth = 1920;

  /// scale 下限 / 上限：超宽屏不无限放大、小窗不无限缩小。
  static const double kMinScale = 0.5;
  static const double kMaxScale = 2.0;

  final Widget child;

  /// 取最近 [TvLayoutScale] 作用域的 scale；不在作用域内时兜底 1.0。
  static double of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_TvLayoutScaleScope>();
    return scope?.scale ?? 1.0;
  }

  /// 便捷换算：设计稿 px → 当前 scale 下的逻辑 px。
  ///
  /// 批次43：文本统一经本方法换算（×scale）。字号不再叠加
  /// MediaQuery.textScaler 二次缩放——TV 固定大屏（1080p 观看距离 3m+），
  /// 系统字体缩放对大字号反而易引发行溢出，故刻意省略（规范允许）。
  static double px(BuildContext context, double designPx) =>
      of(context) * designPx;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double scale = constraints.maxWidth.isFinite
            ? (constraints.maxWidth / kDesignWidth).clamp(kMinScale, kMaxScale)
            : 1.0;
        return _TvLayoutScaleScope(scale: scale, child: child);
      },
    );
  }
}

/// 向后代暴露当前 scale 的 InheritedWidget（私有，经 [TvLayoutScale.of] 消费）。
class _TvLayoutScaleScope extends InheritedWidget {
  const _TvLayoutScaleScope({required this.scale, required super.child});

  final double scale;

  @override
  bool updateShouldNotify(_TvLayoutScaleScope oldWidget) =>
      scale != oldWidget.scale;
}

/// tv: 色板静态常量（批次43）。
///
/// 品牌色**不入此类**：走 `ThemeProvider.effectiveSeedColor` 动态取
/// （与手机端主题一致；规范的极光绿/赛博红是批次44 TV 设置页的 seed 选项）。
class TvColors {
  TvColors._();

  /// 页面基底色（刻意不用纯黑，暗部仍有层次）。
  static const Color base = Color(0xFF08090C);

  /// 主文字。
  static const Color white = Color(0xFFFFFFFF);

  /// 次要文字（歌手/专辑/时长等辅助信息）。
  static const Color secondary = Color(0xFF8E929E);

  /// 失效态。
  static const Color disabled = Color(0xFF4E515A);

  /// 进度轨道。
  static const Color track = Color(0xFF2A2D37);
}

/// tv: 字号/字重静态样式工厂（批次43）。
///
/// 全部以设计稿 px 为基准，`scale` 参数在返回时内乘
/// （`TvType.songTitle(TvLayoutScale.of(context))`）；颜色除注明外为主文字白。
class TvType {
  TvType._();

  /// 歌名：48 Bold。
  static TextStyle songTitle([double scale = 1.0]) => TextStyle(
    fontSize: 48 * scale,
    fontWeight: FontWeight.w700,
    color: TvColors.white,
    height: 1.2,
  );

  /// 当前歌词行：42 Medium。
  static TextStyle currentLyric([double scale = 1.0]) => TextStyle(
    fontSize: 42 * scale,
    fontWeight: FontWeight.w500,
    color: TvColors.white,
    height: 1.3,
  );

  /// 行标题（导航分组标题等）：32 Bold。
  static TextStyle sectionTitle([double scale = 1.0]) => TextStyle(
    fontSize: 32 * scale,
    fontWeight: FontWeight.w700,
    color: TvColors.white,
    height: 1.3,
  );

  /// 导航项与普通歌词：26。
  static TextStyle body([double scale = 1.0]) => TextStyle(
    fontSize: 26 * scale,
    fontWeight: FontWeight.w400,
    color: TvColors.white,
    height: 1.4,
  );

  /// 歌手/专辑等次要信息：24 次要灰。
  static TextStyle subtitle([double scale = 1.0]) => TextStyle(
    fontSize: 24 * scale,
    fontWeight: FontWeight.w400,
    color: TvColors.secondary,
    height: 1.4,
  );

  /// 时长等数字：20 Light。
  static TextStyle duration([double scale = 1.0]) => TextStyle(
    fontSize: 20 * scale,
    fontWeight: FontWeight.w300,
    color: TvColors.secondary,
    fontFeatures: const [/* 等宽数字可后续加 tabularFigures */],
  );

  /// 数量标签：18。
  static TextStyle countLabel([double scale = 1.0]) => TextStyle(
    fontSize: 18 * scale,
    fontWeight: FontWeight.w400,
    color: TvColors.secondary,
  );
}

/// tv: 动效时长/曲线常量（批次43，规范终版值）。
class TvMotion {
  TvMotion._();

  /// 切歌动态背景溶解时长（Z1）。
  static const Duration bgSwitch = Duration(milliseconds: 600);

  /// 卡片/控件焦点动效时长。
  static const Duration focus = Duration(milliseconds: 150);

  /// 控制条无操作自动隐藏等待。
  static const Duration controlBarAutoHide = Duration(milliseconds: 3500);

  /// 控制条淡出（淡入同用，规范只约束淡出 600ms，对称复用）。
  static const Duration controlBarFade = Duration(milliseconds: 600);

  /// 歌词行滚动时长（复用的 AppleMusicLyricsView 内部为 300ms easeOut，
  /// 此常量供 TV 侧自有滚动场景对齐）。
  static const Duration lyricsScroll = Duration(milliseconds: 300);

  /// 黑胶转速 33.3RPM ≈ 18s/圈：播放时匀速旋转周期。
  static const Duration vinylRevolution = Duration(seconds: 18);

  /// 暂停时黑胶平滑减速滑行时长（简化实现：减速曲线滑行 ~8% 圈，
  /// 非物理精确的角速度衰减，规范允许简化）。
  static const Duration vinylCoastDown = Duration(milliseconds: 900);

  /// 通用焦点/淡入淡出曲线。
  static const Curve easeOut = Curves.easeOutCubic;
}

/// tv: 画布与安全区常量（批次43）。
///
/// 1920×1080 基准；安全区 X:96~1824 / Y:96~984（比例 5%）。
class TvSafeArea {
  TvSafeArea._();

  /// 安全区比例（5%）。
  static const double kTvSafeFraction = 0.05;

  /// 设计稿基准尺寸。
  static const double designWidth = 1920;
  static const double designHeight = 1080;

  /// 安全区边界（design px）。
  static const double safeLeft = 96;
  static const double safeTop = 96;
  static const double safeRight = 1824;
  static const double safeBottom = 984;
}
