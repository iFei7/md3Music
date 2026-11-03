import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/remote/tv_seek_stepper.dart';

/// 批次43：TvSeekStepper 状态机单测（步进推进 / 600ms debounce 合并落定 /
/// abort）。纯逻辑类，普通 flutter test（无 dart-define）即可覆盖。
void main() {
  test('步进推进：左右 ±stepSeconds，会话内连加基准', () {
    fakeAsync((async) {
      final steps = <double>[];
      final stepper = TvSeekStepper(
        onBegin: () {},
        onStep: steps.add,
        onCommit: () {},
        onAbort: () {},
        stepSeconds: 5,
      );

      // 右键一次：30s/100s → 35s。
      expect(
        stepper.handleDirection(
          TraversalDirection.right,
          currentMs: 30000,
          durationMs: 100000,
        ),
        isTrue,
      );
      expect(steps.single, closeTo(0.35, 1e-9));
      expect(stepper.isAdjusting, isTrue);

      // 连按第二次：基准是会话目标 35s（不是外部 currentMs）→ 40s。
      steps.clear();
      stepper.handleDirection(
        TraversalDirection.right,
        currentMs: 30000, // 控件展示位置不随按键变，状态机必须忽略它
        durationMs: 100000,
      );
      expect(steps.single, closeTo(0.40, 1e-9));

      // 左键：40s → 35s。
      steps.clear();
      stepper.handleDirection(
        TraversalDirection.left,
        currentMs: 30000,
        durationMs: 100000,
      );
      expect(steps.single, closeTo(0.35, 1e-9));

      stepper.dispose();
    });
  });

  test('600ms debounce 合并落定：连按只 commit 一次', () {
    fakeAsync((async) {
      var begin = 0;
      var commit = 0;
      final steps = <double>[];
      final stepper = TvSeekStepper(
        onBegin: () => begin++,
        onStep: steps.add,
        onCommit: () => commit++,
        onAbort: () {},
        stepSeconds: 5,
      );

      stepper.handleDirection(
        TraversalDirection.right,
        currentMs: 0,
        durationMs: 100000,
      );
      async.elapse(const Duration(milliseconds: 400));
      stepper.handleDirection(
        TraversalDirection.right,
        currentMs: 0,
        durationMs: 100000,
      );
      async.elapse(const Duration(milliseconds: 400)); // 距上次按键 <600ms
      stepper.handleDirection(
        TraversalDirection.right,
        currentMs: 0,
        durationMs: 100000,
      );

      expect(begin, 1, reason: '三次连按是同一会话，只 begin 一次');
      expect(commit, 0, reason: '静默期未到，不应落定');

      async.elapse(const Duration(milliseconds: 600));
      expect(commit, 1, reason: '静默 600ms 后合并成一次落定');
      expect(stepper.isAdjusting, isFalse);
      expect(steps.length, 3);

      stepper.dispose();
    });
  });

  test('flush 立即落定 / abort 收态不 seek', () {
    fakeAsync((async) {
      var commit = 0;
      var abort = 0;
      final stepper = TvSeekStepper(
        onBegin: () {},
        onStep: (_) {},
        onCommit: () => commit++,
        onAbort: () => abort++,
        stepSeconds: 5,
      );

      // 无会话时 flush/cancel 零副作用。
      stepper.flush();
      stepper.cancel();
      expect(commit, 0);
      expect(abort, 0);

      // flush：立即落定。
      stepper.handleDirection(
        TraversalDirection.right,
        currentMs: 0,
        durationMs: 100000,
      );
      stepper.flush();
      expect(commit, 1);
      expect(stepper.isAdjusting, isFalse);

      // cancel：收态但不 commit。
      stepper.handleDirection(
        TraversalDirection.right,
        currentMs: 0,
        durationMs: 100000,
      );
      stepper.cancel();
      expect(abort, 1);
      expect(commit, 1, reason: 'cancel 不得触发落定');
      // 取消后挂起的 debounce 不再触发。
      async.elapse(const Duration(seconds: 2));
      expect(commit, 1);

      stepper.dispose();
    });
  });

  test('上/下放行、时长未知放行、边界夹取', () {
    fakeAsync((async) {
      final stepper = TvSeekStepper(
        onBegin: () {},
        onStep: (_) {},
        onCommit: () {},
        onAbort: () {},
        stepSeconds: 5,
      );

      expect(
        stepper.handleDirection(
          TraversalDirection.up,
          currentMs: 0,
          durationMs: 100000,
        ),
        isFalse,
        reason: '上键必须放行，否则焦点被困在进度条',
      );
      expect(
        stepper.handleDirection(
          TraversalDirection.down,
          currentMs: 0,
          durationMs: 100000,
        ),
        isFalse,
      );
      expect(
        stepper.handleDirection(
          TraversalDirection.left,
          currentMs: 0,
          durationMs: 0,
        ),
        isFalse,
        reason: '时长未知不进会话',
      );

      // 边界：0s 左键夹 0；到末尾右键夹 duration。
      stepper.handleDirection(
        TraversalDirection.left,
        currentMs: 0,
        durationMs: 100000,
      );
      stepper.flush();
      stepper.handleDirection(
        TraversalDirection.right,
        currentMs: 0,
        durationMs: 100000,
      );
      async.elapse(const Duration(seconds: 1));

      stepper.dispose();
    });
  });
}
