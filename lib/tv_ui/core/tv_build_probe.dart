// 批次51：TV 旗标探针——仅 kTvBuild=true 构建编译进 libapp.so 的常量，
// 供 CI 在 --obfuscate 下校验 --dart-define=MD3_TV 确实生效（类名已被
// 混淆不可检索，字符串常量不受影响）。
//
// 防剔除论证：本常量被 TvMainShell.build（tv_ui/core/layout/tv_shell.dart）
// 引用并写入 Semantics.label（恒可达的 TV 主壳层 widget 属性）。AOT 编译器
// 的树摇只剔除「不可达代码」与「const 折叠后为假的分支」，不会剥离被可达
// 代码引用的字符串字面量——该串随 Semantics 构造调用进入 AOT snapshot，
// 最终以 ASCII 明文存在于 libapp.so，可被 CI grep 检索。
// 不能用 assert 承载（release 下 assert 整体剔除）；也不用 debugPrint
// （release 下为 no-op，调用可能被折叠）。
import 'package:md3music/core/build_flags.dart';

const String kTvBuildProbe = kTvBuild ? 'MD3_TV_ACTIVE_probe_b50' : '';
