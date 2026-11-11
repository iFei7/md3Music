// 批次50：TV 命名空间兼容层——上游 KugouProvider 新增成员适配。
// 上游实现依赖大量私有状态（_apiClient/_error/_newSongs/_hotSearch 等），
// extension 无法访问 lite 实例内部；按上游签名降级为返回保守结果
// （扫码登录降级失败态 / 列表空态 / no-op），降级点逐项标注。
// TV 端账号登录主链路（lite KugouProvider 既有 isLoggedIn/userid）不受影响。
// ignore_for_file: invalid_use_of_protected_member

import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/tv_ui/compat/kugou_models_extra.dart';

/// 批次50 适配：上游实例 ValueNotifier<HotSearchState> → 模块级单例。
final ValueNotifier<HotSearchState> tvHotSearchState =
    ValueNotifier<HotSearchState>(const HotSearchState());

extension KugouProviderTvCompat on KugouProvider {
  /// 批次50 适配：上游读私有热搜通知器；TV 降级为模块级常量态（idle，
  /// 热搜榜单卡显示空态，功能降级）。
  ValueListenable<HotSearchState> get hotSearchState => tvHotSearchState;

  /// 批次50 适配：上游读私有新歌列表；TV 降级为空列表。
  List<KugouSongDetail> get newSongs => const <KugouSongDetail>[];

  /// 批次50 适配：上游读私有首页发现失败标记；降级 false。
  bool get homeDiscoverLastLoadFailed => false;

  /// 批次50 适配：扫码登录二维码创建依赖上游私有 client；TV 降级返回 null。
  Future<KugouWxQrSession?> createWxLoginQr() async => null;

  Future<KugouQqQrSession?> createQqLoginQr() async => null;

  /// 批次50 适配：扫码登录轮询依赖上游私有 client；TV 降级返回错误态。
  Future<WxScanResult> checkWxLogin(String uuid) async =>
      const WxScanResult(WxScanKind.error, message: 'TV 端暂不支持微信扫码登录');

  Future<QqScanResult> checkQqLogin(KugouQqQrSession session) async =>
      const QqScanResult(QqScanKind.error, message: 'TV 端暂不支持 QQ 扫码登录');

  /// 批次50 适配：第三方登录凭证落库依赖上游私有状态刷新链；TV 降级 false。
  Future<bool> completeThirdPartyLogin({
    required String token,
    required String userid,
    String? vipToken,
  }) async =>
      false;

  /// 批次50 适配：新歌分页加载依赖上游私有分页状态；TV 降级 no-op。
  Future<void> fetchMoreNewSongs() async {}

  /// 批次50 适配：新歌拉取依赖上游私有时间戳缓存；TV 降级 no-op。
  Future<void> getNewSongs({bool forceRefresh = false}) async {}

  /// 批次50 适配：热搜拉取依赖上游私有加载框架；TV 降级 no-op。
  Future<void> loadHotSearch({bool forceRefresh = false}) async {}

  /// 批次50 适配：私人FM行为上报依赖上游私有加载框架；TV 降级 no-op。
  /// 签名对齐上游（action/mode/songPoolId/hash/songId/curMark/playtime/isOverplay）。
  Future<List<KugouSongDetail>?> reportPersonalFmAction({
    required Object? action,
    required Object? mode,
    required Object? songPoolId,
    required Object? hash,
    required Object? songId,
    Object? curMark,
    Object? playtime,
    Object? isOverplay,
  }) async =>
      null;

  /// 批次50 适配：用户偏好拉取依赖上游私有 client；TV 降级返回 null。
  Future<KugouUserPreference?> getUserPreference() async => null;

  /// 批次50 适配：用户资料/偏好更新依赖上游私有 client 与状态链；TV 降级 false。
  Future<(bool, String?)> updateUserPreference({
    String? mode,
    String? gender,
    String? age,
    String? lang,
    String? style,
    String? songLang,
  }) async =>
      (false, '批次50 适配：TV 端音乐偏好更新降级不可用');

    Future<(bool, String?)> updateUserAvatar(Uint8List bytes) async =>
      (false, '批次50 适配：TV 端头像上传降级不可用');

  Future<(bool, String?)> updateUserProfile({
    String? nickname,
    int? sex,
    String? birthday,
    String? signature,
    String? province,
    String? city,
    String? memo,
    String? tags,
  }) async =>
      (false, '批次50 适配：TV 端资料更新降级不可用');
}
