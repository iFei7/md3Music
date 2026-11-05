import 'dart:async';

// 批次45：scheduler 同时提供 Ticker 与 VoidCallback（内部已 re-export
// foundation），因此不再单独 import foundation，避免 unnecessary_import。
import 'package:flutter/scheduler.dart';

/// 播放页共享的帧驱动（批次45：改为 vsync 驱动 + 保留限额档）。
///
/// **为什么需要它**：歌词（AppleLyricsView 省电模式限帧）与封面旋转
/// 原本各自持有一个独立的 16ms [Timer]，两者启动时刻随机、
/// 相位错开 → 每 8.3ms 就有一方 `scheduleFrame`，在 120Hz 屏上整页实测
/// 115~120fps（功耗近似翻倍），而**单个组件都只要求 60fps**。
///
/// 把所有帧驱动挂到同一节拍上即可消除帧提交的交错：改成单一 vsync 节拍后
/// 同样不会翻倍 —— 一帧只跑一次回调，无论屏幕上还有多少别的动画。
///
/// **两种模式**（批次45）：
/// - [kFrameRateAuto]（= 0）：跟随屏幕刷新率，由 [Ticker] 驱动。120Hz 屏上
///   每 8.3ms 一拍，跑马灯/频谱真正跑到 120fps；[step] 每帧写入「距上一帧的
///   实际间隔」，订阅者按 step 累加 → 速度天然守恒。
/// - [kFrameRateLow] / [kFrameRateHigh]：限额模式，仍是 [Timer.periodic]，
///   [step] 固定为目标间隔（1e6 / fps），与批次45 之前的行为完全一致。
///
/// **为什么还保留限额档**：auto 模式下每一帧都会做一次「插值 + 重绘」，
/// 120Hz 屏上的成本约等于 60fps 档的 2 倍；省电场景需要显式把上限压到 30fps。
///
/// 语义：首个订阅者到来时启动驱动，最后一个订阅者离开时停掉（不留空转）；
/// 后台挂起（[_appSuspended]）时两套机制都必须真正停掉，而不是在回调里 return。
class PlayerFrameDriver {
  PlayerFrameDriver._();

  static final PlayerFrameDriver instance = PlayerFrameDriver._();

  /// 帧率档位：跟随屏幕刷新率（vsync 驱动），不做任何帧率上限。
  ///
  /// 用 [Ticker] 挂在引擎的 vsync 上，屏幕 120Hz 就出 120 拍、60Hz 就出 60 拍；
  /// 后台时引擎不产帧，Ticker 自然不跑。
  static const int kFrameRateAuto = 0;

  /// 帧率档位：标准 60fps（限额模式）。
  static const int kFrameRateHigh = 60;

  /// 帧率档位：省电 30fps（限额模式）。
  static const int kFrameRateLow = 30;

  /// 步进周期（批次45：auto 模式下为「最近一帧的实际间隔」）。
  ///
  /// 订阅者按 step 计算增量（`step.inMicroseconds / 1e6 * 速度`、动画相位累加等），
  /// 改 step 后滚动速度与动画周期**自动守恒**；不要在订阅方做任何补偿。
  ///
  /// 不变式：step 恒 > 0。[_onVsync] 会丢弃 delta 为 0/负的首帧，
  /// 限额模式的间隔由 30/60fps 换算而来，同样不可能为 0。
  static Duration step = const Duration(milliseconds: 16);

  /// 当前瞬时帧率（由 [step] 反推，便于读取与测试断言）。
  ///
  /// auto 模式下 step 是「最近一帧的间隔」，因此这里反映的是**最近一帧的
  /// 瞬时帧率**（例如 120Hz 屏上约为 120），不是目标值 —— 目标值看
  /// [targetFrameRate]。
  int get frameRate =>
      (Duration.microsecondsPerSecond / step.inMicroseconds).round();

  Timer? _timer;
  Ticker? _ticker;
  final List<VoidCallback> _listeners = <VoidCallback>[];

  /// 当前目标档位（[kFrameRateAuto] / [kFrameRateLow] / [kFrameRateHigh]）。
  ///
  /// 默认仍是 60（限额模式）：纯 `test()` 用例与 widget 测试都依赖
  /// Timer 路径的确定性时序，App 启动时由 [setFrameRate] 显式切到 auto。
  int _targetFps = kFrameRateHigh;

  /// [Ticker] 上一帧的累计 elapsed（仅 auto 模式使用）。
  ///
  /// [Ticker.start] 后 elapsed 从 0 重新计时，因此每次（重新）启动前必须归零，
  /// 否则会算出一个巨大的负 delta 或跳变。
  Duration _lastElapsed = Duration.zero;

  /// App 是否已进入后台（挂起）状态。
  ///
  /// 注意：只有 `paused` / `hidden` / `detached` 才算挂起。`inactive`
  /// （下拉通知栏、来电浮层、分屏失焦、部分车机投屏）**不在此列** ——
  /// 那时 App 仍在出帧，跟着停会让动画表现成「拉一下通知栏就冻住」。
  ///
  /// 批次45：Ticker 在后台天然不产帧，但在 inactive 下仍会出帧，所以这个
  /// 硬闸门必须保留（对两种模式同时生效）。
  bool _appSuspended = false;

  /// 累计节拍数（诊断 / 测试用）。
  int _tickCount = 0;

  /// 是否已有订阅者（诊断用）。
  bool get hasListeners => _listeners.isNotEmpty;

  /// App 是否处于后台挂起状态（诊断 / 测试用）。
  bool get isAppSuspended => _appSuspended;

  /// 累计节拍数，可用来验证驱动是否真的在跑（诊断 / 测试用）。
  int get tickCount => _tickCount;

  /// 当前是否为 vsync（跟随屏幕）驱动（诊断 / 测试用）。
  bool get isVsyncDriven => _targetFps == kFrameRateAuto;

  /// 当前目标帧率档位（诊断 / 测试用）：0 = auto，30 / 60 = 限额模式。
  int get targetFrameRate => _targetFps;

  /// 由生命周期入口（PlayerProvider）转调，设置后台挂起状态。
  ///
  /// 值未变化直接返回，避免 resumed 之类的重复通知反复重排驱动。
  void setAppSuspended(bool suspended) {
    if (_appSuspended == suspended) return;
    _appSuspended = suspended;
    // 后台必须真正 stop / cancel 而不是在回调里 return：Timer 存活时 Dart
    // 仍每次周期被唤醒（后台约 62.5 次/秒），而 scheduleFrame 已被平台丢弃，
    // 属于纯粹的白跑耗电。Ticker 同理：不停掉会让引擎继续申请 vsync。
    _syncDriver();
  }

  /// 切换帧率档位（auto / 30 / 60fps）。
  ///
  /// 入参归一化：`<= 0` → [kFrameRateAuto]；`<= 45` → [kFrameRateLow]；
  /// 其余 → [kFrameRateHigh]。因此任意值都不会产生 0 周期或除零。
  void setFrameRate(int fps) {
    final int normalized = _normalize(fps);
    if (normalized == _targetFps) {
      // 档位未变：不重建驱动。但限额模式仍要把 step 对齐到精确间隔 ——
      // 初始默认 16000µs 与 1e6/60 = 16667µs 差一点，不对齐会使 frameRate
      // getter 读成 63 而不是 60。
      if (normalized != kFrameRateAuto) step = _limitInterval(normalized);
      return;
    }
    _targetFps = normalized;

    // 切模式必须先把另一套机制彻底停掉（Timer ↔ Ticker 互斥），
    // 否则会出现「Ticker 与 16ms Timer 同时存在」的双倍帧提交，
    // 正是本类最初要消除的问题。
    _stopTimer();
    _stopTicker();

    // 限额模式的 step 是固定目标间隔；auto 模式保持上一帧的 step 不动，
    // 由 [_onVsync] 在第二帧起写入真实间隔（首帧 delta 为 0 会被丢弃，
    // 若此时把 step 改成 0 会让订阅者的 `% total` 直接产生 NaN）。
    if (normalized != kFrameRateAuto) {
      step = _limitInterval(normalized);
    }
    _syncDriver();
  }

  /// 把任意入参归一化到三个档位之一。
  int _normalize(int fps) {
    if (fps <= 0) return kFrameRateAuto;
    if (fps <= (kFrameRateHigh + kFrameRateLow) ~/ 2) return kFrameRateLow;
    return kFrameRateHigh;
  }

  /// 限额模式的固定出拍间隔（fps 只可能是 30 / 60，不会被 0 除）。
  Duration _limitInterval(int fps) =>
      Duration(microseconds: (Duration.microsecondsPerSecond / fps).round());

  /// 订阅共享节拍。
  void addListener(VoidCallback listener) {
    if (_listeners.contains(listener)) return;
    _listeners.add(listener);
    _syncDriver();
  }

  /// 取消订阅；最后一个订阅者离开时停掉驱动。
  void removeListener(VoidCallback listener) {
    if (!_listeners.remove(listener)) return;
    _syncDriver();
  }

  /// 按「有订阅者且未挂起」统一收敛驱动状态（批次45：Timer / Ticker 二选一）。
  void _syncDriver() {
    final bool shouldRun = _listeners.isNotEmpty && !_appSuspended;
    if (!shouldRun) {
      _stopTimer();
      _stopTicker();
      return;
    }
    if (_targetFps == kFrameRateAuto) {
      _stopTimer(); // 互斥：auto 模式绝不能留着 Timer 一起出拍
      final Ticker ticker = _ticker ??= Ticker(_onVsync);
      if (!ticker.isActive) {
        // start() 会让 elapsed 从 0 重新计时；已激活时再 start 会抛异常。
        _lastElapsed = Duration.zero;
        ticker.start();
      }
      return;
    }
    _stopTicker(); // 互斥：限额模式绝不能留着 Ticker 一起出拍
    if (_timer == null) {
      final Duration interval = _limitInterval(_targetFps);
      step = interval;
      _timer = Timer.periodic(interval, _onTick);
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// 停掉 Ticker 并复位 elapsed 基准（stop 必须成对，否则引擎会一直申请 vsync）。
  void _stopTicker() {
    _ticker?.stop();
    _lastElapsed = Duration.zero;
  }

  /// 限额模式的一拍：间隔由 Timer.periodic 保证，step 已在创建时固定。
  void _onTick(Timer timer) => _fire();

  /// auto 模式的一拍：`elapsed` 是自 [Ticker.start] 起的累计时长。
  void _onVsync(Duration elapsed) {
    final Duration delta = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    // 首帧 delta 为 0，跳过：订阅者会用 step 做累加/取模，0 会导致进度不动甚至 NaN。
    if (delta <= Duration.zero) return;
    step = delta;
    _fire();
  }

  /// 两种模式共用的派发逻辑。
  void _fire() {
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
