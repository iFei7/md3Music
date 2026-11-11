// 批次50：TV 命名空间兼容层——上游 build_flags/player_provider 新增全局旗标
// 与模块级状态（lite 无对应物）。上游原值搬运。

/// 上游 build_flags.dart：端侧分离编译期闸门（lite 恒不可用，树摇剔除调用方）。
const bool kFullBuild = false;
const bool kStemSeparationAvailable = kFullBuild;

/// 上游 player_provider.dart：mini_player 跳过下一次入场动画的模块级旗标。
bool kMiniPlayerSkipNextEntrance = false;
