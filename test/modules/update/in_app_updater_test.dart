import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/update/in_app_updater.dart';
import 'package:md3music/modules/update/update_manifest.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 批次34：本地桩适配器——记录请求 URL 并回放固定字节，不联网。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body);

  final Uint8List body;
  final List<Uri> uris = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uris.add(options.uri);
    return ResponseBody.fromBytes(body, 200);
  }

  @override
  void close({bool force = false}) {}
}

/// 批次34：桩掉 getTemporaryDirectory()，避免测试依赖平台插件。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.temporaryPath);

  final String temporaryPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;
}

UpdateManifest _manifest({required String apkUrl, required int size}) =>
    UpdateManifest.explicit(
      versionName: '5.9.27',
      applicationId: 'com.example.app',
      apkUrl: apkUrl,
      apkSize: size,
      sha256: '',
      releasePageUrl: 'https://github.com/iFei7/md3Music/releases/tag/x',
    );

const String _apkUrl =
    'https://github.com/iFei7/md3Music/releases/download/v5.9.27-lite-abc1234/'
    'GraceMusic-v5.9.27-lite-standard-arm64.apk';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('isBetaNewerVersion（批次34：Beta 下同版本按构建号比较）', () {
    test('版本号更新直接视为新版', () {
      expect(
        InAppUpdater.isBetaNewerVersion(
          remoteVersion: '5.10.0',
          remoteBuild: 0,
          localVersion: '5.9.27',
          localBuild: 208,
        ),
        isTrue,
      );
    });

    test('版本号相同且远端构建号更新视为新版', () {
      expect(
        InAppUpdater.isBetaNewerVersion(
          remoteVersion: '5.9.27',
          remoteBuild: 209,
          localVersion: '5.9.27',
          localBuild: 208,
        ),
        isTrue,
      );
    });

    test('版本号相同且构建号相同视为最新', () {
      expect(
        InAppUpdater.isBetaNewerVersion(
          remoteVersion: '5.9.27',
          remoteBuild: 208,
          localVersion: '5.9.27',
          localBuild: 208,
        ),
        isFalse,
      );
    });

    test('本地版本更高时宁可不提示', () {
      expect(
        InAppUpdater.isBetaNewerVersion(
          remoteVersion: '5.9.27',
          remoteBuild: 999,
          localVersion: '5.10.0',
          localBuild: 1,
        ),
        isFalse,
      );
    });

    test('远端无构建号标注时退化为版本号比较', () {
      expect(
        InAppUpdater.isBetaNewerVersion(
          remoteVersion: '5.9.27',
          remoteBuild: 0,
          localVersion: '5.9.27',
          localBuild: 208,
        ),
        isFalse,
      );
    });

    test('本地构建号无法解析时退化为版本号比较', () {
      expect(
        InAppUpdater.isBetaNewerVersion(
          remoteVersion: '5.9.27',
          remoteBuild: 209,
          localVersion: '5.9.27',
          localBuild: 0,
        ),
        isFalse,
      );
    });
  });

  group('startDownload 加速下载（批次34）', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('updater_test');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    InAppUpdater _updater(_RecordingAdapter adapter) => InAppUpdater(
          dio: Dio(BaseOptions(validateStatus: (_) => true))
            ..httpClientAdapter = adapter,
        );

    test('accelerated=true 时请求走 ghclone.com 镜像前缀', () async {
      final payload = Uint8List.fromList(List.filled(8, 0x4d));
      final adapter = _RecordingAdapter(payload);
      final updater = _updater(adapter);
      final manifest = _manifest(apkUrl: _apkUrl, size: payload.length);
      updater.debugMarkAvailable(manifest);

      await updater.startDownload(manifest, accelerated: true);

      expect(adapter.uris.single.toString(), startsWith('https://ghclone.com/'));
      expect(
        adapter.uris.single.toString(),
        'https://ghclone.com/$_apkUrl',
      );
      expect(updater.phase, InAppUpdaterPhase.readyToInstall);
    });

    test('默认（accelerated=false）仍请求原始直链，行为不变', () async {
      final payload = Uint8List.fromList(List.filled(8, 0x4d));
      final adapter = _RecordingAdapter(payload);
      final updater = _updater(adapter);
      final manifest = _manifest(apkUrl: _apkUrl, size: payload.length);
      updater.debugMarkAvailable(manifest);

      await updater.startDownload(manifest);

      expect(adapter.uris.single.toString(), _apkUrl);
      expect(updater.phase, InAppUpdaterPhase.readyToInstall);
    });

    test('文件名仍取自原始 apkUrl（镜像域名不混入文件名）', () async {
      final payload = Uint8List.fromList(List.filled(8, 0x4d));
      final adapter = _RecordingAdapter(payload);
      final updater = _updater(adapter);
      final manifest = _manifest(apkUrl: _apkUrl, size: payload.length);
      updater.debugMarkAvailable(manifest);

      await updater.startDownload(manifest, accelerated: true);

      expect(updater.apkFile, isNotNull);
      expect(updater.apkFile!.uri.pathSegments.last,
          'GraceMusic-v5.9.27-lite-standard-arm64.apk');
    });

    test('镜像下载不影响校验：字节数不符仍转入 error 并清理文件', () async {
      final payload = Uint8List.fromList(List.filled(4, 0x4d)); // 少于清单 8
      final adapter = _RecordingAdapter(payload);
      final updater = _updater(adapter);
      final manifest = _manifest(apkUrl: _apkUrl, size: 8);
      updater.debugMarkAvailable(manifest);

      await updater.startDownload(manifest, accelerated: true);

      expect(adapter.uris.single.toString(), startsWith('https://ghclone.com/'));
      expect(updater.phase, InAppUpdaterPhase.error);
      expect(updater.apkFile, isNull);
    });
  });
}
