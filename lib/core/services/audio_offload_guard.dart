import 'dart:async';

import 'package:just_audio/just_audio.dart' show PlayerException, PlayerState;

import '../../data/repositories/settings_repository.dart';
import '../utils/app_toast.dart';
import 'audio_offload_config.dart';
import 'audio_service.dart';

/// 硬解（audio offload）失败的判定策略（批次44 软解兜底）。
///
/// 纯逻辑、零平台依赖：所有方法都是 static 且只吃基本类型，
/// 便于单测直接跑真值表，不需要 Flutter binding / 平台通道。
class AudioOffloadFallbackPolicy {
  AudioOffloadFallbackPolicy._();

  /// 播放开始后多久还没推进过位置，就认为 offload 卡死。
  static const Duration initTimeout = Duration(seconds: 10);

  /// 判卡死所需的「本地已缓冲但没被消费」的最小余量。
  ///
  /// 这是区分「网络拉不到数据」和「sink 不消费数据」的关键：网络卡顿时
  /// bufferedAhead 接近 0（缓冲区被吃空），而 offload sink 卡死时数据早已
  /// 缓冲好、只是不往前走。
  static const Duration minBufferedAhead = Duration(seconds: 2);

  /// 该错误是否「可能是 offload 引起的」。
  ///
  /// 依据 Media3 的错误码语义（`PlaybackException`）：
  /// - 5001 `ERROR_CODE_AUDIO_TRACK_INIT_FAILED`：`MediaCodecAudioRenderer` 在
  ///   `audioSink.configure()` 抛 `ConfigurationException` 时就是它 —— offload
  ///   初始化失败的主信号；
  /// - 5002 `ERROR_CODE_AUDIO_TRACK_WRITE_FAILED`：写 AudioTrack 失败，offload
  ///   路径同样可能触发；
  /// - 4001 `ERROR_CODE_DECODER_INIT_FAILED` / 4003 `ERROR_CODE_DECODING_FAILED`：
  ///   硬解解码器初始化/解码失败；
  /// - 2000–2008 是网络类（`ERROR_CODE_IO_*`），与 offload 无关，**必须排除**，
  ///   否则网络抖动会被误判成"硬件解码坏了"，把用户的开关悄悄关掉。
  ///
  /// `code` 为 null（部分平台/旧版本只给 message）时退化为关键字匹配。
  static bool isOffloadSuspiciousError(int? code, String? message) {
    if (code != null) {
      // 先排除网络类区间，避免未来新增 IO 错误码被下面的集合漏判。
      if (code >= 2000 && code <= 2008) return false;
      return code == 4001 || code == 4003 || code == 5001 || code == 5002;
    }
    if (message == null) return false;
    final lower = message.toLowerCase();
    return lower.contains('audiotrack') ||
        lower.contains('offload') ||
        lower.contains('audio sink') ||
        lower.contains('mediacodec');
  }

  /// 是否卡死：**四者同时成立**才算。
  ///
  /// 1. `elapsed >= threshold`：已经等满观察窗口；
  /// 2. `playing` 为 true：暂停不算卡死；
  /// 3. `positionNow - positionAtStart <= Duration.zero`：位置零进展或**回退**；
  ///    只要有正向前进（哪怕只有 100ms）就一票否决 —— 正向前进说明 sink 在
  ///    消费数据，抖动不该被归因成硬解故障；
  /// 4. `bufferedAhead >= minBufferedAhead`：本地有 2s 以上缓冲却没被消费。
  ///
  /// 为什么必须有第 4 条：慢网下 `playing` 仍为 true、位置同样不动，和 offload
  /// 卡死在「位置不动」这一个观测上完全同形。只有「有数据却不消费」才能把
  /// 责任归给 sink。误判的代价是关掉用户的硬解开关 + 弹一条错误提示，所以宁可
  /// 漏判也不能误判。
  static bool isHang({
    required Duration elapsed,
    required Duration threshold,
    required Duration positionAtStart,
    required Duration positionNow,
    required bool playing,
    required Duration bufferedAhead,
  }) {
    if (elapsed < threshold) return false;
    if (!playing) return false;
    if (positionNow - positionAtStart > Duration.zero) return false;
    return bufferedAhead >= minBufferedAhead;
  }
}

/// 硬解失败 → 静默降级软解的运行时守卫（批次44）。
///
/// 设计要点：
/// - **不做机型黑名单**：只按运行时信号判定，失败一次后本会话永久关闭 offload，
///   重启复位。
/// - **单次闸门**：并发触发（同一首歌连续抛多个错误、错误与超时同时命中）只走
///   一次降级，避免重复写设置 / 重复弹 toast。
/// - **不干预播放控制**：这里**不** stop / seek / 重新 play。`PlayerProvider`
///   已经在 `player_provider.dart` 订阅同一条 `errorStream` 并做重试/跳歌，
///   两边各管一段：本守卫只负责「把这个设备的 offload 关掉」，重试交给 provider。
///   因此即使本守卫先跑完，provider 的重试链路行为也不变（它不读本类的状态）。
/// - **超时判据要求「有缓冲但不动」，且只在首次成功起播前生效**：
///   慢网缓冲与 offload 卡死在「播放位置不前进」上完全同形，唯一能区分的是
///   本地还有没有数据（bufferedAhead）。而一旦某次播放已经顺利走过
///   [playbackConfirmPosition]，就证明这台设备这次的 offload 初始化是好的，
///   之后的卡顿按网络/解码问题处理，不再归因 offload。误判的代价是关掉用户
///   的开关 + 弹一条「硬件解码初始化失败」的错误提示，所以这两道闸门都保留。
class AudioOffloadGuard {
  AudioOffloadGuard._();

  static final AudioOffloadGuard instance = AudioOffloadGuard._();

  /// 播放位置越过这个值就算「本会话已成功起播」，看门狗从此永久停用。
  static const Duration playbackConfirmPosition = Duration(seconds: 3);

  StreamSubscription<PlayerException>? _errorSub;
  StreamSubscription<PlayerState>? _stateSub;
  Timer? _watchdog;

  /// 本轮播放周期的起始位置，看门狗到点时用来判断位置有没有推进。
  Duration _positionAtStart = Duration.zero;

  bool _started = false;

  /// 本会话是否已经有过一次成功起播（位置越过 [playbackConfirmPosition]）。
  ///
  /// 为 true 后不再启动看门狗：已经证明 offload 初始化正常，后续的「不动」
  /// 只可能是网络/解码/用户操作，不该让硬解背锅。
  bool _playbackConfirmed = false;

  /// 单次闸门：本会话只会降级一次。
  bool _handled = false;

  /// 开始监听（幂等）。
  ///
  /// 只有在 [AudioOffloadConfig.effective] 为 true 时才真正挂监听 ——
  /// 没开 offload 的用户不该为这套兜底付出任何运行时开销。
  /// 必须在 `_restoreAudioOffloadPref()` 之后调用，否则读不到 effective。
  void start() {
    if (_started) return;
    if (!AudioOffloadConfig.effective) return;
    final player = AudioService().player;
    _started = true;
    // 错误流钉在「启动时就是主播放器」的那一个上：offload 只下发给主播放器
    // （见 audio_service_io 的 `!aux && ...`），交叉淡化换引擎不该让守卫失聪。
    _errorSub = player.errorStream.listen(
      (e) {
        if (AudioOffloadFallbackPolicy.isOffloadSuspiciousError(
          e.code,
          e.message,
        )) {
          // fork 的 PlayerException.code 是非空 int。
          unawaited(_fallback('error:${e.code}'));
        }
      },
      // 守卫自身绝不能因为订阅异常影响播放链路。
      onError: (Object _) {},
    );
    // 状态流用 AudioService 自己转发的那条：交叉淡化会把 _activePlayer 换成
    // 辅播放器，直接订阅某个 AudioPlayer 的流会在换引擎后错位（状态来自旧
    // 引擎、位置读的是新引擎），从而误判卡死。
    _stateSub = AudioService().playerStateStream.listen(
      _onPlayerState,
      onError: (Object _) {},
    );
  }

  /// 撤掉订阅与定时器（供测试用；生产环境不调用）。
  ///
  /// 注意会一并复位单次闸门，便于同一个测试进程里多次验证。
  Future<void> stop() async {
    await _errorSub?.cancel();
    _errorSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    _cancelWatchdog();
    _started = false;
    _handled = false;
    _playbackConfirmed = false;
  }

  void _onPlayerState(PlayerState state) {
    final player = AudioService().player;
    // 已经正常播过 3s：这台设备的 offload 初始化没问题，本会话不再看超时。
    // 放在 playing 判断之前，暂停在 5s 处也要能确认。
    if (!_playbackConfirmed &&
        player.position >= playbackConfirmPosition) {
      _playbackConfirmed = true;
      _cancelWatchdog();
      return;
    }
    if (!state.playing) {
      // 暂停/停止：本轮的"是否卡死"判定不再有意义。
      _cancelWatchdog();
      return;
    }
    if (_watchdog != null) {
      // 已经开始计时：位置一旦有正向前进就说明 sink 在消费，撤掉看门狗。
      if (player.position - _positionAtStart > Duration.zero) {
        _cancelWatchdog();
      }
      return;
    }
    if (_playbackConfirmed) return;
    // playing 变 true 的第一拍：记录起点并启动看门狗。
    _positionAtStart = player.position;
    _watchdog = Timer(AudioOffloadFallbackPolicy.initTimeout, () {
      _watchdog = null;
      // 位置 / playing / 缓冲余量必须取自同一个播放器实例，避免换引擎时混算。
      final active = AudioService().player;
      if (AudioOffloadFallbackPolicy.isHang(
        elapsed: AudioOffloadFallbackPolicy.initTimeout,
        threshold: AudioOffloadFallbackPolicy.initTimeout,
        positionAtStart: _positionAtStart,
        positionNow: active.position,
        playing: active.playing,
        bufferedAhead: active.bufferedPosition - active.position,
      )) {
        unawaited(_fallback('timeout'));
      }
    });
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// 执行降级。单次闸门 + 全链路 try/catch：任何一环失败都不能冒泡到播放链路。
  Future<void> _fallback(String reason) async {
    if (_handled) return;
    _handled = true;
    _cancelWatchdog();
    // 1) 会话级标记：后续（主/辅）播放器创建时不再下发 offload。
    AudioOffloadConfig.runtimeFailed = true;
    // 2) 运行期把偏好改成 disabled：让**当前**播放器的后续曲目也不再尝试
    //    offload（Media3 的 maybeDisableOffload 只在本次 configure 内有效）。
    //    分工：这里**不** stop/seek/重新 play —— PlayerProvider 已在同一
    //    errorStream 上做重试/跳歌，本守卫只负责"把这个设备的 offload 关掉"。
    try {
      await AudioService().player.setAndroidAudioOffloadPreferences(null);
    } catch (_) {}
    // 3) 持久化开关置为关：下次启动不再默认开启（用户可在设置页重新打开）。
    try {
      await SettingsRepository().setAudioOffloadEnabled(false);
    } catch (_) {}
    // 4) 通知 UI：设置页据此把开关回弹为关。
    AudioOffloadConfig.autoDisabledNotifier.value = reason;
    // 5) 用户可见提示（长时长，避免一闪而过）。toast 走平台通道，失败也不能
    //    影响上面的降级结果。
    try {
      showToast('硬件解码初始化失败，已自动切换为软件解码；可在设置中重新开启', long: true);
    } catch (_) {}
  }
}
