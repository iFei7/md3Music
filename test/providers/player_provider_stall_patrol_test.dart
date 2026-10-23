/// 批次30：stalled 巡检器（续播/恢复播放无声死局修复）测试。
///
/// 场景坐实自主控真机诊断日志（v5.9.23 诊断版）：断网 6 小时后 resume，
/// ExoPlayer stalled 在 position=7220ms，平台层停发位置事件
/// （positionStream 静默），所有挂在 positionStream 里的既有看门狗
/// （位置兜底切歌 / CDN 速率检测 / 预防性预取）全部停摆；fork 的
/// position getter 按挂钟外推，Dart 侧看到进度正常在走、实际无声。
///
/// 本组用例验证独立 Timer 巡检器（不依赖 positionStream 驱动）能发现该
/// 死局并复用既有恢复链路（[_handleCdnStall] 的 URL 刷新 + 断点续播），
/// 恢复失败时收敛为用户可见的「播放失败请重试」。
///
/// 注意：巡检基于 `Timer.periodic` + `DateTime.now()` 的真实时间轴，
/// fake async 时钟推不动，故用 `test()` 而非 `testWidgets()`；
/// 生产阈值（3s/3s/12s）经构造参数注入缩到亚秒级。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';
import '../test_helpers/fake_secure_storage.dart';

/// 巡检阈值注入（生产值见 PlayerProvider 的 _stallEventSilenceThreshold 等常量）：
/// 事件停发判定 300ms、防抖持续 300ms、恢复观察窗 800ms。
const Duration _fastSilence = Duration(milliseconds: 300);
const Duration _fastPersist = Duration(milliseconds: 300);
const Duration _fastWatch = Duration(milliseconds: 800);

/// 判据 B 专用：事件持续（间隔 300ms < 停发阈值 800ms），保证判据 A 不成立。
const Duration _wideSilence = Duration(milliseconds: 800);

/// 真机日志坐实的 stalled 断点（resume 后卡死的位置）。
const Duration _stalledPosition = Duration(milliseconds: 7220);

Song _onlineSong(String id) => Song(
  id: id,
  title: 'Stall Patrol $id',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  url: 'https://media.example/$id.mp3',
  isOnline: true,
);

/// 播放链接解析接口不可用（503）：[_handleCdnStall] 拿不到新 URL，
/// 且不产生任何装载——用于验证巡检器的「恢复失败可见收敛」。
class _UnavailablePlaybackUrlAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      return ResponseBody.fromString(
        '{}',
        503,
        headers: const {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '平台位置事件停发且播放中：巡检判定 stalled 并复用换源续播恢复',
    () async {
      SharedPreferences.setMockInitialValues({});
      final audio = ControlledAudioService();
      AudioServiceLoader.setTestOverride(() async => audio);
      final player = PlayerProvider(
        stallPatrolEventSilence: _fastSilence,
        stallPatrolPersistWindow: _fastPersist,
        stallPatrolRecoveryWatchWindow: _fastWatch,
      );
      try {
        await player.audioReady.timeout(const Duration(seconds: 10));
        final song = _onlineSong('stall-patrol-event-silence');
        final initialPlay = player.playSong(song);
        await audio.waitForPlaylistLoads(1);
        await audio.completeSourceLoad(0);
        await initialPlay;
        audio.emitPlaying(true);

        // 平台最后一次上报位置（真机 7220ms 场景）后停发位置事件（stalled）：
        // 既有看门狗全部挂在 positionStream 上，此时已完全停摆。
        audio.setDiagnosticSnapshot(
          position: _stalledPosition,
          bufferedPosition: _stalledPosition,
          speed: 1,
        );
        audio.emitPosition(_stalledPosition);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        player.debugSetPrefetchedCdnUrlForTest(
          songId: song.id,
          url: 'https://media.example/refreshed.mp3',
          quality: '128',
        );

        // 巡检器不依赖 positionStream：平台停发事件后仍应触发既有恢复装载
        await audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 6));
        expect(
          audio.playlistLoads,
          hasLength(2),
          reason: 'stalled 判定应触发既有 CDN 换源恢复（setUrl 再次发生）',
        );
        expect(
          audio.sourceInitialPositions.last,
          _stalledPosition,
          reason: '断点续播必须使用平台真实位置，不能回退到 0',
        );

        // 恢复成功：新源装载完成且平台位置事件恢复
        await audio.completeSourceLoad(1);
        final recoveryDeadline = DateTime.now().add(
          const Duration(seconds: 2),
        );
        while (player.isResolvingUrl &&
            DateTime.now().isBefore(recoveryDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(player.isResolvingUrl, isFalse);
        audio.setDiagnosticSnapshot(
          position: const Duration(milliseconds: 7300),
          bufferedPosition: const Duration(seconds: 60),
          speed: 1,
        );
        audio.emitPosition(const Duration(milliseconds: 7300));
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        expect(
          player.resolveError,
          isNull,
          reason: '恢复成功后不得落入失败收敛',
        );
      } finally {
        player.dispose();
        await audio.dispose();
        AudioServiceLoader.setTestOverride(null);
      }
    },
  );

  test('正常播放（位置事件持续、缓冲在前）不误判 stalled', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider(
      stallPatrolEventSilence: _wideSilence,
      stallPatrolPersistWindow: _fastPersist,
      stallPatrolRecoveryWatchWindow: _fastWatch,
    );
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = _onlineSong('stall-patrol-healthy');
      final initialPlay = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);

      // 位置事件每 300ms 持续上报（< 停发阈值），缓冲始终在位置前方
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var positionMs = _stalledPosition.inMilliseconds;
      while (DateTime.now().isBefore(deadline)) {
        positionMs += 300;
        final position = Duration(milliseconds: positionMs);
        audio.setDiagnosticSnapshot(
          position: position,
          bufferedPosition: position + const Duration(seconds: 20),
          speed: 1,
        );
        audio.emitPosition(position);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      expect(
        audio.playlistLoads,
        hasLength(1),
        reason: '正常播放不得被巡检器误判为 stalled 而换源',
      );
      expect(player.resolveError, isNull);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('URL 加载保护期内停发事件不触发，保护窗外才触发', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider(
      stallPatrolEventSilence: _fastSilence,
      stallPatrolPersistWindow: _fastPersist,
      stallPatrolRecoveryWatchWindow: _fastWatch,
    );
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = _onlineSong('stall-patrol-load-guard');
      // playPlaylist 走 _setUrlAndPlay：_lastUrlLoadStarted 被记录，
      // 3s 加载保护窗内巡检器不得触发（复用既有 _urlLoadGuardWindow 门控）。
      final initialPlay = player.playPlaylist([song], 0);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      audio.setDiagnosticSnapshot(
        position: _stalledPosition,
        bufferedPosition: _stalledPosition,
        speed: 1,
      );
      audio.emitPosition(_stalledPosition);
      player.debugSetPrefetchedCdnUrlForTest(
        songId: song.id,
        url: 'https://media.example/refreshed.mp3',
        quality: '128',
      );

      // 保护窗（3s）内：同样的停发场景不得触发
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(
        audio.playlistLoads,
        hasLength(1),
        reason: 'URL 加载保护期内不得触发巡检恢复',
      );

      // 保护窗外：同样的停发场景应触发（正对照，证明上方是门控生效而非巡检失效）
      await audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 6));
      expect(audio.playlistLoads, hasLength(2));
      expect(audio.sourceInitialPositions.last, _stalledPosition);
      await audio.completeSourceLoad(1);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('恢复失败（解析不可用）收敛为用户可见的播放失败态', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    apiClient.dio.httpClientAdapter = _UnavailablePlaybackUrlAdapter();
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider(
      stallPatrolEventSilence: _fastSilence,
      stallPatrolPersistWindow: _fastPersist,
      stallPatrolRecoveryWatchWindow: _fastWatch,
    );
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = _onlineSong('stall-patrol-recovery-failed');
      final initialPlay = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      audio.setDiagnosticSnapshot(
        position: _stalledPosition,
        bufferedPosition: _stalledPosition,
        speed: 1,
      );
      audio.emitPosition(_stalledPosition);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 无预取 URL + 解析接口 503：恢复失败必须在观察窗超时后收敛为
      // 可见的失败态（用户正在听歌时遭遇，属交互路径），而非静默假播。
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(
        player.resolveError,
        isNotNull,
        reason: '恢复失败必须让用户看到重试入口，不得静默假播',
      );
      expect(player.resolveErrorForDisplay, isNotNull);
      expect(player.isPlaybackNotReady, isTrue);
      expect(
        audio.playlistLoads,
        hasLength(1),
        reason: '解析失败不产生新装载，也不得循环触发巡检',
      );
      expect(audio.playCommandCount, 1, reason: '失败收敛不得擅自起播');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('判据 B（外推位置超过缓冲）持续成立即触发，缓冲恢复后不重复触发', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider(
      stallPatrolEventSilence: _wideSilence,
      stallPatrolPersistWindow: _fastPersist,
      stallPatrolRecoveryWatchWindow: _fastWatch,
    );
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = _onlineSong('stall-patrol-extrapolation');
      final initialPlay = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await initialPlay;
      audio.emitPlaying(true);
      player.debugSetPrefetchedCdnUrlForTest(
        songId: song.id,
        url: 'https://media.example/refreshed.mp3',
        quality: '128',
      );

      // 判据 B：位置事件仍在持续（判据 A 不成立），但外推位置持续超过
      // 缓冲末端（fork getter 挂钟外推超过 bufferedPosition = 缓冲耗尽铁证）。
      final triggerDeadline = DateTime.now().add(const Duration(seconds: 6));
      while (audio.playlistLoads.length < 2 &&
          DateTime.now().isBefore(triggerDeadline)) {
        audio.setDiagnosticSnapshot(
          position: _stalledPosition,
          bufferedPosition: const Duration(milliseconds: 5000),
          speed: 1,
        );
        audio.emitPosition(_stalledPosition);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(
        audio.playlistLoads,
        hasLength(2),
        reason: '判据 B 持续成立应触发既有恢复',
      );
      expect(audio.sourceInitialPositions.last, _stalledPosition);

      // 恢复装载完成；排除起播宽限门控后，缓冲回到位置前方 + 事件持续：
      // 判据消失，不得重复触发换源。
      await audio.completeSourceLoad(1);
      player.debugExpireRateCheckGraceForTest();
      final clearDeadline = DateTime.now().add(const Duration(seconds: 3));
      var positionMs = _stalledPosition.inMilliseconds + 100;
      while (DateTime.now().isBefore(clearDeadline)) {
        positionMs += 300;
        final position = Duration(milliseconds: positionMs);
        audio.setDiagnosticSnapshot(
          position: position,
          bufferedPosition: position + const Duration(seconds: 15),
          speed: 1,
        );
        audio.emitPosition(position);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(
        audio.playlistLoads,
        hasLength(2),
        reason: '缓冲恢复正常后不得重复触发巡检恢复',
      );
      expect(player.resolveError, isNull);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}
