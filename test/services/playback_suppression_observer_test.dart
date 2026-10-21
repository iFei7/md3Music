import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/audio_service_io.dart';

/// 批次26：播放抑制（playback suppression）观测器单测。
///
/// 用可控 `StreamController<int>` 驱动 [PlaybackSuppressionObserver]，
/// 验证 reason 变化被留痕（context.onObserve）与保守自动暂停策略的
/// 触发点（context.onAutoPause）在各条件下的行为。观测器的 timer 经
/// timerFactory 注入录制替身，倒计时到点由测试手动触发，完全确定性。
void main() {
  group('reason 变化留痕', () {
    test('每次变化（含回到 NONE）都经 onObserve 记录，带角色标注', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext();
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
      );
      ctl.add(1);
      ctl.add(2);
      ctl.add(0);
      expect(ctx.observed, [
        (role: 'main', reason: 1),
        (role: 'main', reason: 2),
        (role: 'main', reason: 0),
      ]);
      ctl.close();
    });

    test('辅播放器事件以 aux 角色留痕', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext();
      PlaybackSuppressionObserver(
        role: 'aux',
        reasonStream: ctl.stream,
        context: ctx,
      );
      ctl.add(2);
      expect(ctx.observed, [(role: 'aux', reason: 2)]);
      ctl.close();
    });

    test('未知/非法 reason 值原样留痕，不吞事件', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext();
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
      );
      ctl.add(7);
      expect(ctx.observed, [(role: 'main', reason: 7)]);
      ctl.close();
    });

    test('stream 错误不上抛，后续事件仍可达', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext();
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
      );
      expect(() => ctl.addError(StateError('boom')), returnsNormally);
      ctl.add(1);
      expect(ctx.observed, [(role: 'main', reason: 1)]);
      ctl.close();
    });

    test('dispose 后取消订阅，迟到事件不再处理', () async {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext();
      final observer = PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
      );
      ctl.add(1);
      await observer.dispose();
      ctl.add(2);
      expect(ctx.observed, [(role: 'main', reason: 1)]);
      await ctl.close();
    });
  });

  group('保守自动暂停策略（默认关闭，只诊断）', () {
    test('默认关闭：抑制出现也不创建倒计时、不自动暂停', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: false);
      final timers = <_RecordingTimer>[];
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      ctl.add(2);
      expect(timers, isEmpty);
      expect(ctx.autoPaused, isEmpty);
      expect(ctx.observed.length, 2); // 留痕不受策略开关影响
      ctl.close();
    });

    test('开启 + 活动角色 + 播放中 → arm 倒计时，延迟为 kSuppressionAutoPauseDelay', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true);
      final timers = <_RecordingTimer>[];
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      expect(timers.length, 1);
      expect(timers.single.duration, kSuppressionAutoPauseDelay);
      expect(timers.single.isActive, true);
      expect(ctx.autoPaused, isEmpty); // 没到点不触发
      ctl.close();
    });

    test('倒计时到点 → 调用 onAutoPause（策略触发点），且只触发一次', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true);
      final timers = <_RecordingTimer>[];
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(2);
      timers.single.fire();
      timers.single.fire(); // 已消费，不重复触发
      expect(ctx.autoPaused, [(role: 'main', reason: 2)]);
      ctl.close();
    });

    test('reason 回到 NONE → 取消倒计时，不再自动暂停', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true);
      final timers = <_RecordingTimer>[];
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      ctl.add(0); // 恢复出声
      expect(timers.single.cancelled, true);
      timers.single.fire();
      expect(ctx.autoPaused, isEmpty);
      ctl.close();
    });

    test('用户操作（noteUserActivity）取消挂起倒计时', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true);
      final timers = <_RecordingTimer>[];
      final observer = PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      observer.noteUserActivity();
      expect(timers.single.cancelled, true);
      timers.single.fire();
      expect(ctx.autoPaused, isEmpty);
      ctl.close();
    });

    test('非活动角色（淡出方）被抑制不 arm：交叉淡化中只盯当前歌曲', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true, activeRole: 'aux');
      final timers = <_RecordingTimer>[];
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      expect(timers, isEmpty);
      expect(ctx.autoPaused, isEmpty);
      ctl.close();
    });

    test('未播放时不 arm（suppression 语义只对 playWhenReady=true 有意义）', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true, isPlaying: false);
      final timers = <_RecordingTimer>[];
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      expect(timers, isEmpty);
      ctl.close();
    });

    test('角色互换后旧活动角色的过期倒计时到点不再触发（fire 时复检）', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true, activeRole: 'main');
      final timers = <_RecordingTimer>[];
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      ctx.activeRole = 'aux'; // promote：main 变成淡出方
      timers.single.fire();
      expect(ctx.autoPaused, isEmpty);
      ctl.close();
    });

    test('reason 1→2 抖动不重置倒计时（保守：保持首次 arm 的时限）', () {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true);
      final timers = <_RecordingTimer>[];
      PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      ctl.add(2);
      expect(timers.length, 1);
      expect(timers.single.isActive, true);
      ctl.close();
    });

    test('dispose 取消挂起倒计时（不泄漏）', () async {
      final ctl = StreamController<int>.broadcast(sync: true);
      final ctx = _RecordingContext(autoPauseEnabled: true);
      final timers = <_RecordingTimer>[];
      final observer = PlaybackSuppressionObserver(
        role: 'main',
        reasonStream: ctl.stream,
        context: ctx,
        timerFactory: (d, cb) {
          final t = _RecordingTimer(d, cb);
          timers.add(t);
          return t;
        },
      );
      ctl.add(1);
      await observer.dispose();
      expect(timers.single.cancelled, true);
      timers.single.fire();
      expect(ctx.autoPaused, isEmpty);
      await ctl.close();
    });
  });

  group('reason 值 → 中文标签', () {
    test('0/1/2 与未知值', () {
      expect(playbackSuppressionReasonLabel(0), '无抑制');
      expect(playbackSuppressionReasonLabel(1), '瞬时音频焦点丢失');
      expect(playbackSuppressionReasonLabel(2), '无合适音频输出设备');
      expect(playbackSuppressionReasonLabel(7), contains('未知'));
    });
  });
}

/// 录制替身 timer：不真正计时，由测试手动 [fire]。
class _RecordingTimer implements Timer {
  _RecordingTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  bool cancelled = false;
  bool fired = false;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  void cancel() => cancelled = true;

  @override
  int get tick => 0;

  void fire() {
    if (cancelled || fired) return;
    fired = true;
    callback();
  }
}

/// 录制替身 context：把留痕与策略触发点记下来供断言。
class _RecordingContext implements PlaybackSuppressionContext {
  _RecordingContext({
    this.autoPauseEnabled = false,
    this.isPlaying = true,
    this.activeRole = 'main',
  });

  @override
  bool autoPauseEnabled;

  @override
  bool isPlaying;

  String activeRole;

  final List<({String role, int reason})> observed = [];
  final List<({String role, int reason})> autoPaused = [];

  @override
  bool isActiveRole(String role) => role == activeRole;

  @override
  void onObserve({required String role, required int reason}) =>
      observed.add((role: role, reason: reason));

  @override
  void onAutoPause({required String role, required int reason}) =>
      autoPaused.add((role: role, reason: reason));
}
