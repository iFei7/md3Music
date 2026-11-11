// 批次50：TV 命名空间兼容层——上游 PlayerProvider 新增成员降级适配。
//
// 上游为私有字段实现（伴奏/交叉淡化 ValueNotifier、播放快照、循环模式直设等），
// extension 无法访问；此处映射到 lite PlayerProvider 公开 API 或以模块级
// 单例 / 保守默认值降级，语义降级点逐项标注「批次50 适配」。
// ignore_for_file: invalid_use_of_protected_member

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/tv_ui/data/repositories/history_repository.dart';
import 'package:md3music/providers/player_provider.dart';

// 上游实例字段 → 模块级单例（tv_ui 命名空间内共享）
final ValueNotifier<bool> tvAccompanyActiveNotifier = ValueNotifier<bool>(false);
final ValueNotifier<bool> tvAccompanyLoadingNotifier = ValueNotifier<bool>(false);
final ValueNotifier<bool> tvCrossfadeActiveNotifier = ValueNotifier<bool>(false);
bool tvKillBackgroundOnTimerEnd = false;
bool tvStemMix = false;

extension PlayerProviderTvCompat on PlayerProvider {
  ValueNotifier<bool> get accompanyActiveNotifier => tvAccompanyActiveNotifier;
  ValueNotifier<bool> get accompanyLoadingNotifier => tvAccompanyLoadingNotifier;
  ValueNotifier<bool> get crossfadeActiveNotifier => tvCrossfadeActiveNotifier;

  /// 批次50 适配：上游读私有伴奏混音状态；降级为跟随 notifier 值。
  bool get accompanyActive => tvAccompanyActiveNotifier.value;

  /// 批次50 适配：上游读私有字段；TV 内降级为模块级开关（无定时器联动）。
  bool get killBackgroundOnTimerEnd => tvKillBackgroundOnTimerEnd;

  Future<void> setKillBackgroundOnTimerEnd(bool value) async {
    tvKillBackgroundOnTimerEnd = value;
  }

  /// 批次50 适配：上游读 _loopMode/_shuffleEnabled 组合出的房间播放模式；
  /// 降级为按 lite 公开状态推导（0 顺序 / 1 随机）。
  int get roomPlayModeValue => shuffleEnabled ? 1 : 0;

  /// 批次50 适配：上游 stemMix 为双声道混合比例（double）；lite 无分离
  /// 运行时，恒 0.0。
  double get stemMix => 0.0;

  Future<void> setStemMix(double mix) async {}

  /// 批次50 适配：伴奏开关动作需要上游私有音频链；TV 降级为只翻 notifier 状态。
  Future<void> toggleAccompany() async {
    tvAccompanyActiveNotifier.value = !tvAccompanyActiveNotifier.value;
  }

  Future<void> stopAccompany() async {
    tvAccompanyActiveNotifier.value = false;
    tvAccompanyLoadingNotifier.value = false;
  }

  /// 批次50 适配：缓冲状态上游读私有 processingState；降级 false。
  bool get isStreamBuffering => false;

  /// 批次50 适配：慢启动检测上游读私有计时；降级 false。
  bool get isWaitingForAudioStart => false;

  /// 批次50 适配：上游抑制播放通知窗口（防上报回声）；TV 降级为直接执行。
  Future<T> suppressPlaybackNotify<T>(Future<T> Function() action) => action();

  /// 批次50 适配：桌面保活计时器刷新依赖上游私有同步方法；TV 降级 no-op。
  Future<void> refreshIdleKeepaliveStopTimer() async {}

  /// 批次50 适配：实时歌词过滤设置刷新依赖上游私有加载；TV 降级 no-op。
  Future<void> refreshLiveFilterSettings() async {}

  /// 批次50 适配：Windows 设置加载流程；lite 无该流程，no-op。
  Future<void> reloadWindowsSettings() async {}

  /// 批次50 适配：MV 音频回退开关依赖上游私有字段；TV 降级 no-op。
  Future<void> setMvAudioFallbackEnabled(bool value) async {}

  /// 批次50 适配：当前歌曲元数据更新依赖上游私有通知链；TV 降级 no-op。
  Future<void> updateCurrentSongMetadata(Object? patch) async {}

  /// 批次50 适配：历史条目刷新——上游实现同源（HistoryRepository 公开仓库），
  /// lite 侧同名仓库直接调用，非降级。
  void refreshHistoryEntry(Song song) {
    unawaited(HistoryRepository().replaceHistoryEntry(song));
  }

  /// 直接设定循环模式（上游 MCP/程序化入口）：lite 无公开 setter，
  /// 用公开 toggleLoopMode 循环至目标（AppLoopMode 共 3 态，最多 2 跳）。
  Future<void> setLoopMode(AppLoopMode mode) async {
    var guard = 0;
    while (loopMode != mode && guard++ < 3) {
      await toggleLoopMode();
    }
  }

  /// 直接设定随机开关：lite 无公开 setter，用公开 toggleShuffle 归位。
  Future<void> setShuffle(bool enabled) async {
    var guard = 0;
    while (shuffleEnabled != enabled && guard++ < 2) {
      await toggleShuffle();
    }
  }

  /// 批次50 适配：播放快照。上游读私有字段，降级为 lite 公开状态
  /// （originalPlaylist lite 无对应公开态，以 playlist 代替）。
  ({
    List<Song> playlist,
    List<Song> originalPlaylist,
    int index,
    Duration position,
    bool playing,
  })?
  capturePlaybackSnapshot() {
    final song = currentSong;
    if (song == null || playlist.isEmpty) return null;
    return (
      playlist: List<Song>.from(playlist),
      originalPlaylist: List<Song>.from(playlist),
      index: currentIndex,
      position: position,
      playing: isPlaying,
    );
  }

  /// 批次50 适配：恢复快照需要整表回写上游私有队列；降级为 lite 公开
  /// playPlaylist（整表替换并跳转记录位置），播放态差异可接受（一起听退房路径）。
  Future<void> restorePlaybackSnapshot({
    required List<Song> playlist,
    required List<Song> originalPlaylist,
    required int index,
    required Duration position,
    required bool playing,
  }) async {
    if (playlist.isEmpty) return;
    final safeIndex = index.clamp(0, playlist.length - 1);
    await playPlaylist(playlist, safeIndex);
    if (position > Duration.zero) {
      await seek(position);
    }
    if (!playing) {
      await pause();
    }
  }

  /// 批次50 适配：上游按索引插入队列；lite 无对应公开 API，降级为
  /// appendPlaylist 追加（顺序偏差可接受，一起听点歌场景）。
  Future<void> restorePlaylistEntries(
    List<({int index, Song song})> entries,
  ) async {
    if (entries.isEmpty) return;
    final sorted = [...entries]..sort((a, b) => a.index.compareTo(b.index));
    await appendPlaylist(sorted.map((e) => e.song).toList());
  }
}
