import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 批次44：显示刷新率跟随滚动的服务。
///
/// 目标：用户手指滑动内容时把显示刷新率提到设备支持的**最高档**
/// （90/120Hz），手指停下约 700ms 后回落到系统默认档。
///
/// 为什么只在滑动期开启：静止时画面几乎不更新，高刷只会让面板多刷空帧，
/// 白白耗电（部分 OLED 机型还会因为强制高刷而无法进入自适应降频）。
/// 因此这里只在「滑动中」持有高刷，静止就立刻还给系统。
///
/// 为什么失败要永久停用：通道缺失（老包 / 非 Android / 宿主未注册）会抛
/// [MissingPluginException]。滚动期间 `ScrollUpdateNotification` 每帧都会
/// 调进来，若每次重试都要走一遍平台通道 + 抛异常，主线程会被异常构造和
/// 平台消息往返拖慢，反而比不开高刷更卡。所以一旦失败就置 `_unsupported`，
/// 本次会话不再尝试。
class DisplayRefreshService {
  DisplayRefreshService._();

  static final DisplayRefreshService instance = DisplayRefreshService._();

  static const _channel = MethodChannel('com.md3music.md3music/display_refresh');

  /// 距最后一次滑动事件多久后回落。取 700ms：
  /// 短于惯性滚动（fling）的尾段会反复 request/release 抖动，
  /// 长于用户「停下即点击」的感知阈值又会显得降档迟钝。
  static const _releaseDelay = Duration(milliseconds: 700);

  /// 测试钩子：非空时代替真实 [MethodChannel] 调用，签名与 `invokeMethod` 一致。
  /// 真实运行路径只在它为 `null` 时走平台通道（避免任何线上旁路）。
  @visibleForTesting
  static Future<dynamic> Function(String method)? debugChannelOverride;

  /// 测试钩子：`null` 时按真实平台判定（`!kIsWeb && Platform.isAndroid`）；
  /// 非空时直接覆盖判定结果，用于在桌面/CI 宿主上模拟 Android 与非 Android。
  @visibleForTesting
  static bool? debugPlatformOverride;

  bool _highRefreshActive = false; // 当前是否处于（我们请求的）高刷态
  bool _unsupported = false; // 通道/设备不支持，本次会话永久降级
  bool _requestInFlight = false; // 请求在途，避免连续 beginScroll 重复发通道
  Timer? _releaseTimer;
  double _lastReportedMaxFps = 0; // 原生回报的实际最高刷新率，取不到为 0

  @visibleForTesting
  bool get isHighRefreshActive => _highRefreshActive;

  @visibleForTesting
  double get lastReportedMaxFps => _lastReportedMaxFps;

  bool get _isAndroidPlatform {
    final override = debugPlatformOverride;
    if (override != null) return override;
    // Web 端没有 dart:io 的平台概念，直接排除；其他桌面/移动平台也不处理。
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  /// 滑动中反复调用：重置 700ms 释放定时器；首次进入时请求最高刷新率。
  Future<void> beginScroll() async {
    if (!_isAndroidPlatform) return;
    if (_unsupported) return;
    // 每帧都会进来，先续命定时器（幂等：重复调用只是把到期时间往后推）。
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_releaseDelay, _onReleaseTimer);
    if (_highRefreshActive) return;
    await _request();
  }

  /// 滑动结束（`ScrollEndNotification`）：立即起 700ms 释放定时器。
  ///
  /// 不在这里直接 release：惯性滚动后的轻触/回弹仍可能有零星更新，
  /// 统一走定时器可以让「开始—结束—再开始」的短间隔不来回切档。
  Future<void> endScroll() async {
    if (!_isAndroidPlatform) return;
    if (_unsupported) return;
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_releaseDelay, _onReleaseTimer);
  }

  /// 测试用：撤销定时器；若处于高刷态则还原系统默认档。
  ///
  /// 顺带把单例复位到初始态（`_unsupported` / `_lastReportedMaxFps`），
  /// 否则单个用例的降级状态会污染后续用例。
  @visibleForTesting
  Future<void> dispose() async {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    if (_highRefreshActive) {
      await _release();
    }
    _unsupported = false;
    _lastReportedMaxFps = 0;
  }

  void _onReleaseTimer() {
    _releaseTimer = null;
    unawaited(_release());
  }

  /// 请求最高刷新率。幂等：已在目标态 / 已在途 / 已降级都不发通道。
  Future<void> _request() async {
    if (_unsupported || _highRefreshActive || _requestInFlight) return;
    _requestInFlight = true;
    try {
      final raw = await _invoke('requestMax');
      final fps = raw is num ? raw.toDouble() : 0.0;
      if (fps <= 0) {
        // 原生侧取不到模式或应用失败时返回 0——按「不支持」处理，
        // 不弹提示、不影响滚动，只是本次会话不再尝试。
        _unsupported = true;
        return;
      }
      _lastReportedMaxFps = fps;
      _highRefreshActive = true;
      // 请求在途期间定时器可能已经到期（手指早就停了）：
      // 此时不能再留着高刷，立即回落，避免面板被卡在最高档。
      if (_releaseTimer == null) {
        await _release();
      }
    } on MissingPluginException {
      _unsupported = true;
    } on PlatformException {
      _unsupported = true;
    } finally {
      _requestInFlight = false;
    }
  }

  /// 还原系统默认刷新率。幂等：不在高刷态则不发通道。
  Future<void> _release() async {
    if (!_highRefreshActive) return;
    _highRefreshActive = false;
    if (_unsupported) return;
    try {
      await _invoke('release');
    } on MissingPluginException {
      _unsupported = true;
    } on PlatformException {
      _unsupported = true;
    }
  }

  Future<dynamic> _invoke(String method) {
    final override = debugChannelOverride;
    if (override != null) return override(method);
    // 只接受无参调用：这两个方法都不需要任何来自 Dart 侧的入参，
    // 也不暴露任何可被外部进程/深链触发的入口。
    return _channel.invokeMethod<dynamic>(method);
  }
}
