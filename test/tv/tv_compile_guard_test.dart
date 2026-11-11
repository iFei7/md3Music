// 批次51：TV 编译守卫探针（口径随入口迁移）。
//
// 背景：批次51 后段起 TV 构建入口 = lib/main_tv.dart（Flutter 多入口，
// `flutter build apk -t lib/main_tv.dart`），TV 编译根不再经 main.dart →
// app.dart 拉入手机 UI 闭包。本探针用 import 强制把 main.dart（手机装配）
// + main_tv.dart（TV 入口编排）+ tv_app.dart（TV 装配）拉进测试内核，使
// 两个构建目标的编译错误在测试步即可暴露（不真跑 App——顶层全局量惰性
// 初始化，import 本身不触发 WidgetsBinding）。TvApp 的 provider 闭包
// （lite providers + tv_ui providers）与路由表 / 壳层装配 / 焦点包装全链
// 在 MD3_TV=true 通道下一并拉进编译。
//
// 运行方式：
// - 普通 `flutter test test/tv/`：kTvBuild=false——验证手机构建侧编译
//   （main.dart → app.dart 纯手机装配）+ main_tv / TvApp 独立编译；
// - `flutter test --dart-define=MD3_TV=true test/tv/`：kTvBuild=true——
//   完整编译 TV 分支（CI tv job 的前置守卫，compile error 在测试步即红）。
// 两通道都必须绿（断言与旗标无关；编译失败由内核阶段直接报错）。
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/main.dart' as entry;
import 'package:md3music/main_tv.dart' as tv_main;
import 'package:md3music/tv_ui/app/tv_app.dart' as tv_entry;

void main() {
  test('main.dart / main_tv.dart / tv_app.dart 在 MD3_TV 两档旗标下均可编译',
      () {
    // 编译依赖由 import 建立（CafeDT/kernel 阶段即完成全量类型检查）；
    // 断言只触碰常量级符号，不初始化 WidgetsBinding（currentState 等
    // 需要 binding 在场，探针不做真机启动验证）。
    expect(entry.appNavigatorKey, isNotNull);
    // 批次51：TV 专用入口 main_tv.dart 编译覆盖（引用其 main 顶层函数）。
    expect(tv_main.main, isNotNull);
    expect(tv_entry.TvApp, isNotNull);
  });
}
