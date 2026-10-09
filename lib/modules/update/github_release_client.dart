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

/// 从 releases 列表页 HTML 中解析**第一个** release 的 tag 名。
///
/// 匹配 `/releases/tag/<tag>` 形式的链接。GitHub 的 releases 页面已按
/// 发布时间倒序排列，故扫描到的**第一个 lite tag** 即最新。
/// `ci-<sha>` 形式的 Release 会被 [isLiteTag] 跳过。
/// 解析不出返回 null（放弃，不抛异常）。
///
/// 不用 HTML 实体解码：tag 只含字母数字与 `-` / `_` / `.`，GitHub 在链接
/// 里原样输出，无需 `unescape`。
String? parseTagFromReleasesHtml(String html) {
  const marker = '/releases/tag/';
  String? firstAny;
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
    firstAny ??= tag;
    if (isLiteTag(tag)) return tag;
  }
  // 没有 lite tag 时退回首个 link，保持旧行为（不因格式变化而彻底失效）
  return firstAny;
}

/// GitHub Release 客户端：REST API 为主链路，HTML 页面为回退链路。
///
/// 为什么不用 `/releases/latest`：该端点按 GitHub 规范**排除 prerelease**，
/// 而本仓库的 lite Release 全部标记为 prerelease（每次 push 自动发一个），
/// 实测 `api.github.com/repos/iFei7/md3Music/releases/latest` 返回 404。
/// 因此改用 `/releases` 列表端点：它包含 prerelease，且按发布时间倒序，
/// 首条即最新。
///
/// 为什么需要回退：部分网络环境下 `api.github.com` 易超时，且未鉴权
/// 限额 60 次/小时/IP。`github.com/<repo>/releases` 的 HTML 页面能给出
/// 同样的 tag 名，且不消耗 API 配额。
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
  static const String userAgent = 'MD3Music-Android';

  /// 列表端点而非 `/latest`：lite Release 全是 prerelease，latest 端点会404。
  /// `per_page=10` 而非 1：仓库里还残留 `ci-<sha>` 形式的 Release（由另一个
  /// CI 步骤产出），列表按时间倒序时它可能排在 lite 之前，需多取几条再挑。
  static final Uri apiLatestUri = Uri.parse(
    'https://api.github.com/repos/$owner/$repo/releases?per_page=10',
  );
  static final Uri htmlLatestUri = Uri.parse(
    'https://github.com/$owner/$repo/releases',
  );

  static final Uri _fallbackHtmlUri = Uri.parse(
    'https://github.com/$owner/$repo/releases',
  );

  final Dio _dio;

  @override
  Future<ReleaseInfo?> fetchLatest() async {
    final viaApi = await _fetchViaApi();
    if (viaApi != null) return viaApi;
    return _fetchViaRedirect();
  }

  /// 主链路：GitHub REST API。
  Future<ReleaseInfo?> _fetchViaApi() async {
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
      if (response.statusCode != 200 || response.data == null) {
        debugPrint('[UpdateCheck] API 返回 ${response.statusCode}，转回退链路');
        return null;
      }
      // `/releases` 返回数组；`/releases/latest` 返回对象。兼容两种形状，
      // 便于用注入的 mock Dio 直接喂对象单测。
      final dynamic payload = response.data;
      final List<Map<String, dynamic>> items = payload is List
          ? payload.whereType<Map>().map(Map<String, dynamic>.from).toList()
          : (payload is Map ? [Map<String, dynamic>.from(payload)] : const[]);
      if (items.isEmpty) {
        debugPrint('[UpdateCheck] API 响应为空或形状异常，转回退链路');
        return null;
      }
      // 仓库里混有 `ci-<sha>` 形式的 Release（另一个 CI 步骤产出），
      // 列表按时间倒序时它可能排在 lite 之前。挑第一个 lite tag；
      // 无 liteTag 前缀的老 release（历史 `lite-<sha>` 形式）也接受。
      final picked = items.firstWhere(
        (e) => isLiteTag(e['tag_name'] as String?),
        orElse: () => items.first,
      );
      final tagName = (picked['tag_name'] as String?)?.trim();
      if (tagName == null || tagName.isEmpty) {
        debugPrint('[UpdateCheck] API 响应缺少 tag_name，转回退链路');
        return null;
      }
      final htmlUrl = (picked['html_url'] as String?)?.trim();
      return ReleaseInfo.fromTag(
        tagName: tagName,
        htmlUrl: (htmlUrl == null || htmlUrl.isEmpty)
            ? _fallbackHtmlUri.toString()
            : htmlUrl,
      );
    } catch (error) {
      debugPrint('[UpdateCheck] API 查询失败：$error');
      return null;
    }
  }

  /// 回退链路：解析 releases 页面 HTML，不消耗 API 配额。
  ///
  /// 为什么不再用 302：`/releases/latest` 会因lite Release 全为 prerelease
  /// 而 404（latest 端点排除 prerelease），没有 Location 头可解析。
  /// releases 列表页里每个 release 都有 `/releases/tag/<tag>` 链接，
  /// 取**第一个**即最新（页面已按发布时间倒序）。
  Future<ReleaseInfo?> _fetchViaRedirect() async {
    try {
      final response = await _dio.getUri<String>(
        htmlLatestUri,
        options: Options(
          headers: {'User-Agent': userAgent},
          validateStatus: (_) => true,
        ),
      );
      if (response.statusCode != 200 || response.data == null) {
        debugPrint(
          '[UpdateCheck] 回退链路 HTTP ${response.statusCode}，放弃',
        );
        return null;
      }
      final tagName = parseTagFromReleasesHtml(response.data!);
      if (tagName == null) {
        debugPrint('[UpdateCheck] 回退链路未从页面解析出 tag');
        return null;
      }
      return ReleaseInfo.fromTag(
        tagName: tagName,
        htmlUrl: 'https://github.com/$owner/$repo/releases/tag/$tagName',
      );
    } catch (error) {
      debugPrint('[UpdateCheck] 回退链路失败：$error');
      return null;
    }
  }
}
