// 批次50：TV 命名空间兼容层——上游 KugouApiClient 新增成员适配。
// isBizOk 为静态纯函数，原样搬运；其余成员依赖上游私有 HTTP 封装
// （_getAllowNonOk/_post/dio 实例），extension 无法访问 lite 实例内部，
// 按上游签名降级为返回空结果（TV 端对应功能不可用，遗留缺口报告主控）。
// 批次50 适配：上游实例字段 lastKnownPlaylistTotalVer / static 回调
// onLocalServerUnavailable → 模块级单例（调用点已同步改写）。
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/tv_ui/compat/kugou_models_extra.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/services/kugou_api/comment_send_result.dart';

int tvKugouLastKnownPlaylistTotalVer = 0;
void Function()? tvKugouOnLocalServerUnavailable;

  bool kugouIsBizOk(Map<String, dynamic> json) {
  final errorCode = json['error_code'];
  if (errorCode is num && errorCode != 0) return false;
  final status = json['status'];
  if (status is num && status != 1) return false;
  return true;
}

extension KugouApiClientTvCompat on KugouApiClient {

  int get lastKnownPlaylistTotalVer => tvKugouLastKnownPlaylistTotalVer;

  /// 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk）；TV 降级返回空结果
  Future<Map<String, dynamic>?> getSheetRank({int page = 1}) async => null;

  /// 批次50 适配：上游实现依赖私有 HTTP 封装（_post）；TV 降级返回空结果
  Future<Map<String, dynamic>?> savePlaylistTrackOrder(
    Object? original,
    Object? reordered,
  ) async => null;

  /// 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk）；TV 降级返回空结果
  Future<KugouLoginDeviceSnapshot?> getLoginDevices() async => null; // 批次50 适配：上游返回快照模型

  /// 批次50 适配：上游实现依赖私有 HTTP 封装；TV 降级返回 null（伴奏页空态）
  Future<KugouAccompany?> getAudioAccompany(String hash) async => null;

  /// 批次50 适配：上游实现依赖私有 HTTP 封装；TV 降级返回 null
  Future<Map<String, dynamic>?> getAudioKtvTotal(String hash) async => null;

  /// 批次50 适配：上游 await _ensureInitialized 后判 isLoggedIn；
  /// lite 客户端构造时已自初始化，直接读公开状态。
  Future<bool> isLoggedInWhenReady() async => isLoggedIn;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<List<KugouSongRankingFilterItem>?> getSongRankingFilter( String albumAudioId, { int page = 1, int pagesize = 30, }) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> getSongBarrage({ required String hash, String? specialId, String? name, String? mixsongid, int page = 1, int pagesize = 50, }) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<CommentSendResult> sendSongDanmaku({ required String content, required String hash, String? name, String? mixsongid, }) async => CommentSendResult.failure('批次50 适配：TV 端弹幕发送降级不可用');

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> kickLoginDevice({ required String tMid, required String t, required String tAppid, required String tClientver, }) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> editBlacklist({ String? hash, String? mixsongid, String? singerid, String? name, String label = 'song', bool isDelete = false, String? items, String? moduleId, }) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> getBlacklistList({ String label = 'song', int page = 1, int pagesize = 30, String? moduleId, }) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> getAllUserPlaylists({bool noCache = false}) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> getAllUserFollow({bool noCache = false}) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> sortPlaylists( String data, { int totalVer = 0, }) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> uploadPlaylistCover( String filePath, { String type = 'custom', String extendName = '.jpg', }) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<Map<String, dynamic>?> updatePlaylistInfo({ required String listid, required int totalVer, int type = 0, String? name, int sort = 0, String? tags, String? intro, String? pic, bool? isPri, }) async => null;

  // 批次50 适配：上游实现依赖私有 HTTP 封装（_getAllowNonOk/_post），extension 无法复用 lite 实例；TV 降级返回空结果
  Future<KugouAlbumSongs?> getAlbumSongsAll(String albumId) async => null;
}
