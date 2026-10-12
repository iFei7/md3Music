/// 应用内更新清单（GitHub Release 附件 latest.json）的解析与校验。
///
/// 协议与 sonify 的 `updates/latest.json` 同构：
/// 每次发版在 Release 附件中附带 `latest.json`，字段含义见 [UpdateManifest]。
/// 本地约束（本项目特化）：
/// - `apkUrl` 必须是 https 且指向 `github.com/<owner>/<repo>/releases/download/`；
/// - `releaseNotes` 仅要求 zh-CN 字符串数组（允许其他语言并存）；
/// - `sha256` 为 64 位**小写**十六进制；
/// - 任何字段非法 → 整体拒绝（抛 [FormatException]），绝不部分采用。
library;

import 'dart:convert';

import 'github_release_client.dart';

/// 允许的 ABI 集合（与 sonify 客户端一致）。
const Set<String> kSupportedAbis = {
  'armeabi-v7a',
  'arm64-v8a',
  'x86',
  'x86_64',
};

/// 清单 JSON 原文大小上限（256 KiB，防异常附件撑爆内存）。
const int kMaxManifestBytes = 256 * 1024;

/// 单条更新说明长度上限。
const int kMaxNoteLength = 4096;

/// 一条已通过校验的更新清单。
class UpdateManifest {
  const UpdateManifest({
    required this.schemaVersion,
    required this.applicationId,
    required this.versionCode,
    required this.versionName,
    required this.publishedAt,
    required this.minSdk,
    required this.abis,
    required this.apkUrl,
    required this.apkSize,
    required this.sha256,
    required this.releasePageUrl,
    required this.releaseNotes,
  });

  /// 协议版本，当前固定为 1。
  final int schemaVersion;

  /// APK 包名（必须与本机安装包一致才可覆盖安装）。
  final String applicationId;

  /// 严格递增的构建号；与本地 PackageInfo.buildNumber 比较判断是否有更新。
  final int versionCode;

  /// 展示用版本名，如 `5.9.1`；不参与先后判断。
  final String versionName;

  /// ISO 8601 发布时间字符串（仅展示用途）。
  final String publishedAt;

  /// APK 最低系统版本。
  final int minSdk;

  /// APK 包含的 ABI 列表（1~4 项，均在 [kSupportedAbis] 内）。
  final List<String> abis;

  /// APK 附件 HTTPS 直链（github.com releases download 域）。
  final String apkUrl;

  /// APK 准确字节数（JSON 整数）。
  final int apkSize;

  /// APK 文件 SHA-256，64 位小写十六进制。
  final String sha256;

  /// 同 Tag 的 Release 页面地址（兜底跳转用）。
  final String releasePageUrl;

  /// 更新说明（语言代码 → 条目列表），至少包含一个语言。
  final Map<String, List<String>> releaseNotes;

  /// 按优先级取中文说明：zh-CN → 任意 zh-* → 第一个语言 → 空列表。
  List<String> get notesZh {
    final zhCn = releaseNotes['zh-CN'];
    if (zhCn != null && zhCn.isNotEmpty) return zhCn;
    for (final entry in releaseNotes.entries) {
      if (entry.key.toLowerCase().startsWith('zh')) {
        return entry.value;
      }
    }
    return releaseNotes.values.isEmpty
        ? const <String>[]
        : releaseNotes.values.first;
  }

  /// 解析并整体校验清单 JSON。非法输入抛 [FormatException]。
  factory UpdateManifest.parse(String rawJson) {
    // 按真实字节数（UTF-8）而非字符数判限
    if (utf8.encode(rawJson).length > kMaxManifestBytes) {
      throw const FormatException('清单超过 256 KiB 上限');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException {
      rethrow;
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('清单根节点必须是 JSON 对象');
    }
    final m = decoded;

    final schemaVersion = _requireInt(m, 'schemaVersion');
    if (schemaVersion != 1) {
      // 含插值不能声明 const
      throw FormatException('不支持的清单协议版本 schemaVersion=$schemaVersion');
    }

    final applicationId = _requireString(m, 'applicationId');
    if (applicationId.isEmpty || applicationId.length > 128) {
      throw const FormatException('applicationId 非法');
    }

    final versionCode = _requireInt(m, 'versionCode');
    if (versionCode <= 0) {
      throw const FormatException('versionCode 必须为正整数');
    }

    final versionName = _requireString(m, 'versionName');
    if (versionName.isEmpty || versionName.length > 128) {
      throw const FormatException('versionName 非法');
    }

    final publishedAt = _requireString(m, 'publishedAt');
    if (DateTime.tryParse(publishedAt) == null) {
      throw const FormatException('publishedAt 不是合法的 ISO 8601 时间');
    }

    final minSdk = _requireInt(m, 'minSdk');
    if (minSdk < 1 || minSdk > 10000) {
      throw const FormatException('minSdk 超出允许范围');
    }

    final abisRaw = m['abis'];
    if (abisRaw is! List) {
      throw const FormatException('abis 必须是字符串数组');
    }
    final abis = <String>[];
    for (final item in abisRaw) {
      if (item is! String) throw const FormatException('abis 含非字符串项');
      abis.add(item);
    }
    if (abis.isEmpty ||
        abis.length > 4 ||
        abis.toSet().length != abis.length ||
        abis.any((a) => !kSupportedAbis.contains(a))) {
      throw const FormatException('abis 列表非法');
    }

    final apkUrl = _requireString(m, 'apkUrl');
    _validateApkUrl(apkUrl);

    final apkSize = _requireInt(m, 'apkSize');
    if (apkSize <= 0 || apkSize > 200 * 1024 * 1024) {
      throw const FormatException('apkSize 超出允许范围（1 B ~ 200 MiB）');
    }

    final sha256 = _requireString(m, 'sha256');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('sha256 必须是 64 位小写十六进制');
    }

    final releasePageUrl = _requireString(m, 'releasePageUrl');
    final pageUri = Uri.tryParse(releasePageUrl);
    if (pageUri == null ||
        pageUri.scheme != 'https' ||
        pageUri.host != 'github.com' ||
        pageUri.userInfo.isNotEmpty) {
      throw const FormatException('releasePageUrl 必须是 github.com 的 https 地址');
    }

    final notesRaw = m['releaseNotes'];
    if (notesRaw is! Map) {
      throw const FormatException('releaseNotes 必须是语言映射对象');
    }
    final releaseNotes = <String, List<String>>{};
    for (final entry in notesRaw.entries) {
      final locale = entry.key;
      if (locale is! String ||
          !RegExp(r'^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$').hasMatch(locale)) {
        throw const FormatException('releaseNotes 语言键非法');
      }
      final listRaw = entry.value;
      if (listRaw is! List) {
        throw FormatException('releaseNotes[$locale] 必须是字符串数组');
      }
      final notes = <String>[];
      for (final item in listRaw) {
        if (item is! String ||
            item.trim().isEmpty ||
            item.length > kMaxNoteLength) {
          throw FormatException('releaseNotes[$locale] 条目非法');
        }
        notes.add(item);
      }
      if (notes.length > 100) {
        throw FormatException('releaseNotes[$locale] 条目过多');
      }
      releaseNotes[locale] = notes;
    }
    if (releaseNotes.isEmpty || releaseNotes.length > 32) {
      throw const FormatException('releaseNotes 必须非空且不超过 32 种语言');
    }

    return UpdateManifest(
      schemaVersion: schemaVersion,
      applicationId: applicationId,
      versionCode: versionCode,
      versionName: versionName,
      publishedAt: publishedAt,
      minSdk: minSdk,
      abis: List<String>.unmodifiable(abis),
      apkUrl: apkUrl,
      apkSize: apkSize,
      sha256: sha256,
      releasePageUrl: releasePageUrl,
      releaseNotes: Map<String, List<String>>.unmodifiable(releaseNotes),
    );
  }

  /// 从 GitHub API 的 Release 附件直接构造「隐式清单」。
  ///
  /// 用于 Release 未附带 latest.json 的场景：附件元数据（字节数、可选的
  /// SHA-256 digest）由 GitHub API 本身提供，可信度等同附件 URL 本身。
  /// 与 [parse] 的差异：
  /// - [versionCode] 传 0（API 元数据无构建号，版本比较走 versionName）；
  /// - [sha256] 可为空串（API 未返回 digest 时只做字节数校验）；
  /// - [applicationId] 由调用方传入本地包名（同仓库 Release，覆盖安装的
  ///   包名/签名一致性最终由 Android 系统兜底）。
  factory UpdateManifest.explicit({
    required String versionName,
    required String applicationId,
    required String apkUrl,
    required int apkSize,
    String sha256 = '',
    int buildNumber = 0,
    required String releasePageUrl,
    List<String> releaseNotes = const <String>[],
  }) {
    return UpdateManifest(
      schemaVersion: 1,
      applicationId: applicationId,
      // Release body 中解析出的 CI 构建号（GitHub run_number，单调递增）；
      // 0 表示 Release 未标注（旧 Release），比较走 versionName。
      versionCode: buildNumber,
      versionName: versionName,
      publishedAt: '',
      minSdk: 0,
      abis: const <String>[],
      apkUrl: apkUrl,
      apkSize: apkSize,
      sha256: sha256,
      releasePageUrl: releasePageUrl,
      releaseNotes: releaseNotes.isEmpty
          ? const <String, List<String>>{'': <String>[]}
          : <String, List<String>>{'zh-CN': releaseNotes},
    );
  }

  /// 复制并替换下载目标（UI 选择不同 ABI 附件时使用）。
  UpdateManifest copyWith({
    String? apkUrl,
    int? apkSize,
    String? sha256,
  }) {
    return UpdateManifest(
      schemaVersion: schemaVersion,
      applicationId: applicationId,
      versionCode: versionCode,
      versionName: versionName,
      publishedAt: publishedAt,
      minSdk: minSdk,
      abis: abis,
      apkUrl: apkUrl ?? this.apkUrl,
      apkSize: apkSize ?? this.apkSize,
      sha256: sha256 ?? this.sha256,
      releasePageUrl: releasePageUrl,
      releaseNotes: releaseNotes,
    );
  }

  /// apkUrl 白名单：https、无凭据、github.com、
  /// 路径形如 `/<owner>/<repo>/releases/download/<tag>/<name>.apk`。
  ///
  /// 下载时的 302 跳转（release-assets.githubusercontent.com 等 CDN 域）
  /// 由 HTTP 客户端自动跟随，不在清单 URL 校验范围内。
  static void _validateApkUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('apkUrl 必须是无凭据的 https github.com 地址');
    }
    final segments = uri.pathSegments;
    final expected = <String>[
      GithubReleaseClient.owner,
      GithubReleaseClient.repo,
      'releases',
      'download',
    ];
    if (segments.length != 7) {
      throw const FormatException('apkUrl 路径段数不符');
    }
    for (var i = 0; i < expected.length; i++) {
      if (segments[i] != expected[i]) {
        throw const FormatException('apkUrl 不指向本项目 Release 附件');
      }
    }
    final tag = segments[5];
    final file = segments[6];
    if (tag.isEmpty ||
        file.isEmpty ||
        !file.toLowerCase().endsWith('.apk') ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(tag) ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(file)) {
      throw const FormatException('apkUrl 的 tag/文件名含非法字符');
    }
  }

  /// 逐字段强类型提取：缺失或类型不符一律抛 [FormatException]。
  static int _requireInt(Map<String, dynamic> m, String key) {
    final value = m[key];
    // 仅接受 JSON 整数（dart:convert 将其解析为 int），不接受 5.0 之类的浮点
    if (value is int) return value;
    throw FormatException('字段 $key 缺失或不是整数');
  }

  static String _requireString(Map<String, dynamic> m, String key) {
    final value = m[key];
    if (value is String) return value.trim();
    throw FormatException('字段 $key 缺失或不是字符串');
  }
}
