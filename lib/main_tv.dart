// 批次51：TV 专用编译入口（Flutter 多入口）。
//
// 背景：批次51 前段尝试「main.dart kTvBuild 分支 + const 树摇」未达目标
// ——CI 实测 TV APK 只降 2MB（恰为混淆收益），纯入口的树摇剔除落空。
// 根因 = Dart import 不可按 dart-define 条件化：TV 构建编译根仍是
// main.dart，其 `import 'app.dart'` 链把手机 UI（10.1 万行）全量编译进
// TV 包（kTvBuild 早退只是运行时不走）。真解 = Flutter 多入口：TV 构建
// 以本文件为编译根（`flutter build apk -t lib/main_tv.dart`），本文件
// **不 import 'app.dart' / 不 import 任何 lib/ 手机页面**，手机 UI 从
// TV 构建不可达（import 闭包级断开，反向 main.dart 也不 import 本文件，
// 手机构建不含 tv_ui）。手机构建编译根仍是 main.dart（ci.yml 不带 -t）。
//
// 初始化对照：本文件 main() 与 main.dart 的 main() 并存不冲突（按 -t
// 选择）。启动编排 = main.dart runBootstrap 的 **TV 路径实际执行子集**
// 逐项对照搬运（批次43 三处 TV 跳过逻辑 QuickActions / 升级检查 / 通知
// 权限在此直接不做；onboarding / 用户协议读取仅服务手机 MyApp，TvApp
// 不消费，省略）；共享原语（appNavigatorKey / requestPermissions /
// FallbackErrorWidget / restore* 五件套 / markStartup）取自
// lib/bootstrap_common.dart（批次51 自 main.dart 原样上移），TV 装配取
// lib/tv_ui/app/tv_app.dart 的 TvApp（自带 MaterialApp/MultiProvider/
// 路由/焦点包装）。批次50 播种的 TvFocusDebug.install 随入口迁移到此处。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'bootstrap_common.dart'
    show
        installFallbackErrorWidget,
        markStartup,
        resetStartupClock,
        restoreAudioOffloadPref,
        restoreLandscapeDockSidePref,
        restoreLandscapeImmersivePref,
        restoreLyricPushPref,
        restoreUiLowFrameRatePref,
        setupFirstFrameCallback;
import 'core/remote/tv_focus_debug.dart';
import 'core/services/audio_offload_guard.dart';
import 'core/services/audio_offload_status.dart';
import 'core/services/desktop_lyric_service.dart';
import 'core/services/diagnostic_logger.dart';
import 'core/services/equalizer_service.dart';
import 'core/services/listen_report_service.dart';
import 'core/services/listening_grade_service.dart';
import 'core/services/media_notification_service.dart';
import 'core/services/viper_master_service.dart';
import 'core/services/wakelock_service.dart';
import 'services/kugou_api/kugou_api_client.dart';
import 'services/kugou_server.dart';
import 'tv_ui/app/tv_app.dart';
import 'widgets/md3_lyric_preferences.dart';

Future<void> main() async {
  // Zone 级兜底（与 main.dart main() 同款）：任何未被 try/catch 与错误
  // 钩子接住的异步错误都记入诊断日志。
  runZonedGuarded(_mainTv, (error, stack) {
    DiagnosticLogger.instance.e('Zone 未捕获错误: $error\n$stack');
  });
}

Future<void> _mainTv() async {
  await _runTvBootstrap();

  // 批次51：TV 纯入口——直接 runApp TvApp（lib/tv_ui/app/tv_app.dart，
  // 自带 MaterialApp + providers + 路由表 + builder 焦点包装）。手机装配
  // （main.dart 的 MyApp）不在本入口闭包内。
  runApp(const TvApp());

  // 批次43：TV 无通知权限需求（requestPermissions 内部 kTvBuild 编译期
  // 守卫在 TV 构建直接跳过），TV 入口不再安排首帧权限请求——与 main.dart
  // TV 路径的实际执行结果一致（该回调在 TV 构建内是立即返回的空转）。
}

/// TV 构建启动引导：main.dart `runBootstrap()` 的 TV 路径实际执行子集，
/// 逐项对照搬运（来源行号为批次51 前段 main.dart 实码）。对照结论：
/// - 全量保留：binding / 图像缓存上限 / 诊断日志 / 启动计时 / 首帧回调 /
///   ErrorWidget 兜底 / 硬解配置（批次44 串行前置）/ 软解兜底 / 硬解状态
///   接收（批次45）/ 八项本地偏好并发恢复 / 通知栏·桌面歌词原生回调注册 /
///   批次50 TV 焦点诊断播种 / 听歌等级与上报 / 酷狗本地服务懒启动接线
///   （TV 在线内容依赖）；
/// - 唯一偏差（批次51 后段，依据见调用点注释）：悬浮窗识曲原生回调注册
///   不做——lib 副本会把 37 个手机页面拉进 TV 闭包，TV 由 tv_ui 副本
///   （同 channel 名）承接，无行为缺口；
/// - 编译期跳过（批次43，TV 本就不执行）：QuickActions / 升级检查 /
///   通知权限；
/// - 省略（执行了但 TvApp 不消费返回值）：onboarding / 用户协议读取
///   （纯 prefs 读，无副作用，省略不改变行为）。
Future<void> _runTvBootstrap() async {
  // main.dart :107 —— binding 必须最先就绪
  WidgetsFlutterBinding.ensureInitialized();
  // main.dart :112-113 —— lite 低内存目标：收紧全局图像缓存上限
  PaintingBinding.instance.imageCache.maximumSize = 200;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20; // 48 MiB
  // main.dart :114 —— 启动计时归零
  resetStartupClock();

  // main.dart :129-130 —— 诊断日志尽早初始化（滚动文件 + 全局错误钩子），
  // 内部自带失败兜底，不会中断启动。
  await DiagnosticLogger.instance.init();
  markStartup('diagnostics_ready');

  // main.dart :136-143 —— 首帧回调：记录首帧耗时 + intl 日期符号初始化
  // （zh_CN，C2 不阻塞启动串行链路；TV 消费面经验证不依赖首帧前的
  // DateFormat）。
  setupFirstFrameCallback();

  // main.dart :149-154 —— 全局 ErrorWidget 兜底（可读占位 + 写诊断日志）。
  installFallbackErrorWidget();

  // main.dart :162 —— 批次44：硬解播放（audio offload）配置必须在
  // AudioService 被构造前就绪（EqualizerService.init() 会构造 AudioService），
  // 串行前置，不能进下面的 Future.wait。
  await restoreAudioOffloadPref();
  // main.dart :166 —— 批次44 软解兜底：必须在 offload 配置已确定后启动。
  AudioOffloadGuard.instance.start();
  // main.dart :171 —— 批次45：开始接收 Media3 的真实硬解状态（start 幂等）。
  AudioOffloadStatusService.instance.start();

  // main.dart :172-193 —— 无依赖初始化并发执行 + 八项本地偏好恢复。
  await Future.wait([
    // 加载 MD3 风格播放页的独立歌词偏好（从 SharedPreferences）
    Md3LyricPreferences.instance.load(),
    // 恢复屏幕常亮开关状态，供 PlayerProvider/MV 页播放时读取
    WakelockService.instance.init().catchError((_) {}),
    // 初始化均衡器服务（恢复偏好设置，监听播放状态自动绑定）
    EqualizerService.instance.init().catchError((_) {}),
    // 初始化蝰蛇母带服务（恢复开关与 10 段增益并推送原生处理链）
    ViperMasterService.instance.init().catchError((_) {}),
    // 恢复蓝牙歌词开关 + 实时歌词推送协议（SuperLyric + 关闭）
    restoreLyricPushPref(),
    // 恢复全屏播放器横屏沉浸开关（全局变量，播放器同步读取）
    restoreLandscapeImmersivePref(),
    // 恢复横屏悬浮 Dock 贴边方向（批次36）：必须在 runApp 前完成
    restoreLandscapeDockSidePref(),
    // 恢复省电帧率开关：帧率预算必须在首帧前应用
    restoreUiLowFrameRatePref(),
  ]);
  markStartup('local_preferences_ready');

  // main.dart :197-198 —— 注册原生回调（通知栏按钮 / 桌面歌词）。桌面歌词
  // 与通知栏在共享服务层（lib/core/services），TV 路径保持注册（零行为差异）。
  MediaNotificationService.initCallbacks();
  DesktopLyricService.instance.registerNativeCallbacks();
  // 批次51 后段偏差记录：main.dart :200 的悬浮窗识曲原生回调注册
  // （FloatingRecognitionService.registerNativeCallbacks，lib 副本）在 TV
  // 入口**不做**——该 lib 副本经 recognition_utils → 手机 full_player_route
  // 把 37 个手机页面（专辑/歌手/登录/评论/睡眠定时器/均衡器设置等）拉进
  // TV 编译闭包，树摇目标直接破功；且 tv_ui 有自己的适配副本
  // （lib/tv_ui/modules/recognition/floating_recognition_service.dart，
  // 由 tv_ui SongRecognitionPage 使用与注册），两副本 method channel 完全
  // 同名（floating_recognition / media_store），TV 上 lib 副本的启动期
  // 注册是冗余链路。TV 识曲功能由 tv_ui 副本全权承接，无行为缺口。

  // 批次50 播种（随入口迁移）：TV 焦点诊断日志（仅 debug 构建实际生效，
  // release 随 kDebugMode 树摇剔除；内部 kTvBuild 守卫保留，幂等）。
  TvFocusDebug.install();

  // main.dart :211-214 —— 启动听歌等级与 CSCC 真实播放事件上报
  // （内部按平台/登录态自行处理）。
  ListeningGradeService.instance.init();
  ListenReportService.instance.init();

  // main.dart :227-229 —— 酷狗本地 API 服务器懒启动接线（lite 策略：
  // 不在启动时无条件启动 dlopen libkugou_server.so，首个请求按需触发）。
  // TV 在线内容（发现/歌单/搜索）依赖此链路，必须接线。
  // LocalHttpServer（DLNA 拉流）同为懒启动（DlnaProvider.castSong 触发）。
  if (!kIsWeb) {
    KugouApiClient.onServerNeeded = KugouApiServer.ensureStarted;
  }

  // main.dart 批次43 TV 跳过项（TV 构建本就不执行，此处不做）：
  // - QuickActions.initialize（:234-244，`!kTvBuild` 守卫）
  // - UpdateCheckService.scheduleStartupCheck（:266-270，`!kTvBuild` 守卫）
  // - requestPermissions 首帧回调（TV 分支内部立即返回）
  // main.dart 省略项（执行但 TV 不消费）：onboarding / 用户协议读取
  // （:247-259，返回值仅传入手机 MyApp，TvApp 无 onboarding/协议路由）。

  markStartup('bootstrap_ready');
}
