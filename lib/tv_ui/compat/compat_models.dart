// 批次50：TV 命名空间兼容层——lite 模型类的上游新增字段降级。
//
// lite 模型类（Song/KugouSheetInfo/KugouUserDetail 等）是跨界类型
// （lite Provider 树产出的实例直接流入 TV UI），不能搬上游副本（类型分裂）；
// 上游新增字段在 lite 的 JSON 解析中未落盘，extension 无法还原真实值，
// 统一返回保守默认值（nullable → null / 非空 → 零值），UI 呈现降级。
// 降级点标注「批次50 适配」。

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer;
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/models/playlist.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/services/kugou_api/comment_send_result.dart';
import 'package:md3music/tv_ui/compat/kugou_models_extra.dart';

// —— Song：上游远程存储/本地歌词扩展字段 ——
extension SongTvCompat on Song {
  /// 批次50 适配：上游 WebDAV/FTP 远程源字段；lite 不解析，返回 none。
  SongRemoteType get remoteType => SongRemoteType.none;
  String? get remoteSourceId => null;
  String? get folderPath => null;
  String? get localLyrics => null;
  int? get playlistSort => null;
}

// —— Playlist：上游置顶/排序扩展字段 ——
extension PlaylistTvCompat on Playlist {
  /// 批次50 适配：上游云歌单置顶标记；lite 不解析。
  bool get isPri => false;
  int get sort => 0;
}

// —— TabItem：上游桌面端固定标题标记 ——
extension TabItemTvCompat on TabItem {
  /// 批次50 适配：上游桌面固定标题；TV 构建不适用，恒 false。
  bool get pinnedTitle => false;
}

// —— KugouSheetInfo：上游 K 歌伴奏/戏曲扩展字段 ——
extension KugouSheetInfoTvCompat on KugouSheetInfo {
  String get opernId => '';
  String? get songName => null;
  String? get singerName => null;
  String? get jumpUrl => null;
  int get instruments => 0;
  int get opernLevel => 0;
  String? get opernTypeName => null;
  String? get opernDrawTypeName => null;
  String? get originalTune => null;
  String? get opernAuthor => null;
}

// —— KugouSongDetail：上游 K 歌已唱标记 ——
extension KugouSongDetailTvCompat on KugouSongDetail {
  String? get curMark => null;
}

// —— KugouSongRanking：上游榜单扩展 ——
extension KugouSongRankingTvCompat on KugouSongRanking {
  /// 批次50 适配：上游榜单详情列表；lite 解析未落盘，返回空。
  List<KugouSongRankingInfo> get info => const <KugouSongRankingInfo>[];
  String? get title2 => null;
  /// 批次50 适配：上游榜单主标题；lite 解析未落盘，降级 null（调用方空态）。
  String? get title => null;
}

// —— KugouUserDetail：上游用户资料扩展 ——
extension KugouUserDetailTvCompat on KugouUserDetail {
  int? get sex => null;
  String? get birthday => null;
  String? get signature => null;
  String? get province => null;
  String? get city => null;
  String? get memo => null;
  String? get tags => null;
}

// —— KugouApiClient：静态回调改挂点（extension 无法补 static）——
/// 批次50 适配：上游 static onLocalServerUnavailable → 模块级单例。
/// 上游语义：本地代理服务不可用时的全局通知钩子。
void Function()? tvKugouOnLocalServerUnavailable;

/// 批次50 适配：上游 static lastKnownPlaylistTotalVer → 模块级单例。
int tvKugouLastKnownPlaylistTotalVer = 0;

// —— 杂项上游全局工具函数（上游 lib/data/models/song.dart 原样搬运）——

/// 上游：歌手名拆分（独唱判定唯一真值，上游原样搬运）。
List<String> splitSongArtistNames(String? artist) {
  if (artist == null || artist.isEmpty) return const [];
  return artist
      .split(RegExp(r'[、;；/,，&]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// 批次50 适配：上游 song.dart 的未知专辑占位常量与判定（lite 无对应物，
/// 上游原值搬运——上游 kUnknownAlbumPlaceholder）。
const String kTvUnknownAlbumPlaceholder = '未知专辑';

bool isUnknownAlbum(String? album) {
  if (album == null) return true;
  final v = album.trim();
  return v.isEmpty || v == kTvUnknownAlbumPlaceholder;
}

/// 上游：播放页长按复制的完整信息文本（依赖 lite Song 公开字段，非降级）。
String formatSongFullCopyText(Song song) {
  final title = song.displayName.trim();
  final artist = isUnknownArtist(song.artist) ? '' : song.artist.trim();
  final album = isUnknownAlbum(song.album) ? '' : song.album.trim();
  if (title.isEmpty) {
    if (artist.isNotEmpty && album.isNotEmpty) return '$artist-$album';
    return artist.isNotEmpty ? artist : album;
  }
  final buffer = StringBuffer(title);
  if (artist.isNotEmpty && album.isNotEmpty) {
    buffer.write(' $artist-$album');
  } else if (artist.isNotEmpty || album.isNotEmpty) {
    buffer.write(' ${artist.isNotEmpty ? artist : album}');
  }
  return buffer.toString();
}

// —— AudioPlayer：上游 just_audio fork 的静默会话扩展 ——
// lite just_audio fork（批次47-49 能耗改造）无上游 setSilentSession/
// setSharedAudioSessionId 原生通道；TV 降级为 no-op（静默会话角色仅影响
// 后台混音策略，不影响播放主链路）。

extension AudioPlayerTvCompat on AudioPlayer {
  /// 批次50 适配：上游 native 静默会话角色；lite fork 无该通道，no-op。
  Future<void> setSilentSession(bool silent) async {}

  /// 批次50 适配：上游共享音频会话 id；lite fork 无该通道，no-op。
  Future<void> setSharedAudioSessionId(Object? id) async {}
}

// —— 上游 MV/榜单响应解析扩展（上游为具体响应类的成员，TV 内降级为
// Map 扩展空值——调用点为 discover/artist MV 网格的空态渲染）——
extension KugouResponseMapTvCompat on Map<String, dynamic> {
  /// 批次50 适配：上游 KugouArtistVideos.mvs；lite 接口返回 Map，降级空列表。
  List<KugouMvBrief>? get mvs => null;
  int? get total => null;
  bool get hasMatch => false;
  int? get totalOpusNum => null;
}

// —— 色值工具（compat_theme_provider 持久化恢复用）——
Color tvColorFromArgb(String argb) => Color(int.parse(argb));

// —— CommentSendResult：上游风控验证扩展字段（lite 版无；TV 降级不支持
// 风控验证流程，验证入口恒为不可用）——
extension CommentSendResultTvCompat on CommentSendResult {
  /// 批次50 适配：上游风控判定；TV 端无验证 UI 链路，恒 false。
  bool get needsVerification => false;
  String? get verificationEventId => null;
}
