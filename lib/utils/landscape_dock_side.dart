import 'package:flutter/foundation.dart';

/// 横屏悬浮 Dock（纵向导航条 + 独立播放球）的贴边方向（批次36）。
///
/// 用户口径：「支持设置选择悬浮 dock 在左在右（在哪哪边内容就要避让）。」
///
/// 与既有 [kLandscapeImmersiveEnabled]（landscape_immersive.dart）同模式：
/// - **持久化**：SettingsRepository `settings_landscape_dock_side`；
/// - **启动恢复**：main.dart 在 runApp 前读入并写入 [kLandscapeDockSide]；
/// - **即时生效**：设置页修改时直接改 [kLandscapeDockSide]（ValueNotifier），
///   Dock 布局（glass_dock_player.dart）与页面避让注入（app.dart）都监听它，
///   无需重启或切页。
///
/// 默认 [right] = 批次35 起的既有行为（右侧纵条），保证默认配置逐字节不变。
enum LandscapeDockSide {
  /// 贴屏幕左侧（纵条/球在左，展开体向右伸出，内容左侧避让）。
  left,

  /// 贴屏幕右侧（纵条/球在右，展开体向左伸出，内容右侧避让）——默认。
  right;

  /// 从持久化字符串解析；未知值 / 空值一律回落 [right]（历史脏值安全）。
  static LandscapeDockSide fromStorage(String? raw) {
    for (final side in LandscapeDockSide.values) {
      if (side.name == raw) return side;
    }
    return LandscapeDockSide.right;
  }
}

/// 当前生效的横屏 Dock 贴边方向（全局单一数据源，批次36）。
///
/// 用 ValueNotifier 而非裸 bool：设置页切换后 Dock 与页面避让需**即时**
/// 重建，监听者各自 addListener 即可（Dock 段 setState、app.dart 主布局
/// setState、MaterialApp builder 经 Listenable.merge 重建二级页避让）。
final ValueNotifier<LandscapeDockSide> kLandscapeDockSide =
    ValueNotifier<LandscapeDockSide>(LandscapeDockSide.right);
