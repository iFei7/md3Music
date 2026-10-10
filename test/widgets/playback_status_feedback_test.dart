import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/history_repository.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/widgets/md3e_transport_row.dart';
import 'package:md3music/widgets/playback_status_feedback.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/controlled_audio_service.dart';

Widget _feedbackHost(PlayerProvider player) {
  return ChangeNotifierProvider<PlayerProvider>.value(
    value: player,
    child: const MaterialApp(home: Scaffold(body: PlaybackStatusFeedback())),
  );
}

Song _song() => Song(
  id: 'feedback-target',
  title: 'Feedback Target',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  localPath: '/music/feedback-target.flac',
);

void _mockConnectivityStream() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
        const services.EventChannel(
          'dev.fluttercommunity.plus/connectivity_status',
        ),
        MockStreamHandler.inline(
          onListen: (_, events) => events.success(<String>['wifi']),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('恢复后未收到音频进度时不显示等待提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _mockConnectivityStream();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player.audioReady.timeout(const Duration(seconds: 10));
        await player.resume();
      });
      await tester.pumpWidget(_feedbackHost(player));

      expect(player.isPlaying, isTrue);
      expect(player.isAwaitingPlaybackProgress, isTrue);
      expect(find.text('播放命令已发出，等待音频进度'), findsNothing);
      expect(find.text('暂停'), findsNothing);

      audio.emitPosition(const Duration(milliseconds: 200));
      await tester.pump();
      expect(player.isAwaitingPlaybackProgress, isFalse);
      expect(find.text('播放命令已发出，等待音频进度'), findsNothing);

      await tester.runAsync(() async {
        await player.pause();
        await player.resume();
      });
      await tester.pump();
      expect(find.text('播放命令已发出，等待音频进度'), findsNothing);

      await tester.runAsync(() async => player.pause());
      await tester.pump();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();

      expect(player.isPlaying, isFalse);
      expect(player.isAwaitingPlaybackProgress, isFalse);
      expect(find.text('播放命令已发出，等待音频进度'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      await tester.runAsync(audio.dispose);
      AudioServiceLoader.setTestOverride(null);
    }
  });

  testWidgets('准备中不显示提示条且暂停使迟到装载失效', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _mockConnectivityStream();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player.audioReady.timeout(const Duration(seconds: 10));
      });
      await tester.pumpWidget(_feedbackHost(player));

      final request = player.playPlaylist([_song()], 0);
      await tester.runAsync(
        () => audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 2)),
      );
      await tester.pump();
      expect(find.text('正在准备播放'), findsNothing);
      expect(find.text('取消'), findsNothing);

      await tester.runAsync(() async => player.pause());
      await tester.pump();
      await audio.completeSourceLoad(0);
      await tester.runAsync(() => request);

      expect(audio.playCommandCount, 0);
      expect(player.isPlaying, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      await tester.runAsync(() => HistoryRepository().flush());
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  testWidgets('当前曲运行时错误显示重试并保留原队列位置', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _mockConnectivityStream();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player.audioReady.timeout(const Duration(seconds: 10));
      });
      await tester.pumpWidget(_feedbackHost(player));

      final song = _song();
      final load = player.playPlaylist([song], 0);
      await tester.runAsync(
        () => audio.waitForPlaylistLoads(1).timeout(const Duration(seconds: 2)),
      );
      await audio.completeSourceLoad(0);
      await tester.runAsync(() => load);
      audio.emitPlaying(true);
      audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
      await tester.pump();

      expect(find.text('播放失败，请重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.runAsync(
        () => audio.waitForPlaylistLoads(2).timeout(const Duration(seconds: 2)),
      );
      expect(player.currentSong?.id, song.id);
      expect(player.currentIndex, 0);

      await audio.completeSourceLoad(1);
      await tester.pump();
      expect(audio.playCommandCount, 2);
      expect(player.resolveError, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      await tester.runAsync(() => HistoryRepository().flush());
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
    }
  });

  testWidgets('窄屏两倍字体下播放失败提示不溢出且重试按钮仍可见', (tester) async {
    final originalPhysicalSize = tester.view.physicalSize;
    final originalDevicePixelRatio = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    SharedPreferences.setMockInitialValues({});
    _mockConnectivityStream();
    final audio = ControlledAudioService();
    AudioServiceLoader.setTestOverride(() async => audio);
    late final PlayerProvider player;
    try {
      await tester.runAsync(() async {
        player = PlayerProvider();
        await player.audioReady.timeout(const Duration(seconds: 10));
        final load = player.playPlaylist([_song()], 0);
        await audio.waitForPlaylistLoads(1);
        await audio.completeSourceLoad(0);
        await load;
        audio.emitPlaying(true);
        audio.emitError(just_audio.PlayerException(2, 'decoder failed', 0));
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<PlayerProvider>.value(
          value: player,
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: const Scaffold(body: PlaybackStatusFeedback()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('播放失败，请重试'), findsOneWidget);
      final retryButton = find.text('重试');
      expect(retryButton, findsOneWidget);
      final retryBounds = tester.getRect(retryButton);
      expect(retryBounds.left, greaterThanOrEqualTo(0));
      expect(retryBounds.right, lessThanOrEqualTo(320));
      expect(retryBounds.bottom, lessThanOrEqualTo(640));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      player.dispose();
      await tester.runAsync(() => HistoryRepository().flush());
      await audio.dispose();
      AudioServiceLoader.setTestOverride(null);
      tester.view.physicalSize = originalPhysicalSize;
      tester.view.devicePixelRatio = originalDevicePixelRatio;
    }
  });
}
