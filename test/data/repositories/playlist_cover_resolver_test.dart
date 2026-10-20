/// [resolveLastSongCover] 单测：缓存短路、有封面不解析、本地歌曲缓存末曲语义、
/// 末页轻请求、就近兜底、https 升级、失败静默。
///
/// 注：KugouApiClient 单例构造即读 SharedPreferences，故每个用例都在
/// `setMockInitialValues` 之后才触碰单例（项目已知坑：mock 未就位会让
/// `_initCompleter` 挂起，进而把所有请求饿死）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/favorite_lists_cache.dart';
import 'package:md3music/data/repositories/hidden_playlists_cache.dart';
import 'package:md3music/data/repositories/playlist_cover_cache.dart';
import 'package:md3music/data/repositories/playlist_cover_resolver.dart';
import 'package:md3music/modules/playlist/playlist_songs_loader.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/fake_secure_storage.dart';

/// 无封面歌单（globalCollectionId 存在 → playlistKey 走它）。
KugouPlaylistBrief _brief({String? coverUrl, int songCount = 3}) =>
    KugouPlaylistBrief(
      id: 'pl-1',
      name: '测试歌单',
      coverUrl: coverUrl,
      songCount: songCount,
      globalCollectionId: 'gc-1',
      listId: 'lid-1',
    );

Song _song(String id, {String? artworkUri}) => Song(
  id: id,
  title: '歌曲$id',
  artist: '歌手',
  album: '专辑',
  duration: const Duration(milliseconds: 180000),
  artworkUri: artworkUri,
);

/// 记录请求次数并按需返回歌单歌曲 JSON 的替身 adapter。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.body = '{}', this.calls});

  final String body;
  final List<RequestOptions>? calls;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls?.add(options);
    return ResponseBody.fromString(
      body,
      200,
      headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 末页歌曲接口响应：队首与末曲都带封面（验证取最后一个而非第一个）。
String _songsBody() => jsonEncode({
  'data': {
    'info': [
      {
        'hash': 'h0',
        'songname': '队首',
        'sizable_cover': 'http://img.example/head.jpg',
      },
      {
        'hash': 'h1',
        'songname': '末曲',
        'sizable_cover': 'http://img.example/tail.jpg',
      },
    ],
  },
});

/// 末曲无封面、倒数第二首带封面（验证向队首就近兜底）。
String _songsBodyTailNoCover() => jsonEncode({
  'data': {
    'info': [
      {
        'hash': 'h0',
        'songname': '倒数第二',
        'sizable_cover': 'http://img.example/second-last.jpg',
      },
      {'hash': 'h1', 'songname': '末曲无封面'},
    ],
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpClientAdapter previousAdapter;
  late List<RequestOptions> calls;

  setUp(() async {
    installFakeSecureStorage();
    // 必须先于 KugouApiClient 单例首次构造就位（见文件头注释）
    SharedPreferences.setMockInitialValues({});
    calls = [];
    final client = KugouApiClient();
    previousAdapter = client.dio.httpClientAdapter;
    // 未登录：缓存/本地命中路径不应发请求
    await client.clearCookies();
    client.dio.httpClientAdapter = _StubAdapter(
      body: _songsBody(),
      calls: calls,
    );
    // 本地服务就绪门禁放行（请求实际由替身 adapter 吸收）
    KugouApiClient.markServerReady(KugouApiClient.markServerStarting());
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = previousAdapter;
    uninstallFakeSecureStorage();
  });

  test('缓存命中：直接返回，不读本地缓存也不发请求', () async {
    final cover = await resolveLastSongCover(
      _brief(),
      cached: {'gc-1': 'https://img.example/cached.jpg'},
    );

    expect(cover, 'https://img.example/cached.jpg');
    expect(calls, isEmpty);
  });

  test('缓存命中优先于歌单自带封面', () async {
    final cover = await resolveLastSongCover(
      _brief(coverUrl: 'https://img.example/own.jpg'),
      cached: {'gc-1': 'https://img.example/cached.jpg'},
    );

    expect(cover, 'https://img.example/cached.jpg');
    expect(calls, isEmpty);
  });

  test('歌单自带封面非空：返回 null（不解析）', () async {
    final cover = await resolveLastSongCover(
      _brief(coverUrl: 'https://img.example/own.jpg'),
      cached: const {},
    );

    expect(cover, isNull);
    expect(calls, isEmpty);
  });

  test('本地歌曲缓存命中：倒序取最后一个非空封面并升级 https + 写缓存', () async {
    final brief = _brief();
    // 本地缓存 key 与详情页/收藏页同口径（PlaylistSongsLoader.cacheKey）
    final cacheKey = PlaylistSongsLoader.cacheKey(
      brief.toPlaylist(),
      isInMyFavorites: true,
    );
    await FavoriteListsCache.savePlaylistSongs(cacheKey!, [
      _song('s1'), // 无封面 → 跳过
      _song('s2', artworkUri: 'http://img.example/first.jpg'),
      _song('s3', artworkUri: 'https://img.example/second.jpg'), // 末曲优先
    ]);

    final cover = await resolveLastSongCover(brief, cached: const {});

    expect(cover, 'https://img.example/second.jpg');
    // 命中本地缓存无需网络
    expect(calls, isEmpty);
    // 已持久化（同为 https）
    expect(
      (await PlaylistCoverCache.readAll())['gc-1'],
      'https://img.example/second.jpg',
    );
  });

  test('本地缓存末曲无封面：向队首就近兜底（取最后一支带封面的歌）', () async {
    final brief = _brief();
    final cacheKey = PlaylistSongsLoader.cacheKey(
      brief.toPlaylist(),
      isInMyFavorites: true,
    );
    await FavoriteListsCache.savePlaylistSongs(cacheKey!, [
      _song('s1', artworkUri: 'http://img.example/only.jpg'),
      _song('s2'), // 末曲无封面 → 向前就近兜底到 s1
    ]);

    final cover = await resolveLastSongCover(brief, cached: const {});

    expect(cover, 'https://img.example/only.jpg');
    expect(calls, isEmpty);
  });

  test('未登录且本地无缓存：静默返回 null，不发请求', () async {
    final cover = await resolveLastSongCover(_brief(), cached: const {});

    expect(cover, isNull);
    expect(calls, isEmpty);
  });

  test('已登录：本地无缓存时按 songCount 算末页轻请求，取末曲封面并写缓存', () async {
    await KugouApiClient().setLoginCookies('token-x', 'uid-x');

    // 12 首 / 每页 5 → 末页 = ceil(12/5) = 3
    final cover = await resolveLastSongCover(
      _brief(songCount: 12),
      cached: const {},
    );

    expect(cover, 'https://img.example/tail.jpg');
    final playlistCalls = calls
        .where((o) => o.queryParameters['listid'] == 'lid-1')
        .toList();
    expect(playlistCalls, isNotEmpty);
    // 轻请求口径：page=末页 / pagesize=5 / noCache=true
    final options = playlistCalls.first;
    expect(options.queryParameters['page'], 3);
    expect(options.queryParameters['pagesize'], 5);
    expect(options.extra['noCache'], isTrue);
    expect(
      (await PlaylistCoverCache.readAll())['gc-1'],
      'https://img.example/tail.jpg',
    );
  });

  test('末页计算整除边界：songCount=10/pagesize=5 → page=2', () async {
    await KugouApiClient().setLoginCookies('token-x', 'uid-x');

    final cover = await resolveLastSongCover(
      _brief(songCount: 10),
      cached: const {},
    );

    expect(cover, 'https://img.example/tail.jpg');
    final options = calls.firstWhere(
      (o) => o.queryParameters['listid'] == 'lid-1',
    );
    expect(options.queryParameters['page'], 2);
  });

  test('已登录：末曲无封面时向队首就近兜底（取倒数第二首）', () async {
    await KugouApiClient().setLoginCookies('token-x', 'uid-x');
    KugouApiClient().dio.httpClientAdapter = _StubAdapter(
      body: _songsBodyTailNoCover(),
      calls: calls,
    );

    final cover = await resolveLastSongCover(_brief(), cached: const {});

    expect(cover, 'https://img.example/second-last.jpg');
  });

  test('接口失败（非 200/空响应）：返回 null 不抛异常', () async {
    await KugouApiClient().setLoginCookies('token-x', 'uid-x');
    KugouApiClient().dio.httpClientAdapter = _StubAdapter(
      body: '{}',
      calls: calls,
    );

    final cover = await resolveLastSongCover(_brief(), cached: const {});

    expect(cover, isNull);
    expect(await PlaylistCoverCache.readAll(), isEmpty);
  });

  test('songCount<=0：已登录也静默返回 null，不发请求', () async {
    await KugouApiClient().setLoginCookies('token-x', 'uid-x');

    final cover = await resolveLastSongCover(
      _brief(songCount: 0),
      cached: const {},
    );

    expect(cover, isNull);
    expect(calls, isEmpty);
  });

  test('brief 无可用 listid：已登录也不发请求，返回 null', () async {
    await KugouApiClient().setLoginCookies('token-x', 'uid-x');
    const brief = KugouPlaylistBrief(
      id: 'pl-2',
      name: '无 listid 歌单',
      globalCollectionId: 'gc-2',
    );

    final cover = await resolveLastSongCover(brief, cached: const {});

    expect(cover, isNull);
    expect(calls, isEmpty);
  });

  test(
    'playlistKey 口径与 HiddenPlaylistsCache 一致（globalCollectionId 优先）',
    () async {
      final brief = _brief();
      expect(HiddenPlaylistsCache.playlistKey(brief), 'gc-1');
    },
  );
}
