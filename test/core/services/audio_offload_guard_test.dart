import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_offload_config.dart';
import 'package:md3music/core/services/audio_offload_guard.dart';

void main() {
  // 批次44 软解兜底：这里只覆盖纯逻辑（真值表 + 阈值判定），
  // 不触碰 MethodChannel / AudioService，保证单测零平台依赖。
  group('AudioOffloadFallbackPolicy.isOffloadSuspiciousError', () {
    test('5001（AudioTrack 初始化失败）→ true', () {
      expect(
        AudioOffloadFallbackPolicy.isOffloadSuspiciousError(5001, null),
        isTrue,
      );
    });

    test('5002（AudioTrack 写失败）→ true', () {
      expect(
        AudioOffloadFallbackPolicy.isOffloadSuspiciousError(5002, null),
        isTrue,
      );
    });

    test('4001（解码器初始化失败）→ true', () {
      expect(
        AudioOffloadFallbackPolicy.isOffloadSuspiciousError(4001, null),
        isTrue,
      );
    });

    test('4003（解码失败）→ true', () {
      expect(
        AudioOffloadFallbackPolicy.isOffloadSuspiciousError(4003, null),
        isTrue,
      );
    });

    test('2003（网络类，IO 区间）→ false，不能被误判成 offload 失败', () {
      expect(
        AudioOffloadFallbackPolicy.isOffloadSuspiciousError(2003, null),
        isFalse,
      );
    });

    test('code 为 null + message 含 AudioTrack → true', () {
      expect(
        AudioOffloadFallbackPolicy.isOffloadSuspiciousError(
          null,
          'AudioTrack init failed',
        ),
        isTrue,
      );
    });

    test('code 为 null + message 是网络错误 → false', () {
      expect(
        AudioOffloadFallbackPolicy.isOffloadSuspiciousError(
          null,
          'network unreachable',
        ),
        isFalse,
      );
    });

    test('code 与 message 都为 null → false', () {
      expect(
        AudioOffloadFallbackPolicy.isOffloadSuspiciousError(null, null),
        isFalse,
      );
    });
  });

  // 批次44：超时判据从「位置几乎不动」收紧为「零/负进展 + 有缓冲但没消费」。
  // 取舍说明（二选一）：这里采用 `positionNow - positionAtStart <= Duration.zero`，
  // 而不是「< 300ms」。理由：正向前进哪怕只有 100ms 也证明 sink 正在消费数据，
  // 再小的正向前进都应当一票否决（慢网起播瞬间的位置抖动就属于这一类）；
  // 而「回退」一定是 seek/切歌引起的，此时位置停在新目标上、缓冲又充足，
  // 从 sink 视角看确实"有数据却不消费"，归为未前进与线上语义一致。
  group('AudioOffloadFallbackPolicy.isHang', () {
    const threshold = AudioOffloadFallbackPolicy.initTimeout;
    const plentyBuffered = Duration(seconds: 3);

    test('未到阈值 → false', () {
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold - const Duration(seconds: 1),
          threshold: threshold,
          positionAtStart: Duration.zero,
          positionNow: Duration.zero,
          playing: true,
          bufferedAhead: plentyBuffered,
        ),
        isFalse,
      );
    });

    test('位置正向前进 1s → false（sink 在消费）', () {
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold,
          threshold: threshold,
          positionAtStart: const Duration(seconds: 5),
          positionNow: const Duration(seconds: 6),
          playing: true,
          bufferedAhead: plentyBuffered,
        ),
        isFalse,
      );
    });

    test('位置只前进 100ms → false（任何正向前进都一票否决）', () {
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold,
          threshold: threshold,
          positionAtStart: const Duration(seconds: 5),
          positionNow: const Duration(seconds: 5, milliseconds: 100),
          playing: true,
          bufferedAhead: plentyBuffered,
        ),
        isFalse,
      );
    });

    test('位置回退 1s 视为未前进、且有缓冲 → true（用户 seek 回退）', () {
      // 回退是负数，满足 `<= Duration.zero`。这条与线上语义一致：回退只会来自
      // seek/切歌，此时位置停在新目标、缓冲充足，sink 确实没有消费。
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold,
          threshold: threshold,
          positionAtStart: const Duration(seconds: 5),
          positionNow: const Duration(seconds: 4),
          playing: true,
          bufferedAhead: plentyBuffered,
        ),
        isTrue,
      );
    });

    test('位置零进展但缓冲为 0（网络拉不到）→ false', () {
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold,
          threshold: threshold,
          positionAtStart: const Duration(seconds: 5),
          positionNow: const Duration(seconds: 5),
          playing: true,
          bufferedAhead: Duration.zero,
        ),
        isFalse,
      );
    });

    test('位置零进展但缓冲只有 1s（< 2s 门槛）→ false', () {
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold,
          threshold: threshold,
          positionAtStart: const Duration(seconds: 5),
          positionNow: const Duration(seconds: 5),
          playing: true,
          bufferedAhead: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('位置零进展 + 缓冲 3s + playing → true（有数据却不消费）', () {
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold,
          threshold: threshold,
          positionAtStart: const Duration(seconds: 5),
          positionNow: const Duration(seconds: 5),
          playing: true,
          bufferedAhead: plentyBuffered,
        ),
        isTrue,
      );
    });

    test('playing=false → false（暂停不是卡死）', () {
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold,
          threshold: threshold,
          positionAtStart: Duration.zero,
          positionNow: Duration.zero,
          playing: false,
          bufferedAhead: plentyBuffered,
        ),
        isFalse,
      );
    });

    test('缓冲恰好等于门槛（2s）→ true（>= 闭区间）', () {
      expect(
        AudioOffloadFallbackPolicy.isHang(
          elapsed: threshold,
          threshold: threshold,
          positionAtStart: Duration.zero,
          positionNow: Duration.zero,
          playing: true,
          bufferedAhead: const Duration(seconds: 2),
        ),
        isTrue,
      );
    });
  });

  group('AudioOffloadConfig.shouldEnable（runtimeFailed 分支）', () {
    tearDown(() {
      AudioOffloadConfig.userEnabled = false;
      AudioOffloadConfig.dspActive = false;
      AudioOffloadConfig.runtimeFailed = false;
    });

    test('用户开启 + 无音效 + 本会话已失败 → 不再下发 offload', () {
      expect(
        AudioOffloadConfig.shouldEnable(
          userEnabled: true,
          dspActive: false,
          runtimeFailed: true,
        ),
        isFalse,
      );
    });

    test('runtimeFailed 默认 false → 行为与旧版一致（向后兼容）', () {
      expect(
        AudioOffloadConfig.shouldEnable(userEnabled: true, dspActive: false),
        isTrue,
      );
    });

    test('runtimeFailed 置位后 effective 也为 false', () {
      AudioOffloadConfig.userEnabled = true;
      AudioOffloadConfig.dspActive = false;
      AudioOffloadConfig.runtimeFailed = true;
      expect(AudioOffloadConfig.effective, isFalse);
    });
  });
}
