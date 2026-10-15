import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';

import '../core/utils/app_toast.dart';
import '../data/models/song.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';
import '../utils/playlist_order_utils.dart';
import 'smart_artwork_image.dart';

/// 「添加到歌单」共享对话框：歌曲列表项菜单与播放页更多菜单共用。
///
/// 从 FullPlayer 的私有实现原样迁移（含去重检查、乐观更新与后台同步），
/// 供多处复用；行为与原实现保持一致。
///
/// 添加前先检查歌曲是否已在歌单中（用 global_collection_id 拉取歌单歌曲，
/// 按歌曲 hash 判断），存在则不执行——这是公开版偏好。

/// 弹出「添加到歌单」对话框（单首）。
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  dynamic song,
) async {
  await _showPlaylistPickerDialog(
    context,
    onPicked: (playlist) => addSongToPlaylist(song, playlist),
  );
}

/// 弹出「添加到歌单」对话框（批量版，多选操作条等场景）。
///
/// 与单首版共用同一歌单选择器与去重偏好，行为一致。
Future<void> showAddToPlaylistDialogForSongs(
  BuildContext context,
  List<Song> songs,
) async {
  await _showPlaylistPickerDialog(
    context,
    onPicked: (playlist) => addSongsToPlaylist(songs, playlist),
  );
}

/// 共享歌单选择器：拉取用户歌单列表并展示，选中后回调 [onPicked]。
///
/// 未登录直接 toast 提示并返回（与原单首版守卫一致）。
Future<void> _showPlaylistPickerDialog(
  BuildContext context, {
  required Future<void> Function(Map<String, dynamic> playlist) onPicked,
}) async {
  final api = KugouApiClient();
  if (!api.isLoggedIn) {
    showToast('请先登录', long: true);
    return;
  }

  showDialog(
    context: context,
    builder: (dialogContext) {
      return FutureBuilder<List<Map<String, dynamic>>?>(
        future: loadUserPlaylistsSorted(api),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  M3ELoadingIndicator(
                    constraints: BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                  ),
                  SizedBox(height: 16),
                  Text('加载歌单中...'),
                ],
              ),
            );
          }

          if (snapshot.hasError || snapshot.data == null) {
            return AlertDialog(
              title: const Text('错误'),
              content: const Text('获取歌单失败'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
              ],
            );
          }

          final playlists = snapshot.data!;

          if (playlists.isEmpty) {
            return AlertDialog(
              title: const Text('我的歌单'),
              content: const Text('暂无歌单，请先创建歌单'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
              ],
            );
          }

          return AlertDialog(
            title: const Text('添加到歌单'),
            content: SizedBox(
              width: 300,
              height: 400,
              child: ListView.builder(
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  final name =
                      (playlist['name'] ?? playlist['specialname'] ?? '未知歌单')
                          .toString();
                  // 优先使用模型解析后的 songCount，再尝试原始字段
                  final songCount =
                      playlist['songCount'] ??
                      playlist['songcount'] ??
                      playlist['song_count'] ??
                      playlist['count'] ??
                      0;
                  final coverUrl = playlist['coverUrl']?.toString();

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                    ),
                    leading: SmartArtworkImage(
                      artworkUri: coverUrl,
                      size: 44,
                      borderRadius: 6,
                    ),
                    title: Text(name),
                    subtitle: Text('$songCount 首'),
                    onTap: () {
                      Navigator.pop(dialogContext);
                      onPicked(playlist);
                    },
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 拉取用户歌单并解析为「添加到歌单」对话框所需的 Map 列表，
/// 再按收藏页「创建的歌单」自定义顺序原地排序后返回。
/// 返回 null 表示请求失败（与旧逻辑中 snapshot.data == null 等价）。
Future<List<Map<String, dynamic>>?> loadUserPlaylistsSorted(
  KugouApiClient api,
) async {
  final resp = await api.getUserPlaylist(pagesize: 50);
  if (resp == null) return null;
  final data = resp['data'];
  List<dynamic> rawPlaylists = [];
  if (data is List) {
    rawPlaylists = data;
  } else if (data is Map) {
    rawPlaylists = data['info'] ?? data['list'] ?? data['special_list'] ?? [];
  }

  // 使用 KugouPlaylistBrief 模型解析，确保字段名映射正确
  // 只显示用户自己创建的歌单 (type=0)
  final playlists = <Map<String, dynamic>>[];
  for (final item in rawPlaylists) {
    final json = item as Map<String, dynamic>;
    final brief = KugouPlaylistBrief.fromJson(json);
    if (brief.type != 0) continue;
    // 排除「我喜欢」默认收藏歌单：收藏走红心机制，不走添加到歌单
    // （判定与 FavoritesProvider 一致：name == '我喜欢' || is_def == 2）
    if (brief.name == '我喜欢' || json['is_def'] == 2) continue;
    // 将模型数据转回 Map 以便 UI 使用（包含正确的字段值）
    playlists.add({
      'name': brief.name,
      'songCount': brief.songCount,
      'coverUrl': brief.coverUrl,
      'listid': brief.listId.isEmpty ? brief.id : brief.listId,
      'specialid': brief.id,
      'global_collection_id': brief.globalCollectionId,
      'type': brief.type,
      // 保留原始 JSON 用于 API 调用
      ...json,
    });
  }

  await PlaylistOrderUtils.sortCreatedPlaylistMaps(playlists);
  return playlists;
}

/// 将歌曲添加到指定歌单。
///
/// 不依赖对话框的 BuildContext：调用时对话框刚被 pop，其子树会在退出动画
/// 结束后卸载；若用该 context 做 mounted 检查，await 网络请求后必然
/// 提前 return，导致"第一次点击没反应"（issue #66）。
/// showToast 为全局 Fluttertoast，API 调用为后台异步，均无需挂载中的 context。
Future<void> addSongToPlaylist(
  dynamic song,
  Map<String, dynamic> playlist,
) async {
  final api = KugouApiClient();
  final listid =
      playlist['listid']?.toString() ?? playlist['list_id']?.toString() ?? '';
  final globalCollectionId =
      playlist['global_collection_id']?.toString() ??
      playlist['gid']?.toString() ??
      '';

  if (listid.isEmpty) {
    showToast('歌单ID无效', long: true);
    return;
  }

  final name = (playlist['name'] ?? playlist['specialname'] ?? '未知歌单')
      .toString();

  // 公开版偏好：添加前先检查歌曲是否已在歌单中，存在则不执行。
  // 用 global_collection_id 拉取歌单歌曲，按歌曲 hash（song.id）判断是否已存在。
  try {
    final gid = globalCollectionId.isNotEmpty ? globalCollectionId : listid;
    final existing = await api.getPlaylistTrackAll(
      id: gid,
      page: 1,
      pagesize: 100,
    );
    if (existing != null) {
      final songHash = song.id?.toString().toLowerCase() ?? '';
      final already = existing.any((s) => s.hash.toLowerCase() == songHash);
      if (already) {
        showToast('已在歌单「$name」中');
        return;
      }
    }
  } catch (_) {
    // 查询失败不阻断添加，继续走原逻辑
  }

  // 乐观更新：立即显示成功，后台同步到酷狗服务器
  showToast('已添加到「$name」');

  // 构造歌曲数据 — 酷狗API要求的格式：歌名|hash|albumId|albumAudioId
  final songData =
      '${song.title}|${song.id}|${song.albumId ?? 0}|${int.tryParse(song.albumAudioId ?? '') ?? 0}';
  debugPrint(
    '[AddToPlaylist] listid=$listid name=${playlist['name']} songData=$songData',
  );

  // 后台同步，不阻塞 UI
  api
      .addPlaylistTracks(listid, songData)
      .then((result) {
        debugPrint('[AddToPlaylist] result=$result');
        // 同步失败时提示用户（静默失败，不影响已显示的乐观更新）
        if (result == null) {
          showToast('同步到服务器失败，将在下次启动时重试', long: true);
        }
      })
      .catchError((_) {
        // 网络错误等，同样静默处理
      });
}

/// 将多首歌曲批量添加到指定歌单（歌单详情页多选操作条等场景）。
///
/// 与 [addSongToPlaylist] 同一套偏好：先按 global_collection_id 拉取歌单
/// 现有歌曲做**一次整体去重**（按歌曲 hash），再逐首调用 addPlaylistTracks
/// （单首 data 格式「title|hash|albumId|albumAudioId」，不假设服务端支持
/// 多条目合并提交）。任一首失败不阻断其余歌曲。
Future<void> addSongsToPlaylist(
  List<Song> songs,
  Map<String, dynamic> playlist,
) async {
  if (songs.isEmpty) return;
  final api = KugouApiClient();
  final listid =
      playlist['listid']?.toString() ?? playlist['list_id']?.toString() ?? '';
  final globalCollectionId =
      playlist['global_collection_id']?.toString() ??
      playlist['gid']?.toString() ??
      '';

  if (listid.isEmpty) {
    showToast('歌单ID无效', long: true);
    return;
  }

  final name = (playlist['name'] ?? playlist['specialname'] ?? '未知歌单')
      .toString();

  // 整体去重：一次拉取歌单现有歌曲，hash 集合过滤（与单首版同口径）。
  final existingHashes = <String>{};
  try {
    final gid = globalCollectionId.isNotEmpty ? globalCollectionId : listid;
    final existing = await api.getPlaylistTrackAll(
      id: gid,
      page: 1,
      pagesize: 100,
    );
    if (existing != null) {
      existingHashes
        ..clear()
        ..addAll(existing.map((s) => s.hash.toLowerCase()));
    }
  } catch (_) {
    // 查询失败不阻断添加，继续走原逻辑
  }

  final pending = songs
      .where((s) => !existingHashes.contains(s.id.toLowerCase()))
      .toList();
  if (pending.isEmpty) {
    showToast('所选歌曲均已在「$name」中');
    return;
  }

  var ok = 0;
  for (final song in pending) {
    // 构造歌曲数据 — 酷狗API要求的格式：歌名|hash|albumId|albumAudioId
    final songData =
        '${song.title}|${song.id}|${song.albumId ?? 0}|${int.tryParse(song.albumAudioId ?? '') ?? 0}';
    try {
      final result = await api.addPlaylistTracks(listid, songData);
      if (result != null) ok++;
    } catch (_) {
      // 单首失败不阻断其余歌曲
    }
  }
  showToast(
    ok == pending.length
        ? '已把 $ok 首歌曲加入「$name」'
        : '已添加 $ok/${pending.length} 首，部分失败',
    long: true,
  );
}
