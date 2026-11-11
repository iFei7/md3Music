// 批次51：手机 / TV 双入口共享的启动件。
//
// 背景：批次51 后段起 TV 构建改走 Flutter 多入口（`flutter build apk
// -t lib/main_tv.dart`，编译根 = lib/main_tv.dart），TV 入口不再经
// main.dart → app.dart 拉入手机 UI 闭包。但以下符号此前声明在 main.dart，
// 被 tv_ui 装配面（tv_app.dart / player_provider.dart / 桌面歌词与识曲
// 服务 / FM 小组件同步 / 锁屏操作服务等）与手机装配面（app.dart 等）
// 双向消费——若留在 main.dart，tv_ui 的 import 会把 main.dart（连带
// app.dart 手机 UI）重新拉回 TV 闭包，树摇剔除再次落空。故统一下沉到
// 本文件：main.dart 与 main_tv.dart 都从这里 import，tv_ui / 共享
// providers 只允许 import 本文件、严禁 import main.dart。
//
// 本文件内容全部为 main.dart 原样上移（逐字迁移，仅私有名改公开名 +
// 来源标注），不新增/修改任何初始化语义。
import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/build_flags.dart';
import 'core/services/audio_offload_config.dart';
import 'core/services/desktop_lyric_service.dart';
import 'core/services/diagnostic_logger.dart';
import 'core/services/player_frame_driver.dart';
import 'data/repositories/settings_repository.dart';
import 'utils/landscape_dock_side.dart';
import 'utils/landscape_immersive.dart';

/// 顶级 Navigator 的 GlobalKey，预留供后续扩展使用。
/// （批次51 自 main.dart 上移：TV 装配面 tv_app.dart 等经本文件取用，
/// 避免 tv_ui → main.dart 的反向依赖把手机 UI 拉进 TV 闭包。）
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 启动阶段计时（自 main.dart runBootstrap 的 startupClock 上移）。
/// 由各入口在 bootstrap 起点调用 [resetStartupClock] 归零启动，
/// [markStartup] 记录各阶段耗时。
final Stopwatch _startupClock = Stopwatch();

/// 启动计时归零并开始计时（对齐 main.dart 原 `Stopwatch()..start()` 语义）。
void resetStartupClock() {
  _startupClock
    ..reset()
    ..start();
}

/// 记录启动阶段耗时到诊断日志（自 main.dart runBootstrap 的 markStartup
/// 上移，逐字迁移）。
void markStartup(String phase) {
  final elapsedMs = _startupClock.elapsedMilliseconds;
  final message = '[Startup] phase=$phase elapsed_ms=$elapsedMs';
  DiagnosticLogger.instance.i(message);
  // 启动阶段日志便于设备采样时区分 Dart bootstrap 与原生窗口首显；
  // 仅包含阶段名和耗时，不输出偏好值、端口或请求信息。
  debugPrint(message);
  if (phase == 'first_frame') {
    debugPrint('[StartupFrame] elapsed_ms=$elapsedMs');
  }
}

/// 首帧后的 intl 日期符号初始化（zh_CN），自 main.dart runBootstrap 的
/// first_frame postFrame 回调上移（C2：不阻塞启动串行链路）。公开与
/// 私有入口共用。
void setupFirstFrameCallback() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    markStartup('first_frame');
    unawaited(
      initializeDateFormatting('zh_CN').then((_) {
        markStartup('date_format_ready');
      }),
    );
  });
}

/// 全局 ErrorWidget 兜底占位（替代 release 默认的纯灰块）。
///
/// 仅在某个 widget 构建/布局抛异常时由 [ErrorWidget.builder] 使用；
/// 用中性可读外观（surface 背景 + 图标 + 简短提示）替代整屏纯灰，
/// 让用户知道是局部错误而非崩溃，同时异常已写入 [DiagnosticLogger]。
/// 无 MaterialApp 上下文时也能独立渲染（用 Directionality + 直接取色），
/// 因为它可能在 widget 树任意位置替换出错子树。
/// （批次51 自 main.dart 的私有类 _FallbackErrorWidget 上移改公开。）
class FallbackErrorWidget extends StatelessWidget {
  const FallbackErrorWidget({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    // 尽量取当前主题色；拿不到时回退到中性深灰（仍非纯灰全屏）。
    //
    // 此处用 findAncestorWidgetOfExactType 而非 Theme.of：本仓库依赖的
    // material_ui 未提供 Theme.maybeOf（只有 of/brightnessOf/maybeBrightnessOf），
    // 而 Theme.of 在无 Theme 祖先时会回退到 ThemeData.fallback()（浅色），与下方
    // 「中性深灰」意图相反。MaterialApp 无论是否走 AnimatedTheme，最终都会构建
    // Theme widget，故这里能取到与 Theme.maybeOf 等价的 ThemeData，无祖先时为 null。
    final theme = context.findAncestorWidgetOfExactType<Theme>()?.data;
    final bg = theme?.colorScheme.surface ?? const Color(0xFF1C1B1F);
    final fg = theme?.colorScheme.onSurfaceVariant ?? const Color(0xFFCAC4D0);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 40, color: fg),
            const SizedBox(height: 12),
            Text(
              '此处内容加载出错',
              textAlign: TextAlign.center,
              style: TextStyle(color: fg, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// 安装全局 ErrorWidget 兜底（自 main.dart runBootstrap 的
/// ErrorWidget.builder 赋值段上移，双入口共用一处生效两端）。
void installFallbackErrorWidget() {
  ErrorWidget.builder = (FlutterErrorDetails details) {
    DiagnosticLogger.instance.e(
      'ErrorWidget: ${details.exceptionAsString()}\n${details.stack}',
    );
    return FallbackErrorWidget(details: details);
  };
}

/// 请求启动后立即需要的运行时权限（通知）。
/// 音频库权限在用户打开本地曲库时按需请求；下载默认使用应用专属目录。
/// （批次51 自 main.dart 上移：tv_ui 引导页/协议页也经本文件调用。）
Future<void> requestPermissions() async {
  // Web 平台不支持 permission_handler，跳过所有权限请求
  if (kIsWeb) return;
  // 批次43：TV 无通知权限需求（TV 端不使用系统通知栏交互），编译期跳过。
  if (kTvBuild) return;
  // 桌面端无 Android 专属权限，跳过（permission_handler 桌面语义不同）
  if (!Platform.isAndroid) return;

  // Android 13+ 通知权限
  if (await Permission.notification.isDenied) {
    try {
      await Permission.notification.request();
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
  }
}

/// 恢复「硬解播放（audio offload）」的会话级配置（批次44）。
///
/// 必须在 `AudioService`（主播放器）被构造**之前**完成：offload 偏好是
/// `AudioPlayer` 的构造参数，而播放器在整个会话内只创建一次
/// （`AudioService._internal()` 中的 `_mainPlayer = _createPlayer()`）。
/// `EqualizerService.instance.init()` 内部就会构造 `AudioService`，因此本
/// helper 只能串行前置在多服务并发恢复**之前**；放进 Future.wait
/// 里只是并发启动，并不保证先后（EqualizerService.init 只需两次 prefs
/// await 就会构造播放器，会先于本 helper 完成）。
///
/// 同一条理由：此刻 DSP 服务的内存状态尚未恢复，均衡器开关只能按它的持久化
/// 来源 `eq_enabled` 读取（等价于 `EqualizerService.enabled` 的判据，只是忽略
/// 运行期才置位的 `_suspended`）。异常一律吞掉并保持默认值（=不下发 offload）。
/// （批次51 自 main.dart 的私有 _restoreAudioOffloadPref 上移。）
Future<void> restoreAudioOffloadPref() async {
  try {
    final repo = SettingsRepository();
    final prefs = await SharedPreferences.getInstance();
    final bool userEnabled = await repo.getAudioOffloadEnabled();
    final bool viper = await repo.getViperMasterEnabled();
    final bool normalization = await repo.getVolumeNormalizationEnabled();
    // 保守侧：eq_enabled 为 true 即视为音效链在用（不因 _systemEffectsDisabled
    // / _suspended 额外放行 offload）。
    final bool equalizer = prefs.getBool('eq_enabled') ?? false;
    AudioOffloadConfig.userEnabled = userEnabled;
    AudioOffloadConfig.dspActive = viper || normalization || equalizer;
  } catch (_) {}
}

/// 恢复蓝牙歌词开关 + 实时歌词推送协议（SuperLyric + 关闭）。
/// 从 SettingsRepository 读取协议与共用偏好，启用选中协议、禁用其他，并同步偏好。
/// （批次51 自 main.dart 的私有 _restoreLyricPushPref 上移，逐字迁移。）
Future<void> restoreLyricPushPref() async {
  try {
    final settings = SettingsRepository();
    // C1 性能优化：各偏好键的读取相互独立，先一次性并发发起全部读取
    // （SharedPreferences.getInstance 内部有实例缓存，不会重复加载），
    // 再按原有顺序依次 await 消费，替代原先约 12 次串行 await。
    // 每个键的回落默认值仍由 SettingsRepository 各 getter 负责，语义不变。
    final timeOffsetFuture = settings.getLyricTimeOffset();
    final btLyricEnabledFuture = settings.getBluetoothLyricEnabled();
    final protocolFuture = settings.getLyricPushProtocol();
    final translationFuture = settings.getLyricPushTranslation();
    final romaFuture = settings.getLyricPushRoma();
    final preferTranslationFuture = settings.getLyricPushPreferTranslation();

    // 逐字歌词时间偏移：加载到内存缓存（播放页每帧读取），默认 0
    await timeOffsetFuture;

    // 蓝牙歌词（独立开关）
    final btLyricEnabled = await btLyricEnabledFuture;
    await DesktopLyricService.instance.setBluetoothLyricEnabled(btLyricEnabled);

    // 实时歌词推送协议
    final protocol = await protocolFuture;
    final translation = await translationFuture;
    final roma = await romaFuture;
    final preferTranslation = await preferTranslationFuture;
    // 应用共用偏好
    // ignore: discarded_futures
    DesktopLyricService.instance.setLyricPushPreferences(
      translation: translation,
      roma: roma,
      preferTranslation: preferTranslation,
    );
    // 启用选中协议（词幕渠道已在 lite 精简中移除；LyricInfo 通道按需求始终
    // 关闭，启动恢复不启用：协议值仅 super_lyric 命中启用分支，历史残留的
    // lyric_info 与未知值一律不启用任何通道）
    if (protocol == 'super_lyric') {
      // ignore: discarded_futures
      DesktopLyricService.instance.setSuperLyricEnabled(true);
    }
  } catch (_) {}
}

/// 恢复「全屏播放器横屏隐藏状态栏」开关到全局变量（默认开启）。
/// 必须在 runApp 前完成：播放器 didChangeDependencies 首次应用系统栏时同步读取该变量。
/// （批次51 自 main.dart 的私有 _restoreLandscapeImmersivePref 上移。）
Future<void> restoreLandscapeImmersivePref() async {
  try {
    kLandscapeImmersiveEnabled = await SettingsRepository()
        .getLandscapeImmersiveEnabled();
  } catch (_) {}
}

/// 恢复「横屏悬浮 Dock 贴边方向」（批次36，默认右侧）到全局 ValueNotifier。
///
/// 必须在 runApp 前完成：MainLayout 首帧即读该值决定纵条/球贴边与避让注入
/// 方向；读取失败保持默认 right（= 改造前行为，不引入首帧异常）。
/// （批次51 自 main.dart 的私有 _restoreLandscapeDockSidePref 上移。）
Future<void> restoreLandscapeDockSidePref() async {
  try {
    kLandscapeDockSide.value = await SettingsRepository()
        .getLandscapeDockSide();
  } catch (_) {}
}

/// 恢复「省电动画帧率」开关到全局共享帧驱动（批次45：关闭省电 = 跟随屏幕）。
///
/// 必须在 runApp 前完成：首帧起就按目标帧率出拍，避免先 60fps 再降档的抖动。
/// 关闭省电 = 跟随屏幕刷新率，120Hz 屏动画同步到 120fps。
/// （批次51 自 main.dart 的私有 _restoreUiLowFrameRatePref 上移。）
Future<void> restoreUiLowFrameRatePref() async {
  try {
    final bool low = await SettingsRepository().getUiLowFrameRate();
    PlayerFrameDriver.instance.setFrameRate(
      low ? PlayerFrameDriver.kFrameRateLow : PlayerFrameDriver.kFrameRateAuto,
    );
  } catch (_) {}
}
