import '../../modules/playlist/playlist_songs_loader.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../models/song.dart';
import 'hidden_playlists_cache.dart';
import 'playlist_cover_cache.dart';

/// 为「brief 无封面」的歌单解析首曲封面。
///
/// 取数顺序（严格）：
/// 1. [cached] 命中 → 直接返回（免网络、免本地读）；
/// 2. brief 自带 [KugouPlaylistBrief.coverUrl] 非空 → 返回 null
///    （本身有封面，不需要兜底）；
/// 3. 本地歌曲缓存（[PlaylistSongsLoader.readCached]，与收藏页/详情页
///    同 key 口径）正序取第一首带 `artworkUri` 的歌；
/// 4. 本地缓存为空且已登录：用 `subscribedListId ?? listCreateListid`
///    发一次轻请求（`pagesize: 5`），取首曲封面
///    （禁止走 PlaylistSongsLoader.fetch 的全量分页链路）；
/// 5. 命中后 http→https 升级 + 写 [PlaylistCoverCache] + 返回。
///
/// 任何失败（未登录、无 listid、接口空响应、解析异常）都静默返回 null，
/// 由调用方回退占位图，不阻塞页面加载。
Future<String?> resolveFirstSongCover(
  KugouPlaylistBrief brief, {
  required Map<String, String> cached,
}) async {
  final key = HiddenPlaylistsCache.playlistKey(brief);
  final hit = cached[key];
  if (hit != null && hit.isNotEmpty) return hit;

  final ownCover = brief.coverUrl;
  if (ownCover != null && ownCover.isNotEmpty) return null;

  try {
    // 3. 本地歌曲缓存优先（收藏歌单页面已同步过全量歌曲时可命中）
    final playlist = brief.toPlaylist();
    final localSongs = await PlaylistSongsLoader.readCached(
      playlist,
      isInMyFavorites: true,
    );
    final localCover = _firstArtwork(localSongs);
    if (localCover != null) return await _persist(key, localCover);

    // 4. 轻请求兜底：仅登录用户（接口需要订阅后的 listid 鉴权）
    final api = KugouApiClient();
    if (!api.isLoggedIn) return null;
    final listid = _listidOf(brief);
    if (listid == null) return null;
    final result = await api.getPlaylistSongsByListid(
      listid: listid,
      page: 1,
      pagesize: 5,
      noCache: true,
    );
    final songs = result?.songs.map((s) => s.toSong()).toList() ?? const [];
    final remoteCover = _firstArtwork(songs);
    if (remoteCover == null) return null;
    return await _persist(key, remoteCover);
  } catch (_) {
    // 静默：封面只是展示增强，失败不得影响列表渲染
    return null;
  }
}

/// 正序取第一首带封面歌曲的 artworkUri（首曲即歌单封面语义）。
String? _firstArtwork(List<Song> songs) {
  for (final s in songs) {
    final art = s.artworkUri;
    if (art != null && art.isNotEmpty) return art;
  }
  return null;
}

/// 拉取歌曲用的 listid：订阅版本优先，缺失回退原歌单 listid。
String? _listidOf(KugouPlaylistBrief brief) {
  final subscribed = brief.listId;
  if (subscribed.isNotEmpty) return subscribed;
  final created = brief.listCreateListid;
  if (created != null && created.isNotEmpty) return created;
  return null;
}

/// 统一 https 升级后写入缓存并返回（与两个页面的封面渲染升级规则一致）。
Future<String> _persist(String key, String url) async {
  final normalized = url.startsWith('http://')
      ? url.replaceFirst('http://', 'https://')
      : url;
  await PlaylistCoverCache.put(key, normalized);
  return normalized;
}
