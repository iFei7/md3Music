// 批次51：TV 编译守卫探针（口径随入口迁移）。
//
// 背景：批次51 起 TV 构建入口 = lib/tv_ui/app/tv_app.dart 的 TvApp（纯 TV
// 应用入口），main.dart kTvBuild 分支直接 runApp(TvApp())；app.dart 的全部
// 自定义 TV 接线已退役，恢复纯手机形态。本探针用 import 强制把 main.dart +
// tv_app.dart 拉进测试内核（app.dart 经 main.dart 的既有 import 传递拉入，
// 其纯手机形态同样被编译核对），使两个构建目标的编译错误在测试步即可暴露
// （不真跑 App——顶层全局量惰性初始化，import 本身不触发 WidgetsBinding）。
// TvApp 的 provider 闭包（lite providers + tv_ui providers）与路由表 /
// 壳层装配 / 焦点包装全链在 MD3_TV=true 通道下一并拉进编译。
//
// 运行方式：
// - 普通 `flutter test test/tv/`：kTvBuild=false——验证手机构建侧编译
//   （main.dart → app.dart 纯手机装配）+ TvApp 独立编译；
// - `flutter test --dart-define=MD3_TV=true test/tv/`：kTvBuild=true——
//   完整编译 TV 分支（CI tv job 的前置守卫，compile error 在测试步即红）。
// 两通道都必须绿（断言与旗标无关；编译失败由内核阶段直接报错）。
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/main.dart' as entry;
import 'package:md3music/tv_ui/app/tv_app.dart' as tv_entry;

void main() {
  test('main.dart / tv_app.dart 在 MD3_TV 两档旗标下均可编译', () {
    // 编译依赖由 import 建立（CafeDT/kernel 阶段即完成全量类型检查）；
    // 断言只触碰常量级符号，不初始化 WidgetsBinding（currentState 等
    // 需要 binding 在场，探针不做真机启动验证）。
    expect(entry.appNavigatorKey, isNotNull);
    expect(tv_entry.TvApp, isNotNull);
  });
}
