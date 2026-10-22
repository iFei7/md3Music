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

/// 批次28：冷启动续播对齐 Sonify（sonify-ref KugouRepository.kt:1902-2000 的
/// 持久化 URL 缓存 + 失败重解析）的行为契约：
///
/// 1. 恢复播放流**保留旧 URL 直接装载**（零网络请求，不需要登录/token/服务器
///    就绪）——批次27 的「恢复必清 URL」已撤销（真机反馈：每次冷启动都因
///    登录/服务器未就绪解析失败 → 进度清零 + 提示重试）；
/// 2. 旧 URL 装载失败 → **自动重解析一轮**（clearUrl + 重新解析 + 装载，
///    seekTo 仍用恢复进度）——只补这一轮，不无限重试；
/// 3. 再失败落回批次27 收敛：_playbackNotReady + 哨兵文案
///    kSilentResolveErrorText，仍不武装自动重试；用户主动 resume()/重试的
///    reload 分支补 seekTo: _position，续播从上次进度继续（不把 0 写进持久化）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 种入「上次播放」持久化状态：一首在线歌曲。
  ///
  /// [url] 置非空模拟「上次会话的链接仍在 song 上、恢复时直接装载」的
  /// Sonify 式路径（批次28 主路径）；置空则模拟「上次会话未解析出链接，
  /// 恢复必须走 API」——重解析出口的入口。
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

  test('批次28：恢复保留旧URL直接装载，零解析请求，进度=恢复位置', () async {
    // Sonify 式主路径：旧 URL 大多数时候仍有效，恢复直接装载（对齐
    // KugouRepository 的持久化 URL 缓存复用），不发起任何解析请求。
    SharedPreferences.setMockInitialValues(
      _seedRestoredOnlineSong(
        'restore-succeeded',
        url: 'https://media.example/expired-or-valid.mp3',
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

      // 直接装载旧 URL：**没有发起任何解析请求**（零网络请求）。
      expect(adapter.playbackUrlRequestCount, 0,
          reason: '旧 URL 应直接装载，不重解析（对齐 Sonify 的 URL 缓存复用）');
      expect(audio.playlistLoads, hasLength(1));
      // 装载用 initialPosition 一次性定位到恢复进度（平台 prepare 定位）。
      expect(audio.sourceInitialPositions.single, const Duration(seconds: 60));
      // 旧 URL 被保留（未清），装载成功后标志干净。
      expect(player.currentSong?.id, 'restore-succeeded');
      expect(player.currentSong?.url, 'https://media.example/expired-or-valid.mp3');
      expect(audio.playCommandCount, 0); // play=false：只装载不起播
      expect(player.isPlaybackNotReady, isFalse);
      expect(player.resolveError, isNull);
      expect(player.isPlaying, isFalse);

      // 有音源时 resume() 不需要重新装载，直接补发播放命令。
      await player.resume();
      expect(audio.playlistLoads, hasLength(1));
      expect(adapter.playbackUrlRequestCount, 0);
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

  test('批次28：旧URL装载失败→自动重解析一轮→装载成功且保住恢复进度', () async {
    // 第一次装载（旧 URL）失败后，自动 clearUrl + 重新解析 + 再装载一轮；
    // 第二次装载的 initialPosition 必须仍是恢复进度（进度不丢）。
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
    final player = PlayerProvider();
    try {
      // 第一次装载抛异常（不产生 completer），自动重解析后第二次装载才是
      // playlistLoads[0]：等它出现并放行。
      await audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 5));
      await audio.completeSourceLoad(0);
      await player.audioReady.timeout(const Duration(seconds: 10));

      // 自动重解析恰好发生一轮：解析计数 1（第一次装载失败触发的重解析）。
      expect(adapter.playbackUrlRequestCount, 1,
          reason: '装载失败应自动重解析一轮（且仅一轮）');
      // 两次装载（旧 URL + 重解析出的新 URL）都带恢复进度定位。
      expect(audio.sourceInitialPositions, hasLength(2));
      expect(audio.sourceInitialPositions[0], const Duration(seconds: 60));
      expect(
        audio.sourceInitialPositions[1],
        const Duration(seconds: 60),
        reason: '重解析后的装载必须保住恢复进度（initialPosition == 恢复位置）',
      );
      expect(audio.playlistLoads, hasLength(1));
      // 第二次装载成功：真正恢复（但不自动起播），标志干净、无错误文案。
      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
      expect(player.isPlaybackNotReady, isFalse);
      expect(player.resolveError, isNull);
      expect(player.currentSong?.id, 'restore-stale-url');
      expect(player.currentSong?.url, adapter.resolvedUrl);

      // 有音源时 resume() 直接补发播放命令，不再解析、不再装载。
      await player.resume();
      expect(audio.playlistLoads, hasLength(1));
      expect(adapter.playbackUrlRequestCount, 1);
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

  test('批次28：重解析后装载仍失败→哨兵收敛，resume reload带seekTo保进度', () async {
    // 旧 URL 装载失败 → 自动重解析（解析成功）→ 第二次装载也失败 →
    // 落回批次27 收敛（_playbackNotReady + 哨兵文案，不武装自动重试）；
    // 随后用户主动 resume() 走 reload 分支，且必须带 seekTo（重试不丢进度）。
    SharedPreferences.setMockInitialValues(
      _seedRestoredOnlineSong(
        'restore-both-failed',
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
      ..persistentSetUrlError = StateError(
        'decoder failed: https://secret.invalid/signed',
      );
    AudioServiceLoader.setTestOverride(() async => audio);
    // 零退避：后台兜底定时器一旦被错误武装，会立刻发起自动重试——
    // 本测试用「解析请求数/budget 不涨」来证明哨兵语义未被破坏。
    final budget = PlaybackRecoveryBudget(
      backoff: [Duration.zero, Duration.zero, Duration.zero],
    );
    final player = PlayerProvider(failedRecoveryBudget: budget);
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));

      // 恢复路径：两次装载（旧 URL + 重解析出的新 URL）都失败。
      expect(adapter.playbackUrlRequestCount, 1,
          reason: '旧 URL 装载失败后应自动重解析一轮（且仅一轮）');
      expect(audio.sourceInitialPositions, hasLength(2));
      expect(audio.sourceInitialPositions[0], const Duration(seconds: 60));
      expect(audio.sourceInitialPositions[1], const Duration(seconds: 60),
          reason: '第二次装载（自动重解析轮）同样用恢复进度定位');
      expect(audio.playlistLoads, isEmpty);
      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
      // 批次27 收敛保持：标志置位 + 静默哨兵文案。
      expect(player.isPlaybackNotReady, isTrue);
      expect(player.resolveError, kSilentResolveErrorText);

      // 自动重试不得被武装（后台定时器 + 回前台）。
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(budget.attempts, 0);
      expect(adapter.playbackUrlRequestCount, 1);
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(budget.attempts, 0);
      expect(adapter.playbackUrlRequestCount, 1);

      // resume() 走 reload 分支（needsReload），且带 seekTo: _position——
      // 批次28 直接根因修复：不带 seekTo 会从 0 装载并把 0 写进持久化。
      final resumeRequest = player.resume();
      await resumeRequest;
      expect(audio.sourceInitialPositions, hasLength(3));
      expect(
        audio.sourceInitialPositions[2],
        const Duration(seconds: 60),
        reason: 'resume() reload 必须带 seekTo（断言 initialPosition == _position）',
      );
      // 仍失败：无装载成功、无播放命令；用户主动 intent 回归交互文案。
      expect(audio.playlistLoads, isEmpty);
      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
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

  test('批次28：旧URL装载失败后重解析也失败→哨兵收敛，resume重新解析且不自动重试', () async {
    // 批次27「URL 解析失败收敛」用例的批次28 版本：第一次装载（旧 URL）
    // 失败 → 自动重解析在**解析阶段**就失败（503）→ 哨兵语义不变。
    SharedPreferences.setMockInitialValues(
      _seedRestoredOnlineSong(
        'restore-url-failed',
        url: 'https://media.example/expired.mp3',
      ),
    );
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    final adapter = _AlwaysFailPlaybackUrlAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    KugouApiClient.markServerReady();

    final audio = ControlledAudioService()
      ..nextSetUrlError = StateError(
        'decoder failed: https://secret.invalid/signed',
      );
    AudioServiceLoader.setTestOverride(() async => audio);
    // 零退避：后台兜底定时器一旦被错误武装，会立刻发起自动重试——
    // 本测试用「解析请求数不涨」来证明静默失败没有武装自动重试。
    final budget = PlaybackRecoveryBudget(
      backoff: [Duration.zero, Duration.zero, Duration.zero],
    );
    final player = PlayerProvider(failedRecoveryBudget: budget);
    try {
      await player.audioReady.timeout(const Duration(seconds: 10));

      // —— 两次尝试都失败后的状态：歌曲在、播放流未就绪、无音源、无播放命令 ——
      expect(player.currentSong?.id, 'restore-url-failed');
      // 自动重解析确实发生（≥1 次解析请求；一次解析在降级链下可能发多个
      // HTTP 请求）。「只补一轮不无限重试」由后续生命周期检查兜底证明。
      expect(adapter.playbackUrlRequestCount, greaterThan(0));
      final countAfterRestore = adapter.playbackUrlRequestCount;
      // 第一次装载确实尝试过旧 URL 并带恢复进度。
      expect(audio.sourceInitialPositions, hasLength(1));
      expect(audio.sourceInitialPositions[0], const Duration(seconds: 60));
      expect(audio.playlistLoads, isEmpty);
      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
      // 批次27：失败出口收敛——标志置位，resume() 的 needsReload 才会触发重新解析。
      expect(player.isPlaybackNotReady, isTrue);
      // 静默路径不弹窗不 toast，但给非打扰文案（UI 提示条 + 重试按钮）。
      expect(player.resolveError, kSilentResolveErrorText);
      expect(player.resolveErrorForDisplay, kSilentResolveErrorText);

      // —— 自动重试不得被武装：后台兜底定时器 + 回前台都不发起解析 ——
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(budget.attempts, 0);
      expect(adapter.playbackUrlRequestCount, countAfterRestore);

      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(budget.attempts, 0);
      expect(adapter.playbackUrlRequestCount, countAfterRestore);

      // —— resume() 必须走重新解析分支（needsReload）——
      await player.resume();
      expect(
        adapter.playbackUrlRequestCount,
        greaterThan(countAfterRestore),
        reason: 'resume() 应触发重新解析，而不是把 play() 打到空播放器上',
      );
      // 重新解析仍失败：依旧没有装载过音源、没有下发过播放命令。
      expect(audio.playlistLoads, isEmpty);
      expect(audio.sourceInitialPositions, hasLength(1));
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

  test('批次28：播放器无音源时resume兜底走重新装载且带seekTo（不依赖状态标志）', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    final apiClient = KugouApiClient();
    await apiClient.clearCookies();
    await apiClient.setLoginCookies('fixture-token', 'fixture-user');
    final originalAdapter = apiClient.dio.httpClientAdapter;
    // resume 兜底 reload 沿用 song.url 直接装载（批次28 语义），需要解析 mock
    // 兜底（URL 缺失时走解析）。
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
      // 给一个非零进度：通过位置流发布（_updatePosition 真实通路），
      // 验证 reload 带 seekTo（批次28 进度保真）。
      audio.emitPosition(const Duration(seconds: 42));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final resumeRequest = player.resume();
      await audio.waitForPlaylistLoads(2);
      await audio.completeSourceLoad(1);
      await resumeRequest;

      // 兜底判据触发重新装载，装载成功后才真正下发播放命令——
      // 修复前这里会把 play() 打到 STATE_IDLE 的空播放器上（无声、无通知）。
      expect(audio.playlistLoads, hasLength(2));
      expect(
        audio.sourceInitialPositions[1],
        const Duration(seconds: 42),
        reason: 'resume() reload 带 seekTo: _position，不从头装载',
      );
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

  test('批次28：播放器有音源时resume不误触发兜底（对照）', () async {
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
