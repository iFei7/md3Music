import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 硬解播放（audio offload）的**真实运行状态**（批次45）。
///
/// 与 `audio_offload_config.dart` 里的 AudioOffloadConfig 的区别是这一条最要紧：
/// - `AudioOffloadConfig` 描述的是「我们**下发了**什么偏好」——意愿；
/// - 本类是「Media3 + 系统**实际**协商出了什么」——事实。
///
/// 两者不一致是常态：设备不支持、格式不支持（如部分无损/高码率）、
/// 或走了 passthrough 直通，都会让偏好生效但硬解没真正开启。
/// 在此之前 App 只能靠 adb 看 AudioTrack 猜，本类把 ground truth 拉回 Dart。
///
/// 数据来源（Java 侧 `AudioPlayer.pushOffloadStatus()`，独立通道
/// `com.md3music.md3music/audio_offload`）：
/// - [offloaded]：`AudioTrack.isOffloadedPlayback()` 的真实返回值，由 Media3
///   `DefaultAudioSink.buildAudioTrack()` 在创建 AudioTrack 后回调
///   `AudioOffloadListener.onOffloadedPlayback()` 带出。**这是硬解是否真正
///   生效的唯一判据**，不是「我们下发了偏好」。
/// - [sleepingForOffload]：播放器主循环是否为省电停摆。为 true 说明 offload
///   scheduling 生效——系统把唤醒交给音频硬件，CPU 可以睡，**这是省电
///   真实生效的直接证据**（Media3 `ExoPlayerImpl.updatePlaybackInfo` 里
///   `sleepingForOffload` 变化时回调）。
///
/// 两者**都可能为 false**，且各自独立：
/// - 设备/格式不支持硬解 → offloaded=false（退回软解或 passthrough）；
/// - 硬解生效但没开 offload scheduling → sleeping 一直 false。
@immutable
class AudioOffloadStatus {
  const AudioOffloadStatus({
    required this.offloaded,
    required this.sleepingForOffload,
  });

  /// 底层 AudioTrack 是否真的处于 offload 播放（`isOffloadedPlayback()`）。
  final bool offloaded;

  /// 播放器主循环是否因 offload 而停摆（省电生效的证据）。
  final bool sleepingForOffload;

  /// 把平台通道传来的消息解析成状态对象；**纯函数、绝不抛异常**。
  ///
  /// 解析规则（与 Java 侧 `pushOffloadStatus()` 的 `{offloaded, sleeping}` 对齐）：
  /// - `message` 不是 `Map`（null / 字符串 / 列表…）→ 返回 null，调用方保持
  ///   「未知」而不是误判成软解；
  /// - **缺键** → 该字段按 false 处理（Java 固定发两个键，缺键只可能是未来裁剪
  ///   协议，此时另一个键仍然可信）；
  /// - **类型不符**（如 `{offloaded: "yes"}`）→ **整条丢弃返回 null**。
  ///   理由：类型错意味着载荷不是我们理解的协议，此时「把另一个字段当真」
  ///   会把未知静默说成 offloaded=false，UI 就会显示"确认软解"——那是一个
  ///   比"未知"更糟的错误结论。宁可让 UI 继续显示未知，等下一次自洽的事件。
  static AudioOffloadStatus? fromMap(dynamic message) {
    if (message is! Map) return null;
    final offloaded = _readBool(message, 'offloaded', false);
    final sleeping = _readBool(message, 'sleeping', false);
    if (identical(offloaded, _typeError) || identical(sleeping, _typeError)) {
      return null;
    }
    return AudioOffloadStatus(
      offloaded: offloaded as bool,
      sleepingForOffload: sleeping as bool,
    );
  }

  /// 类型不符的哨兵：与「缺键回退 false」区分开，避免把协议错位当成软解。
  static const Object _typeError = Object();

  /// 读一个布尔字段：缺键 → [fallback]；存在但不是 bool → 返回 [_typeError]。
  static Object _readBool(Map<dynamic, dynamic> map, String key, bool fallback) {
    if (!map.containsKey(key)) return fallback;
    final value = map[key];
    return value is bool ? value : _typeError;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioOffloadStatus &&
          other.offloaded == offloaded &&
          other.sleepingForOffload == sleepingForOffload;

  @override
  int get hashCode => Object.hash(offloaded, sleepingForOffload);

  @override
  String toString() =>
      'AudioOffloadStatus(offloaded: $offloaded, '
      'sleepingForOffload: $sleepingForOffload)';
}

/// 硬解状态的接收端（批次45）。
///
/// 为什么是**独立通道**而不是 `com.ryanheise.just_audio.methods.$id`：
/// lite 内联的 just_audio Dart 侧在该通道上只有 `invokeMethod`，
/// 全文没有 `setMethodCallHandler`，Java 往里回传会直接丢包。
/// 因此 Java/Dart 各自持有一个同名独立通道
/// `com.md3music.md3music/audio_offload`。
///
/// 线程/生命周期：通道回调在主线程分发，直接写 [status] 即可；
/// [start] 幂等，重复调用不会重复注册。
class AudioOffloadStatusService {
  AudioOffloadStatusService._();

  static final AudioOffloadStatusService instance = AudioOffloadStatusService._();

  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/audio_offload',
  );

  /// Java 侧固定使用的方法名。
  static const String _methodName = 'audioOffloadStatus';

  /// 最近一次收到的真实状态；**null = 尚未收到任何事件**。
  ///
  /// UI 必须把 null 显示为"未知"，而不是"软解"：
  /// 播放器还没起播 / 还没建 AudioTrack 时，我们确实一无所知。
  /// （未被通知 ≠ 没开硬解。）
  final ValueNotifier<AudioOffloadStatus?> status =
      ValueNotifier<AudioOffloadStatus?>(null);

  bool _started = false;

  /// 开始监听（幂等）。
  ///
  /// 非 Android 平台直接返回：该通道由 Android 的 just_audio fork 实现，
  /// 桌面 / iOS / Web 上不存在发送方，注册了也只会永远收到 null。
  ///
  /// 用 [defaultTargetPlatform] 而不是 `dart:io` 的 `Platform.isAndroid`：
  /// 本文件可能被打进 Web 构建，`dart:io` 会直接编译失败。
  void start() {
    if (_started) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _started = true;
    try {
      _channel.setMethodCallHandler(_handleCall);
    } catch (_) {
      // 注册失败只意味着拿不到状态，绝不能影响播放。
      _started = false;
    }
  }

  /// 撤销接收端（测试用；生产环境不调用）。
  void stop() {
    _started = false;
    try {
      _channel.setMethodCallHandler(null);
    } catch (_) {}
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method != _methodName) return null;
    _apply(call.arguments);
    return null;
  }

  /// 唯一的解析入口：通道回调与测试注入共用同一条路径。
  ///
  /// 解析失败时**保留上一个值**而不是清成 null：一次畸形消息不足以推翻
  /// 已知事实，下一次正常事件会覆盖它。
  void _apply(dynamic message) {
    try {
      final parsed = AudioOffloadStatus.fromMap(message);
      if (parsed != null) status.value = parsed;
    } catch (_) {
      // fromMap 本身不抛；这里只是兜住任何意外（例如自定义 Map 实现）。
    }
  }

  /// 测试入口：绕过真实通道，把一条消息喂进同一条解析路径。
  @visibleForTesting
  void handleMessageForTest(dynamic message) => _apply(message);
}
