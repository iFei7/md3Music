import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/update/github_release_client.dart';
import 'package:md3music/modules/update/release_info.dart';
import 'package:md3music/modules/update/release_version.dart';

void main() {
  test('仓库地址为唯一来源常量', () {
    expect(
      GithubReleaseClient.apiLatestUri.toString(),
      'https://api.github.com/repos/iFei7/md3Music/releases?per_page=10',
    );
    expect(
      GithubReleaseClient.htmlLatestUri.toString(),
      'https://github.com/iFei7/md3Music/releases',
    );
    expect(GithubReleaseClient.userAgent, isNotEmpty);
  });

  group('parseTagFromRedirectLocation', () {
    test('标准 Location 解析出 tag', () {
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/iFei7/md3Music/releases/tag/v5.6.5',
        ),
        'v5.6.5',
      );
    });

    test('容忍查询串与锚点', () {
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/iFei7/md3Music/releases/tag/v5.6.5?x=1',
        ),
        'v5.6.5',
      );
    });

    test('无 tag 段或空值返回 null', () {
      expect(parseTagFromRedirectLocation(null), isNull);
      expect(parseTagFromRedirectLocation(''), isNull);
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/iFei7/md3Music/releases',
        ),
        isNull,
      );
      expect(
        parseTagFromRedirectLocation(
          'https://github.com/iFei7/md3Music/releases/tag/',
        ),
        isNull,
      );
    });
  });

  group('parseTagFromReleasesHtml', () {
    //回退链路专用：lite Release 全为 prerelease，/releases/latest 会404，
    // 只能从列表页 HTML 解析。
    test('解析出首个 release 的 tag', () {
      const html =
          '<a href="/iFei7/md3Music/releases/tag/v5.8.0-lite.2">v5.8.0-lite.2</a>'
          '<a href="/iFei7/md3Music/releases/tag/v5.8.0-lite.1">v5.8.0-lite.1</a>';
      expect(parseTagFromReleasesHtml(html), 'v5.8.0-lite.2');
    });

    test('容忍绝对链接', () {
      const html =
          '<a href="https://github.com/iFei7/md3Music/releases/tag/v5.8.0">v5.8.0</a>';
      expect(parseTagFromReleasesHtml(html), 'v5.8.0');
    });

    test('页面无 release 链接时返回 null', () {
      expect(parseTagFromReleasesHtml('<html><body>无内容</body></html>'), isNull);
      expect(parseTagFromReleasesHtml(''), isNull);
    });

    test('链接未闭合返回 null', () {
      expect(parseTagFromReleasesHtml('/releases/tag/'), isNull);
    });
  });

  group('ReleaseInfo.fromTag', () {
    test('剥离 v 前缀得到展示版本号', () {
      final info = ReleaseInfo.fromTag(
        tagName: 'v5.6.5',
        htmlUrl: 'https://github.com/iFei7/md3Music/releases/tag/v5.6.5',
      );
      expect(info.tagName, 'v5.6.5');
      expect(info.version, '5.6.5');
    });

    test('lite 版本号截断 -lite.N 后可与本地比较', () {
      final info = ReleaseInfo.fromTag(
        tagName: 'v5.8.0-lite.2',
        htmlUrl: 'https://github.com/iFei7/md3Music/releases/tag/v5.8.0-lite.2',
      );
      expect(info.tagName, 'v5.8.0-lite.2');
      expect(info.version, '5.8.0-lite.2');
      // release_version.dart 会截断 -lite.2 得到 5.8.0
      expect(isNewerRelease(info.version, '5.8.0'), isFalse);
      expect(isNewerRelease(info.version, '5.7.0'), isTrue);
    });

    test('无 v 前缀时原样保留', () {
      final info = ReleaseInfo.fromTag(
        tagName: '5.6.5',
        htmlUrl: 'https://example.com',
      );
      expect(info.version, '5.6.5');
    });
  });
}
