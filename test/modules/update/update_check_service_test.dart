import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/modules/update/github_release_client.dart';
import 'package:md3music/modules/update/release_info.dart';
import 'package:md3music/modules/update/update_check_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

GithubReleaseClient _clientWith(_StubAdapter adapter) =>
    GithubReleaseClient(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
    );

// extends 而非 implements：继承 ReleaseSource 的 fetchChannelDetail 默认
// 实现（Beta 关 → 委托 fetchLatest；Beta 开 → null），替身只需覆盖 fetchLatest。
class _FakeSource extends ReleaseSource {
  _FakeSource(this.release);

  final ReleaseInfo? release;
  int calls = 0;

  @override
  Future<ReleaseInfo?> fetchLatest() async {
    calls++;
    return release;
  }
}

ReleaseInfo _release(String tag) => ReleaseInfo.fromTag(
  tagName: tag,
  htmlUrl: 'https://github.com/zzyoxml/md3Music/releases/tag/$tag',
);

/// 构造被测服务：注入假数据源、假当前版本、捕获提醒文案。
({UpdateCheckService service, _FakeSource source, List<String> messages}) _build({
  required ReleaseInfo? remote,
  required String currentVersion,
}) {
  final source = _FakeSource(remote);
  final messages = <String>[];
  final service = UpdateCheckService(
    source: source,
    readCurrentVersion: () async => currentVersion,
    notifier: messages.add,
  );
  return (service: service, source: source, messages: messages);
}

Future<int> _hoursAgo(int hours) async => DateTime.now().millisecondsSinceEpoch -
    Duration(hours: hours).inMilliseconds;

void main() {
  test('提醒开关关闭时不发起查询', () async {
    SharedPreferences.setMockInitialValues({
      'settings_update_reminder_enabled': false,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.skipped,
    );
    expect(ctx.source.calls, 0);
    expect(ctx.messages, isEmpty);
  });

  test('距上次检查不足 12 小时时跳过且不查询', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.skipped,
    );
    expect(ctx.source.calls, 0);
  });

  test('超过 12 小时后正常查询', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': DateTime.now().millisecondsSinceEpoch -
          const Duration(hours: 13).inMilliseconds,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(await ctx.service.checkAndNotify(), UpdateCheckOutcome.notified);
    expect(ctx.source.calls, 1);
  });

  test('发现新版本时提醒一次并记录版本与检查时间', () async {
    SharedPreferences.setMockInitialValues({});
    final ctx = _build(remote: _release('v5.6.5'), currentVersion: '5.6.0');

    expect(await ctx.service.checkAndNotify(), UpdateCheckOutcome.notified);
    expect(ctx.messages, ['发现新版本 v5.6.5（当前 5.6.0），可在「设置 → 关于」中立即更新']);

    final repo = SettingsRepository();
    expect(await repo.getUpdateLastNotifiedVersion(), '5.6.5');
    expect(await repo.getUpdateLastCheckMs(), greaterThan(0));
  });

  test('同一版本不重复提醒', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': await _hoursAgo(13),
      'update_last_notified_version': '5.6.5',
    });
    final ctx = _build(remote: _release('v5.6.5'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.skipped,
    );
    expect(ctx.messages, isEmpty);
  });

  // 批次34：开关切换后立即检查（checkNow(force: true)）不受 12h 窗口阻挡
  test('开关关闭时 checkNow(force: true) 仍按开关判定跳过', () async {
    SharedPreferences.setMockInitialValues({
      'settings_update_reminder_enabled': false,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkNow(force: true),
      UpdateCheckOutcome.skipped,
    );
    expect(ctx.source.calls, 0);
    expect(ctx.messages, isEmpty);
  });

  test('checkNow(force: true) 忽略 12h 窗口发起查询', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(await ctx.service.checkNow(force: true), UpdateCheckOutcome.notified);
    expect(ctx.source.calls, 1);
  });

  test('checkNow 不带 force 仍受 12h 窗口限制', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(await ctx.service.checkNow(), UpdateCheckOutcome.skipped);
    expect(ctx.source.calls, 0);
  });

  test('force=true 但同版本已提醒过仍跳过（提醒一次语义保留）', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_notified_version': '5.6.5',
    });
    final ctx = _build(remote: _release('v5.6.5'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkNow(force: true),
      UpdateCheckOutcome.skipped,
    );
    expect(ctx.messages, isEmpty);
  });

  test('远端不高于本地时视为已是最新', () async {
    SharedPreferences.setMockInitialValues({});
    final ctx = _build(remote: _release('v5.6.0'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.upToDate,
    );
    expect(ctx.messages, isEmpty);
  });

  test('查询失败返回 failed 且不写入已提醒版本', () async {
    SharedPreferences.setMockInitialValues({});
    final ctx = _build(remote: null, currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.failed,
    );
    expect(ctx.messages, isEmpty);
    expect(await SettingsRepository().getUpdateLastNotifiedVersion(), '');
    // 失败也记录检查时间：避免每次启动反复重试
    expect(await SettingsRepository().getUpdateLastCheckMs(), greaterThan(0));
  });

  test('版本号无法解析时不误报', () async {
    SharedPreferences.setMockInitialValues({});
    final ctx = _build(remote: _release('latest'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.upToDate,
    );
    expect(ctx.messages, isEmpty);
  });

  group('批次34：Beta 通道', () {
    test('Beta 开启时改查 Pre-release 列表源并提醒快照', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = _StubAdapter(
        (_) => _jsonBody([
          {
            'tag_name': 'v5.9.27-lite-abc1234',
            'prerelease': true,
            'body': '- 构建号: 208',
            'assets': const <Map<String, dynamic>>[],
          },
        ]),
      );
      final messages = <String>[];
      final service = UpdateCheckService(
        source: _clientWith(adapter),
        readCurrentVersion: () async => '5.9.20',
        readCurrentBuildNumber: () async => 200,
        readBetaChannel: () async => true,
        notifier: messages.add,
      );

      expect(
        await service.checkNow(force: true),
        UpdateCheckOutcome.notified,
      );
      expect(adapter.requests.single.uri.path, '/repos/iFei7/md3Music/releases');
      expect(adapter.requests.single.uri.queryParameters['per_page'], '15');
      expect(messages.single, contains('v5.9.27-lite-abc1234'));
    });

    test('Beta 关闭时查正式 Latest 源（行为不变）', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = _StubAdapter(
        (_) => _jsonBody({
          'tag_name': 'v5.6.5',
          'prerelease': false,
          'body': '',
          'assets': const <Map<String, dynamic>>[],
        }),
      );
      final messages = <String>[];
      final service = UpdateCheckService(
        source: _clientWith(adapter),
        readCurrentVersion: () async => '5.6.0',
        readCurrentBuildNumber: () async => 100,
        readBetaChannel: () async => false,
        notifier: messages.add,
      );

      expect(
        await service.checkNow(force: true),
        UpdateCheckOutcome.notified,
      );
      expect(
        adapter.requests.single.uri.path,
        '/repos/iFei7/md3Music/releases/latest',
      );
      expect(messages.single, contains('v5.6.5'));
    });

    test('Beta 下同版本按构建号比较：远端构建号更新则提醒', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = _StubAdapter(
        (_) => _jsonBody([
          {
            'tag_name': 'v5.9.27-lite-abc1234',
            'prerelease': true,
            'body': '- 构建号: 208',
            'assets': const <Map<String, dynamic>>[],
          },
        ]),
      );
      final messages = <String>[];
      final service = UpdateCheckService(
        source: _clientWith(adapter),
        readCurrentVersion: () async => '5.9.27',
        readCurrentBuildNumber: () async => 200,
        readBetaChannel: () async => true,
        notifier: messages.add,
      );

      expect(await service.checkNow(force: true), UpdateCheckOutcome.notified);
      expect(messages, isNotEmpty);
    });

    test('Beta 下同版本且构建号不高于本地视为最新', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = _StubAdapter(
        (_) => _jsonBody([
          {
            'tag_name': 'v5.9.27-lite-abc1234',
            'prerelease': true,
            'body': '- 构建号: 208',
            'assets': const <Map<String, dynamic>>[],
          },
        ]),
      );
      final messages = <String>[];
      final service = UpdateCheckService(
        source: _clientWith(adapter),
        readCurrentVersion: () async => '5.9.27',
        readCurrentBuildNumber: () async => 208,
        readBetaChannel: () async => true,
        notifier: messages.add,
      );

      expect(await service.checkNow(force: true), UpdateCheckOutcome.upToDate);
      expect(messages, isEmpty);
    });

    test('Beta 关闭时同版本不做构建号比较（保持原行为零变化）', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = _StubAdapter(
        (_) => _jsonBody({
          'tag_name': 'v5.6.5',
          'prerelease': false,
          'body': '- 构建号: 300',
          'assets': const <Map<String, dynamic>>[],
        }),
      );
      final messages = <String>[];
      final service = UpdateCheckService(
        source: _clientWith(adapter),
        readCurrentVersion: () async => '5.6.5',
        readCurrentBuildNumber: () async => 200,
        readBetaChannel: () async => false,
        notifier: messages.add,
      );

      expect(await service.checkNow(force: true), UpdateCheckOutcome.upToDate);
      expect(messages, isEmpty);
    });

    test('Beta 提醒按快照 tag 记录（同版本新快照可再提醒）', () async {
      SharedPreferences.setMockInitialValues({});
      final adapter = _StubAdapter(
        (_) => _jsonBody([
          {
            'tag_name': 'v5.9.27-lite-abc1234',
            'prerelease': true,
            'body': '- 构建号: 208',
            'assets': const <Map<String, dynamic>>[],
          },
        ]),
      );
      final service = UpdateCheckService(
        source: _clientWith(adapter),
        readCurrentVersion: () async => '5.9.20',
        readCurrentBuildNumber: () async => 200,
        readBetaChannel: () async => true,
        notifier: (_) {},
      );
      await service.checkNow(force: true);

      expect(
        await SettingsRepository().getUpdateLastNotifiedVersion(),
        'v5.9.27-lite-abc1234',
      );
    });
  });
}
