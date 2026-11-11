// 批次50：TV 命名空间兼容层——LibraryProvider/CommentDisplayProvider/
// FavoritesProvider/DeviceProvider/GridColumnsProvider/TabConfigProvider/
// ShortcutConfigProvider 的上游新增成员适配。
// 上游实现依赖私有字段/仓库/加载代数，extension 无法访问 lite 实例内部，
// 按上游签名降级（模块级存储 / no-op / 立即就绪），降级点逐项标注。
// ignore_for_file: invalid_use_of_protected_member
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/favorites_provider.dart';
import 'package:md3music/providers/device_provider.dart';
import 'package:md3music/providers/grid_columns_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:md3music/providers/shortcut_config_provider.dart';

/// 批次50 适配：上游私有过滤开关 → 模块级存储（TV 内闭环，无索引联动刷新）。
bool tvFilterShortAudio = false;

extension LibraryProviderTvCompat on LibraryProvider {
  /// 批次50 适配：上游读私有开关；TV 降级为模块级变量。
  bool get filterShortAudio => tvFilterShortAudio;

  Future<void> setFilterShortAudio(bool value) async {
    tvFilterShortAudio = value;
  }

  /// 批次50 适配：按路径批量移除索引依赖上游私有索引状态；TV 降级 no-op。
  Future<void> removeFoldersFromIndex(Iterable<String> folderPaths) async {}

  /// 批次50 适配：Windows 设置重置代数依赖上游私有状态；TV 降级 no-op。
  Future<void> prepareWindowsSettingsReset() async {}

  /// 批次50 适配：Windows 设置加载流程；lite 无该流程，no-op。
  Future<void> reloadWindowsSettings() async {}
}

extension CommentDisplayProviderTvCompat on CommentDisplayProvider {
  /// 批次50 适配：上游私有字号字段 + prefs 持久化；lite 实例无 setter，
  /// 此处保留调用通路并通知（字号显示暂不持久生效，遗留缺口报告主控）。
  Future<void> setCommentFontSize(double size) async {
    // 批次50 适配：lite 该成员为 visibleForTesting，TV 兼容层需跨层通知。
    // ignore: invalid_use_of_visible_for_testing_member
    notifyListeners();
  }

  /// 批次50 适配：Windows 设置加载流程；lite 无该流程，立即就绪。
  Future<void> get settingsReady => Future.value();

  Future<void> reloadWindowsSettings() async {}

  /// 批次50 适配：上游字号重置依赖私有字段；TV 降级为仅通知（显示值不变）。
  Future<void> resetToDefault() async {
    // 批次50 适配：lite 该成员为 visibleForTesting，TV 兼容层需跨层通知。
    // ignore: invalid_use_of_visible_for_testing_member
    notifyListeners();
  }
}

extension FavoritesProviderTvCompat on FavoritesProvider {
  /// 批次50 适配：上游组合私有云/本地收藏列表；降级为 lite 公开 favorites
  /// （TV 端收藏桥接以本地收藏为准）。
  List<Song> get favoritesForBridge => favorites;
}

extension DeviceProviderTvCompat on DeviceProvider {
  /// 批次50 适配：Windows 设置加载流程；lite 无该流程，立即就绪。
  Future<void> get settingsReady => Future.value();

  Future<void> reloadWindowsSettings() async {}
}

extension GridColumnsProviderTvCompat on GridColumnsProvider {
  Future<void> get settingsReady => Future.value();

  Future<void> reloadWindowsSettings() async {}
}

extension TabConfigProviderTvCompat on TabConfigProvider {
  Future<void> get settingsReady => Future.value();
}

extension ShortcutConfigProviderTvCompat on ShortcutConfigProvider {
  Future<void> get settingsReady => Future.value();
}
