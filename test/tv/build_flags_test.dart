import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/build_flags.dart';

/// 批次43：build_flags 纯函数单测。
///
/// `flutter test` 不带 `--dart-define=MD3_TV`，kTvBuild 恒为 false——
/// 恰好钉住「非 TV 构建零影响」口径：[tvBlurSigma] 必须恒等返回原值，
/// 即使 sigma 超过 [kTvMaxBlurSigma] 也不得钳制（钳制只在 TV 构建生效）。
/// TV 构建分支（sigma 超上限钳到 kTvMaxBlurSigma）无法在普通测试通道
/// 执行（const false 分支被编译期剔除），由 CI tv job 的 DpadFocusable
/// 符号校验兜底。
void main() {
  group('tvBlurSigma（非 TV 构建）', () {
    test('恒等返回原值——低于上限', () {
      expect(tvBlurSigma(18), 18);
      expect(tvBlurSigma(4), 4);
      expect(tvBlurSigma(0), 0);
    });

    test('恒等返回原值——超过 kTvMaxBlurSigma 也不钳制', () {
      // TV 构建下该值会被钳到 kTvMaxBlurSigma(12)；非 TV 必须原样透传，
      // 保证手机端玻璃模糊观感（如 LiquidGlassSurface 的 sigma=18）不变。
      expect(tvBlurSigma(kTvMaxBlurSigma + 6), kTvMaxBlurSigma + 6);
      expect(tvBlurSigma(48), 48);
    });

    test('常量定义在位', () {
      expect(kTvBuild, isFalse);
      expect(kTvMaxBlurSigma, 12.0);
      expect(kTvOverscanInset, 48);
      expect(kTvMinTextScale, 1.15);
    });
  });
}
