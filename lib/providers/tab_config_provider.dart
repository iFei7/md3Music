import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';

/// 主页 Tab 配置项。
///
/// [id] 唯一标识，[label] 显示名称，[isRemovable] 是否允许隐藏。
/// 设置/登录入口由各 tab 页右上角用户头像提供。
class TabItem {
  final String id;
  final String label;
  final bool isRemovable;

  const TabItem({
    required this.id,
    required this.label,
    this.isRemovable = true,
  });

  TabItem copyWith({String? id, String? label, bool? isRemovable}) {
    return TabItem(
      id: id ?? this.id,
      label: label ?? this.label,
      isRemovable: isRemovable ?? this.isRemovable,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TabItem && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// v7 起已下线的 tab id（「我的」user 与音乐库子页面歌单/专辑/歌手/
/// 文件夹/本地收藏）：迁移时从持久化顺序与隐藏集合中剔除，避免残留。
const Set<String> kRetiredTabIds = {
  'user',
  'playlists',
  'albums',
  'artists',
  'folders',
  'local_favorites',
};

/// 默认 Tab 定义（v7：首页 / 音乐库 / FM / 搜索，顺序与底部玻璃 Dock 一致）。
///
/// v7 起收藏由默认降级为可选 Tab（默认隐藏，可在设置页「主页管理」手动
/// 开启）；「我的」tab（user）与音乐库子页面 tab 整体下线，设置/登录入口
/// 改由各 tab 页右上角用户头像提供。
const List<TabItem> kDefaultTabs = [
  TabItem(id: 'discover', label: '首页'),
  TabItem(id: 'library', label: '音乐库'),
  TabItem(id: 'fm', label: 'FM'),
  TabItem(id: 'search', label: '搜索'),
];

/// 可选 Tab（默认隐藏，需在设置页手动开启）。
///
/// v7 起收藏由默认降级加入本列表；最近播放为原音乐库子页面中保留的可
/// 独立导航项（歌单/专辑/歌手/文件夹/本地收藏已下线）。v8 起「扫描状态」
/// 下线：本地音乐页顶栏扫描钮仍进扫描页，只是不再作为底部 tab 项。
const List<TabItem> kOptionalTabs = [
  TabItem(id: 'favorites', label: '收藏'),
  TabItem(id: 'recognition', label: '听歌识曲'),
  TabItem(id: 'audiobook', label: '听书'),
  TabItem(id: 'settings', label: '设置'),
  TabItem(id: 'recent', label: '最近播放'),
];

/// 所有可用 Tab（默认显示 + 可选，共 9 项；v8 起移除扫描状态）。
const List<TabItem> kAllAvailableTabs = [
  TabItem(id: 'discover', label: '首页'),
  TabItem(id: 'library', label: '音乐库'),
  TabItem(id: 'fm', label: 'FM'),
  TabItem(id: 'search', label: '搜索'),
  TabItem(id: 'favorites', label: '收藏'),
  TabItem(id: 'recognition', label: '听歌识曲'),
  TabItem(id: 'audiobook', label: '听书'),
  TabItem(id: 'settings', label: '设置'),
  TabItem(id: 'recent', label: '最近播放'),
];

/// 管理主页底部导航 Tab 的显示/隐藏和排序。
///
/// 持久化到 SharedPreferences，通过 [SettingsRepository] 读写。
class TabConfigProvider extends ChangeNotifier {
  final SettingsRepository _repo = SettingsRepository();

  /// 当前生效的 tab 列表（已排序、已过滤隐藏项）。
  List<TabItem> _visibleTabs = List.from(kDefaultTabs);

  /// 所有 tab 的完整排序（含隐藏项），用于设置页展示。
  List<TabItem> _allTabs = List.from(kAllAvailableTabs);

  /// 隐藏的 tab id 集合。可选 Tab 默认隐藏。
  Set<String> _hiddenTabs = {
    for (final t in kOptionalTabs) t.id,
  };

  List<TabItem> get visibleTabs => _visibleTabs;
  List<TabItem> get allTabs => _allTabs;
  Set<String> get hiddenTabs => _hiddenTabs;

  TabConfigProvider() {
    _load();
  }

  Future<void> _load() async {
    try {
      final order = await _repo.getTabOrder();
      final hidden = await _repo.getHiddenTabs();
      _hiddenTabs = hidden;

      // 0d5851d 将收藏移入默认 Tab，但旧版本已经把 favorites 持久化在
      // 隐藏集合中；同时本地音乐的默认显示状态也曾在多个版本间切换。
      // v1：恢复这两个默认入口，同时保留用户后续的手动配置。
      // v2（玻璃 Dock 改版）：tab 链收敛为 主页/收藏/我的，library 从
      // 主页 tab 迁出（隐藏），入口收敛到收藏页「本地」tab 与快捷方式。
      // v3/v4/v6：历史版本曾为「我的」（user）维护「收尾」不变量（user
      // 统一排在 order 末位）；v7 起 user 整体下线，这些迁移块已随之
      // 删除（fromVersion < 3/4/6 的用户不再执行任何 user 移位，与原
      // 块的 no-op 分支行为等价）。
      // v5（library 回归默认 Tab）：音乐库（本地音乐）重新进入默认导航，
      // 老用户此前由 v2/v4 迁移写入持久化隐藏集合的 library 由 v5 块统一
      // 移除恢复显示（见下方 v5 块）。
      // v7（默认 Tab 重构）：默认 Tab 收敛为 首页/音乐库/FM/搜索；收藏
      // 降级为可选（默认隐藏）；FM/搜索升级为默认（老用户立即可见）；
      // user 与歌单/专辑/歌手/文件夹/本地收藏下线，持久化中的残留 id
      // 由 v7 块剔除并回写（见下方 v7 块）。
      // v8（移除「扫描状态」Tab）：scan 不再是底部 tab 项（本地音乐页
      // 顶栏扫描钮仍进扫描页），持久化顺序与隐藏集合中的 scan 残留由
      // v8 块剔除并回写（见下方 v8 块）；resetToDefault/_load 默认路径
      // 随 kAllAvailableTabs/kOptionalTabs 不再含 scan。
      final fromVersion = await _repo.getTabConfigMigrationVersion();
      const tabConfigMigrationVersion = 8;
      if (fromVersion < 2) {
        if (fromVersion < 1) {
          _hiddenTabs..remove('favorites')..remove('library');
        }
        // v5：library 已回归默认 Tab，不再在此写回隐藏集合。
        await _repo.setHiddenTabs(_hiddenTabs);
      }

      if (order != null && order.isNotEmpty) {
        // 按持久化顺序重排
        final ordered = <TabItem>[];
        for (final id in order) {
          final tab = kAllAvailableTabs.where((t) => t.id == id).firstOrNull;
          if (tab != null) ordered.add(tab);
        }
        // 补充新增的 tab（版本更新可能新增 tab）。
        // 新增 tab 一律默认隐藏，避免老用户升级后突然多出 Tab；
        // 默认 Tab 升级后保持默认显示。
        // 若用户此前主动打开过（toggleTabVisibility 会写 order 使其
        // 包含该 tab，从而不会走到这个分支），则保持可见。
        for (final tab in kAllAvailableTabs) {
          if (!ordered.any((t) => t.id == tab.id)) {
            ordered.add(tab);
            if (!kDefaultTabs.any((defaultTab) => defaultTab.id == tab.id)) {
              _hiddenTabs.add(tab.id);
            }
          }
        }
        _allTabs = ordered;
      } else {
        // 新用户：使用全部可用 Tab，可选 Tab 默认隐藏
        _allTabs = List.from(kAllAvailableTabs);
        for (final tab in kOptionalTabs) {
          _hiddenTabs.add(tab.id);
        }
      }

      // v5：library 回归默认 Tab。老用户隐藏集合中的 library 由 v2/v4
      // 迁移写入（非用户主动隐藏），统一恢复显示；用户若确不需要，可在
      // 主页管理再次手动隐藏（本块只跑一次，之后的手动开关不受影响）。
      // 条件幂等：library 不在 hidden 集合时无副作用。
      if (fromVersion < 5) {
        _hiddenTabs.remove('library');
      }
      // v7：默认 Tab 重构（首页/音乐库/FM/搜索）。FM/搜索升级为默认——
      // 老用户隐藏集合中的这两个 id 移除，升级后立即可见；收藏降级为
      // 可选——无论此前显示与否，一律加入隐藏集合（老用户可在主页管理
      // 重新开启）。已下线 id（user 与歌单/专辑/歌手/文件夹/本地收藏）
      // 从完整顺序中剔除并回写，同时清理隐藏集合残留。本块只跑一次，
      // 之后的用户操作不受影响；幂等：fm/search 不在隐藏集合、favorites
      // 已隐藏、无已下线 id 时无副作用。
      if (fromVersion < 7) {
        _hiddenTabs..removeAll({'fm', 'search'})..add('favorites');
        _allTabs.removeWhere((t) => kRetiredTabIds.contains(t.id));
        _hiddenTabs.removeAll(kRetiredTabIds);
        await _repo.setTabOrder([for (final t in _allTabs) t.id]);
      }
      // v8：移除「扫描状态」可选 Tab——本地音乐页顶栏扫描钮仍进扫描页，
      // 只是不再作为底部 tab 项。scan 从完整顺序中剔除、从隐藏集合移除
      // 并回写持久化 order。本块只跑一次，之后的用户操作不受影响；幂等：
      // 无 scan 残留时无副作用。
      if (fromVersion < 8) {
        _allTabs.removeWhere((t) => t.id == 'scan');
        _hiddenTabs.remove('scan');
        await _repo.setTabOrder([for (final t in _allTabs) t.id]);
      }
      if (fromVersion < tabConfigMigrationVersion) {
        await _repo.setTabConfigMigrationVersion(tabConfigMigrationVersion);
      }

      _rebuildVisible();
      notifyListeners();
      // 持久化更新后的 hidden，确保新 Tab 的默认隐藏状态被保存
      await _repo.setHiddenTabs(_hiddenTabs);
    } catch (_) {}
  }

  void _rebuildVisible() {
    _visibleTabs = _allTabs.where((t) => !_hiddenTabs.contains(t.id)).toList();
    // 安全检查：至少保留一个 tab
    if (_visibleTabs.isEmpty) {
      _visibleTabs = [_allTabs.last];
    }
  }

  /// 切换某个 tab 的显示/隐藏。
  /// [isRemovable] 为 false 的 tab 不允许隐藏。
  Future<void> toggleTabVisibility(String tabId) async {
    final tab = _allTabs.where((t) => t.id == tabId).firstOrNull;
    if (tab == null || !tab.isRemovable) return;

    if (_hiddenTabs.contains(tabId)) {
      _hiddenTabs.remove(tabId);
      // 显示 tab 时同步持久化顺序：_load() 会把持久化 order 中缺失的
      // tab 当作"新增 tab"重新加回隐藏列表，因此必须让 order 包含该 tab，
      // 否则重启后开关状态被重置。
      await _repo.setTabOrder(_allTabs.map((t) => t.id).toList());
    } else {
      // 不允许隐藏所有可移除 tab（至少保留一个可见）
      final visibleCount =
          _allTabs.where((t) => !_hiddenTabs.contains(t.id)).length;
      if (visibleCount <= 1) return;
      _hiddenTabs.add(tabId);
    }

    _rebuildVisible();
    notifyListeners();
    await _repo.setHiddenTabs(_hiddenTabs);
  }

  /// 拖拽排序：将 [oldIndex] 位置的 tab 移动到 [newIndex]。
  Future<void> reorderTabs(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _allTabs.length) return;
    if (newIndex < 0 || newIndex > _allTabs.length) return;

    final item = _allTabs.removeAt(oldIndex);
    // ReorderableListView 的 newIndex 在向下拖动时需要 -1
    final adjustedIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
    _allTabs.insert(adjustedIndex.clamp(0, _allTabs.length), item);

    _rebuildVisible();
    notifyListeners();
    await _repo.setTabOrder(_allTabs.map((t) => t.id).toList());
  }

  /// 重置为默认配置。
  Future<void> resetToDefault() async {
    _allTabs = List.from(kAllAvailableTabs);
    _hiddenTabs = {
      for (final t in kOptionalTabs) t.id,
    };
    _rebuildVisible();
    notifyListeners();
    await _repo.setTabOrder(kAllAvailableTabs.map((t) => t.id).toList());
    await _repo.setHiddenTabs(_hiddenTabs);
  }

  /// 根据 tab id 获取其在 visibleTabs 中的索引。
  int visibleIndexOf(String tabId) {
    return _visibleTabs.indexWhere((t) => t.id == tabId);
  }
}
