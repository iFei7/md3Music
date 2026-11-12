import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_endpoints.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// audioMatch 独立超时语义测试。
///
/// `_postBinary` 支持 `timeout` 参数（audioMatch 默认 12s）：
/// - 超时抛 TimeoutException → `_postBinary` 捕获后返回 null（现有错误路径）
/// - 调用方（识别循环）把 null 当「本轮未命中」继续下一轮，不会误判终止
///
/// 用本地 HttpServer 模拟慢服务器：请求挂起超过客户端超时。
/// 注意：不调用 TestWidgetsFlutterBinding.ensureInitialized()，
/// 否则 flutter_test 会拦截全部真实 HTTP（统一返回 400），
/// 本测试必须走真实 socket 才能验证超时语义。
void main() {
  late KugouApiClient client;
  late String originalBaseUrl;
  late HttpServer server;
  late int requestCount;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    client = KugouApiClient();
    originalBaseUrl = KugouEndpoints.baseUrl;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requestCount++;
      // 挂住请求 3s：任何 <3s 的客户端超时都会触发 TimeoutException
      await Future<void>.delayed(const Duration(seconds: 3));
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"status":1,"data":[{"songname":"x"}]}');
      await req.response.close();
    });
    client.updateBaseUrl('http://127.0.0.1:${server.port}');
  });

  tearDownAll(() async {
    client.updateBaseUrl(originalBaseUrl);
    await server.close(force: true);
  });

  setUp(() {
    requestCount = 0;
  });

  test('audioMatch 超时（timeout 参数生效）→ 返回 null 而非挂起', () async {
    final pcm = Uint8List.fromList(List.filled(1600, 0x08));

    final result = await client.audioMatch(
      pcm,
      timeout: const Duration(milliseconds: 300),
    );

    expect(result, isNull);
    expect(requestCount, 1, reason: '请求确实发出，被客户端超时打断');
  });

  test('audioMatch 未超时（timeout 足够长）→ 正常解析响应', () async {
    final pcm = Uint8List.fromList(List.filled(1600, 0x08));

    final result = await client.audioMatch(
      pcm,
      timeout: const Duration(seconds: 10),
    );

    expect(result, isNotNull);
    expect(requestCount, 1);
    expect(result!['status'], 1);
  });
}
