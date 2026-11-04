import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_offload_config.dart';

void main() {
  // 批次44：硬解播放（audio offload）的最终判决只取决于两个布尔量。
  // 真值表覆盖「用户开关 × 音效链是否在用」四种组合。
  group('AudioOffloadConfig.shouldEnable', () {
    test('用户关闭 + 无音效 → 不下发', () {
      expect(
        AudioOffloadConfig.shouldEnable(userEnabled: false, dspActive: false),
        isFalse,
      );
    });

    test('用户开启 + 无音效 → 下发', () {
      expect(
        AudioOffloadConfig.shouldEnable(userEnabled: true, dspActive: false),
        isTrue,
      );
    });

    test('用户关闭 + 有音效 → 不下发', () {
      expect(
        AudioOffloadConfig.shouldEnable(userEnabled: false, dspActive: true),
        isFalse,
      );
    });

    test('用户开启 + 有音效 → 不下发（offload 会绕过整条 AudioProcessor 链）', () {
      expect(
        AudioOffloadConfig.shouldEnable(userEnabled: true, dspActive: true),
        isFalse,
      );
    });
  });

  group('AudioOffloadConfig.effective', () {
    setUp(() {
      AudioOffloadConfig.userEnabled = false;
      AudioOffloadConfig.dspActive = false;
    });

    tearDown(() {
      // 静态字段会污染后续用例
      AudioOffloadConfig.userEnabled = false;
      AudioOffloadConfig.dspActive = false;
    });

    test('默认（都没开）→ false', () {
      expect(AudioOffloadConfig.effective, isFalse);
    });

    test('只开用户开关 → true', () {
      AudioOffloadConfig.userEnabled = true;
      expect(AudioOffloadConfig.effective, isTrue);
    });

    test('用户开关 + 音效链并存 → false', () {
      AudioOffloadConfig.userEnabled = true;
      AudioOffloadConfig.dspActive = true;
      expect(AudioOffloadConfig.effective, isFalse);
    });
  });
}
