// MD3Music fork: playbackSuppressionReason（播放抑制原因）事件通道的 Dart 侧单测。
//
// 事件契约（与 Android 侧 AudioPlayer.java 中 BetterEventChannel 的转发一一对应）：
//   channel: com.ryanheise.just_audio.suppression_events.<playerId>
//   payload: {'suppressionReason': int}
//   reason 取值对齐 androidx.media3.common.Player.PLAYBACK_SUPPRESSION_REASON_*：
//     0 = NONE（无抑制，正常出声）
//     1 = TRANSIENT_AUDIO_FOCUS_LOSS（瞬时音频焦点丢失，等待焦点回调期间抑制输出）
//     2 = UNSUITABLE_AUDIO_OUTPUT（无合适音频输出设备，如拔耳机/蓝牙断开）
// 行为语义：reason != 0 时 ExoPlayer 的 playWhenReady 仍可能为 true、
// playbackState 仍为 READY、position 继续前进，但音频输出被抑制（无声）。
// 排查「进度条走但没声音」时优先订阅本流。
//
// 本文件用 mock channel（TestDefaultBinaryMessenger）验证 Dart 侧对上述
// 契约事件的解码：合法 payload 入流、非法 payload 安全忽略、dispose 后断开。
// 自包含 mock 平台（不依赖 mockito），经根项目包解析运行。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// 最小 mock 平台：仅实现激活 native 播放器所必需的方法
/// （setUrl → _setPlatformActive(true) 会依次调用这些 setter 与 load）。
class _MockJustAudioPlatform extends JustAudioPlatform
    with MockPlatformInterfaceMixin {
  _MockJustAudioPlatform() : super();

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    _lastInitId = request.id;
    return _MockAudioPlayerPlatform(request.id);
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    return DisposePlayerResponse();
  }
}

class _MockAudioPlayerPlatform extends AudioPlayerPlatform {
  _MockAudioPlayerPlatform(String id) : super(id);

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _eventController.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: const Duration(seconds: 30),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
    return LoadResponse(duration: const Duration(seconds: 30));
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
      SetSkipSilenceRequest request) async {
    return SetSkipSilenceResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    return SetShuffleModeResponse();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  JustAudioPlatform.instance = _MockJustAudioPlatform();
  const audioSessionChannel = MethodChannel('com.ryanheise.audio_session');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  /// 冲刷微任务/事件循环，等待事件通道的异步派发完成。
  Future<void> pumpEventQueue() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    messenger.setMockMethodCallHandler(audioSessionChannel,
        (MethodCall methodCall) async {
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(audioSessionChannel, null);
  });

  test('playbackSuppressionReasonStream decodes suppression events',
      () async {
    final player = AudioPlayer();
    // 激活 native 平台（mock），事件通道名后缀即平台侧 player id。
    await player.setUrl('https://foo.foo/foo.mp3');
    // 平台侧 id 无法直接从 Dart 公开 API 读取，经最近一次 init 请求取。
    final platformId = _lastInitId;
    expect(platformId, isNotNull);
    final suppressionChannel =
        'com.ryanheise.just_audio.suppression_events.$platformId';

    final reasons = <int>[];
    // ignore: discarded_futures
    final subscription = player.playbackSuppressionReasonStream.listen(
      reasons.add,
    );
    await pumpEventQueue();
    // BehaviorSubject 种子值 0（NONE）随订阅立即发出。
    expect(reasons, equals(<int>[0]));

    // 模拟 Java 侧 eventSink.success(map) 经 StandardMethodCodec 的编码。
    Future<void> pushEvent(Object? payload) =>
        messenger.handlePlatformMessage(
          suppressionChannel,
          codec.encodeSuccessEnvelope(payload),
          (ByteData? reply) {},
        );

    // 契约 payload：{'suppressionReason': int}
    await pushEvent(const <String, Object?>{'suppressionReason': 2});
    await pushEvent(const <String, Object?>{'suppressionReason': 1});
    await pushEvent(const <String, Object?>{'suppressionReason': 0});
    await pumpEventQueue();
    expect(reasons, equals(<int>[0, 2, 1, 0]));

    // 非契约 payload 必须被安全忽略：不入流、不抛错。
    await pushEvent(const <String, Object?>{'unexpected': 7});
    await pushEvent('not-a-map');
    await pushEvent(null);
    await pumpEventQueue();
    expect(reasons, equals(<int>[0, 2, 1, 0]));

    // dispose 路径必须清理通道订阅：之后再推事件不再入流。
    await player.dispose();
    await pushEvent(const <String, Object?>{'suppressionReason': 2});
    await pumpEventQueue();
    expect(reasons, equals(<int>[0, 2, 1, 0]));

    await subscription.cancel();
  });
}

/// 记录最近一次 init 的平台 id（mock 平台无公开 id 查询途径）。
String? _lastInitId;
