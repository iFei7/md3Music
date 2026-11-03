import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_seek_math.dart';

/// 批次43：tvSeekTarget / tvPageTarget 边界夹取单测（纯函数）。
void main() {
  group('tvSeekTarget', () {
    const zero = Duration.zero;

    test('正常步进', () {
      expect(
        tvSeekTarget(
          const Duration(seconds: 30),
          const Duration(seconds: 100),
          10,
        ),
        const Duration(seconds: 40),
      );
      expect(
        tvSeekTarget(
          const Duration(seconds: 30),
          const Duration(seconds: 100),
          -10,
        ),
        const Duration(seconds: 20),
      );
    });

    test('前边界：负向越界夹到 0', () {
      expect(
        tvSeekTarget(
          const Duration(seconds: 5),
          const Duration(seconds: 100),
          -10,
        ),
        zero,
      );
      // 恰好到 0 不越界。
      expect(
        tvSeekTarget(
          const Duration(seconds: 10),
          const Duration(seconds: 100),
          -10,
        ),
        zero,
      );
    });

    test('后边界：正向越界夹到总时长', () {
      expect(
        tvSeekTarget(
          const Duration(seconds: 95),
          const Duration(seconds: 100),
          10,
        ),
        const Duration(seconds: 100),
      );
      // 恰好到总时长。
      expect(
        tvSeekTarget(
          const Duration(seconds: 90),
          const Duration(seconds: 100),
          10,
        ),
        const Duration(seconds: 100),
      );
    });

    test('时长未知（duration <= 0）不夹上限', () {
      // durationMs <= 0 的语义由 TvSeekStepper 拦截；纯函数层此时只在
      // 负侧夹 0（对齐实现：duration > Duration.zero 才夹上限）。
      expect(
        tvSeekTarget(const Duration(seconds: 5), zero, 10),
        const Duration(seconds: 15),
      );
      expect(tvSeekTarget(const Duration(seconds: 5), zero, -10), zero);
    });
  });

  group('tvPageTarget', () {
    test('正常换页', () {
      expect(tvPageTarget(2, 10, 1), 3);
      expect(tvPageTarget(2, 10, -1), 1);
      expect(tvPageTarget(2, 10, 0), 2);
    });

    test('下边界夹 0', () {
      expect(tvPageTarget(0, 10, -1), 0);
      expect(tvPageTarget(0, 10, -5), 0);
    });

    test('上边界夹 count-1', () {
      expect(tvPageTarget(9, 10, 1), 9);
      expect(tvPageTarget(9, 10, 5), 9);
    });

    test('空列表返回 0', () {
      expect(tvPageTarget(0, 0, 1), 0);
      expect(tvPageTarget(3, 0, 1), 0);
    });
  });
}
