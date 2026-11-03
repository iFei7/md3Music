import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/build_flags.dart';

/// 批次43：build_flags 纯函数单测（旗标无关——两通道皆可跑）。
///
/// 本文件在两条测试通道下运行：
/// - 普通 `flutter test`：kTvBuild=false，钉住「非 TV 构建零影响」口径——
///   [tvBlurSigma] 恒等返回原值，即使超过 [kTvMaxBlurSigma] 也不钳制
///   （手机端玻璃模糊观感如 LiquidGlassSurface 的 sigma=18 不变）；
/// - `flutter test --dart-define=MD3_TV=true`（CI dart-tests 的 TV 编译
///   守卫步）：kTvBuild=true，钉住「TV 构建钳制」口径——超上限钳到
///   [kTvMaxBlurSigma]（弱 GPU 模糊降载）。
/// 分支由 [kTvBuild] 编译期常量取值，测试按同一常量选择期望值，两通道皆绿。
void main() {
  group('tvBlurSigma（按 kTvBuild 实际旗标取口径）', () {
    test('低于上限恒等返回原值', () {
      expect(tvBlurSigma(4), 4);
      expect(tvBlurSigma(0), 0);
      // sigma <= 上限时不钳制（两档口径一致）
      expect(tvBlurSigma(kTvMaxBlurSigma), kTvMaxBlurSigma);
    });

    test('超过上限：非 TV 透传 / TV 钳到上限', () {
      final input = kTvMaxBlurSigma + 6.0;
      expect(tvBlurSigma(input), kTvBuild ? kTvMaxBlurSigma : input);
      expect(tvBlurSigma(48), kTvBuild ? kTvMaxBlurSigma : 48.0);
    });

    test('常量定义在位', () {
      // kTvBuild 随编译旗标取值：普通通道 false、MD3_TV 通道 true。
      expect(kTvBuild, isA<bool>());
      expect(kTvMaxBlurSigma, 12.0);
      expect(kTvOverscanInset, 48);
      expect(kTvMinTextScale, 1.15);
    });
  });
}
