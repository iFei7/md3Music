import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../services/kugou_api/kugou_models.dart';

/// 「隐藏歌单」本地仓库（音乐库一级页与「我的收藏」页共用）。
///
/// 目的：用户可在音乐库 / 收藏页把暂不关心的歌单从横滑轨中隐藏
/// （不删除、不同步云端，纯本地视图偏好），需要时再从「已隐藏」
/// 入口恢复。两个页面消费同一套 API，key 口径必须与
/// `favorites_page._playlistKey` 一字不差（`globalCollectionId ?? id`），
/// 否则同一歌单在两侧的隐藏状态会对不上。
///
/// 存储：SharedPreferences 字符串值（JSON 数组），风格与
/// [FavoriteListsCache] 一致（静态无状态、失败静默返回空集合）。
/// 键名带 `_v1` 后缀，未来破坏性结构变更可平滑升级 `_v2`。
class HiddenPlaylistsCache {
  static const String _kHiddenV1 = 'fav_hidden_playlists_v1';

  /// 歌单稳定 key（与 favorites_page._playlistKey 同口径：
  /// globalCollectionId 优先，缺失回退 id）。
  static String playlistKey(KugouPlaylistBrief p) =>
      p.globalCollectionId ?? p.id;

  /// 读取已隐藏的歌单 key 集合。无数据 / 解析失败返回空集合。
  static Future<Set<String>> readHidden() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kHiddenV1);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      return decoded.map((e) => e.toString()).toSet();
    } catch (_) {
      return {};
    }
  }

  /// 整体覆盖写入隐藏集合（调用方先 readHidden 再改，避免并发丢键）。
  static Future<void> writeHidden(Set<String> keys) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHiddenV1, jsonEncode(keys.toList()));
    } catch (_) {
      // 写入失败忽略（下次进入管理态会重读）
    }
  }

  /// 切换某个歌单的隐藏状态：已隐藏则移除（恢复），否则加入（隐藏）。
  /// 返回切换后的隐藏状态（true = 当前处于隐藏）。
  static Future<bool> toggleHidden(String key) async {
    final keys = await readHidden();
    final nowHidden = !keys.contains(key);
    if (nowHidden) {
      keys.add(key);
    } else {
      keys.remove(key);
    }
    await writeHidden(keys);
    return nowHidden;
  }
}
