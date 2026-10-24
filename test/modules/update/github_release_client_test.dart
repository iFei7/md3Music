import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/update/github_release_client.dart';
import 'package:md3music/modules/update/release_info.dart';

/// 批次34：本地桩适配器——记录请求并回放固定响应，不联网。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.responder);

  final ResponseBody Function(RequestOptions options) responder;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(Object json, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(json),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

Map<String, dynamic> _releaseItem(
  String tag, {
  bool prerelease = true,
  String body = '',
}) =>
    {
      'tag_name': tag,
      'prerelease': prerelease,
      'body': body,
      'assets': const <Map<String, dynamic>>[],
      'html_url': 'https://github.com/iFei7/md3Music/releases/tag/$tag',
    };

GithubReleaseClient _clientWith(_StubAdapter adapter) =>
    GithubReleaseClient(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
    );

void main() {
  test('仓库地址为唯一来源常量', () {
    expect(
      GithubReleaseClient.apiLatestUri.toString(),
      'https://api.github.com/repos/iFei7/md3Music/releases/latest',
    );
    expect(
      GithubReleaseClient.htmlLatestUri.toString(),
      'https://github.com/iFei7/md3Music/releases',
    );
    expect(GithubReleaseClient.userAgent, 'GraceMusic-Android');
  });

  group('parseTagFromRedirectLocation', () {
    test('标准 Location 解析出 tag', () {
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/zzyoxml/md3Music/releases/tag/v5.6.5',
        ),
        'v5.6.5',
      );
    });

    test('容忍查询串与锚点', () {
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/zzyoxml/md3Music/releases/tag/v5.6.5?x=1',
        ),
        'v5.6.5',
      );
    });

    test('无 tag 段或空值返回 null', () {
      expect(parseTagFromRedirectLocation(null), isNull);
      expect(parseTagFromRedirectLocation(''), isNull);
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/zzyoxml/md3Music/releases',
        ),
        isNull,
      );
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/zzyoxml/md3Music/releases/tag/',
        ),
        isNull,
      );
    });
  });

  group('ReleaseInfo.fromTag', () {
    test('剥离 v 前缀得到展示版本号', () {
      final info = ReleaseInfo.fromTag(
        tagName: 'v5.6.5',
        htmlUrl: 'https://github.com/zzyoxml/md3Music/releases/tag/v5.6.5',
      );
      expect(info.tagName, 'v5.6.5');
      expect(info.version, '5.6.5');
    });

    test('无 v 前缀时原样保留', () {
      final info = ReleaseInfo.fromTag(
        tagName: '5.6.5',
        htmlUrl: 'https://example.com',
      );
      expect(info.version, '5.6.5');
    });
  });

  group('fetchLatestPreReleaseDetail（批次34 Beta 通道）', () {
    test('请求 releases 列表并取第一个 prerelease 且 lite 序列项', () async {
      final adapter = _StubAdapter(
        (_) => _jsonBody([
          _releaseItem('ci-abcdef1234567890'), // ci 产物：isLiteTag 排除
          _releaseItem('v5.9.20', prerelease: false), // 正式版：非 prerelease 排除
          _releaseItem('v5.9.27-lite-abc1234', body: '- 构建号: 208'),
          _releaseItem('v5.9.26-lite-aaa0000'), // 更旧的快照：不应选中
        ]),
      );
      final detail = await _clientWith(adapter).fetchLatestPreReleaseDetail();

      expect(
        adapter.requests.single.uri.toString(),
        'https://api.github.com/repos/iFei7/md3Music/releases?per_page=15',
      );
      expect(detail, isNotNull);
      expect(detail!.info.tagName, 'v5.9.27-lite-abc1234');
      // 既有 ReleaseInfo.fromTag 语义：只剥 v 前缀，version 保留 lite 后缀；
      // 版本比较时由 parseReleaseVersion 截断 `-lite-<sha>` 段
      expect(detail.info.version, '5.9.27-lite-abc1234');
      expect(detail.body, '- 构建号: 208');
    });

    test('历史遗留 lite-<sha7> 形式的 prerelease 仍可选中（保留 isLiteTag 语义）', () async {
      final adapter = _StubAdapter(
        (_) => _jsonBody([_releaseItem('lite-abc1234')]),
      );
      final detail = await _clientWith(adapter).fetchLatestPreReleaseDetail();
      expect(detail?.info.tagName, 'lite-abc1234');
    });

    test('全部为 prerelease=false 时返回 null', () async {
      final adapter = _StubAdapter(
        (_) => _jsonBody([_releaseItem('v5.9.27-lite-abc1234', prerelease: false)]),
      );
      expect(
        await _clientWith(adapter).fetchLatestPreReleaseDetail(),
        isNull,
      );
    });

    test('ci-<sha> 条目即使 prerelease 也被排除', () async {
      final adapter = _StubAdapter(
        (_) => _jsonBody([_releaseItem('ci-abcdef1234567890')]),
      );
      expect(
        await _clientWith(adapter).fetchLatestPreReleaseDetail(),
        isNull,
      );
    });

    test('非 2xx 返回 null（与既有风格一致）', () async {
      final adapter = _StubAdapter((_) => _jsonBody(<Object>[], 500));
      expect(
        await _clientWith(adapter).fetchLatestPreReleaseDetail(),
        isNull,
      );
    });

    test('响应非数组返回 null', () async {
      final adapter = _StubAdapter((_) => _jsonBody({'message': 'nope'}));
      expect(
        await _clientWith(adapter).fetchLatestPreReleaseDetail(),
        isNull,
      );
    });
  });

  group('fetchChannelDetail（批次34 通道分流）', () {
    test('beta=false 走正式 Latest 端点', () async {
      final adapter = _StubAdapter(
        (_) => _jsonBody(_releaseItem('v5.6.5', prerelease: false)),
      );
      final detail =
          await _clientWith(adapter).fetchChannelDetail(beta: false);
      expect(
        adapter.requests.single.uri.toString(),
        'https://api.github.com/repos/iFei7/md3Music/releases/latest',
      );
      expect(detail?.info.version, '5.6.5');
    });

    test('beta=true 走 Pre-release 列表端点', () async {
      final adapter = _StubAdapter(
        (_) => _jsonBody([_releaseItem('v5.9.27-lite-abc1234')]),
      );
      final detail = await _clientWith(adapter).fetchChannelDetail(beta: true);
      expect(
        adapter.requests.single.uri.toString(),
        'https://api.github.com/repos/iFei7/md3Music/releases?per_page=15',
      );
      expect(detail?.info.version, '5.9.27-lite-abc1234');
    });
  });
}
