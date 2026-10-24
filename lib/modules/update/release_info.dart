/// 一次 Release 查询的结果（纯数据，不依赖任何网络/Flutter 类型）。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.htmlUrl,
  });

  /// 由 GitHub tag 构造：剥离 `v` 前缀写入 [version] 供展示与比较。
  factory ReleaseInfo.fromTag({
    required String tagName,
    required String htmlUrl,
  }) {
    final tag = tagName.trim();
    final bare = (tag.startsWith('v') || tag.startsWith('V'))
        ? tag.substring(1)
        : tag;
    return ReleaseInfo(tagName: tag, version: bare, htmlUrl: htmlUrl);
  }

  /// 原始 tag，形如 `v5.6.5`。
  final String tagName;

  /// 去掉 `v` 前缀的版本号，形如 `5.6.5`。
  final String version;

  /// Release 页面地址（供跳转下载）。
  final String htmlUrl;
}

/// Release 数据来源抽象：让 [UpdateCheckService] 可在测试中注入假实现，不联网。
abstract class ReleaseSource {
  /// 查询最新 Release。查不到（网络失败 / 无 Release / 响应异常）返回 null。
  Future<ReleaseInfo?> fetchLatest();

  /// 批次34：按通道查询带附件详情。
  ///
  /// [beta] 为 true 查 Pre-release 通道（开发快照），false 查正式 Latest。
  /// 默认实现：非 Beta 委托 [fetchLatest]（附件为空、说明为空——既有
  /// 测试替身只需实现 [fetchLatest] 即可继续工作）；Beta 通道返回 null
  /// （替身未支持时按「查不到」处理，绝不误报新版）。
  Future<ReleaseDetail?> fetchChannelDetail({required bool beta}) async {
    if (beta) return null;
    final info = await fetchLatest();
    return info == null
        ? null
        : ReleaseDetail(info: info, assets: const <ReleaseAsset>[], body: '');
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

/// 批次34：从 Release body 解析 CI 构建号（「- 构建号: N」行，jq 写入的
/// run_number）。旧 Release body 无此行 → 返回 0（比较退化为 versionName）。
///
/// 抽为公共函数：自动提醒（UpdateCheckService）与应用内更新器
/// （InAppUpdater）在 Beta 通道下都需用构建号区分同一 versionName 的
/// 相邻快照。
int buildNumberFromBody(String body) {
  final match = RegExp(r'构建号[:：]\s*(\d+)').firstMatch(body);
  if (match == null) return 0;
  return int.tryParse(match.group(1)!) ?? 0;
}
