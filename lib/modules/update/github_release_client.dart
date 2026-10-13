import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'release_info.dart';

/// 从 302 的 Location 头解析 tag 名。
///
/// `/releases/latest` 的 Location 形如
/// `https://github.com/<owner>/<repo>/releases/tag/v5.6.5`。
/// 解析不出返回 null（回退链路放弃，不抛异常）。
///
/// 保留此函数供单元测试与将来可能出现非 prerelease Release 的场景使用；
/// 当前 lite 全部为 prerelease，回退链路走的是 [parseTagFromReleasesHtml]。
String? parseTagFromRedirectLocation(String? location) {
  if (location == null) return null;
  const marker = '/releases/tag/';
  final start = location.indexOf(marker);
  if (start < 0) return null;
  var tag = location.substring(start + marker.length);
  for (final separator in const ['?', '#', '/']) {
    final end = tag.indexOf(separator);
    if (end >= 0) tag = tag.substring(0, end);
  }
  tag = tag.trim();
  return tag.isEmpty ? null : tag;
}

/// 判断一个 release tag 是否属于 lite 版本序列。
///
/// 仓库里同时存在两类 Release：
/// - `v<ver>-lite-<sha7>` —— lite 正式版（当前 CI 产出形式）
/// - `lite-<sha7>`         —— lite 历史遗留形式（tag 改造前）
/// - `ci-<sha40>`          —— 另一个 CI 步骤产出的构建产物，**不是**可安装的
///   lite 版本，tag 也无法被 [parseReleaseVersion] 解析，必须排除。
bool isLiteTag(String? tag) {
  if (tag == null) return false;
  final t = tag.trim();
  if (t.startsWith('lite-')) return true;
  return t.startsWith('v') && t.contains('-lite-');
}

/// 从 releases 列表页 HTML 中解析第一个 lite release 的 tag 名。
///
/// 匹配 `/releases/tag/<tag>` 形式的链接。GitHub 的 releases 页面已按
/// 发布时间倒序排列，故扫描到的**第一个 lite tag** 即最新。
/// `ci-<sha>` 形式的 Release 会被 [isLiteTag] 跳过。
/// 解析不出（或页面里没有 lite tag）返回 null（放弃，不抛异常）。
///
/// 不用 HTML 实体解码：tag 只含字母数字与 `-` / `_` / `.`，GitHub 在链接
/// 里原样输出，无需 `unescape`。
String? parseTagFromReleasesHtml(String html) {
  const marker = '/releases/tag/';
  var cursor = 0;
  while (true) {
    final start = html.indexOf(marker, cursor);
    if (start < 0) break;
    final tail = html.substring(start + marker.length);
    final end = tail.indexOf('"');
    if (end < 0) break;
    var tag = tail.substring(0, end);
    cursor = start + marker.length + end;
    // 相对链接写法（`/owner/repo/releases/tag/x`）会多带路径片段，剥掉
    final slash = tag.lastIndexOf('/');
    if (slash >= 0) tag = tag.substring(slash + 1);
    tag = tag.trim();
    if (tag.isEmpty || tag == 'tag') continue;
    if (isLiteTag(tag)) return tag;
  }
  // 没有 lite tag 时放弃本次更新提醒，绝不把非 lite tag 当作最新版
  return null;
}

/// GitHub Release 客户端：正式版更新检测。
///
/// 构建发布规则（2026-10 起）：push 到 lite 发 Pre-release 开发快照；
/// push tag `vX.Y.Z`（无连字符）发正式版并占用 GitHub Latest。
/// 主链路直接用 `/releases/latest`：该端点只返回正式 Latest，
/// Pre-release 天然排除——应用内「检查更新」只对正式版提示。
/// 仓库尚无任何正式 Release 时该端点返回 404，客户端按「无更新」处理。
class GithubReleaseClient implements ReleaseSource {
  GithubReleaseClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              // 非 2xx/302 也交回调用方，由状态码分支处理，不抛异常
              validateStatus: (_) => true,
            ),
          );

  /// 检测目标（唯一来源；换仓库只改这两行）
  static const String owner = 'iFei7';
  static const String repo = 'md3Music';

  /// GitHub 要求 User-Agent 非空，显式声明产品标识避免被拒。
  static const String userAgent = 'GraceMusic-Android';

  /// 正式版 Latest 端点：只返回 GitHub 标记为 Latest 的非 prerelease Release。
  /// 日常 push 的 Pre-release 快照天然被排除，客户端只对正式版做更新检测。
  static final Uri apiLatestUri = Uri.parse(
    'https://api.github.com/repos/$owner/$repo/releases/latest',
  );
  static final Uri htmlLatestUri = Uri.parse(
    'https://github.com/$owner/$repo/releases',
  );

  final Dio _dio;

  /// 查询 GitHub 标记为 Latest 的正式 Release（含附件与说明）。
  ///
  /// 构建发布规则（2026-10 起）：
  /// - push 到 lite：Pre-release（tag `v<ver>-lite-<sha7>`），开发快照；
  /// - push tag `vX.Y.Z`（无连字符）→ 正式版 + GitHub Latest；
  ///   `vX.Y.Z-<suffix>` → Pre-release。
  /// `/releases/latest` 端点天然只返回正式 Latest，Pre-release 一律排除，
  /// 客户端因此只对正式版做更新检测。
  Future<ReleaseDetail?> fetchLatestDetail() async {
    try {
      final response = await _dio.getUri<dynamic>(
        apiLatestUri,
        options: Options(
          headers: {
            'User-Agent': userAgent,
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        ),
      );
      // 404 = 仓库尚无任何正式 Release（全是 prerelease）→ 视为无更新
      if (response.statusCode != 200 || response.data is! Map) {
        debugPrint('[UpdateCheck] /releases/latest HTTP ${response.statusCode}');
        return null;
      }
      return _detailFromApiItem(Map<String, dynamic>.from(response.data));
    } catch (error) {
      debugPrint('[UpdateCheck] latest 查询失败：$error');
      return null;
    }
  }

  @override
  Future<ReleaseInfo?> fetchLatest() async {
    final detail = await fetchLatestDetail();
    return detail?.info;
  }
  /// 从 GitHub API 的 Release JSON 对象构造 [ReleaseDetail]。
  ReleaseDetail? _detailFromApiItem(Map<String, dynamic> item) {
    final tagName = (item['tag_name'] as String?)?.trim();
    if (tagName == null || tagName.isEmpty) return null;
    final htmlUrl = (item['html_url'] as String?)?.trim();
    final info = ReleaseInfo.fromTag(
      tagName: tagName,
      htmlUrl: (htmlUrl == null || htmlUrl.isEmpty)
          ? 'https://github.com/$owner/$repo/releases/tag/$tagName'
          : htmlUrl,
    );
    final assets = <ReleaseAsset>[];
    final rawAssets = item['assets'];
    if (rawAssets is List) {
      for (final a in rawAssets.whereType<Map>()) {
        final asset = Map<String, dynamic>.from(a);
        final name = asset['name'];
        final size = asset['size'];
        final url = asset['browser_download_url'];
        if (name is! String || url is! String) continue;
        final sizeInt = size is int ? size : int.tryParse('$size');
        if (sizeInt == null || sizeInt <= 0) continue;
        final digestRaw = asset['digest'];
        String? sha256;
        if (digestRaw is String && digestRaw.startsWith('sha256:')) {
          final hex = digestRaw.substring(7).toLowerCase();
          if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) sha256 = hex;
        }
        assets.add(
          ReleaseAsset(
            name: name,
            size: sizeInt,
            downloadUrl: url,
            sha256: sha256,
          ),
        );
      }
    }
    final body = item['body'];
    return ReleaseDetail(
      info: info,
      assets: assets,
      body: body is String ? body : '',
    );
  }
}

/// GitHub Release 的一个附件（asset）。
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.downloadUrl,
    this.sha256,
  });

  /// 附件文件名，形如 `GraceMusic-v5.9.0-...-standard-arm64.apk`。
  final String name;

  /// 附件精确字节数（GitHub API 直接提供）。
  final int size;

  /// 下载直链（github.com 域，302 跳 CDN 由 HTTP 客户端自动跟随）。
  final String downloadUrl;

  /// GitHub API 提供的附件 SHA-256（`sha256:<64hex>` 中的 hex 部分）；
  /// null 表示响应未带 digest，只能做字节数校验。
  final String? sha256;
}

/// 一次「带附件详情」的 Release 查询结果。
class ReleaseDetail {
  const ReleaseDetail({
    required this.info,
    required this.assets,
    required this.body,
  });

  /// 基础信息（tag / version / 页面地址）。
  final ReleaseInfo info;

  /// 全部附件（含 APK）。
  final List<ReleaseAsset> assets;

  /// Release 说明原文（Markdown），用于更新说明展示。
  final String body;
}
