import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 歌单「首曲封面」本地缓存仓库（音乐库 hub 与我的收藏页共用）。
///
/// 用途：部分歌单接口不返回封面（`coverUrl` 为空），此时用该歌单第一首歌
/// 的专辑封面兜底展示。解析结果写入本地，避免每次进页都发请求。
///
/// 语义边界：这里只缓存「快照型」首曲封面——歌单首曲基本不变，一次解析
/// 长期有效；与收藏页「我喜欢」的动态封面（随时可能因新红心变化，单独
/// 存在 `fav_my_favorite_cover_v1`）是两套独立机制，互不覆盖。
///
/// 存储：SharedPreferences 字符串值（JSON map：playlistKey → https url），
/// 风格与 [FavoriteListsCache] 一致（静态无状态、失败静默）。
/// 键名带 `_v1` 后缀，未来破坏性结构变更可平滑升级 `_v2`。
class PlaylistCoverCache {
  static const String _kCoversV1 = 'fav_playlist_covers_v1';

  /// 缓存条目上限：超过后按写入先后丢弃最旧的 key，防止撑爆
  /// SharedPreferences（与 FavoriteListsCache 歌单歌曲缓存同口径）。
  static const int _maxEntries = 200;

  /// 读取全部缓存（playlistKey → 封面 URL）。无数据 / 解析失败返回空 map。
  static Future<Map<String, String>> readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCoversV1);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, String>{};
      decoded.forEach((k, v) {
        if (v is String && v.isNotEmpty) {
          result[k.toString()] = v;
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  /// 写入某个歌单的封面 URL，并裁剪超限条目。
  ///
  /// 顺序语义：Dart Map 保持插入序；写入前先移除同 key 再插到末尾，
  /// 使「最近写入」始终排在最后，超限时从头部确定性丢弃最旧条目
  /// （重复写入同一歌单不会把它误判为最旧）。
  static Future<void> put(String playlistKey, String url) async {
    if (playlistKey.isEmpty || url.isEmpty) return;
    try {
      final map = await readAll();
      map.remove(playlistKey);
      map[playlistKey] = url;
      if (map.length > _maxEntries) {
        final keysToRemove = map.keys.take(map.length - _maxEntries).toList();
        for (final k in keysToRemove) {
          map.remove(k);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCoversV1, jsonEncode(map));
    } catch (_) {
      // 写入失败忽略：仅影响下次进页是否重新解析，不影响本次展示
    }
  }
}
