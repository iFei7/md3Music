/// [CreatedPlaylistsCache] 单测：读写、覆盖、移除、坏数据容错。
///
/// 缓存格式契约：SharedPreferences 单 key（fav_created_playlists_v1）存
/// JSON map（playlistId → name），上游不返回 0 首歌单时供「我创建的
/// 歌单」合并补位。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/created_playlists_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = 'fav_created_playlists_v1';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('readAll：无缓存返回空 map', () async {
    expect(await CreatedPlaylistsCache.readAll(), isEmpty);
  });

  test('readAll：有值原样读回', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode({
        'list-1': '注册表歌单一',
        'list-2': '注册表歌单二',
      }),
    });

    expect(await CreatedPlaylistsCache.readAll(), {
      'list-1': '注册表歌单一',
      'list-2': '注册表歌单二',
    });
  });

  test('put：写入后可读回', () async {
    await CreatedPlaylistsCache.put('list-1', '注册表歌单一');

    expect(await CreatedPlaylistsCache.readAll(), {
      'list-1': '注册表歌单一',
    });
  });

  test('put：同 id 重复写入覆盖旧 name，不产生重复条目', () async {
    await CreatedPlaylistsCache.put('list-1', '旧名字');
    await CreatedPlaylistsCache.put('list-1', '新名字');

    final map = await CreatedPlaylistsCache.readAll();
    expect(map.length, 1);
    expect(map['list-1'], '新名字');
  });

  test('put：空 id 跳过，不写入', () async {
    await CreatedPlaylistsCache.put('', '空 id 歌单');

    expect(await CreatedPlaylistsCache.readAll(), isEmpty);
  });

  test('remove：移除后读不到，其余条目保留', () async {
    await CreatedPlaylistsCache.put('list-1', '歌单一');
    await CreatedPlaylistsCache.put('list-2', '歌单二');

    await CreatedPlaylistsCache.remove('list-1');

    expect(await CreatedPlaylistsCache.readAll(), {'list-2': '歌单二'});
  });

  test('remove：不存在的 id 静默返回', () async {
    await CreatedPlaylistsCache.put('list-1', '歌单一');

    await CreatedPlaylistsCache.remove('missing');

    expect(await CreatedPlaylistsCache.readAll(), {'list-1': '歌单一'});
  });

  test('readAll：坏数据（非 map / 非法 JSON）容错返回空 map', () async {
    SharedPreferences.setMockInitialValues({key: '["not-a-map"]'});
    expect(await CreatedPlaylistsCache.readAll(), isEmpty);

    SharedPreferences.setMockInitialValues({key: 'not-json'});
    expect(await CreatedPlaylistsCache.readAll(), isEmpty);
  });
}
