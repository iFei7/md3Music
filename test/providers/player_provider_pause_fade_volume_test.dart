import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

/// 批次26：暂停淡出（[PlayerProvider.pause] 的 fadeEnabled 分支）音量收尾回归。
///
/// 历史缺陷：淡出循环把 `target.setVolume(currentVol * i / steps)` 递减到 0
/// （i=0 时写 0）后，`await _audioService?.pause()` 无 try 保护——平台层
/// 偶发抛异常时后续 `setVolume(_volume)` 恢复全部被跳过，播放器音量永久 0；
/// 之后任何不经 setUrl 的恢复播放路径（中断 GAIN 自动恢复、
/// [_restoreLatestPlaybackAfterStalePause]、resume 非淡入分支）都会
/// 「进度条走、完全没声音」。
///
/// 本组用例钉住收尾语义：
/// 1. 异常逃逸路径也必须把音量恢复为 `_volume`（而不是停在 0）；
/// 2. 正常淡出完成后恢复（既有契约不回归）；
/// 3. gate 失效但 fadeToken 未易主时仍恢复（切歌抢占场景）；
/// 4. 被 resume 抢占（fadeToken 易主）时，pause 收尾不得在 resume 淡入
///    中途插入满量恢复——与批次17「resume 淡入 finally 统一收尾」契约一致，
///    否则出现「先恢复再被打到 0.01」的音量抖动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Song buildSong(String id) => Song(
    id: id,
    title: 'Fade Target $id',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    url: 'https://media.example/$id.mp3',
    isOnline: true,
  );

  /// 装配：暂停淡出开、播一首歌进入播放态，返回 provider 与受控音频服务。
  Future<({PlayerProvider player, ControlledAudioService audio})>
  setupPlaying({String songId = 'fade-target'}) async {
    SharedPreferences.setMockInitialValues({
      'settings_pause_fade_enabled': true,
    });
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    final player = PlayerProvider();
    await player.audioReady.timeout(const Duration(seconds: 10));
    final playRequest = player.playSong(buildSong(songId));
    await audio.waitForPlaylistLoads(1);
    await audio.completeSourceLoad(0);
    await playRequest;
    return (player: player, audio: audio);
  }

  test('批次26：暂停淡出中平台 pause() 抛异常，音量仍恢复到 _volume 而非停在 0', () async {
    final setup = await setupPlaying();
    final player = setup.player;
    final audio = setup.audio;
    try {
      // 非默认用户音量：验证恢复的是 _volume，不是硬编码满量
      await player.setVolume(0.6);
      audio.nextPauseError = StateError('platform pause failed');
      await expectLater(player.pause(), throwsA(isA<StateError>()));
      // 淡出确实把音量压到过 0（缺陷窗口被真实走到）
      expect(audio.player.volumeWrites.contains(0.0), isTrue);
      // 收尾必须把音量拉回用户音量，不停在 0
      expect(audio.player.volume, closeTo(0.6, 0.001));
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('批次26：暂停淡出正常完成后音量恢复为 _volume（既有契约不回归）', () async {
    final setup = await setupPlaying();
    final player = setup.player;
    final audio = setup.audio;
    try {
      await player.setVolume(0.6);
      await player.pause();
      expect(audio.pauseCommandCount, 1);
      expect(player.isPlaying, isFalse);
      // 淡出确实把音量压到过 0
      expect(audio.player.volumeWrites.contains(0.0), isTrue);
      // 收尾恢复用户音量
      expect(audio.player.volume, closeTo(0.6, 0.001));
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('批次26：淡出中途切歌（gate 失效、fadeToken 未易主）仍恢复音量', () async {
    final setup = await setupPlaying();
    final player = setup.player;
    final audio = setup.audio;
    try {
      await player.setVolume(0.6);
      final pauseRequest = player.pause();
      final volumeChanged = Completer<void>();
      audio.player.volumeChanged = volumeChanged;
      await volumeChanged.future.timeout(const Duration(seconds: 2));
      // 切歌：invalidate + issue 新请求 → gate 失效，但不触碰 _fadeToken
      final nextPlay = player.playSong(buildSong('fade-target-2'));
      await audio.waitForPlaylistLoads(2);
      await audio.completeSourceLoad(1);
      await pauseRequest;
      await nextPlay;
      expect(audio.player.volume, closeTo(0.6, 0.001));
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  test('批次26：淡出被 resume 抢占时不在淡入中途插入满量恢复（批次17 契约）', () async {
    final setup = await setupPlaying();
    final player = setup.player;
    final audio = setup.audio;
    try {
      final pauseRequest = player.pause();
      final volumeChanged = Completer<void>();
      audio.player.volumeChanged = volumeChanged;
      await volumeChanged.future.timeout(const Duration(seconds: 2));
      await player.resume();
      await pauseRequest;

      expect(audio.playing, isTrue);
      expect(audio.player.volume, closeTo(1.0, 0.001));
      // resume 抢占后先写 0.01，紧接着必须是淡入斜坡的 0.1；
      // 若 pause 收尾在 fadeToken 易主后仍恢复，这里会先出现 1.0 的抖动
      final writes = audio.player.volumeWrites as List<double>;
      final lowIndex = writes.indexWhere((v) => (v - 0.01).abs() < 1e-9);
      expect(lowIndex, greaterThanOrEqualTo(0));
      expect(lowIndex + 1, lessThan(writes.length));
      expect(writes[lowIndex + 1], closeTo(0.1, 0.001));
    } finally {
      player.dispose();
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });
}
