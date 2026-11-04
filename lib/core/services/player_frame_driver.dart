import 'dart:async';

import 'package:flutter/foundation.dart';

/// 播放页共享的 60fps 帧驱动。
///
/// **为什么需要它**：歌词（AppleLyricsView 省电模式限帧）与封面旋转
/// 原本各自持有一个独立的 16ms [Timer]，两者启动时刻随机、
/// 相位错开 → 每 8.3ms 就有一方 `scheduleFrame`，在 120Hz 屏上整页实测
/// 115~120fps（功耗近似翻倍），而**单个组件都只要求 60fps**。
///
/// 把所有 60fps 驱动挂到同一节拍上即可让整页回到 60fps：各订阅者的更新率
/// 不变（仍是 60fps），无视觉降级，只是消除了帧提交的交错。
///
/// 语义：首个订阅者到来时启动定时器，最后一个订阅者离开时停掉（不留空转）。
class PlayerFrameDriver {
  PlayerFrameDriver._();

  static final PlayerFrameDriver instance = PlayerFrameDriver._();

  /// 帧率档位：标准 60fps。
  static const int kFrameRateHigh = 60;

  /// 帧率档位：省电 30fps。
  static const int kFrameRateLow = 30;

  /// 步进周期（默认 60fps，可由 [setFrameRate] 切到 30fps）。
  ///
  /// 订阅者按 step 计算增量（`step.inMicroseconds / 1e6 * 速度`、动画相位累加等），
  /// 改 step 后滚动速度与动画周期**自动守恒**；不要在订阅方做任何补偿。
  static Duration step = const Duration(milliseconds: 16);

  /// 当前帧率（由 [step] 反推，便于读取与测试断言）。
  int get frameRate =>
      (Duration.microsecondsPerSecond / step.inMicroseconds).round();

  Timer? _timer;
  final List<VoidCallback> _listeners = <VoidCallback>[];

  /// App 是否已进入后台（挂起）状态。
  ///
  /// 注意：只有 `paused` / `hidden` / `detached` 才算挂起。`inactive`
  /// （下拉通知栏、来电浮层、分屏失焦、部分车机投屏）**不在此列** ——
  /// 那时 App 仍在出帧，跟着停会让动画表现成「拉一下通知栏就冻住」。
  bool _appSuspended = false;

  /// 累计节拍数（诊断 / 测试用）。
  int _tickCount = 0;

  /// 是否已有订阅者（诊断用）。
  bool get hasListeners => _listeners.isNotEmpty;

  /// App 是否处于后台挂起状态（诊断 / 测试用）。
  bool get isAppSuspended => _appSuspended;

  /// 累计节拍数，可用来验证定时器是否真的在跑（诊断 / 测试用）。
  int get tickCount => _tickCount;

  /// 由生命周期入口（PlayerProvider）转调，设置后台挂起状态。
  ///
  /// 值未变化直接返回，避免 resumed 之类的重复通知反复重排定时器。
  void setAppSuspended(bool suspended) {
    if (_appSuspended == suspended) return;
    _appSuspended = suspended;
    // 后台必须真正 cancel 而不是在 _onTick 里 return：定时器存活时 Dart
    // 仍每 16ms 被唤醒一次（后台约 62.5 次/秒），而 scheduleFrame 已被
    // 平台丢弃，属于纯粹的白跑耗电。只有 cancel 才能让 isolate 彻底静默。
    _syncTimer();
  }

  /// 切换帧率档位（30 / 60fps）。
  ///
  /// 入参先归一化到 [kFrameRateLow] 或 [kFrameRateHigh]，因此任意值都不会
  /// 产生 0 周期或除零：低于等于中位数取 30，高于中位数取 60。
  void setFrameRate(int fps) {
    final int normalized = fps <= (kFrameRateHigh + kFrameRateLow) ~/ 2
        ? kFrameRateLow
        : kFrameRateHigh;
    final Duration next = Duration(
      microseconds: (Duration.microsecondsPerSecond / normalized).round(),
    );
    if (next == step) return;
    step = next;
    // 必须重建定时器：Timer.periodic 的周期在创建时就固定了，改 step 不会
    // 影响已在跑的定时器，只有 cancel + 重新创建才会按新周期出拍。
    _timer?.cancel();
    _timer = null;
    _syncTimer();
  }

  /// 订阅共享节拍。
  void addListener(VoidCallback listener) {
    if (_listeners.contains(listener)) return;
    _listeners.add(listener);
    _syncTimer();
  }

  /// 取消订阅；最后一个订阅者离开时停掉定时器。
  void removeListener(VoidCallback listener) {
    if (!_listeners.remove(listener)) return;
    _syncTimer();
  }

  /// 按「有订阅者且未挂起」统一收敛定时器状态。
  void _syncTimer() {
    final bool shouldRun = _listeners.isNotEmpty && !_appSuspended;
    if (shouldRun) {
      _timer ??= Timer.periodic(step, _onTick);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _onTick(Timer timer) {
    _tickCount++;
    // 拷贝快照：回调内可能增删订阅（如收敛停帧）
    final List<VoidCallback> snapshot = List<VoidCallback>.of(_listeners);
    for (final VoidCallback cb in snapshot) {
      // 同一拍较早的回调可能销毁另一个订阅者；跳过已移除项，避免对已卸载
      // Widget 再触发一次 setState。
      if (_listeners.contains(cb)) cb();
    }
  }
}
