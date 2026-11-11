// 批次43：TV 编译守卫探针（批次50 沿用，注释更新）。
//
// 背景：app.dart / main.dart 的 TV 分支（kTvBuild 恒真路径：_tvContentScope /
// _MainLayout 的 TvMainShell 壳层分支 / tv_ui FullPlayer 路由 / TV 媒体键
// 兜底等）没有任何既有测试导入——普通 flutter test 编译不到它们，唯一编译
// 时机是 CI 的 TV APK 构建（--dart-define=MD3_TV=true）。本探针用 import
// 强制把 app.dart + main.dart 拉进测试内核，使 TV 分支的编译错误在测试步
// 即可暴露（不真跑 App——顶层全局量惰性初始化，import 本身不触发
// WidgetsBinding）。批次50 起 TV 分支消费 lib/tv_ui/ 全量（五大页面映射 /
// RemoteControlProvider / TvPlayerBackFallback / TvImeProxyBridge 等），
// 本探针在 MD3_TV=true 通道下把这些链路一并拉进编译。
//
// 运行方式：
// - 普通 `flutter test test/tv/`：kTvBuild=false——验证手机构建侧编译；
// - `flutter test --dart-define=MD3_TV=true test/tv/`：kTvBuild=true——
//   完整编译 TV 分支（CI tv job 的前置守卫，compile error 在测试步即红）。
// 两通道都必须绿（断言与旗标无关；编译失败由内核阶段直接报错）。
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/app.dart';
import 'package:md3music/main.dart' as entry;

void main() {
  test('app.dart / main.dart 在 MD3_TV 两档旗标下均可编译', () {
    // 编译依赖由 import 建立（CafeDT/kernel 阶段即完成全量类型检查）；
    // 断言只触碰常量级符号，不初始化 WidgetsBinding（currentState 等
    // 需要 binding 在场，探针不做真机启动验证）。
    expect(entry.appNavigatorKey, isNotNull);
    expect(MyApp, isNotNull);
  });
}
