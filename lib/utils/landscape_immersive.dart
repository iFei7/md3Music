import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 全屏播放器 Zen 模式「实际生效」的沉浸状态。
///
/// 由 MD3 / AM 两套全屏播放器在进入/退出 Zen 时置位；主界面 [_SystemUiUpdater]
/// 据此跳过系统栏覆盖，避免亮屏 resumed、切歌重建等场景把 Zen 的
/// immersiveSticky 冲掉、导致状态栏重新显示。参照 kCoverFlowImmersiveActive 模式。
final ValueNotifier<bool> kPlayerZenImmersiveActive = ValueNotifier<bool>(false);

/// 封面流横屏沉浸相关状态（原定义于已下线的 coverflow 模块，因全屏播放器
/// 退出时需感知「仍处于封面流沉浸」而保留在此）。
///
/// [kCoverFlowImmersive] 为用户请求语义，[kCoverFlowImmersiveActive] 为
/// 「实际生效」状态；封面流 tab 下线后恒为 false，仅作为播放器侧系统栏
/// 决策的兼容信号存在。
final ValueNotifier<bool> kCoverFlowImmersive = ValueNotifier<bool>(false);

/// 封面流页横屏「实际生效」的沉浸状态（封面流 tab 下线后恒为 false）。
final ValueNotifier<bool> kCoverFlowImmersiveActive = ValueNotifier<bool>(false);

/// 全屏播放器横屏沉浸（非 Zen）「实际生效」状态。
///
/// 横屏下 [applyImmersiveForOrientation] 启用 immersiveSticky 隐藏系统栏；
/// 由 MD3 / AM 播放器在所有系统栏决策点同步，主界面 [_SystemUiUpdater] 据此
/// 跳过覆盖，避免切歌/亮屏把横屏沉浸冲掉（与 Zen 同源问题）。参照 kCoverFlowImmersiveActive 模式。
final ValueNotifier<bool> kPlayerLandscapeImmersiveActive = ValueNotifier<bool>(false);

/// 全屏播放器「横屏自动隐藏系统栏」开关（设置 → 播放 → 横屏隐藏状态栏），默认开启。
///
/// 由 main.dart 启动引导从设置恢复、由设置页开关即时同步。
/// 仅影响横屏自动沉浸；Zen 模式（用户长按封面主动进入）不受此开关影响。
bool kLandscapeImmersiveEnabled = true;

/// 全屏播放器系统栏样式（默认值）：透明 + 恒浅色图标。
///
/// 作为 PlayerSystemUiScope 的 expandedOverlayStyle 兜底（未显式传入时）；
/// md 播放器按主题亮度传入自有样式（full_player.dart 的 mdOverlayStyle：
/// 浅色主题黑字 / 深色主题白字）。
///
/// **不再由 [applyImmersiveForOrientation] 直设**：竖屏 edgeToEdge 下系统栏
/// 样式由播放器的 AnnotatedRegion（PlayerSystemUiScope）单一数据源驱动，
/// 直设会与其竞态，造成展开完成时刻图标亮度跳变（详见该函数注释）。
const SystemUiOverlayStyle kPlayerOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Color(0x00000000),
  statusBarIconBrightness: Brightness.light,
  systemNavigationBarColor: Color(0x00000000),
  systemNavigationBarIconBrightness: Brightness.light,
);

/// 主页面（非播放器）系统栏样式：全屏播放器拖拽展开期间使用。
///
/// **必须与主页面的稳态样式取值完全一致**，否则 RenderView._updateSystemChrome
/// 每帧合并出的样式会在拖拽起点 / settle 末段发生跳变，平台侧系统栏反复重设
/// （真机反馈：Dock 上滑过程中状态栏 / 导航栏颜色不停跳变）。主页面的稳态
/// 样式 = 各页 AppBar 的 `appBarTheme.systemOverlayStyle` 注解
/// （app_theme.dart：透明状态栏 + 主题亮度图标 + statusBarBrightness，
/// **不含任何导航栏属性**——导航栏处无注解，合并结果为 null = 不改动），
/// 叠加 app 级 applyMainEdgeToEdge 已应用的透明导航栏。
/// 因此这里刻意**不设 systemNavigationBar* 属性**：一旦设了（如此前的
/// surface 底色），覆盖层 / 路由的 FullPlayer 注解在拖拽第一帧盖住导航栏
/// 采样点，合并样式立即多出导航栏取值 → 一次真实的平台调用 → 导航栏颜色
/// 从透明跳为不透明（edgeToEdge 生效前的设备 / 未强制 edge-to-edge 的场景
/// 下直接可见）。
SystemUiOverlayStyle mainPageOverlayStyle(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: const Color(0x00000000),
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
  );
}

/// 根据当前屏幕方向启用或禁用全屏沉浸模式。
///
/// - 横屏（landscape）：[kLandscapeImmersiveEnabled] 开启时启用
///   [SystemUiMode.immersiveSticky]，隐藏状态栏和导航栏；关闭时按竖屏处理。
/// - 竖屏（portrait）：主界面本就是 [SystemUiMode.edgeToEdge]（见
///   [applyMainEdgeToEdge]），**无需任何模式切换**；仅当从沉浸态
///   （Zen / 横屏沉浸）退出时才需要 manual 显式恢复系统栏再切回 edgeToEdge
///   （部分设备从 immersiveSticky 直接切 edgeToEdge 时状态栏不会自动重新显示）。
///
/// **不再直设 [SystemChrome.setSystemUIOverlayStyle]**：竖屏 edgeToEdge 下
/// 系统栏样式由 FullPlayer 的 AnnotatedRegion（[PlayerSystemUiScope]）单一
/// 数据源驱动。此前此处直设 [kPlayerOverlayStyle]（恒浅色图标）会与播放器
/// 自己的主题亮度图标注解竞态——展开完成一帧内图标深浅跳变；且
/// manual→edgeToEdge 的模式往返会引发 didChangeMetrics 回灌，app 级
/// _SystemUiUpdater 再次覆写，形成多数据源混战（真机反馈：上滑过程系统栏
/// 颜色不停跳变）。
///
/// 返回值：是否实际切换过系统 UI 模式（调用方据此决定 dispose 时是否需要
/// [restoreSystemUi] 恢复）。
///
/// 调用时机：
/// - 全屏播放器 initState 时首次调用（didChangeDependencies，tap 模式立即、
///   拖拽模式延迟到展开完成，避免拖动过程系统栏提前闪烁）
/// - didChangeMetrics 回调中调用（用户旋转设备时响应）
/// - 退出 Zen 模式时调用（fromImmersive: true）
bool applyImmersiveForOrientation({bool fromImmersive = false}) {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final isLandscape = view.physicalSize.width > view.physicalSize.height;
  if (isLandscape && kLandscapeImmersiveEnabled) {
    // 横屏：完全沉浸，隐藏状态栏和导航栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    return true;
  }
  if (!fromImmersive) {
    // 竖屏且本就处于 edgeToEdge：无模式可切，系统栏样式交给 AnnotatedRegion
    return false;
  }
  // 竖屏 / 横屏但已关闭沉浸：从沉浸态退出，先强制恢复系统栏显示：从
  // immersiveSticky（zen/横屏）切到 edgeToEdge 时，部分设备状态栏不会自动
  // 重新显示，必须先 manual 显式 show 再切 edgeToEdge。
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: SystemUiOverlay.values,
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  return true;
}

/// 主界面恒定沉浸式系统栏：状态栏与底部导航条完全透明，内容延伸到系统栏之后。
///
/// 主界面以及「从全屏播放器返回」的恢复路径都应调用本函数，避免使用
/// [SystemUiMode.manual]：targetSdk 35 起 Android 15 强制 edge-to-edge，
/// manual 会与系统强制行为叠出「新旧两套表现」。
///
/// 另需在首帧之后再调一次：冷启动时首帧前设置的 edgeToEdge 会被随后原生
/// LaunchTheme → NormalTheme 的切换（发生在 Flutter 首帧之后）冲掉，
/// 表现为「底部导航条不沉浸，直到用户改一次设置才恢复」。
void applyMainEdgeToEdge({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: const Color(0x00000000),
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: const Color(0x00000000),
      systemNavigationBarDividerColor: const Color(0x00000000),
      systemNavigationBarContrastEnforced: false,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    ),
  );
}

/// 退出全屏播放器时恢复系统栏显示。
///
/// 恢复目标不是 [SystemUiMode.manual]，而是与主界面完全一致的「恒定沉浸」
/// （edgeToEdge + 透明状态栏 / 导航条）：用 manual 会让返回主界面后的系统栏
/// 状态与冷启动直入不一致，必须等下一次 [_updateSystemUi] 才纠正。
void restoreSystemUi({Brightness? statusBarBrightness}) {
  applyMainEdgeToEdge(
    brightness: statusBarBrightness ?? Brightness.light,
  );
}
