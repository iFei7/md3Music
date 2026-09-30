import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/settings_repository.dart';
import '../../data/models/song.dart';
import '../../main.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/lyric_request_lifecycle.dart';
import '../../core/utils/local_lyric_loader.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../services/kugou_api/lyric_lookup_result.dart';
import 'media_notification_service.dart';

/// 解析歌词文本，超过 32KB 时移入 isolate。
///
/// KRC + 翻译 + 罗马音整曲可达上百 KB，主 isolate 解析会在切歌瞬间
/// 掉帧；小文本直接解析（isolate spawn 本身有开销，不划算）。
Future<List<LyricLine>> parseLyricOffMainThread(
  String text, {
  String? translationText,
  String? romaText,
}) async {
  if (text.length <= 32 * 1024) {
    return LyricParserChain.parse(
      text,
      translationText: translationText,
      romaText: romaText,
    );
  }
  return compute(_parseInIsolate, (text, translationText, romaText));
}

List<LyricLine> _parseInIsolate((String, String?, String?) input) {
  return LyricParserChain.parse(
    input.$1,
    translationText: input.$2,
    romaText: input.$3,
  );
}

/// 歌词外显推送服务：统一管理「应用内歌词」之外的各歌词消费方。
///
/// 用 [LyricParserChain.parse] 自动识别 KRC/LRC/纯文本并输出统一 [LyricLine]
/// 列表，按播放位置推进当前行，再分发给各通道：蓝牙歌词、SuperLyric
/// （Binder 系统级实时歌词）。所有通道复用同一个 250ms 定时器与同一份歌词
/// 列表，避免重复拉词与重复解析。
///
/// Lite 已下线桌面歌词悬浮窗、锁屏歌词、魅族状态栏歌词与 LyricInfo 转发：
/// 本服务不再负责任何悬浮窗渲染、锁屏 Activity 拉起、状态栏 ticker 与
/// MediaSession extras 下发，也不再维护对应的开关状态。
class LyricPushService {
  static final LyricPushService instance = LyricPushService._();
  LyricPushService._();

  PlayerProvider? _player;
  KugouProvider? _kugou;
  final SettingsRepository _settings = SettingsRepository();

  // 蓝牙歌词开关。ColorOS SystemUI 与 AVRCP 共用 MediaSession，
  // 4.0 接入后原生端必须保持稳定 title/artist，因此不再用该通道改写会话身份。
  bool _bluetoothLyricEnabled = false;
  bool get bluetoothLyricEnabled => _bluetoothLyricEnabled;

  // SuperLyric 歌词推送开关：基于 Binder 的系统级实时歌词 API。
  // 复用本服务的定时器与歌词解析管线，在切歌 / 歌词行变化时推送当前行
  // （text/words/翻译/副歌词 + title/artist）；播放/暂停由 SuperLyric 自动
  // 监听 App 的 MediaSession 处理（sendStop），本服务不手动发送停止事件。
  bool _superLyricEnabled = false;
  bool get superLyricEnabled => _superLyricEnabled;

  // 共用偏好（设置页三种推送协议共用一份）：
  // - 翻译歌词开关：是否推送翻译（影响 SuperLyric）
  bool _pushTranslation = true;
  // - 罗马音歌词开关：是否推送罗马音（影响 SuperLyric）
  bool _pushRoma = false;
  // - 同时存在翻译和罗马音时是否优先推送翻译（参照 Lyricon preferTranslation）。
  //   开启：保留 translation、丢弃 roma；关闭：保留 roma、丢弃 translation。
  //   SuperLyric 接收端对同时携带两字段的数据会优先显示 secondary(roma)，故需在 Dart 侧过滤。
  bool _superLyricPreferTranslation = true;

  String? _currentSongId;
  // 解析后的歌词行列表（统一模型，KRC 含 words，LRC/纯文本 words 为空）
  List<LyricLine> _lines = const [];
  int _currentLineIndex = -1;
  // 行切换迟滞时间戳：position 抖动时抑制行来回跳变、重复推送（蓝牙歌词高频刷新根因之一）
  DateTime? _lastLineSwitchAt;
  Timer? _ticker;
  // 播放中 250ms（行检测+逐字调度精度）；暂停后 1s（仅剩对账与切歌检测）
  static const int _tickIntervalPlayingMs = 250;
  static const int _tickIntervalPausedMs = 1000;
  int _tickIntervalMs = _tickIntervalPlayingMs;
  // 行边界预测 Timer：行提交后安排一次性触发，让切行不受 250ms 轮询相位限制
  Timer? _lineTimer;
  bool _awaitingLyric = false;
  int _lyricFetchToken = 0;
  // 上一次观测到的播放态：只用于边沿检测（恢复播放时立即补一拍），不推原生。
  bool _lastObservedPlaying = false;
  // 歌词拉取退避：临时失败按 250ms→10s 指数退避，确认无词按5分钟冷却，
  // 防止播放期间重复请求；错误状态分别显示给歌词消费者。
  String? _lyricFailedKey;
  int _lyricFailCount = 0;
  DateTime? _lyricNextRetryAt;

  /// 在 app 启动时（main 中）调用：注册原生回调
  void registerNativeCallbacks() {
    MediaNotificationService.onPrevious = () {
      _player?.previous();
    };
    MediaNotificationService.onNext = () {
      _player?.next();
    };
    MediaNotificationService.onTogglePlayPause = () {
      if (_player == null) return;
      if (_player!.isPlaying) {
        _player!.pause();
      } else {
        _player!.resume();
      }
    };
    MediaNotificationService.onToggleFavorite = () {
      _handleToggleFavorite();
    };
  }

  Future<void> _handleToggleFavorite() async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    try {
      final player = ctx.read<PlayerProvider>();
      final favorites = ctx.read<FavoritesProvider>();
      final song = player.currentSong;
      if (song != null) {
        await favorites.toggleFavorite(song);
        // Refresh notification after toggle completes to update heart icon
        player.refreshNotification();
      }
    } catch (_) {}
  }

  /// 蓝牙歌词开关。开启后定时器运行以获取当前歌词行并推给车机；
  /// 关闭后若没有其他通道需要歌词则停止定时器。
  Future<void> setBluetoothLyricEnabled(bool enabled) async {
    if (_bluetoothLyricEnabled == enabled) return;
    _bluetoothLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 启用时重置切歌检测状态，让下个 tick 重新拉取歌词并推送。
      // 解决 app 启动时调用本方法、但原生 service 尚未就绪导致的首次播放不推送问题。
      _currentSongId = null;
      _lines = const [];
      _currentLineIndex = -1;
      _awaitingLyric = false;
    } else {
      // 关闭时清空蓝牙歌词，让原生端恢复原始 title/artist
      await MediaNotificationService.updateBluetoothLyric('');
    }
  }

  /// SuperLyric 歌词推送开关：独立于蓝牙歌词。
  /// 开启后定时器运行以在切歌/行变化时推送当前行；关闭时推一次空歌词清空。
  Future<void> setSuperLyricEnabled(bool enabled) async {
    if (_superLyricEnabled == enabled) return;
    _superLyricEnabled = enabled;
    _bindProvidersFromContext();
    _updateTicker();
    if (enabled) {
      // 开启时若已有当前行立即推送一次（无需等下一个 tick）
      if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        _pushSuperLyricLine(_lines[_currentLineIndex]);
      } else {
        _pushSuperLyricLine(null);
      }
    } else {
      // 关闭时推一次「仅 title/artist」清空当前歌词
      _pushSuperLyricLine(null);
    }
  }

  /// 歌曲元数据（标题/歌手/封面）晚到并被回写后，让各推送渠道立即刷新。
  ///
  /// 场景：一起听跟随端起播时只有 hash 身份，`RoomSong.toSong()` 把空标题
  /// 兜底成「未知歌曲」，各渠道先把它推了出去；随后元数据富化回写当前歌
  /// （`PlayerProvider.updateCurrentSongMetadata`，**id 保持不变**），
  /// 但各渠道都按 song.id 去重 → 真实标题永远推不出去。
  ///
  /// 因此这里在元数据变化时**显式**补推一次，而不是放宽各渠道的去重键：
  /// 去重本意是防高频 tick 重复推送，放宽会破坏该保护。
  ///
  /// 覆盖 SuperLyric 这条「不重推就永远停在占位标题」的渠道：
  /// - SuperLyric：重推当前行（含 title/artist）
  /// 注：Lyricon 由 `PlayerProvider._handleLyriconSongChange` 的元数据签名处理。
  Future<void> notifySongMetadataChanged() async {
    if (_superLyricEnabled) {
      if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        await _pushSuperLyricLine(_lines[_currentLineIndex]);
      } else {
        await _pushSuperLyricLine(null);
      }
    }
  }

  /// 设置共用的推送偏好（翻译/罗马音/优先翻译），并让过滤立即生效：
  /// SuperLyric 重推当前行（参照 Lyricon repushLastSong 的做法）。
  Future<void> setLyricPushPreferences({
    required bool translation,
    required bool roma,
    required bool preferTranslation,
  }) async {
    final changed =
        _pushTranslation != translation ||
        _pushRoma != roma ||
        _superLyricPreferTranslation != preferTranslation;
    _pushTranslation = translation;
    _pushRoma = roma;
    _superLyricPreferTranslation = preferTranslation;
    if (!changed) return;
    if (_superLyricEnabled) {
      if (_currentLineIndex >= 0 && _currentLineIndex < _lines.length) {
        await _pushSuperLyricLine(_lines[_currentLineIndex]);
      } else {
        await _pushSuperLyricLine(null);
      }
    }
  }

  /// 定时器是否需要运行：蓝牙歌词、SuperLyric 任一开启即需运行
  bool _shouldTick() => _bluetoothLyricEnabled || _superLyricEnabled;

  /// 根据开关状态启停定时器（250ms tick：逐行歌词足够检测切行）
  void _updateTicker() {
    if (_shouldTick()) {
      _syncTickInterval(_player?.isPlaying ?? false);
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// 按播放状态同步 tick 周期：周期未变化时不重建
  void _syncTickInterval(bool playing) {
    final target = playing ? _tickIntervalPlayingMs : _tickIntervalPausedMs;
    if (_ticker != null && _tickIntervalMs == target) return;
    _tickIntervalMs = target;
    _ticker?.cancel();
    _ticker = Timer.periodic(Duration(milliseconds: target), (_) => _onTick());
  }

  /// 行提交后安排一次性 Timer 在下一行起始时刻触发 _onTick，
  /// 让行切换不受 250ms 轮询相位限制。仅播放中调度（暂停时下一行
  /// 永不到来，避免空转；恢复播放后由 250ms tick 兜底提交并重新调度）。
  void _scheduleLineBoundary(int nextIndex) {
    _lineTimer?.cancel();
    _lineTimer = null;
    final player = _player;
    if (player == null || !player.isPlaying) return;
    if (nextIndex >= _lines.length) return;
    final delayMs =
        _lines[nextIndex].startTime - player.position.inMilliseconds;
    if (delayMs <= 0) return;
    _lineTimer = Timer(Duration(milliseconds: delayMs), _onTick);
  }

  void _cancelLineTimer() {
    _lineTimer?.cancel();
    _lineTimer = null;
  }

  void _bindProvidersFromContext() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    try {
      // 玩家监听：仅换实例时重绑，避免每次绑定都重复 addListener
      final player = ctx.read<PlayerProvider>();
      if (player != _player) {
        _player?.removeListener(_onPlayerChanged);
        _player = player;
        player.addListener(_onPlayerChanged);
      }
      _kugou = ctx.read<KugouProvider>();
    } catch (_) {}
  }

  // 播放状态翻转 → 恢复播放时立即补一拍。
  // 必须边沿触发：position 刷新会高频 notifyListeners，不去重会反复空跑 _onTick。
  void _onPlayerChanged() {
    final playing = _player?.isPlaying ?? false;
    if (playing == _lastObservedPlaying) return;
    _lastObservedPlaying = playing;
    if (playing) {
      // 恢复播放：暂停期 tick 已降频至 1s，立即补一拍对齐当前行与预测调度
      _onTick();
    }
  }

  static const _superLyricChannel = MethodChannel(
    'com.md3music.md3music/super_lyric',
  );

  void _onTick() {
    if (!_shouldTick()) return;
    // provider 未绑定时（如 app 启动早期 context 未就绪）尝试重新绑定，
    // 绑定成功后下个 tick 即可正常推送；仍失败则跳过本次
    if (_player == null || _kugou == null) {
      _bindProvidersFromContext();
      if (_player == null || _kugou == null) return;
    }
    final tickPlaying = _player!.isPlaying;
    // 暂停时下一行永不到来：取消预测调度；tick 周期同步降频
    if (!tickPlaying) {
      _cancelLineTimer();
    }
    _syncTickInterval(tickPlaying);
    final song = _player!.currentSong;
    if (song == null) {
      if (_currentSongId != null) _lyricFetchToken++;
      _currentSongId = null;
      _lines = const [];
      _currentLineIndex = -1;
      _cancelLineTimer();
      return;
    }

    // 切歌检测
    if (song.id != _currentSongId) {
      _currentSongId = song.id;
      _lyricFetchToken++;
      _lines = const [];
      _currentLineIndex = -1;
      _lastLineSwitchAt = null;
      _awaitingLyric = false;
      // 新歌立即尝试拉取：清除上一首的失败退避状态
      _lyricFailedKey = null;
      _lyricFailCount = 0;
      _lyricNextRetryAt = null;
      _pushLyric('歌词加载中...', placeholder: '歌词加载中...');
      // SuperLyric：切歌时立即更新 title/artist（清空上一首歌词）
      if (_superLyricEnabled) {
        _pushSuperLyricLine(null);
      }
      _cancelLineTimer();
      _fetchLyricFor(song);
      return;
    }

    // 歌词加载只由带 token 的请求提交结果，不能直接读取 KugouProvider 的共享
    // current lyric；后者可能正被播放器页或 Lyricon 的另一首请求更新。
    if (!_awaitingLyric && _lines.isEmpty) {
      // 失败退避：同一首歌上次拉取失败且尚未到退避时限时跳过本轮
      if (_lyricNextRetryAt != null &&
          _lyricFailedKey == song.id &&
          DateTime.now().isBefore(_lyricNextRetryAt!)) {
        return;
      }
      _fetchLyricFor(song);
      return;
    }

    // 播放位置：仅供下列行查找使用（不再向原生推送进度/时长）
    final pos = _player!.position;
    final posMs = pos.inMilliseconds;

    // Find current line
    if (_lines.isEmpty) return;
    final newIndex = _findLineIndex(posMs);

    // 行变化时推送（逐行模式：每行只在进入时推一次，不高频刷字色）
    if (newIndex != _currentLineIndex) {
      // P0: 行切换 300ms 迟滞：position 抖动（MediaSession/just_audio 位置源相位差）
      // 会导致行在相邻行间来回跳变、同一行被重复推送（日志实测同一行被推 3~16 次）。
      // 迟滞窗口内保持当前行，稳定后才切换，消除无效推送。
      final now = DateTime.now();
      if (_lastLineSwitchAt != null &&
          now.difference(_lastLineSwitchAt!).inMilliseconds < 300) {
        // 迟滞窗口内：保持当前行，下个 tick 再判定
      } else {
        _lastLineSwitchAt = now;
        _currentLineIndex = newIndex;
        final line = newIndex >= 0 ? _lines[newIndex] : null;
        final current = line?.text ?? '';
        _pushLyric(current);
        // SuperLyric：行变化时推送当前行（含逐字 words、翻译、副歌词）
        if (_superLyricEnabled) {
          _pushSuperLyricLine(line);
        }
        // 预测调度：下一行起始时刻精确触发，切行延迟从最坏 250ms 降到 Timer 精度
        if (newIndex + 1 < _lines.length) {
          _scheduleLineBoundary(newIndex + 1);
        }
      }
    }
  }

  Future<void> _fetchLyricFor(Song song) async {
    if (_awaitingLyric) return;
    final requestedSongId = song.id;
    final token = ++_lyricFetchToken;
    _awaitingLyric = true;
    try {
      if (!song.isOnline) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          String filePath = localPath;
          if (filePath.startsWith('file://')) {
            filePath = Uri.parse(filePath).toFilePath();
          }
          final embedded = await LocalLyricLoader.loadForAudioAsync(filePath);
          if (embedded != null && embedded.isNotEmpty) {
            if (!_isCurrentLyricRequest(token, requestedSongId)) return;
            final lines = await parseLyricOffMainThread(embedded);
            // isolate 解析期间可能已切歌：迟到结果直接丢弃
            if (!_isCurrentLyricRequest(token, requestedSongId)) return;
            _lines = lines;
            if (_lines.isEmpty) _pushLyric('暂无歌词', placeholder: '暂无歌词');
            return;
          }
        }
      }

      // 用 isUnknownArtist 而非比较单一字面量：一起听跟随端的占位值是
      // 「未知歌手」、本地侧是「未知艺术家」，只比一个会漏判，
      // 导致把「未知歌曲 未知歌手」当检索词去搜。
      final searchName = !isUnknownArtist(song.artist)
          ? '${song.title} ${song.artist}'
          : song.title;
      final result = await _kugou!.getLyricResult(
        song.isOnline ? song.id : '',
        songName: searchName,
        fmt: 'lrc',
        localIdentity: song.isOnline ? null : song.localPath,
      );
      if (!_isCurrentLyricRequest(token, requestedSongId)) return;
      switch (result.status) {
        case LyricLookupStatus.found:
          if (await _commitFetchedLyric(
            result.lyric!,
            token,
            requestedSongId,
          )) {
            _clearLyricRetryState();
          }
          break;
        case LyricLookupStatus.notFound:
          _commitNoLyrics(requestedSongId);
          break;
        case LyricLookupStatus.transientFailure:
          _recordLyricFailure(requestedSongId, '歌词加载失败', result.status);
          break;
        case LyricLookupStatus.invalidData:
          _recordLyricFailure(requestedSongId, '歌词数据无效', result.status);
          break;
        case LyricLookupStatus.canceled:
          return;
      }
    } catch (_) {
      if (_isCurrentLyricRequest(token, requestedSongId)) {
        _recordLyricFailure(
          requestedSongId,
          '歌词加载失败',
          LyricLookupStatus.transientFailure,
        );
      }
    } finally {
      // 旧请求完成不能把新请求的 awaiting 状态清掉。
      if (token == _lyricFetchToken) _awaitingLyric = false;
    }
  }

  bool _isCurrentLyricRequest(int token, String songId) =>
      token == _lyricFetchToken &&
      _currentSongId == songId &&
      _player?.currentSong?.id == songId;

  Future<bool> _commitFetchedLyric(
    KugouLyric lyric,
    int token,
    String requestedSongId,
  ) async {
    if (lyric.displayLyric.isEmpty) {
      _commitNoLyrics(requestedSongId);
      return false;
    }
    late final List<LyricLine> lines;
    try {
      lines = await parseLyricOffMainThread(
        lyric.displayLyric,
        translationText: lyric.translatedContent,
        romaText: lyric.romaContent,
      );
    } catch (_) {
      if (_isCurrentLyricRequest(token, requestedSongId)) {
        _recordLyricFailure(
          requestedSongId,
          '歌词解析失败',
          LyricLookupStatus.invalidData,
        );
      }
      return false;
    }
    // isolate 解析期间可能已切歌：迟到结果直接丢弃
    if (!_isCurrentLyricRequest(token, requestedSongId)) return false;
    if (lines.isEmpty) {
      _recordLyricFailure(
        requestedSongId,
        '歌词解析失败',
        LyricLookupStatus.invalidData,
      );
      return false;
    }
    _lines = lines;
    return true;
  }

  void _commitNoLyrics(String songId) {
    _pushLyric('暂无歌词', placeholder: '暂无歌词');
    _lyricFailedKey = songId;
    _lyricFailCount = 0;
    _lyricNextRetryAt = DateTime.now().add(
      LyricRetryPolicy.delayFor(LyricLookupStatus.notFound, 0),
    );
  }

  void _recordLyricFailure(
    String songId,
    String placeholder,
    LyricLookupStatus status,
  ) {
    _pushLyric(placeholder, placeholder: placeholder);
    _lyricFailCount = _lyricFailedKey == songId ? _lyricFailCount + 1 : 1;
    _lyricFailedKey = songId;
    _lyricNextRetryAt = DateTime.now().add(
      LyricRetryPolicy.delayFor(status, _lyricFailCount),
    );
  }

  void _clearLyricRetryState() {
    _lyricFailedKey = null;
    _lyricFailCount = 0;
    _lyricNextRetryAt = null;
  }

  /// 推送当前行文本到蓝牙歌词通道。
  ///
  /// [placeholder] 非空表示这行是占位文案（歌词加载中.../暂无歌词/歌词加载失败）：
  /// 蓝牙通道不需要占位，一律清空，避免把「加载中」当歌词发给车机。
  Future<void> _pushLyric(String current, {String placeholder = ''}) async {
    if (!_bluetoothLyricEnabled) return;
    final btText = (placeholder.isNotEmpty) ? '' : current;
    try {
      await MediaNotificationService.updateBluetoothLyric(btText);
    } catch (_) {}
  }

  /// 推送当前歌词行到 SuperLyric（基于 Binder 的系统级实时歌词 API）。
  ///
  /// [line] 为 null 时只发 title/artist（清空当前歌词，用于切歌/关闭开关）。
  /// 核心字段映射：
  /// - title/artist：取当前歌曲的 displayName（剥后缀）与 artist
  /// - 主行：text + words（逐字）+ startTime/endTime
  /// - translation：翻译（SuperLyricData.setTranslation）
  /// - roma：副歌词（SuperLyricData.setSecondary）
  /// 播放/暂停由 SuperLyric 自动监听 App 的 MediaSession 处理，这里不推停止事件。
  Future<void> _pushSuperLyricLine(LyricLine? line) async {
    if (_player == null) return;
    final song = _player!.currentSong;
    if (song == null) return;

    final Map<String, dynamic> args = {
      'title': song.displayName,
      'artist': song.artist,
    };
    if (line != null) {
      final text = line.text.trim();
      if (text.isNotEmpty) {
        final int startTime = line.startTime;
        // endTime 兜底：LRC duration=0 时 endTime==startTime，补一个合法 end（参照 Lyricon）
        final int endTime = line.endTime > startTime
            ? line.endTime
            : startTime + 5000;
        // 同时存在翻译和罗马音时按偏好二选一（参照 Lyricon preferTranslation），
        // 避免 SuperLyric 接收端优先显示 secondary(roma) 导致"总是罗马音"。
        // 翻译/罗马音还受共用开关 _pushTranslation / _pushRoma 控制。
        final hasTranslation =
            _pushTranslation &&
            line.translation != null &&
            line.translation!.isNotEmpty;
        final hasRoma = _pushRoma && line.roma != null && line.roma!.isNotEmpty;
        final translationValue =
            hasTranslation && hasRoma && !_superLyricPreferTranslation
            ? null
            : line.translation;
        final romaValue =
            hasRoma && hasTranslation && _superLyricPreferTranslation
            ? null
            : line.roma;
        args.addAll({
          'text': text,
          'startTime': startTime,
          'endTime': endTime,
          'words': line.words
              .map(
                (w) => <String, dynamic>{
                  'text': w.text,
                  'start': w.startTime,
                  'end': w.startTime + w.duration,
                },
              )
              .toList(),
          if (translationValue != null && translationValue.isNotEmpty)
            'translation': translationValue,
          if (romaValue != null && romaValue.isNotEmpty) 'roma': romaValue,
        });
      }
    }
    try {
      await _superLyricChannel.invokeMethod('sendLyric', args);
    } catch (_) {}
  }

  /// 二分查找当前播放位置对应的歌词行 index。
  ///
  /// _lines 已按 startTime 升序排列（LyricParserChain 保证），
  /// 找到最后一个 startTime <= posMs 的行。
  int _findLineIndex(int posMs) {
    int lo = 0;
    int hi = _lines.length - 1;
    int idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_lines[mid].startTime <= posMs) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return idx;
  }
}
