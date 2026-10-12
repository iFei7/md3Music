/// 应用内更新器：检查 → 下载 → 校验 → 唤起系统安装器的完整状态机。
///
/// 数据流（对齐 sonify 的 UpdateRepository/UpdateDownloader/UpdateInstaller）：
/// 1. 复用 [GithubReleaseClient] 拿到最新 lite Release 的 tag；
/// 2. 拼出该 Release 的 `latest.json` 附件地址并下载解析（404 → 无应用内
///    更新清单，调用方回退浏览器下载）；
/// 3. 清单 `versionCode` 大于本地 `PackageInfo.buildNumber` 才视为有更新；
/// 4. 下载 APK 到应用缓存子目录，期间通过 [progress] 汇报 0~1 进度；
/// 5. 下载完成后校验字节数与 SHA-256（package:crypto），不一致删文件报错；
/// 6. 校验通过后经 MethodChannel `app.gracemusic/update` 唤起系统安装器
///    （android/ 侧配套改动见 ANDROID_SETUP_NOTES.md，本文件不触碰 android/）。
///
/// 所有异常都被捕获并转入 [InAppUpdaterPhase.error]，不向 UI 抛出。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'github_release_client.dart';
import 'release_version.dart';
import 'update_manifest.dart';

/// 更新器所处阶段。
enum InAppUpdaterPhase {
  /// 初始 / 复位。
  idle,

  /// 正在查询最新 Release 与清单。
  checking,

  /// 清单就绪且确有新版本，等待用户确认下载。
  available,

  /// 正在下载 APK，[InAppUpdater.progress] 持续更新。
  downloading,

  /// 正在校验字节数与 SHA-256。
  verifying,

  /// 校验通过，APK 就绪，等待用户点击安装。
  readyToInstall,

  /// 出错，[InAppUpdater.errorMessage] 携带原因；文件已清理。
  error,
}

/// 一次检查的结论。
enum InAppUpdateCheckResult {
  /// 发现新版本（[InAppUpdater.manifest] 已就绪）。
  available,

  /// 已是最新（或本地构建号无法比较，宁可不提示）。
  upToDate,

  /// 远端没有可用的 latest.json（旧版本 Release 或网络查不到 Release），
  /// 调用方应回退「打开浏览器下载页」的旧行为。
  noManifest,

  /// 检查或清单校验失败。
  error,
}

/// 应用内更新器（ChangeNotifier，供设置页对话框订阅）。
class InAppUpdater extends ChangeNotifier {
  InAppUpdater({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15),
              // 流式下载时该超时作用于「相邻数据块之间」，30s 足够宽容
              receiveTimeout: const Duration(seconds: 30),
              // GitHub 附件 302 → CDN 域，默认 followRedirects 即可
              followRedirects: true,
              maxRedirects: 5,
              headers: {'User-Agent': GithubReleaseClient.userAgent},
            ),
          );

  /// MethodChannel：android/ 侧需注册同名通道并实现 `installApk`，
  /// 配套说明见 lib/modules/update/ANDROID_SETUP_NOTES.md。
  static const MethodChannel _installChannel = MethodChannel(
    'app.gracemusic/update',
  );

  /// APK 缓存子目录名（相对 getTemporaryDirectory()）。
  /// android/ 侧 file_paths.xml 的 cache-path 必须与之保持一致。
  static const String _cacheDirName = 'update_apk';

  final Dio _dio;

  InAppUpdaterPhase _phase = InAppUpdaterPhase.idle;
  UpdateManifest? _manifest;
  List<UpdateManifest> _candidates = const <UpdateManifest>[];
  double _progress = 0;
  String _errorMessage = '';
  File? _apkFile;
  String? _packageName;
  double _lastNotifiedProgress = -1;

  /// 当前阶段。
  InAppUpdaterPhase get phase => _phase;

  /// 已通过校验的更新清单（仅 [InAppUpdaterPhase.available] 之后非空）。
  UpdateManifest? get manifest => _manifest;

  /// 可选的 APK 下载目标（不同 ABI / 兼容包），首个为默认推荐项。
  /// 来自 Release 附件（按 ABI 匹配过滤）；单一附件时长度为 1。
  List<UpdateManifest> get candidates => _candidates;

  /// 下载进度 0~1（仅 [InAppUpdaterPhase.downloading] 阶段有意义）。
  double get progress => _progress;

  /// 错误信息（仅 error 阶段非空）。
  String get errorMessage => _errorMessage;

  /// 已校验通过的 APK 文件（仅 readyToInstall 阶段非空）。
  File? get apkFile => _apkFile;

  void _setPhase(InAppUpdaterPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// 检查更新：取最新 Release（含附件）→ 清单/隐式清单 → 比对版本。
  ///
  /// 优先使用 Release 附件中的 latest.json（sonify 协议，字段强校验）；
  /// 无该附件时直接用 GitHub API 的附件元数据（字节数 + 可选 SHA-256
  /// digest）构造隐式清单，因此**任何 lite Release 都能走应用内更新**。
  /// 任何一步失败都不抛异常，返回对应结论并（在必要时）转入 error 状态。
  Future<InAppUpdateCheckResult> check() async {
    _resetToIdle();
    _setPhase(InAppUpdaterPhase.checking);
    try {
      // Release 资产只有 Android APK，其它平台没有应用内更新可言
      if (kIsWeb || !Platform.isAndroid) {
        _resetToIdle();
        return InAppUpdateCheckResult.noManifest;
      }

      final info = await PackageInfo.fromPlatform();
      _packageName = info.packageName;

      final detail = await GithubReleaseClient().fetchLatestDetail();
      final release = detail?.info;
      if (release == null || release.tagName.isEmpty) {
        _resetToIdle();
        return InAppUpdateCheckResult.noManifest;
      }

      final assets = detail!.assets;
      final manifestJson = await _fetchManifestJson(release.tagName, assets);
      if (manifestJson != null) {
        final manifest = UpdateManifest.parse(manifestJson);
        // 清单声明的包名与本机不一致 → 无法覆盖安装，按「无清单」处理
        if (manifest.applicationId != info.packageName) {
          debugPrint('[InAppUpdate] 清单包名 ${manifest.applicationId} '
              '与本机 ${info.packageName} 不一致，放弃');
          _resetToIdle();
          return InAppUpdateCheckResult.noManifest;
        }
        // 显式清单带构建号：versionCode 大于本地构建号才视为有更新；
        // 本地构建号解析不出时宁可不提示（不误报）
        final localBuild = int.tryParse(info.buildNumber);
        if (localBuild == null || manifest.versionCode <= localBuild) {
          debugPrint('[InAppUpdate] 已是最新（本地 build $localBuild，'
              '远端 ${manifest.versionCode}）');
          _resetToIdle();
          return InAppUpdateCheckResult.upToDate;
        }
        _manifest = manifest;
        _candidates = <UpdateManifest>[manifest];
        _setPhase(InAppUpdaterPhase.available);
        return InAppUpdateCheckResult.available;
      }

      // —— 隐式清单路径：从 Release 附件构造（无 latest.json 时的主路径）——
      // 排除随身听兼容包（伪装包名 com.apple.android.music，不可覆盖安装）
      final apks = assets
          .where((a) =>
              a.name.toLowerCase().endsWith('.apk') &&
              !a.name.contains('apple-music'))
          .toList();
      if (apks.isEmpty) {
        debugPrint('[InAppUpdate] Release 无可安装 APK 附件');
        _resetToIdle();
        return InAppUpdateCheckResult.noManifest;
      }
      // 双重比较：远端版本号更新 → 提示；版本号相同但远端 CI 构建号更新
      // （CI --build-number=run_number 写入 APK，release body 标注）→ 提示。
      // 本地 buildNumber：CI 包装的是 run_number，pubspec 本地构建是 +N。
      final remoteBuild = _buildNumberFromBody(detail.body);
      final localBuild = int.tryParse(info.buildNumber);
      final versionNewer = isNewerRelease(release.version, info.version);
      final buildNewer = remoteBuild > 0 &&
          localBuild != null &&
          remoteBuild > localBuild &&
          !isNewerRelease(info.version, release.version);
      if (!versionNewer && !buildNewer) {
        debugPrint('[InAppUpdate] 已是最新（本地 ${info.version}'
            '+${localBuild ?? '?'}，远端 ${release.version}+${remoteBuild > 0 ? remoteBuild : '?'}）');
        _resetToIdle();
        return InAppUpdateCheckResult.upToDate;
      }
      // 候选排序：arm64 优先、其次 32 位；同 ABI 中 standard 优先
      int rank(ReleaseAsset a) {
        final n = a.name.toLowerCase();
        if (n.contains('standard-arm64')) return 0;
        if (n.contains('standard-arm32')) return 1;
        return 2;
      }

      apks.sort((a, b) => rank(a).compareTo(rank(b)));
      // 更新说明：取 Release body 的前几行非空文本（剥掉 markdown 强调符）
      final notes = _notesFromBody(detail.body);
      _candidates = <UpdateManifest>[
        for (final a in apks)
          UpdateManifest.explicit(
            versionName: release.version,
            applicationId: info.packageName,
            apkUrl: a.downloadUrl,
            apkSize: a.size,
            sha256: a.sha256 ?? '',
            buildNumber: remoteBuild,
            releasePageUrl: release.htmlUrl,
            releaseNotes: notes,
          ),
      ];
      _manifest = _candidates.first;
      _setPhase(InAppUpdaterPhase.available);
      return InAppUpdateCheckResult.available;
    } on FormatException catch (error) {
      debugPrint('[InAppUpdate] 清单校验失败：$error');
      _fail('更新清单校验失败，已放弃应用内更新');
      return InAppUpdateCheckResult.error;
    } catch (error) {
      debugPrint('[InAppUpdate] 检查更新失败：$error');
      _fail('检查更新失败：$error');
      return InAppUpdateCheckResult.error;
    }
  }

  /// 从 Release body 解析 CI 构建号（「- 构建号: N」行，jq 写入的 run_number）。
  /// 旧 Release body 无此行 → 返回 0（比较退化为 versionName）。
  static int _buildNumberFromBody(String body) {
    final match = RegExp(r'构建号[:：]\s*(\d+)').firstMatch(body);
    if (match == null) return 0;
    return int.tryParse(match.group(1)!) ?? 0;
  }

  /// 从 Release body 提取更新说明行（最多 8 行、每行 ≤200 字符）。
  ///
  /// body 形如「Lite 分支 CI 自动构建。\n\n- 版本: ...\n- 提交: ...\n\n### 下载\n…」，
  /// 「### 下载」及之后是固定下载列表，不属于更新说明，直接截断。
  static List<String> _notesFromBody(String body) {    if (body.trim().isEmpty) return const <String>[];
    final cut = body.indexOf('###');
    final head = (cut >= 0 ? body.substring(0, cut) : body).trim();
    if (head.isEmpty) return const <String>[];
    final notes = <String>[];
    for (final raw in head.split('\n')) {
      final line = raw
          .replaceAll('**', '')
          .replaceAll('`', '')
          .replaceAll(RegExp(r'^[-*\s]+'), '')
          .trim();
      if (line.isEmpty) continue;
      notes.add(line.length > 200 ? line.substring(0, 200) : line);
      if (notes.length >= 8) break;
    }
    return notes;
  }

  /// 下载清单 JSON：优先取附件中的 latest.json（sonify 协议）。
  /// 不存在（该 Release 未附带清单）返回 null，由调用方走隐式清单路径。
  Future<String?> _fetchManifestJson(
    String tagName,
    List<ReleaseAsset> assets,
  ) async {
    final hasExplicit =
        assets.any((a) => a.name.toLowerCase() == 'latest.json');
    if (!hasExplicit) return null;
    final uri = Uri.parse(
      'https://github.com/${GithubReleaseClient.owner}/'
      '${GithubReleaseClient.repo}/releases/download/$tagName/latest.json',
    );
    try {
      final response = await _dio.getUri<String>(
        uri,
        options: Options(responseType: ResponseType.plain),
      );
      if (response.statusCode != 200 || response.data == null) {
        debugPrint('[InAppUpdate] latest.json HTTP ${response.statusCode}');
        return null;
      }
      final body = response.data!;
      return body.isEmpty ? null : body;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status != null && status >= 400 && status < 500) {
        debugPrint('[InAppUpdate] latest.json 不可用（HTTP $status），'
            '回退为 Release 附件隐式清单');
        return null;
      }
      rethrow;
    }
  }

  /// 下载 APK 到缓存目录并完成校验。
  ///
  /// [target] 为下载目标清单：null 时用 [_manifest]（默认推荐项）；
  /// UI 允许用户在 [candidates] 中切换 ABI 后传入对应清单。
  /// 流程：downloading(进度) → verifying → readyToInstall，任一步失败
  /// 转入 error 并清理半成品文件。
  Future<void> startDownload([UpdateManifest? target]) async {
    final manifest = target ?? _manifest;
    if (manifest == null ||
        (_phase != InAppUpdaterPhase.available &&
            _phase != InAppUpdaterPhase.error)) {
      return;
    }
    if (target != null) _manifest = target;
    _progress = 0;
    _lastNotifiedProgress = -1;
    _apkFile = null;
    _setPhase(InAppUpdaterPhase.downloading);

    File? apkFile;
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory(
        Platform.isWindows
            ? '${base.path}\\$_cacheDirName'
            : '${base.path}/$_cacheDirName',
      );
      await dir.create(recursive: true);
      apkFile = File(_joinPath(dir.path, _apkFileName(manifest.apkUrl)));
      // 上一次中断可能残留同名文件，先删
      if (await apkFile.exists()) {
        await apkFile.delete();
      }

      await _dio.download(
        manifest.apkUrl,
        apkFile.path,
        onReceiveProgress: _onDownloadProgress,
      );

      _setPhase(InAppUpdaterPhase.verifying);
      final length = await apkFile.length();
      if (length != manifest.apkSize) {
        throw StateError(
          '文件大小不符（实际 $length B，清单 ${manifest.apkSize} B）',
        );
      }
      // sha256 为空串（GitHub API 未返回 digest 的隐式清单）时只做字节数校验
      if (manifest.sha256.isNotEmpty) {
        final digest = await _sha256Hex(apkFile);
        if (digest != manifest.sha256) {
          throw StateError('SHA-256 校验不符');
        }
      }

      _apkFile = apkFile;
      _setPhase(InAppUpdaterPhase.readyToInstall);
    } catch (error) {
      debugPrint('[InAppUpdate] 下载/校验失败：$error');
      // 清理半成品或校验不过的文件
      try {
        if (apkFile != null && await apkFile.exists()) {
          await apkFile.delete();
        }
      } catch (cleanupError) {
        debugPrint('[InAppUpdate] 清理半成品失败：$cleanupError');
      }
      _apkFile = null;
      _fail('下载或校验失败：$error');
    }
  }

  void _onDownloadProgress(int received, int total) {
    final manifest = _manifest;
    var ratio = 0.0;
    if (manifest != null && manifest.apkSize > 0) {
      ratio = received / manifest.apkSize;
    } else if (total > 0) {
      ratio = received / total;
    }
    _progress = ratio.clamp(0.0, 1.0).toDouble();
    // 节流：进度变化不足 0.5% 不通知，避免高频 rebuild
    if (_progress - _lastNotifiedProgress >= 0.005 ||
        _progress >= 1.0) {
      _lastNotifiedProgress = _progress;
      notifyListeners();
    }
  }

  /// 从清单 apkUrl 取文件名：URL 最后一段，清洗为安全字符。
  /// 清单校验已保证以 .apk 结尾，此处兜底改名。
  String _apkFileName(String apkUrl) {
    final segments = Uri.tryParse(apkUrl)?.pathSegments ?? const <String>[];
    var name = segments.isEmpty ? '' : segments.last;
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (name.isEmpty || !name.toLowerCase().endsWith('.apk')) {
      name = 'update.apk';
    }
    return name;
  }

  /// 流式计算文件 SHA-256（小写十六进制，与清单格式一致）。
  Future<String> _sha256Hex(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// 唤起系统安装器。成功发起返回 null；失败返回错误文案（UI 直接 toast）。
  ///
  /// android/ 侧需实现 MethodChannel `app.gracemusic/update` 的 `installApk`：
  /// 参数 `path` 为 APK 绝对路径，`authority` 为 FileProvider authority
  /// （`<applicationId>.fileprovider`，运行时取自 PackageInfo，无需硬编码）。
  Future<String?> install() async {
    final file = _apkFile;
    final packageName = _packageName;
    if (file == null || packageName == null) {
      return '尚未下载更新包';
    }
    try {
      await _installChannel.invokeMethod<void>('installApk', {
        'path': file.path,
        'authority': '$packageName.fileprovider',
      });
      return null;
    } on MissingPluginException {
      const message = '原生安装通道尚未接入（见 lib/modules/update/'
          'ANDROID_SETUP_NOTES.md）';
      debugPrint('[InAppUpdate] $message');
      return message;
    } on PlatformException catch (error) {
      debugPrint('[InAppUpdate] 系统安装器调起失败：$error');
      return '无法启动安装：${error.message ?? error.code}';
    } catch (error) {
      debugPrint('[InAppUpdate] 安装调用异常：$error');
      return '无法启动安装：$error';
    }
  }

  /// 回到 idle 并丢弃清单/文件引用（对话框关闭后调用）。
  void reset() => _resetToIdle();

  void _resetToIdle() {
    _manifest = null;
    _candidates = const <UpdateManifest>[];
    _apkFile = null;
    _progress = 0;
    _lastNotifiedProgress = -1;
    _errorMessage = '';
    _phase = InAppUpdaterPhase.idle;
    notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    _setPhase(InAppUpdaterPhase.error);
  }

  static String _joinPath(String dir, String name) =>
      Platform.isWindows ? '$dir\\$name' : '$dir/$name';
}
