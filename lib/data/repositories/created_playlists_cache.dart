import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 「App 内新建歌单」本地注册表（音乐库一级页 / 收藏页共用）。
///
/// 背景：上游 /v7/get_all_list 不返回 **0 首歌单**——用户在 App 内
/// （收藏页「新建歌单」入口）创建的空歌单在云端歌单列表里缺失，
/// 「我创建的歌单」分区因此看不到刚建好的歌单。
///
/// 方案：[FavoritesProvider.createPlaylist] 调云端 /playlist/add
/// 成功后，把新歌单 id/name 记录到本仓库；音乐库 / 收藏页的
/// 「我创建的歌单」在云端列表基础上合并注册表条目（云端一旦返回
/// 该歌单即自动去重）。纯本地视图层补位，不参与任何云端写操作。
///
/// 存储：SharedPreferences 字符串值（JSON map：playlistId → name），
/// 风格与 [FavoriteListsCache] 一致（静态无状态、失败静默返回空 map）。
/// 键名带 `_v1` 后缀，破坏性结构变更可平滑升级 `_v2`。
class CreatedPlaylistsCache {
  static const String _kCreatedV1 = 'fav_created_playlists_v1';

  /// 读取全部注册表条目（playlistId → name）。无数据 / 解析失败返回空 map。
  static Future<Map<String, String>> readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCreatedV1);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  /// 记录一个新建歌单（id → name）。同 id 重复写入覆盖旧 name。
  static Future<void> put(String id, String name) async {
    if (id.isEmpty) return;
    try {
      final map = await readAll();
      map[id] = name;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCreatedV1, jsonEncode(map));
    } catch (_) {
      // 写入失败忽略（下次创建成功仍会补记）
    }
  }

  /// 移除一个注册表条目（云端已返回该歌单后的清理入口；当前由
  /// 合并逻辑自动去重，无需调用方显式移除，保留 API 备用）。
  static Future<void> remove(String id) async {
    try {
      final map = await readAll();
      if (!map.containsKey(id)) return;
      map.remove(id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCreatedV1, jsonEncode(map));
    } catch (_) {
      // 忽略
    }
  }
}
