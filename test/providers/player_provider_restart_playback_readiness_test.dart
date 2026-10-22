import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/playback_recovery_budget.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';
import '../test_helpers/fake_secure_storage.dart';

/// 批次27：冷启动续播（_restoreState → play=false 装载）失败收敛与
/// resume() 无音源兜底的行为契约。
///
/// 背景（根因链）：恢复路径的失败出口全部静默——不置 _playbackNotReady、
/// 不置 _resolveError，随后 StartupAutoPlay 的 resume() 判 needsReload=false，
/// 把 play() 打到没有 mediaSource 的 ExoPlayer（STATE_IDLE）上：不播、无输出、
/// Media3 通知不显示，而 Dart 侧 _isPlaying 已乐观置真，用户看到「播放中但
/// 没声音、无通知栏控件」，进度条只是恢复路径回填的假象。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 种入「上次播放」持久化状态：一首在线歌曲。
  ///
  /// [url] 置空（null）模拟「上次会话的链接已失效/未解析，冷启动必须走 API
  /// 重新解析」——正是 no_url 失败出口的入口；置非空则模拟「旧链接仍在
  /// song 上、直接进装载」的真实冷启动路径（装载失败出口的入口）。
  Map<String, Object> _seedRestoredOnlineSong(String songId, {String? url}) {
    final songJson = jsonEncode({
      'id': songId,
      'title': 'Restore Target',
      'artist': 'Artist',
      'album': 'Album',
      'duration': 180000,
      'url': url,
      'isOnline': true,
    });
    return <String, Object>{
      'settings_restore_memory': true,
      'player_current_song': songJson,
      'player_playlist': <String>[songJson],
      'player_current_index': 0,
      'player_position': 60000,
      'player_loop_mode': 'off',
      'player_shuffle_enabled': false,
    };
  }

  test('批次27：续播URL解析失败收敛为未就绪标志，resume走重新解析且不自动重试', () async {
    SharedPreferences.setMockInitialValues(
      _seedRestoredOnlineSong('restore-url-failed'),
    );
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _AlwaysFailPlaybackUrlAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    // 零退避：后台兜底定时器一旦被错误武装，会立刻发起自动重试——
    // 本测试用「解析请求数不涨」来证明静默失败没有武装自动重试。
    final budget = PlaybackRecoveryBudget(
      backoff: [Duration.zero, Duration.zero, Duration.zero],
    );
    final player = PlayerProvider(failedRecoveryBudget: budget);
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));

      // —— 静默失败后的状态：歌曲在、播放流未就绪、无音源、无播放命令 ——
      expect(player.currentSong?.id, 'restore-url-failed');
      expect(audio.playlistLoads, isEmpty);
      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
      // 批次27：失败出口收敛——标志置位，resume() 的 needsReload 才会触发重新解析。
      expect(player.isPlaybackNotReady, isTrue);
      // 静默路径不弹窗不 toast，但给非打扰文案（UI 提示条 + 重试按钮）。
      expect(player.resolveError, kSilentResolveErrorText);
      expect(player.resolveErrorForDisplay, kSilentResolveErrorText);

      final countAfterRestore = adapter.playbackUrlRequestCount;
      expect(countAfterRestore, greaterThan(0));

      // —— 自动重试不得被武装：后台兜底定时器 + 回前台都不发起解析 ——
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.playbackUrlRequestCount, countAfterRestore);

      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.playbackUrlRequestCount, countAfterRestore);

      // —— resume() 必须走重新解析分支（修复前 needsReload=false 直接空转）——
      await player.resume();
      expect(
        adapter.playbackUrlRequestCount,
        greaterThan(countAfterRestore),
        reason: 'resume() 应触发重新解析，而不是把 play() 打到空播放器上',
      );
      // 重新解析仍失败：依旧没有装载过音源、没有下发过播放命令。
      expect(audio.playlistLoads, isEmpty);
      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
      // 用户主动 intent 的失败回归既有交互文案（自动重试语义也随之恢复）。
      expect(player.resolveError, '无法获取播放链接');
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('批次27：续播旧URL被清后走完整解析，装载成功不误置未就绪标志', () async {
    // 种入带旧 URL 的在线歌：_restoreState 必须真正把它清掉
    // （copyWith(clearUrl: true)）并走 API 完整解析，否则旧链接会被直接
    // 复用——过期即装载失败。
    SharedPreferences.setMockInitialValues(
      _seedRestoredOnlineSong(
        'restore-succeeded',
        url: 'https://media.example/expired.mp3',
      ),
    );
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _SuccessfulPlaybackUrlAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      // 恢复流程会阻塞在音源装载上：先放行装载再等就绪信号。
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await audio.completeSourceLoad(0);
      await player.audioReady.timeout(const Duration(seconds: 10));

      // 成功路径：标志保持干净，不误报「播放流未就绪」。
      expect(player.currentSong?.id, 'restore-succeeded');
      expect(player.currentSong?.url, adapter.resolvedUrl);
      expect(audio.playlistLoads, hasLength(1));
      expect(audio.playCommandCount, 0); // play=false：只装载不起播
      expect(player.isPlaybackNotReady, isFalse);
      expect(player.resolveError, isNull);
      expect(player.isPlaying, isFalse);

      // 有音源时 resume() 不需要重新装载，直接补发播放命令。
      await player.resume();
      expect(audio.playlistLoads, hasLength(1));
      expect(audio.playCommandCount, 1);
      expect(player.isPlaying, isTrue);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('批次27：续播旧URL装载失败（非超时异常）收敛为未就绪标志，resume重新装载可恢复', () async {
    // 种入带旧 URL 的在线歌。批次27 修正后 _restoreState 会真正清掉它
    // （copyWith(clearUrl: true)），恢复走 API 解析拿到新链接再装载；
    // 这里用 nextSetUrlError 让第一次装载抛非超时异常，验证失败收敛与
    // resume 的「再清 URL → 再解析 → 再装载」闭环。
    SharedPreferences.setMockInitialValues(
      _seedRestoredOnlineSong(
        'restore-stale-url',
        url: 'https://media.example/expired.mp3',
      ),
    );
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _SuccessfulPlaybackUrlAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService()
      ..nextSetUrlError = StateError(
        'decoder failed: https://secret.invalid/signed',
      );
    AudioServiceLoader.setTestOverride(() async => audio);
    // 零退避：后台兜底定时器一旦被错误武装，会立刻发起自动重试。
    final budget = PlaybackRecoveryBudget(
      backoff: [Duration.zero, Duration.zero, Duration.zero],
    );
    final player = PlayerProvider(failedRecoveryBudget: budget);
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));

      // 恢复路径：旧 URL 被清 → API 解析成功 → setUrl 抛非超时异常。
      // 解析至少发生一次，装载从未成功，从未起播。
      expect(adapter.playbackUrlRequestCount, greaterThan(0));
      expect(audio.sourceInitialPositions, hasLength(1));
      expect(audio.playlistLoads, isEmpty);
      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
      // 批次27：非超时的装载异常同样置「播放流未就绪」；静默路径写哨兵
      // 文案且不武装自动重试。
      expect(player.isPlaybackNotReady, isTrue);
      expect(player.resolveError, kSilentResolveErrorText);

      // 自动重试不得被武装（后台定时器 + 回前台）。
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(budget.attempts, 0);
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(budget.attempts, 0);

      // resume() 走重新装载分支：song.url 已是恢复时解析出的新链接（有效），
      // 直接装载、不再重复解析（解析计数不变）；这次装载放行 → 真正恢复播放。
      final countBeforeResume = adapter.playbackUrlRequestCount;
      final resumeRequest = player.resume();
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await resumeRequest;

      expect(
        adapter.playbackUrlRequestCount,
        countBeforeResume,
        reason: 'resume 直接装载恢复时解析出的有效链接，不重复解析',
      );
      expect(audio.sourceInitialPositions, hasLength(2));
      expect(audio.playlistLoads, hasLength(1));
      expect(audio.playCommandCount, 1);
      expect(player.isPlaying, isTrue);
      expect(player.currentSong?.id, 'restore-stale-url');
      expect(player.currentSong?.url, adapter.resolvedUrl);
      // 批次27：重新装载成功即恢复播放，清掉失败残留文案。
      expect(player.resolveError, isNull);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('批次27：播放器无音源时resume兜底走重新装载（不依赖状态标志）', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    // resume 兜底 reload 会先清旧 URL 再解析（批次27），需要解析 mock。
    final adapter = _SuccessfulPlaybackUrlAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'no-source-resume',
        title: 'No Source Resume',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/no-source.mp3',
        isOnline: true,
      );

      final playRequest = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await playRequest;
      await player.pause();

      expect(audio.playlistLoads, hasLength(1));
      expect(player.isPlaybackNotReady, isFalse);

      // 模拟「状态标志全部漏置、但播放器客观上没有音源」：直接把播放器
      // 置为 idle 且不发 playerState 事件（发事件会把 _playbackNotReady
      // 同步置位，就测不到兜底判据了）。
      audio.player.processingState = just_audio.ProcessingState.idle;

      final resumeRequest = player.resume();
      await audio.waitForPlaylistLoads(2);
      await audio.completeSourceLoad(1);
      await resumeRequest;

      // 兜底判据触发重新装载，装载成功后才真正下发播放命令——
      // 修复前这里会把 play() 打到 STATE_IDLE 的空播放器上（无声、无通知）。
      expect(audio.playlistLoads, hasLength(2));
      expect(audio.playCommandCount, 2);
      expect(player.isPlaying, isTrue);
      expect(player.currentSong?.id, song.id);
      // 装载用的仍是 playSong 时解析保留的有效链接（resume 不清 URL）。
      expect(player.currentSong?.url, song.url);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      apiClient.dio.httpClientAdapter = originalAdapter;
      await apiClient.clearCookies();
      uninstallFakeSecureStorage();
    }
  });

  test('批次27：播放器有音源时resume不误触发兜底（对照）', () async {
    SharedPreferences.setMockInitialValues({});
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));
      final song = Song(
        id: 'has-source-resume',
        title: 'Has Source Resume',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        url: 'https://media.example/has-source.mp3',
        isOnline: true,
      );

      final playRequest = player.playSong(song);
      await audio.waitForPlaylistLoads(1);
      await audio.completeSourceLoad(0);
      await playRequest;
      await player.pause();

      expect(player.isPlaybackNotReady, isFalse);

      await player.resume();

      // 有音源（ready）：不重新装载，直接补发播放命令（既有行为不变）。
      expect(audio.playlistLoads, hasLength(1));
      expect(audio.playCommandCount, 2);
      expect(player.isPlaying, isTrue);
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}

/// /song/url 一律 503：解析必然失败（getSongUrlWithFallback 走完降级链后
/// 返回 null，对应 _resolveAndPlayCurrentSongImpl 的 no_url 失败出口）。
class _AlwaysFailPlaybackUrlAdapter implements HttpClientAdapter {
  int playbackUrlRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      playbackUrlRequestCount++;
    }
    return ResponseBody.fromString(
      '{}',
      503,
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// /song/url 返回可用地址：恢复装载成功路径。
class _SuccessfulPlaybackUrlAdapter implements HttpClientAdapter {
  final String resolvedUrl = 'https://media.example/restored.mp3';

  int playbackUrlRequestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/song/url' ||
        options.uri.path == '/song/url/new') {
      playbackUrlRequestCount++;
      return ResponseBody.fromString(
        jsonEncode({
          'data': {'url': [resolvedUrl], 'quality': '128'},
        }),
        200,
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
