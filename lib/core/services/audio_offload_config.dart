import 'package:flutter/foundation.dart';

/// 硬解播放（audio offload）的会话级配置。
///
/// 批次44：lite 内联的 just_audio fork **已经完整具备** offload 参数链路
/// （Dart `AudioPlayer(androidAudioOffloadPreferences:)` → Java 构造解析 →
/// `TrackSelectionParameters.setAudioOffloadPreferences` → Media3
/// `AudioOffloadMode` → `DefaultAudioSink` 的 OFFLOAD 分支），本文件只补
/// 「谁来打开它」这一层。本批次**不含**上游的机型能力探测 / 黑名单
/// （`AudioOffloadController` / `AudioOffloadCapabilities` /
/// `AudioDecoderCapabilities` / `AudioOffloadPlugin.kt` 均未移植），
/// 某曲目是否真的走 offload 完全由 Media3 与设备协商决定。
///
/// 为什么是会话级：`AudioPlayer` 在整个 App 会话内只创建一次
/// （`AudioService._internal()` 里的 `_mainPlayer = _createPlayer()`），
/// 而 offload 偏好是构造参数 —— 批次45 起用户手动改开关不再需要重启 App：
/// 设置页会同步本类的 [userEnabled] 并立刻通过
/// `AudioPlayer.setAndroidAudioOffloadPreferences` 把偏好写回运行中的播放器
/// （Media3 在下一次 `configure()` / 建 AudioTrack 时生效，即「下一首」）。
/// 批次44 软解兜底例外：[AudioOffloadGuard] 判定坏设备后会通过
/// `AudioPlayer.setAndroidAudioOffloadPreferences(null)` 在运行期把偏好改成
/// disabled，并把 [runtimeFailed] 置位，使本次会话后续不再尝试 offload。
///
/// 为什么必须要求「无音效链」：lite 内联的 Media3 `DefaultAudioSink.configure()`
/// 里 PCM 与 OFFLOAD 是互斥分支 —— `AUDIO_RAW` 走 `audioProcessingPipeline`
/// （蝰蛇母带 `ViperMasterProcessor`、音量均衡 `NormalizationGainAudioSink`、
/// 均衡器等全在这条链上），非 RAW 才走 offload / passthrough，源码注释明写
/// "Audio processing is not supported in offload or passthrough mode."。
/// 所以一旦某曲目走 offload，该曲目的音效链全部不生效 —— 这是 offload 的
/// 定义，不是可修的 bug。
class AudioOffloadConfig {
  AudioOffloadConfig._();

  /// 用户开关（设置页），默认关闭。
  static bool userEnabled = false;

  /// 启动时探测到的音效链是否在用（蝰蛇 / 均衡器 / 音量均衡任一开启即为 true）。
  static bool dspActive = false;

  /// 会话级失败标记（批次44 软解兜底）。
  ///
  /// 由 [AudioOffloadGuard] 在判定本机 offload 不可用（初始化错误 / 卡死超时）
  /// 后置为 true：本会话内任何后续播放器创建都不再下发 offload 偏好。
  /// 重启 App 即复位（进程内存状态），因此**不需要机型黑名单**。
  static bool runtimeFailed = false;

  /// 最终是否真的下发 offload 偏好。
  ///
  /// 为 true 时该曲目走 offload，意味着 [dspActive] 所代表的音效链对其
  /// 不生效。该值在播放器构造时读一次；批次45 起设置页改开关时会同步
  /// [userEnabled] 并把新偏好直接下发到运行中的播放器（无需重启 App），
  /// 但**当前正在播的这首不会中途切换解码方式**——要等下一次 configure，
  /// 也就是下一首。
  static bool get effective => shouldEnable(
    userEnabled: userEnabled,
    dspActive: dspActive,
    runtimeFailed: runtimeFailed,
  );

  /// 纯函数：便于单测，不依赖静态字段。
  ///
  /// [runtimeFailed] 给默认值是为了保持既有调用点/用例的向后兼容。
  static bool shouldEnable({
    required bool userEnabled,
    required bool dspActive,
    bool runtimeFailed = false,
  }) =>
      userEnabled && !dspActive && !runtimeFailed;

  /// 把三处状态合成一句用户可读的说明（纯函数，便于单测）。批次45。
  ///
  /// [offloaded] 来自 [AudioOffloadStatusService] 的
  /// `status.value?.offloaded`：**null 表示尚未收到任何事件（未知）**，
  /// false 表示**确认软解**——Media3 每次建 AudioTrack
  /// （`DefaultAudioSink.buildAudioTrack`）都会回调 `onOffloadedPlayback`，
  /// 所以只要起播过一次，「没收到事件」就不再可能，false 是可信结论。
  ///
  /// [sleeping] 对应 `sleepingForOffload`（播放器主循环为省电停摆），
  /// [isPlaying] 用来区分「还没起播」与「正在起播」两种未知态，
  /// [switchEnabled] 是设置页当前开关值（不是 [effective]：被 dspActive /
  /// runtimeFailed 拦下时的文案由设置页另行回弹开关，这里只描述用户意愿）。
  static String describePlaybackState({
    required bool? offloaded,
    required bool sleeping,
    required bool isPlaying,
    required bool switchEnabled,
  }) {
    if (!switchEnabled) return '开关已关闭，当前使用软件解码';
    if (offloaded == null && !isPlaying) return '未播放，起播后可查看实际解码方式';
    if (offloaded == null && isPlaying) return '正在起播，等待确认解码方式';
    if (offloaded == true) {
      return sleeping ? '硬解中（已进入低功耗停摆）' : '硬解中';
    }
    // offloaded == false：确认软解（设备或格式不支持硬解，或退回了 passthrough）。
    return '软解中（设备或格式不支持硬解）';
  }

  /// 硬解与音效的互斥联动（纯函数，便于单测）。批次46。
  ///
  /// offload 绕过全部 AudioProcessor（蝰蛇母带 / 音量均衡）与 Android
  /// 音频会话音效（均衡器），三者与硬解互斥。开启硬解时返回需要
  /// 自动关闭的音效名列表（顺序固定：均衡器、蝰蛇母带、音量均衡），
  /// 空列表表示无冲突、无需联动。
  static List<String> dspConflictsForOffload({
    required bool viper,
    required bool equalizer,
    required bool normalization,
  }) {
    final conflicts = <String>[];
    if (equalizer) conflicts.add('均衡器');
    if (viper) conflicts.add('蝰蛇母带');
    if (normalization) conflicts.add('音量均衡');
    return conflicts;
  }

  /// 自动降级原因（null = 未发生）。
  ///
  /// 用途有两个：设置页用它把开关回弹为关（"设备不支持时会自动关闭"），
  /// 需要时也可由 UI 读出来做二次提示。值本身是短原因串（如 'timeout'、
  /// 'error:5001'），不含 URL 等敏感信息。
  static final ValueNotifier<String?> autoDisabledNotifier =
      ValueNotifier<String?>(null);
}
