import 'package:flutter/services.dart';

/// 为原生重试提供有界的命令去重，并且只确认实际交给回调的命令。
class MediaCommandAckRouter {
  MediaCommandAckRouter({this.maxRememberedCommands = 64});

  final int maxRememberedCommands;
  final Set<int> _handledCommandIds = <int>{};
  final List<int> _handledOrder = <int>[];

  bool dispatch(int? commandId, void Function()? callback) {
    if (commandId == null || callback == null) return false;
    if (_handledCommandIds.contains(commandId)) return true;
    // 回调同步成功返回后才确认并记入去重表。若回调抛错，原生端会以同一
    // commandId 重试；提前记账会让重试被当作重复命令吞掉。
    callback();
    _handledCommandIds.add(commandId);
    _handledOrder.add(commandId);
    while (_handledOrder.length > maxRememberedCommands) {
      _handledCommandIds.remove(_handledOrder.removeAt(0));
    }
    return true;
  }
}

class MediaNotificationService {
  static const MethodChannel _channel = MethodChannel(
    'com.md3music.md3music/floating_lyric',
  );

  static void Function()? onPrevious;
  static void Function()? onNext;
  static void Function()? onTogglePlayPause;
  static void Function(int)? onSeekTo;
  // 线控耳机媒体键映射的独立播放 / 暂停命令（原生端唤醒播放下发）
  static void Function()? onPlay;
  static void Function()? onPause;
  static void Function()? onToggleFavorite;
  // 来自私人FM桌面小部件的按钮动作
  static void Function()? onWidgetFmPlayPause;
  static void Function()? onWidgetFmToggleFavorite;
  // 参数为档位下标（0=红心 1=探索 2=小众）
  static void Function(int)? onWidgetFmSelectStation;
  // 参数为歌曲 hash（预告封面点击，后台起播）
  static void Function(String)? onWidgetFmOpenTrack;
  // 封面点击：app 已被拉起，打开播放器页
  static void Function()? onWidgetFmOpenPlayer;
  // 登录引导卡点击：MainActivity 拉起 app 后转发
  static void Function()? onWidgetFmOpenLogin;
  static final MediaCommandAckRouter _mediaCommandAckRouter =
      MediaCommandAckRouter();

  static int? _commandIdFromArguments(Object? arguments) {
    if (arguments is! Map) return null;
    final commandId = arguments['commandId'];
    return commandId is int ? commandId : null;
  }

  static void initCallbacks() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'previous':
          return _mediaCommandAckRouter.dispatch(
            _commandIdFromArguments(call.arguments),
            onPrevious,
          );
        case 'next':
          return _mediaCommandAckRouter.dispatch(
            _commandIdFromArguments(call.arguments),
            onNext,
          );
        case 'togglePlayPause':
          return _mediaCommandAckRouter.dispatch(
            _commandIdFromArguments(call.arguments),
            onTogglePlayPause,
          );
        case 'play':
          return _mediaCommandAckRouter.dispatch(
            _commandIdFromArguments(call.arguments),
            onPlay,
          );
        case 'pause':
          // just_audio fork 从 Media3 onPlayerCommandRequest 转来的同步暂停没有
          // commandId；它与原生队列重试不同，直接交给 Provider 使在途换源失效。
          final commandId = _commandIdFromArguments(call.arguments);
          if (commandId == null) {
            final callback = onPause;
            if (callback == null) return false;
            callback();
            return true;
          }
          return _mediaCommandAckRouter.dispatch(commandId, onPause);
        case 'seekTo':
          final pos = call.arguments as int?;
          if (pos != null) onSeekTo?.call(pos);
          break;
        case 'toggleFavorite':
          onToggleFavorite?.call();
          break;
        // 私人FM桌面小部件按钮动作
        case 'widgetFmPlayPause':
          onWidgetFmPlayPause?.call();
          break;
        case 'widgetFmToggleFavorite':
          onWidgetFmToggleFavorite?.call();
          break;
        case 'widgetFmSelectStation':
          final index = call.arguments as int?;
          if (index != null) onWidgetFmSelectStation?.call(index);
          break;
        case 'widgetFmOpenTrack':
          final hash = call.arguments as String?;
          if (hash != null) onWidgetFmOpenTrack?.call(hash);
          break;
        case 'widgetFmOpenPlayer':
          onWidgetFmOpenPlayer?.call();
          break;
        case 'widgetFmOpenLogin':
          onWidgetFmOpenLogin?.call();
          break;
      }
      return null;
    });
  }

  static Future<void> updateNotification({
    String songId = '',
    required String title,
    required String artist,
    String? artUrl,
    String? fallbackFilePath,
    required bool isPlaying,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool isFavorited = false,
  }) async {
    try {
      await _channel.invokeMethod('updateNotification', {
        'songId': songId,
        'title': title,
        'artist': artist,
        'artUrl': artUrl,
        'fallbackFilePath': fallbackFilePath,
        'isPlaying': isPlaying,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'isFavorited': isFavorited,
      });
    } catch (_) {}
  }

  static Future<void> hideNotification() async {
    try {
      await _channel.invokeMethod('hideNotification');
    } catch (_) {}
  }

  /// 预取封面到原生本地缓存（方案B：切歌前下载后续歌曲封面，切歌时秒显，根治空档）。
  static Future<void> prefetchCover(List<String?> artUrls) async {
    try {
      final urls = artUrls
          .whereType<String>()
          .where((u) => u.isNotEmpty)
          .toList();
      if (urls.isEmpty) return;
      await _channel.invokeMethod('prefetchCover', {'urls': urls});
    } catch (_) {}
  }

  /// 通知原生端：播放状态已恢复完成，可安全派发线控耳机命令（唤醒播放）。
  /// 原生端 AudioPlaybackService 进程被杀后创建后台 FlutterEngine 并等待该信号
  /// 后才派发 play/next 等命令，确保 PlayerProvider 已完成状态恢复。
  static Future<void> notifyPlayerReady() async {
    try {
      await _channel.invokeMethod('playerReady');
    } catch (_) {}
  }

  // 蓝牙歌词兼容通道仍保留，但原生端不再改写共享 MediaSession 的 TITLE/ARTIST，
  // 避免 ColorOS 锁屏把歌词行误判为歌曲身份。
  static Future<void> updateBluetoothLyric(String lyric) async {
    try {
      await _channel.invokeMethod('updateBluetoothLyric', {'lyric': lyric});
    } catch (_) {}
  }

  static Future<void> setBluetoothLyricEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setBluetoothLyricEnabled', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

}
