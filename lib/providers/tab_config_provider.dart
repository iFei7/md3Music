import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';

/// 主页 Tab 配置项。
///
/// [id] 唯一标识，[label] 显示名称，[isRemovable] 是否允许隐藏。
/// "我的"页面（user）不允许隐藏，保证用户始终有入口进入设置/登录。
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

/// 默认 Tab 定义（lite 版：主页 / 收藏 / 本地音乐 / 我的，顺序与底部玻璃 Dock 一致）。
///
/// v5 起 library（本地音乐，即音乐库页）回归默认 Tab；私人FM/听书等
/// 仍为可选 Tab、默认隐藏，可在设置页「主页管理」手动开启；收藏页
/// 「本地」tab 与桌面快捷方式入口保持不变。
const List<TabItem> kDefaultTabs = [
  TabItem(id: 'discover', label: '主页'),
  TabItem(id: 'favorites', label: '收藏'),
  TabItem(id: 'library', label: '本地音乐'),
  TabItem(id: 'user', label: '我的', isRemovable: false),
];

/// 可选 Tab（默认隐藏，需在设置页手动开启）。
const List<TabItem> kOptionalTabs = [
  TabItem(id: 'fm', label: '私人FM'),
  TabItem(id: 'search', label: '搜索'),
  TabItem(id: 'recognition', label: '听歌识曲'),
  TabItem(id: 'audiobook', label: '听书'),
  TabItem(id: 'settings', label: '设置'),
];

/// 所有可用 Tab（默认显示 + 可选）。
///
/// 「我的」显式收尾：无论用户开启多少可选 Tab，默认顺序下它都排在最后
/// （老用户由 v3/v4 迁移统一移位，之后仍可自行拖动）。
const List<TabItem> kAllAvailableTabs = [
  TabItem(id: 'discover', label: '主页'),
  TabItem(id: 'favorites', label: '收藏'),
  TabItem(id: 'library', label: '本地音乐'),
  TabItem(id: 'fm', label: '私人FM'),
  TabItem(id: 'search', label: '搜索'),
  TabItem(id: 'recognition', label: '听歌识曲'),
  TabItem(id: 'audiobook', label: '听书'),
  TabItem(id: 'settings', label: '设置'),
  TabItem(id: 'user', label: '我的', isRemovable: false),
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
      // v3（FM/听书回归）：私人FM 与听书重新进入可选 Tab；「我的」统一
      // 收尾（老用户持久化 order 中它可能不在末位）。
      // v4（library 回归可选 Tab）：library 的**默认隐藏**靠下方「补充
      // 新增 tab」的追加逻辑自动完成——不在持久化 order 中的非默认 tab
      // 会被加入 _hiddenTabs（library 本就被 v2 迁移写入隐藏集合），无需
      // 为此升迁移版本；但追加逻辑会把 library 排到持久化 order 末尾，
      // 即「我的」之后，破坏了 v3 建立的「我的收尾」不变量，因此「我的
      // 收尾」的**恢复**需要 v4 迁移（见 v3 段之后的 v4 块）。
      // v5（library 回归默认 Tab）：音乐库（本地音乐）重新进入默认导航，
      // 老用户此前由 v2/v4 迁移写入持久化隐藏集合的 library 由 v5 块统一
      // 移除恢复显示（见 v4 段之后的 v5 块）。
      final fromVersion = await _repo.getTabConfigMigrationVersion();
      const tabConfigMigrationVersion = 5;
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

      // v3：「我的」默认收尾。在 order 重排与新增 tab 追加完成之后执行，
      // 此时 _allTabs 已是最终顺序；仅当 user 确实不在末位时移位并回写，
      // 用户此后的手动拖动不受影响（迁移只跑一次）。
      if (fromVersion < 3) {
        final userIndex = _allTabs.indexWhere((t) => t.id == 'user');
        if (userIndex != -1 && userIndex != _allTabs.length - 1) {
          final userTab = _allTabs.removeAt(userIndex);
          _allTabs.add(userTab);
          await _repo.setTabOrder([for (final t in _allTabs) t.id]);
        }
      }
      // v4：library 恢复可选 Tab 后，「补充新增 tab」的追加逻辑把它排在
      // 持久化 order 末尾——即「我的」之后，破坏了「我的收尾」。与 v3
      // 同法，在追加逻辑完成后把 user 一次性移回末位并回写（用户此后的
      // 手动拖动不受影响）。与 v3 块同构但作用域不同：fromVersion=3 的
      // 用户不再进 v3 块，由本块负责恢复收尾；两块各只跑一次、条件幂等
      // （user 已在末位时不做任何事）。
      if (fromVersion < 4) {
        final userIndex = _allTabs.indexWhere((t) => t.id == 'user');
        if (userIndex != -1 && userIndex != _allTabs.length - 1) {
          final userTab = _allTabs.removeAt(userIndex);
          _allTabs.add(userTab);
          await _repo.setTabOrder([for (final t in _allTabs) t.id]);
        }
      }
      // v5：library 回归默认 Tab。老用户隐藏集合中的 library 由 v2/v4
      // 迁移写入（非用户主动隐藏），统一恢复显示；用户若确不需要，可在
      // 主页管理再次手动隐藏（本块只跑一次，之后的手动开关不受影响）。
      // 条件幂等：library 不在 hidden 集合时无副作用。
      if (fromVersion < 5) {
        _hiddenTabs.remove('library');
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
