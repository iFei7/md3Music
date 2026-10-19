/// [PlaylistCoverCache] 单测：读写、容量裁剪、坏数据容错。
///
/// 缓存格式契约：SharedPreferences 单 key（fav_playlist_covers_v1）存
/// JSON map（playlistKey → https url），插入序即写入先后，超 200 条
/// 从头部丢弃最旧项。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/playlist_cover_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = 'fav_playlist_covers_v1';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('readAll：无缓存返回空 map', () async {
    expect(await PlaylistCoverCache.readAll(), isEmpty);
  });

  test('readAll：有值原样读回', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode({
        'gc-1': 'https://img.example/a.jpg',
        'gc-2': 'https://img.example/b.jpg',
      }),
    });

    final covers = await PlaylistCoverCache.readAll();
    expect(covers, {
      'gc-1': 'https://img.example/a.jpg',
      'gc-2': 'https://img.example/b.jpg',
    });
  });

  test('put：写入后可读回', () async {
    await PlaylistCoverCache.put('gc-1', 'https://img.example/a.jpg');

    expect(await PlaylistCoverCache.readAll(), {
      'gc-1': 'https://img.example/a.jpg',
    });
  });

  test('put：同 key 重复写入覆盖旧值，不产生重复条目', () async {
    await PlaylistCoverCache.put('gc-1', 'https://img.example/old.jpg');
    await PlaylistCoverCache.put('gc-1', 'https://img.example/new.jpg');

    final covers = await PlaylistCoverCache.readAll();
    expect(covers.length, 1);
    expect(covers['gc-1'], 'https://img.example/new.jpg');
  });

  test('put：超过 200 条从最旧开始裁剪，保留最近写入', () async {
    for (var i = 0; i < 205; i++) {
      await PlaylistCoverCache.put('gc-$i', 'https://img.example/$i.jpg');
    }

    final covers = await PlaylistCoverCache.readAll();
    expect(covers.length, 200);
    // 最旧 5 条（0..4）被丢弃
    for (var i = 0; i < 5; i++) {
      expect(covers.containsKey('gc-$i'), isFalse);
    }
    // 最近写入的条目保留
    expect(covers['gc-204'], 'https://img.example/204.jpg');
    // 顺序确定：剩余条目仍按写入先后排列
    expect(covers.keys.first, 'gc-5');
    expect(covers.keys.last, 'gc-204');
  });

  test('put：重复写入已存在条目会刷新其「最近写入」位置', () async {
    for (var i = 0; i < 200; i++) {
      await PlaylistCoverCache.put('gc-$i', 'https://img.example/$i.jpg');
    }
    // 刷新最旧条目 → 插到末尾；再写入一条新条目 → 淘汰原第二旧项
    await PlaylistCoverCache.put('gc-0', 'https://img.example/new-0.jpg');
    await PlaylistCoverCache.put('gc-new', 'https://img.example/new.jpg');

    final covers = await PlaylistCoverCache.readAll();
    expect(covers.length, 200);
    expect(covers.containsKey('gc-1'), isFalse);
    expect(covers['gc-0'], 'https://img.example/new-0.jpg');
    expect(covers.keys.last, 'gc-new');
  });

  test('readAll：坏 JSON 返回空 map（静默）', () async {
    SharedPreferences.setMockInitialValues({key: '{not a valid json'});

    expect(await PlaylistCoverCache.readAll(), isEmpty);
  });

  test('readAll：JSON 非 Map（数组）返回空 map', () async {
    SharedPreferences.setMockInitialValues({key: '["a","b"]'});

    expect(await PlaylistCoverCache.readAll(), isEmpty);
  });
}
