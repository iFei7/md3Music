import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/recognition/recognition_utils.dart';

/// 识别前处理纯函数层测试：悬浮窗静音段提前中断后，
/// Kotlin 会把**实际字节数**（< SEGMENT_BYTES，甚至 < 1s）经
/// onSegmentCaptured 透传给 Dart。本组用例验证前处理链路
/// （computeMaxAmplitude → downsamplePcm → normalizeGain，含 Isolate
/// 异步包装）对任意长度短段均按实际字节正确工作，无「必须满段」假设。
void main() {
  /// 构造 16bit 小端 PCM：单个正弦半周期采样序列，峰值为 [peak]
  Uint8List pcm16(int samples, int peak) {
    final out = Uint8List(samples * 2);
    for (var i = 0; i < samples; i++) {
      final v = i.isEven ? peak : -peak;
      out[i * 2] = v & 0xFF;
      out[i * 2 + 1] = (v >> 8) & 0xFF;
    }
    return out;
  }

  group('短段（提前中断）字节透传', () {
    test('极短段（不足 1s）：computeMaxAmplitude 按实际采样计算', () {
      // 800 采样 = 0.1s@8kHz，远小于满段 96000 字节
      final pcm = pcm16(800, 500);
      expect(computeMaxAmplitude(pcm), 500);
      expect(computeMaxAmplitude(pcm16(800, 10)), lessThan(30));
    });

    test('极短段：normalizeGain 不越界、输出长度与输入一致', () {
      final pcm = pcm16(800, 100);
      final out = normalizeGain(pcm, 100);
      expect(out.length, pcm.length);
      expect(computeMaxAmplitude(out), 25000, reason: '增益放大到目标振幅');
    });

    test('极短段：downsamplePcm 44100→8000 输出符合实际输入长度', () {
      // 0.1s@44100Hz = 4410 采样
      final pcm = pcm16(4410, 300);
      final out = downsamplePcm(pcm, 44100, 8000);
      expect(out.length, (4410 * 8000 / 44100).round() * 2);
    });

    test('Isolate 包装：downsamplePcmAsync 与同步版结果一致', () async {
      final pcm = pcm16(4410, 300);
      final sync = downsamplePcm(pcm, 44100, 8000);
      final async = await downsamplePcmAsync(pcm, 44100, 8000);
      expect(async.length, sync.length);
      expect(async, sync);
    });

    test('Isolate 包装：normalizeGainAsync 与同步版结果一致', () async {
      final pcm = pcm16(800, 100);
      final sync = normalizeGain(pcm, 100);
      final async = await normalizeGainAsync(pcm, 100);
      expect(async.length, sync.length);
      expect(async, sync);
    });

    test('Isolate 包装：空输入直接返回', () async {
      final empty = Uint8List(0);
      expect(await normalizeGainAsync(empty, 100), empty);
      expect(await downsamplePcmAsync(empty, 44100, 8000), empty);
    });
  });
}
