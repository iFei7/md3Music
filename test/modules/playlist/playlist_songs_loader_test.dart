/// PlaylistSongsLoader 专辑分支单测：
/// 1. isAlbum=true 时必须走 /album/songs（getAlbumSongsAll），不得走歌单接口；
/// 2. 分页循环在空页即终止（即使 total 谎报很大）；
/// 3. 超 30 首专辑按 30/页聚合完整（3 页 = 30+30+15）。
///
/// 注：KugouApiClient 单例构造即读 SharedPreferences，故每个用例都在
/// `setMockInitialValues` 之后才触碰单例；网络层用替换 dio adapter 的
/// 方式打桩（与 playlist_cover_resolver_test 同一套路）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/playlist.dart';
import 'package:md3music/modules/playlist/playlist_songs_loader.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 记录请求并按回调生成响应体的替身 adapter。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.responder) : calls = [];

  final List<RequestOptions> calls;
  final Map<String, dynamic> Function(RequestOptions options) responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return ResponseBody.fromString(
      jsonEncode(responder(options)),
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 专辑歌曲分页响应：按 page 切片构造 list，total 由调用方指定。
/// [emptyFromPage] 起返回空列表（模拟 total 谎报 / 空页）。
Map<String, dynamic> Function(RequestOptions) albumResponder({
  required int total,
  int perPage = 30,
  int emptyFromPage = 1 << 30,
}) {
  return (options) {
    final page = int.tryParse(options.uri.queryParameters['page'] ?? '1') ?? 1;
    if (page >= emptyFromPage) {
      return {'data': {'list': [], 'total': total}};
    }
    final start = (page - 1) * perPage;
    final end = start + perPage > total ? total : start + perPage;
    final list = <Map<String, dynamic>>[
      for (var i = start + 1; i <= end && i <= total; i++)
        {'hash': 'h$i', 'songname': '歌$i'},
    ];
    return {'data': {'list': list, 'total': total}};
  };
}

Playlist _playlist() => const Playlist(
      id: 'album-placeholder',
      name: '测试专辑',
      songCount: 0,
      songs: [],
    );

Future<PlaylistSongsResult> _fetchAlbum(
  WidgetTester tester, {
  String? albumId = '42',
  bool isAlbum = true,
}) async {
  const key = ValueKey('loader-context-host');
  await tester.pumpWidget(const SizedBox(key: key));
  final context = tester.element(find.byKey(key));
  // dio 请求链与 testWidgets 的 FakeAsync 不兼容（真实定时器/调度不推进），
  // 网络请求须在 runAsync 内走真实事件循环（stub adapter 为纯内存替身）。
  final result = await tester.runAsync(
    () => PlaylistSongsLoader.fetch(
      context,
      _playlist(),
      isAlbum: isAlbum,
      albumId: albumId,
    ),
  );
  return result!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClientAdapter previousAdapter;

  setUp(() async {
    installFakeSecureStorage();
    // 必须先于 KugouApiClient 单例首次构造就位（见文件头注释）
    SharedPreferences.setMockInitialValues({});
    previousAdapter = KugouApiClient().dio.httpClientAdapter;
    // 本地服务就绪门禁放行（请求实际由替身 adapter 吸收）
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previousAdapter;
    uninstallFakeSecureStorage();
  });

  testWidgets('album 分支走 /album/songs，不触碰任何歌单接口', (tester) async {
    final stub = _StubAdapter(albumResponder(total: 5));
    KugouApiClient().dio.httpClientAdapter = stub;

    final result = await _fetchAlbum(tester);

    expect(result.apiSucceeded, isTrue);
    expect(result.songs.length, 5);
    expect(stub.calls, isNotEmpty);
    for (final call in stub.calls) {
      expect(call.uri.path, '/album/songs');
      expect(call.uri.path.contains('playlist'), isFalse);
      expect(call.uri.queryParameters['album_id'], '42');
    }
  });

  testWidgets('total 谎报很大时空页终止分页，不循环到页数上限', (tester) async {
    // 第 1 页满 30 首，第 2 页空；total 谎报 9999，验证循环靠空页退出。
    final stub = _StubAdapter(
      albumResponder(total: 9999, perPage: 30, emptyFromPage: 2),
    );
    KugouApiClient().dio.httpClientAdapter = stub;

    final result = await _fetchAlbum(tester);

    expect(result.apiSucceeded, isTrue);
    expect(result.songs.length, 30);
    expect(stub.calls.length, 2);
    expect(
      stub.calls.map((c) => c.uri.queryParameters['page']).toList(),
      ['1', '2'],
    );
  });

  testWidgets('超 30 首专辑分页聚合完整（75 首 = 30+30+15，共 3 页）', (tester) async {
    final stub = _StubAdapter(albumResponder(total: 75));
    KugouApiClient().dio.httpClientAdapter = stub;

    final result = await _fetchAlbum(tester);

    expect(result.apiSucceeded, isTrue);
    expect(result.songs.length, 75);
    expect(stub.calls.length, 3);
    expect(result.songs.first.title, '歌1');
    expect(result.songs.last.title, '歌75');
  });

  testWidgets('albumId 为空时不发任何请求', (tester) async {
    final stub = _StubAdapter(albumResponder(total: 5));
    KugouApiClient().dio.httpClientAdapter = stub;

    final result = await _fetchAlbum(tester, albumId: '');

    expect(result.apiSucceeded, isFalse);
    expect(result.songs, isEmpty);
    expect(stub.calls, isEmpty);
  });
}
