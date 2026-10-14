import 'package:flutter/animation.dart';

/// M3 Expressive Motion 常量
///
/// 参考：https://m3.material.io/styles/motion/easing-and-duration
/// M3 Expressive 强调"直觉性物理动效"——弹簧物理优先于固定 cubic 曲线，
/// 让动画带有自然的过冲和回弹感。
///
/// 使用方式：
/// - `AnimatedSwitcher` 的 `switchInCurve` / `switchOutCurve` 用 `expressiveEasing`
/// - 需要弹簧物理时用 `defaultSpring` 构造 `SpringSimulation`
/// - 强调动画（如 FullPlayer 入场）用 `emphasizedEasing` + `emphasisDuration`
class M3ExpressiveMotion {
  M3ExpressiveMotion._();

  /// 默认弹簧描述：阻尼比 0.825，刚度 180，质量 1
  /// 0.825 < 1.0 产生轻微过冲，符合 M3 Expressive"有生命感"的动效
  static final SpringDescription defaultSpring = SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: 180,
    ratio: 0.825,
  );

  /// 默认动画时长 400ms（M3 标准时长，对应 medium duration）
  static const Duration defaultDuration = Duration(milliseconds: 400);

  /// 强调动画时长 600ms（对应 long duration，用于 FullPlayer 入场等）
  static const Duration emphasisDuration = Duration(milliseconds: 600);

  /// Expressive easing：略带过冲的减速曲线
  /// 用于 tab 切换、卡片入场
  static const Curve expressiveEasing = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Emphasized easing：M3 标准 emphasized 缓动
  /// 用于大型状态转换（FullPlayer 展开、对话框入场）
  static const Curve emphasizedEasing = Cubic(0.2, 0.0, 0, 1.0);
}

/// 全局统一动画时长档位（UI 重设计·批次 1 新增）。
///
/// 目标：把 Dock / 页面 / 播放器各自的动画时长收敛到三档，**克制不花哨**——
/// 快档反馈跟手、中档状态切换不拖沓、慢档只留给真正的大型转场。
/// 三档取值参考 M3 duration scale 的短/中段（150 / 250 / 350ms），
/// 有意低于 [M3ExpressiveMotion] 现有的 400/600ms 强调档：两套档位并存，
/// 现有消费方（FullPlayer 入场等）时长不变，页面批次再按语义挑档迁移。
///
/// 使用方式：
/// - 控件微反馈（按压、指示条、小状态切换）→ [AppMotion.fast]
/// - 普通状态切换（Tab 内容、卡片进出、滑块）→ [AppMotion.medium]
/// - 大型转场（弹层、页面级显隐）→ [AppMotion.slow]
/// - 曲线默认配 [AppMotion.emphasizedEasing]（M3 emphasized），
///   需要轻微过冲感时用 [AppMotion.expressiveEasing]。
class AppMotion {
  AppMotion._();

  /// 快档 150ms：即时反馈（按钮按压、图标切换、指示点）。
  /// 低于 200ms 时人眼感知为"跟手"，不会注意到动画本身。
  static const Duration fast = Duration(milliseconds: 150);

  /// 中档 250ms：常规状态切换（内容区切换、卡片显隐、进度刷新）。
  /// M3 duration scale 的 medium 档，覆盖大多数 UI 转场。
  static const Duration medium = Duration(milliseconds: 250);

  /// 慢档 350ms：大型转场（弹层出入、页面级内容替换）。
  /// 只允许用于占据大面积的转场，小元素用慢档会显得"肉"。
  static const Duration slow = Duration(milliseconds: 350);

  /// 标准缓动：M3 standard，加速段与减速段对称，通用兜底曲线。
  static const Curve standardEasing = Cubic(0.4, 0.0, 0.2, 1.0);

  /// 强调缓动：M3 emphasized，进入更快、收尾更缓，
  /// 与 [M3ExpressiveMotion.emphasizedEasing] 同值（此处独立定义为
  /// const，供 [AppMotion] 自成体系引用，不产生跨类耦合）。
  static const Curve emphasizedEasing = Cubic(0.2, 0.0, 0, 1.0);

  /// Expressive 缓动：略带过冲的减速曲线（同 [M3ExpressiveMotion.expressiveEasing]）。
  static const Curve expressiveEasing = Cubic(0.05, 0.7, 0.1, 1.0);
}
