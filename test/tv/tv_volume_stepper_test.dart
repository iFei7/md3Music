import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_volume_stepper.dart';

/// 批次43：TvVolumeStepper 状态机单测（0.05 步进 / [0,1] 夹取 / 落定）。
void main() {
  test('0.05 步进：右加左减，会话内连加基准', () {
    fakeAsync((async) {
      final steps = <double>[];
      final stepper = TvVolumeStepper(
        onBegin: () {},
        onStep: steps.add,
        onCommit: (_) {},
        onAbort: () {},
      );

      // 右键一次：0.4 → 0.45。
      expect(
        stepper.handleDirection(TraversalDirection.right, current: 0.4),
        isTrue,
      );
      expect(steps.single, closeTo(0.45, 1e-9));

      // 连按：基准是会话目标（0.45）→ 0.5，不从 current 重算。
      steps.clear();
      stepper.handleDirection(TraversalDirection.right, current: 0.4);
      expect(steps.single, closeTo(0.50, 1e-9));

      // 左键：0.5 → 0.45。
      steps.clear();
      stepper.handleDirection(TraversalDirection.left, current: 0.4);
      expect(steps.single, closeTo(0.45, 1e-9));

      stepper.dispose();
    });
  });

  test('[0,1] 夹取：下限 0、上限 1，边界仍算已消费', () {
    fakeAsync((async) {
      final steps = <double>[];
      final stepper = TvVolumeStepper(
        onBegin: () {},
        onStep: steps.add,
        onCommit: (_) {},
        onAbort: () {},
      );

      // 0 处按左：夹到 0，但按键仍被消费（走出这一行靠上下键）。
      expect(
        stepper.handleDirection(TraversalDirection.left, current: 0.0),
        isTrue,
      );
      expect(steps.single, 0.0);
      stepper.flush();

      // 1 处按右：夹到 1。
      steps.clear();
      expect(
        stepper.handleDirection(TraversalDirection.right, current: 1.0),
        isTrue,
      );
      expect(steps.single, 1.0);

      stepper.dispose();
    });
  });

  test('落定带最终值；abort 不落定；上/下放行', () {
    fakeAsync((async) {
      double? committed;
      var abort = 0;
      final stepper = TvVolumeStepper(
        onBegin: () {},
        onStep: (_) {},
        onCommit: (v) => committed = v,
        onAbort: () => abort++,
      );

      // 上/下放行。
      expect(
        stepper.handleDirection(TraversalDirection.up, current: 0.5),
        isFalse,
      );
      expect(
        stepper.handleDirection(TraversalDirection.down, current: 0.5),
        isFalse,
      );

      // 静默后自动落定，带最后一次的值。
      stepper.handleDirection(TraversalDirection.right, current: 0.5);
      async.elapse(const Duration(milliseconds: 400));
      expect(committed, closeTo(0.55, 1e-9));

      // cancel：不写盘。
      stepper.handleDirection(TraversalDirection.right, current: 0.55);
      stepper.cancel();
      expect(abort, 1);
      expect(committed, closeTo(0.55, 1e-9), reason: 'abort 不得触发落定写盘');

      stepper.dispose();
    });
  });
}
