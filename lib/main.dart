import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:intl/date_symbol_data_local.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/build_flags.dart';
import 'core/services/desktop_lyric_service.dart';
import 'core/services/diagnostic_logger.dart';
import 'modules/recognition/floating_recognition_service.dart';
import 'core/remote/tv_focus_debug.dart';
import 'core/services/equalizer_service.dart';
import 'core/services/audio_offload_config.dart';
import 'core/services/audio_offload_guard.dart';
import 'core/services/audio_offload_status.dart';
import 'core/services/viper_master_service.dart';
import 'core/services/listening_grade_service.dart';
import 'core/services/listen_report_service.dart';
import 'core/services/media_notification_service.dart';
import 'core/services/player_frame_driver.dart';
import 'core/services/wakelock_service.dart';
import 'data/repositories/settings_repository.dart';
import 'providers/theme_provider.dart';
import 'modules/update/update_check_service.dart';
import 'modules/onboarding/user_agreement_page.dart';
import 'services/kugou_api/kugou_api_client.dart';
import 'services/kugou_server.dart';
import 'tv_ui/app/tv_app.dart';
import 'utils/landscape_dock_side.dart';
import 'utils/landscape_immersive.dart';
import 'widgets/md3_lyric_preferences.dart';

/// 顶级 Navigator 的 GlobalKey，预留供后续扩展使用。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 用于在 MyApp 启动前缓存「冷启动时通过 shortcut 触发」的类型。
/// QuickActions.initialize 在 runApp 之前注册回调，但此时 Navigator 还未就绪，
/// 因此把 shortcut 类型暂存到该字段，由 _AppView 在首帧处理后清空。
String? pendingShortcutType;

/// 用于通知 _MainLayout 切换到指定 tab（携带 tab id，而非写死索引）。
/// shortcut 入口按 tab id 解析实际索引：tab 可见则切主 tab，被隐藏则以
/// 二级页面打开（避免依赖固定索引导致 tab 排序/隐藏后跳错）。
/// _MainLayout 在 initState 中监听此 notifier，收到非 null 值后处理并清空。
final ValueNotifier<String?> shortcutTabRequest = ValueNotifier<String?>(null);

Future<void> main() async {
  // Zone 级兜底：任何未被 try/catch 与错误钩子接住的异步错误都记入诊断日志
  runZonedGuarded(_main, (error, stack) {
    DiagnosticLogger.instance.e('Zone 未捕获错误: $error\n$stack');
  });
}

Future<void> _main() async {
  final (
    needsOnboarding,
    needsUserAgreement,
    initialUseBackgroundImage,
  ) = await runBootstrap();

  // 批次51：TV 构建纯 TV 入口——kTvBuild 分支直接 runApp TvApp
  // （lib/tv_ui/app/tv_app.dart，自带 MaterialApp + providers + 路由表 +
  // builder 焦点包装），其后手机装配完全不执行。
  //
  // **可达性双向断开**（用户决策①②）：
  // - TV 构建（kTvBuild=true）：else 分支（MyApp + 手机 10 万行 Dart 页面
  //   闭包）不可达，AOT 编译期整段剔除；
  // - 手机构建（kTvBuild=false）：TV 分支（TvApp + tv_ui 20 万行）不可达，
  //   AOT 整段剔除——本 import 只进依赖图不进产物。
  // 用 if/else 而非「TV 分支内 return」：保证另一分支在两个构建目标下都
  // 是编译期死代码（早退形式下 TV 构建的 fallback 直通代码仍可达）。
  if (kTvBuild) {
    runApp(const TvApp());
  } else {
    runApp(
      MyApp(
        showOnboarding: needsOnboarding,
        showUserAgreement: needsUserAgreement,
        initialUseBackgroundImage: initialUseBackgroundImage,
      ),
    );
  }

  // P0: 权限请求推迟到首帧渲染后执行，避免冷启动期间的系统权限弹窗
  // 阻塞首屏绘制（部分设备上 permission_handler 可能耗时/弹窗）。
  // （requestPermissions 内部自带 kTvBuild 编译期守卫，TV 构建直接跳过。）
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // 权限请求包裹 try/catch：在部分设备/早期阶段 permission_handler 可能抛
    // "Unable to detect current Android Activity"，不能让它中断流程。
    try {
      requestPermissions();
    } catch (e) {
      debugPrint('Request permissions error (ignored): $e');
    }
  });
}

/// 启动引导：并行初始化无依赖服务、恢复偏好、预取 SharedPreferences。
/// 返回 onboarding / 用户协议状态，以及首帧使用的背景图开关值。
/// 公开入口（main）与私有入口（lib/private/main_private）复用同一流程，
/// 私有入口在此基础上安装扩展钩子后 runApp。
Future<(bool, bool, bool)> runBootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  // lite 低内存目标：收紧全局图像缓存上限（默认 1000 张 / 100MiB 偏大）。
  // 需在 ensureInitialized 之后（binding 就绪）设置；配合 PlayerArtworkImage
  // 的 decodeCap 解码上限，缓存条目本身已是小尺寸解码图，200 张 / 48MB
  // 对音乐 App 的封面量级绰绰有余，超限按 LRU 淘汰。
  PaintingBinding.instance.imageCache.maximumSize = 200;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20; // 48 MiB
  final startupClock = Stopwatch()..start();
  void markStartup(String phase) {
    final elapsedMs = startupClock.elapsedMilliseconds;
    final message = '[Startup] phase=$phase elapsed_ms=$elapsedMs';
    DiagnosticLogger.instance.i(message);
    // 启动阶段日志便于设备采样时区分 Dart bootstrap 与原生窗口首显；
    // 仅包含阶段名和耗时，不输出偏好值、端口或请求信息。
    debugPrint(message);
    if (phase == 'first_frame') {
      debugPrint('[StartupFrame] elapsed_ms=$elapsedMs');
    }
  }

  // 诊断日志尽早初始化（滚动文件 + 全局错误钩子），保证启动期异常也被记录。
  // 内部自带失败兜底，不会中断启动。
  await DiagnosticLogger.instance.init();
  markStartup('diagnostics_ready');
  // C2: intl 日期符号初始化（zh_CN）不再阻塞启动串行链路，后移到首帧之后
  // 执行。首帧渲染路径已验证不使用 DateFormat：全仓 DateFormat 调用仅
  // sign_in_calendar_page（签到日历页，非首帧）与 diagnostic_exporter
  // （用户主动导出诊断时触发）两处，后移不影响首帧与后续页面的日期格式化。
  // 在runBootstrap注册，公开与私有入口都可记录真正的首帧时间。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    markStartup('first_frame');
    unawaited(
      initializeDateFormatting('zh_CN').then((_) {
        markStartup('date_format_ready');
      }),
    );
  });

  // 全局 ErrorWidget 兜底：release 版默认 ErrorWidget 是纯灰块，横竖屏切换时
  // 某个 widget 构建异常会让整屏变纯灰且无任何线索（问题③）。改为可读占位
  // （非灰、带图标与提示），并把异常写入诊断日志，便于 adb logcat / 导出定位。
  // 双入口（main / main_private）共用 runBootstrap，一处生效两端。
  ErrorWidget.builder = (FlutterErrorDetails details) {
    DiagnosticLogger.instance.e(
      'ErrorWidget: ${details.exceptionAsString()}\n${details.stack}',
    );
    return _FallbackErrorWidget(details: details);
  };

  // P0: 无依赖的初始化并行执行，替代串行 await，缩短 runApp 前的阻塞时间。
  // 同时预取 SharedPreferences（onboarding / 用户协议检查复用）。
  final prefsFuture = SharedPreferences.getInstance();
  // 批次44: 硬解播放（audio offload）配置必须在 AudioService 被构造前就绪。
  // EqualizerService.init() 会构造 AudioService（播放器只创建一次），所以这条
  // 不能放进下面的 Future.wait（并发启动无法保证先后），必须串行前置。
  await _restoreAudioOffloadPref();
  // 批次44 软解兜底：必须在 offload 配置已确定（上面一行写完 userEnabled /
  // dspActive）之后启动，否则读不到 `AudioOffloadConfig.effective`，守卫会
  // 直接什么都不挂。start() 自身幂等，且 effective 为 false 时不做任何事。
  AudioOffloadGuard.instance.start();
  // 批次45：开始接收 Media3 的真实硬解状态（AudioTrack.isOffloadedPlayback）。
  // 必须在播放器创建之后接线：Java 侧在起播早期建 AudioTrack 时就会推送
  // 首条事件，注册晚了会漏掉，设置页只能显示"未知"直到下一首。start() 幂等，
  // 重复调用（设置页也会调）不会重复注册。
  AudioOffloadStatusService.instance.start();
  await Future.wait([
    // 加载 MD3 风格播放页的独立歌词偏好（从 SharedPreferences）
    Md3LyricPreferences.instance.load(),
    // 恢复屏幕常亮开关状态，供 PlayerProvider/MV 页播放时读取
    WakelockService.instance.init().catchError((_) {}),
    // 初始化均衡器服务（恢复偏好设置，监听播放状态自动绑定）
    EqualizerService.instance.init().catchError((_) {}),
    // 初始化蝰蛇母带服务（恢复开关与 10 段增益并推送原生处理链）
    ViperMasterService.instance.init().catchError((_) {}),
    // 恢复蓝牙歌词开关 + 实时歌词推送协议（SuperLyric + 关闭）：
    // 让歌词服务定时器在需要时启动、启用选中协议。
    // 原生端 AudioPlaybackService.onCreate 会自行从 SharedPreferences 恢复开关。
    _restoreLyricPushPref(),
    // 恢复全屏播放器横屏沉浸开关（全局变量，播放器同步读取）
    _restoreLandscapeImmersivePref(),
    // 恢复横屏悬浮 Dock 贴边方向（批次36）：必须在 runApp 前完成——首帧
    // 布局即按该值决定纵条/球贴边与页面避让注入方向，避免首帧闪一下右侧。
    _restoreLandscapeDockSidePref(),
    // 恢复省电帧率开关：帧率预算必须在首帧前应用，否则首帧按 60fps 起跑
    // 再降档会闪一下。
    _restoreUiLowFrameRatePref(),
  ]);
  markStartup('local_preferences_ready');

  // 注册通知栏回调（通知栏按钮 → DesktopLyricService 转发播放控制/收藏）
  MediaNotificationService.initCallbacks();
  DesktopLyricService.instance.registerNativeCallbacks();
  // 注册悬浮窗识曲原生回调（PCM 段回传 / MediaProjection 授权结果 / 悬浮窗按钮动作）
  FloatingRecognitionService.instance.registerNativeCallbacks();

  // 批次50：TV 焦点诊断播种（对齐上游 main.dart TV 播种处）。lite 无
  // Lyricon 蓝牙歌词屏（精简移除），上游「非 TV 才初始化 Lyricon」分支
  // 无对应物；TV 分支安装焦点诊断日志（仅 debug 构建实际生效，release
  // 随 kDebugMode 树摇剔除），kTvBuild 为 const，正常构建直接跳过。
  if (kTvBuild) {
    TvFocusDebug.install();
  }

  // 启动听歌等级：本地听歌时长累计 + 自动上报（内部按平台/登录态自行处理）
  ListeningGradeService.instance.init();
  // CSCC 真实播放事件上报（/user/listen/report）：由 PlayerProvider 在切歌/播放
  // 边沿驱动，开关复用 settings_upload_listening_duration（默认开启，批次14）。
  ListenReportService.instance.init();

  // 懒启动策略（lite）：本地 API 服务器不再于启动时无条件启动（此前后台
  // unawaited 启动仍会在每次冷启动付出 dlopen libkugou_server.so（4.7MB+）
  // 与 Rust 初始化的成本，即便本次会话一次酷狗请求都没有）。改为把
  // KugouApiServer.ensureStarted 注入 KugouApiClient.onServerNeeded：
  // 首个酷狗 API 请求在等待就绪前发现服务未启动/失败时异步触发启动，
  // 并通过生命周期 completer 与后续并发请求共享同一次启动。回调解耦是
  // 因为 kugou_server.dart 已引用 KugouApiClient 的代次/状态静态成员，
  // 反向 import 会成环。LocalServerDownBanner 重试（app.dart）与播放前
  // 兜底（player_provider）仍直接调用 KugouApiServer.start，语义不变。
  // LocalHttpServer（DLNA 拉流）同为懒启动：仅投屏本地歌曲时由
  // DlnaProvider.castSong 触发，避免 App 常驻一个局域网监听 socket。
  if (!kIsWeb) {
    KugouApiClient.onServerNeeded = KugouApiServer.ensureStarted;
  }

  // 注册 Android 长按应用图标 Shortcut 回调。
  // initialize 必须在 runApp 之前调用，以便冷启动时能接收到 shortcut 触发。
  // 批次43：TV 无快捷方式需求（遥控器无应用图标长按交互），编译期跳过。
  if (!kTvBuild && !kIsWeb && Platform.isAndroid) {
    const quickActions = QuickActions();
    quickActions.initialize((shortcutType) {
      // 应用已就绪时直接处理；否则暂存，由 _AppView 在首帧处理
      if (appNavigatorKey.currentContext != null) {
        handleShortcut(shortcutType);
      } else {
        pendingShortcutType = shortcutType;
      }
    });
  }

  // 检测是否需要显示首次启动引导页（仅新安装/未完成教程时弹出）
  bool needsOnboarding = false;
  var initialUseBackgroundImage = true;
  try {
    final prefs = await prefsFuture;
    needsOnboarding = !(prefs.getBool('onboarding_completed') ?? false);
    initialUseBackgroundImage =
        prefs.getBool(ThemeProvider.backgroundImageEnabledPreferenceKey) ??
            true;
  } catch (_) {}
  markStartup('onboarding_state_ready');

  // 检测是否需要展示用户协议（首次启动）
  final needsUserAgreement = !(await isUserAgreementAccepted());
  markStartup('agreement_state_ready');

  // 启动后静默检查 GitHub Release：发现新版本仅 toast 提醒。
  // 首次启动引导 / 用户协议未确认时抑制，避免与首启流程争夺注意力。
  // 内部仅在 Android 生效、延迟 8s 后执行、12 小时内不重复请求；可在设置中关闭。
  // 批次43：TV 无应用内升级需求（TV 端升级走系统应用市场/侧载，不弹 GitHub 检查）。
  if (!kTvBuild) {
    UpdateCheckService.instance.scheduleStartupCheck(
      suppress: needsOnboarding || needsUserAgreement,
    );
  }

  markStartup('bootstrap_ready');
  return (needsOnboarding, needsUserAgreement, initialUseBackgroundImage);
}

/// 恢复蓝牙歌词开关 + 实时歌词推送协议（SuperLyric + 关闭）。
/// 从 SettingsRepository 读取协议与共用偏好，启用选中协议、禁用其他，并同步偏好。
Future<void> _restoreLyricPushPref() async {
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
Future<void> _restoreLandscapeImmersivePref() async {
  try {
    kLandscapeImmersiveEnabled = await SettingsRepository()
        .getLandscapeImmersiveEnabled();
  } catch (_) {}
}

/// 恢复「横屏悬浮 Dock 贴边方向」（批次36，默认右侧）到全局 ValueNotifier。
///
/// 必须在 runApp 前完成：MainLayout 首帧即读该值决定纵条/球贴边与避让注入
/// 方向；读取失败保持默认 right（= 改造前行为，不引入首帧异常）。
Future<void> _restoreLandscapeDockSidePref() async {
  try {
    kLandscapeDockSide.value = await SettingsRepository()
        .getLandscapeDockSide();
  } catch (_) {}
}

/// 恢复「省电动画帧率」开关到全局共享帧驱动（批次45：关闭省电 = 跟随屏幕）。
///
/// 必须在 runApp 前完成：首帧起就按目标帧率出拍，避免先 60fps 再降档的抖动。
/// 关闭省电 = 跟随屏幕刷新率，120Hz 屏动画同步到 120fps。
Future<void> _restoreUiLowFrameRatePref() async {
  try {
    final bool low = await SettingsRepository().getUiLowFrameRate();
    PlayerFrameDriver.instance.setFrameRate(
      low ? PlayerFrameDriver.kFrameRateLow : PlayerFrameDriver.kFrameRateAuto,
    );
  } catch (_) {}
}

/// 恢复「硬解播放（audio offload）」的会话级配置（批次44）。
///
/// 必须在 `AudioService`（主播放器）被构造**之前**完成：offload 偏好是
/// `AudioPlayer` 的构造参数，而播放器在整个会话内只创建一次
/// （`AudioService._internal()` 中的 `_mainPlayer = _createPlayer()`）。
/// `EqualizerService.instance.init()` 内部就会构造 `AudioService`，因此本
/// helper 只能串行前置在下面的 `Future.wait` **之前**；放进 `Future.wait`
/// 里只是并发启动，并不保证先后（EqualizerService.init 只需两次 prefs
/// await 就会构造播放器，会先于本 helper 完成）。
///
/// 同一条理由：此刻 DSP 服务的内存状态尚未恢复，均衡器开关只能按它的持久化
/// 来源 `eq_enabled` 读取（等价于 `EqualizerService.enabled` 的判据，只是忽略
/// 运行期才置位的 `_suspended`）。异常一律吞掉并保持默认值（=不下发 offload）。
Future<void> _restoreAudioOffloadPref() async {
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

/// 根据 shortcut 类型路由到对应页面。
/// 通过全局 [appNavigatorKey] 获取 NavigatorState，避免依赖具体 BuildContext。
///
/// 快捷方式类型统一为 `action_open_<tabId>`（与现有
/// action_open_favorites/recognition/search 兼容）。这里只把 tab id 交给
/// _MainLayout，由它按当前 tab 配置解析：可见 → 切主 tab；隐藏 → 二级页打开。
void handleShortcut(String shortcutType) {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  if (!shortcutType.startsWith('action_open_')) return;
  final tabId = shortcutType.substring('action_open_'.length);
  if (tabId.isEmpty) return;
  shortcutTabRequest.value = tabId;
}

/// 请求启动后立即需要的运行时权限（通知）。
/// 音频库权限在用户打开本地曲库时按需请求；下载默认使用应用专属目录。
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

/// 全局 ErrorWidget 兜底占位（替代 release 默认的纯灰块）。
///
/// 仅在某个 widget 构建/布局抛异常时由 [ErrorWidget.builder] 使用；
/// 用中性可读外观（surface 背景 + 图标 + 简短提示）替代整屏纯灰，
/// 让用户知道是局部错误而非崩溃，同时异常已写入 [DiagnosticLogger]。
/// 无 MaterialApp 上下文时也能独立渲染（用 Directionality + 直接取色），
/// 因为它可能在 widget 树任意位置替换出错子树。
class _FallbackErrorWidget extends StatelessWidget {
  const _FallbackErrorWidget({required this.details});

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
