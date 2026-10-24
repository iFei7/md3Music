import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/utils/app_toast.dart';
import '../../data/repositories/settings_repository.dart';
import 'github_release_client.dart';
import 'release_info.dart';
import 'release_version.dart';

/// 一次检查的结果。
enum UpdateCheckOutcome {
  /// 已 toast 提醒用户
  notified,
  /// 已是最新（或远端版本无法比较）
  upToDate,
  /// 本次跳过（开关关闭 / 未到检查间隔 / 同一版本已提醒 / 非 Android）
  skipped,
  /// 查询失败（网络等原因，静默）
  failed,
}

/// 提醒方式注入点：默认走全局原生 toast，测试中替换为收集器。
typedef UpdateNotifier = void Function(String message);

/// 版本更新检测与提醒。
///
/// 职责边界：只负责「查最新版本 → 比本地版本 → 提醒一次」，
/// 不做下载、不做安装、不展示更新日志。
class UpdateCheckService {
  UpdateCheckService({
    ReleaseSource? source,
    SettingsRepository? settings,
    UpdateNotifier? notifier,
    Future<String> Function()? readCurrentVersion,
    Future<int> Function()? readCurrentBuildNumber,
    Future<bool> Function()? readBetaChannel,
  }) : _source = source ?? GithubReleaseClient(),
       _settings = settings ?? SettingsRepository(),
       _notifier = notifier ?? _defaultNotifier,
       _readCurrentVersion = readCurrentVersion ?? _defaultCurrentVersion,
       _readCurrentBuildNumber =
           readCurrentBuildNumber ?? _defaultCurrentBuildNumber,
       _readBetaChannel = readBetaChannel ?? _defaultReadBetaChannel;

  /// 全局单例（启动挂载点使用）。
  static final UpdateCheckService instance = UpdateCheckService();

  /// 启动后延迟多久检查：避开冷启动首帧与首屏接口竞争。
  static const Duration startupDelay = Duration(seconds: 8);

  /// 两次网络查询的最小间隔（跨启动持久化）。
  static const Duration minCheckInterval = Duration(hours: 12);

  final ReleaseSource _source;
  final SettingsRepository _settings;
  final UpdateNotifier _notifier;
  final Future<String> Function() _readCurrentVersion;

  /// 本地构建号（CI --build-number=run_number 写入 PackageInfo.buildNumber）。
  /// 仅 Beta 通道下同 versionName 比较时使用。
  final Future<int> Function() _readCurrentBuildNumber;

  /// Beta 通道开关读取（批次34：默认读 SettingsRepository，测试可注入）。
  final Future<bool> Function() _readBetaChannel;

  /// 同一次运行内的防重入。
  bool _running = false;

  static void _defaultNotifier(String message) => showToast(message, long: true);

  static Future<int> _defaultCurrentBuildNumber() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return int.tryParse(info.buildNumber) ?? 0;
    } catch (error) {
      debugPrint('[UpdateCheck] 读取本地构建号失败：$error');
      return 0;
    }
  }

  static Future<bool> _defaultReadBetaChannel() =>
      SettingsRepository().getBetaChannelEnabled();

  static Future<String> _defaultCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (error) {
      debugPrint('[UpdateCheck] 读取本地版本失败：$error');
      return '';
    }
  }

  /// 启动挂载点：延迟 [startupDelay] 后自动检查一次。
  ///
  /// [suppress] 为 true 时直接跳过（首次启动引导 / 用户协议未确认时不应打扰）。
  void scheduleStartupCheck({bool suppress = false}) {
    if (suppress) return;
    // Release 资产只有 Android APK，其它平台检查无意义
    if (kIsWeb || !Platform.isAndroid) return;
    Timer(startupDelay, () {
      // ignore: discarded_futures
      checkAndNotify();
    });
  }

  /// 检查并在发现新版本时提醒。返回值便于日志与测试断言。
  Future<UpdateCheckOutcome> checkAndNotify() async {
    if (_running) return UpdateCheckOutcome.skipped;
    _running = true;
    try {
      return await _run();
    } finally {
      _running = false;
    }
  }

  /// 批次34：用户主动触发（设置页打开提醒开关）时的立即检查。
  ///
  /// [force] 为 true 时跳过 12 小时最小间隔窗口，让开关切换有「立即生效」
  /// 感；防重入、开关判定与「同版本只提醒一次」语义全部保留——开关关闭
  /// 依旧不查，同版本提醒过依旧不打扰。
  Future<UpdateCheckOutcome> checkNow({bool force = false}) async {
    if (_running) return UpdateCheckOutcome.skipped;
    _running = true;
    try {
      return await _run(force: force);
    } finally {
      _running = false;
    }
  }

  Future<UpdateCheckOutcome> _run({bool force = false}) async {
    if (!await _settings.getUpdateReminderEnabled()) {
      debugPrint('[UpdateCheck] 用户已关闭新版本提醒，跳过');
      return UpdateCheckOutcome.skipped;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final lastCheckMs = await _settings.getUpdateLastCheckMs();
      if (lastCheckMs > 0 &&
          now - lastCheckMs < minCheckInterval.inMilliseconds) {
        debugPrint('[UpdateCheck] 距上次检查不足 12 小时，跳过');
        return UpdateCheckOutcome.skipped;
      }
    }

    // 批次34：Beta 通道开启时改查 Pre-release 快照，关闭时行为完全不变。
    final beta = await _readBetaChannel();
    final detail = await _source.fetchChannelDetail(beta: beta);
    // 无论成败都记录时间戳：失败时不重试轰炸，下个窗口再试
    await _settings.setUpdateLastCheckMs(now);
    if (detail == null) return UpdateCheckOutcome.failed;
    final release = detail.info;

    final current = await _readCurrentVersion();
    final versionNewer = isNewerRelease(release.version, current);
    // Beta 下同 versionName 的相邻快照靠 Release body 的「构建号: N」区分：
    // 远端构建号更新才算新版。构建号无法比较时退化为 versionName 判断。
    // Beta 关闭时不做构建号比较，与既有行为保持零变化。
    final remoteBuild = buildNumberFromBody(detail.body);
    final localBuild = await _readCurrentBuildNumber();
    final buildNewer = beta &&
        !versionNewer &&
        !isNewerRelease(current, release.version) &&
        remoteBuild > 0 &&
        remoteBuild > localBuild;
    if (!versionNewer && !buildNewer) {
      debugPrint(
        '[UpdateCheck] 已是最新（本地 ${current.isEmpty ? '未知' : current}，远端 ${release.version}）',
      );
      return UpdateCheckOutcome.upToDate;
    }

    // 同一版本只提醒一次：避免每次启动都弹同一个版本。
    // 提醒身份：正式通道记 versionName（原语义）；Beta 记快照 tag
    // （tag 随每次构建唯一，同 versionName 的新快照可再次提醒）。
    final notifiedIdentity = beta ? release.tagName : release.version;
    if (await _settings.getUpdateLastNotifiedVersion() == notifiedIdentity) {
      debugPrint('[UpdateCheck] $notifiedIdentity 已提醒过，跳过');
      return UpdateCheckOutcome.skipped;
    }

    await _settings.setUpdateLastNotifiedVersion(notifiedIdentity);
    _notify(release, current);
    debugPrint('[UpdateCheck] 已提醒新版本 ${release.version}（本地 $current）');
    return UpdateCheckOutcome.notified;
  }

  void _notify(ReleaseInfo release, String current) {
    final currentPart = current.isEmpty ? '' : '（当前 $current）';
    _notifier('发现新版本 ${release.tagName}$currentPart，可在「设置 → 关于」中立即更新');
  }
}
