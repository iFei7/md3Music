import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主页 Tab 默认配置测试（v7：默认 Tab = 首页/音乐库/FM/搜索）。
///
/// v7 起收藏由默认降级为可选 Tab（默认隐藏）；「我的」（user）与音乐库
/// 子页面（歌单/专辑/歌手/文件夹/本地收藏）整体下线；老用户经 v7 迁移：
/// fm/search 出隐藏集合（立即可见新默认）、favorites 入隐藏集合
/// （收藏降级）、已下线 id 从持久化顺序/隐藏集合剔除并回写。
void main() {
  /// v7 起下线的 tab id（user + 音乐库子页面，不含保留的 recent/scan）。
  const kRetiredTabIds = {'user', 'playlists', 'albums', 'artists', 'folders', 'local_favorites'};

  /// v7 全部可用 Tab（10 项，按 kAllAvailableTabs 顺序）。
  const kAllTabIds = [
    'discover',
    'library',
    'fm',
    'search',
    'favorites',
    'recognition',
    'audiobook',
    'settings',
    'recent',
    'scan',
  ];

  /// v7 默认可见 Tab（4 项）。
  const kDefaultVisibleIds = ['discover', 'library', 'fm', 'search'];

  /// v7 默认隐藏的可选 Tab（6 项）。
  const kOptionalHiddenIds = [
    'favorites',
    'recognition',
    'audiobook',
    'settings',
    'recent',
    'scan',
  ];

  testWidgets('全新安装：默认 Tab 为 首页/音乐库/FM/搜索，其余可选 Tab 默认隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump(); // 等待异步 _load 完成
    await tester.pump();

    // 可见 Tab 顺序：首页 → 音乐库 → FM → 搜索
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      kDefaultVisibleIds,
      reason: 'v7 起默认 Tab 应为 首页/音乐库/FM/搜索',
    );
    // 收藏/识曲/听书/设置/最近播放/扫描状态默认隐藏
    expect(
      provider.hiddenTabs,
      containsAll(kOptionalHiddenIds),
      reason: '可选 Tab 默认隐藏，需在主页管理手动开启',
    );
    // FM/搜索升级为默认 Tab，不应隐藏
    expect(
      provider.hiddenTabs,
      isNot(contains('fm')),
      reason: 'fm 已升级为默认 Tab，不应隐藏',
    );
    expect(
      provider.hiddenTabs,
      isNot(contains('search')),
      reason: 'search 已升级为默认 Tab，不应隐藏',
    );
    // 收藏由默认降级为可选，不应出现在可见 Tab 中
    expect(
      provider.visibleTabs.map((t) => t.id),
      isNot(contains('favorites')),
      reason: '收藏已降级为可选 Tab，默认隐藏',
    );
    // 全部可用 Tab 恰为 10 项，且不含任何已下线 id
    expect(
      provider.allTabs.map((t) => t.id).toList(),
      kAllTabIds,
      reason: 'v7 全部可用 Tab 应为 10 项且按 kAllAvailableTabs 排序',
    );
    for (final id in kRetiredTabIds) {
      expect(
        provider.allTabs.map((t) => t.id),
        isNot(contains(id)),
        reason: '已下线 tab（$id）不应出现在任何 tab 列表',
      );
    }
  });

  testWidgets('重置默认：恢复 首页/音乐库/FM/搜索，收藏等可选 Tab 默认隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 先把收藏手动开启，再重置，应恢复为默认隐藏
    await provider.toggleTabVisibility('favorites');
    expect(provider.hiddenTabs.contains('favorites'), isFalse, reason: '前置：收藏已手动开启');

    await provider.resetToDefault();
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      kDefaultVisibleIds,
      reason: '重置后默认 Tab 顺序应为 首页/音乐库/FM/搜索',
    );
    expect(
      provider.hiddenTabs,
      containsAll(kOptionalHiddenIds),
      reason: '重置后可选 Tab（含降级的收藏）默认隐藏',
    );
    expect(
      provider.hiddenTabs,
      isNot(contains('fm')),
      reason: '重置后 fm 为默认 Tab，应显示',
    );
    expect(
      provider.hiddenTabs,
      isNot(contains('search')),
      reason: '重置后 search 为默认 Tab，应显示',
    );
    expect(
      provider.allTabs.map((t) => t.id).toList(),
      kAllTabIds,
      reason: '重置后完整列表应为 10 项',
    );
  });

  testWidgets('升级迁移（v0）：收藏降级隐藏、fm/search 可见、已下线 id 被过滤', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_tab_order': ['discover', 'favorites', 'launchpad', 'library', 'user'],
      'settings_hidden_tabs': ['favorites', 'library', 'fm'],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // v1 迁移：favorites/library 曾从隐藏集合恢复；v7 再把收藏降级隐藏
    expect(provider.hiddenTabs.contains('favorites'), isTrue,
        reason: 'v7 起收藏降级为可选 Tab，应隐藏');
    // v5 迁移：library 恢复可见（音乐库为默认 Tab）
    expect(provider.hiddenTabs, isNot(contains('library')));
    expect(provider.visibleIndexOf('library'), greaterThanOrEqualTo(0));
    // v7 迁移：fm 出隐藏集合（升级为默认），立即可见
    expect(provider.hiddenTabs, isNot(contains('fm')),
        reason: 'v7 起 fm 为默认 Tab，老用户迁移后应可见');
    expect(provider.visibleIndexOf('fm'), greaterThanOrEqualTo(0));
    // v1 曾恢复收藏显示，v7 再将其降级隐藏
    expect(provider.hiddenTabs.contains('favorites'), isTrue,
        reason: 'v7 起收藏降级为可选 Tab，应隐藏');
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      kDefaultVisibleIds,
      reason: 'v7 迁移后可见 tab 应为默认四项',
    );
    // launchpad / user 从持久化顺序中被过滤（user 已不在 kAllAvailableTabs）
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('launchpad')),
      reason: 'LaunchPad tab 不应从持久化顺序中恢复',
    );
    for (final id in kRetiredTabIds) {
      expect(
        provider.allTabs.map((t) => t.id),
        isNot(contains(id)),
        reason: '已下线 tab（$id）不应从持久化顺序中恢复',
      );
    }
    // 补充新增 tab：v7 新增的 recognition/audiobook/settings/recent/scan
    // 不在持久化 order 中，一律默认隐藏
    expect(
      provider.hiddenTabs,
      containsAll(['recognition', 'audiobook', 'settings', 'recent', 'scan']),
      reason: '追加的新 tab 一律默认隐藏',
    );
    // 迁移版本已推进到 7（持久化）
    expect(
      await SettingsRepository().getTabConfigMigrationVersion(),
      7,
      reason: 'v7 迁移后版本号应写入 7',
    );
  });

  testWidgets('v6 → v7 升级：fm/search 出隐藏、favorites 入隐藏、已下线 id prune 并回写', (tester) async {
    // 模拟已完成 v6 迁移的老用户持久化状态：order 为 v6 的 16 项
    // （含 user 与音乐库子页面）、隐藏集合为 v6 的 12 个可选 Tab。
    SharedPreferences.setMockInitialValues({
      'settings_tab_config_migration_version': 6,
      'settings_tab_order': [
        'discover',
        'favorites',
        'library',
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
        'playlists',
        'albums',
        'artists',
        'recent',
        'folders',
        'scan',
        'local_favorites',
        'user',
      ],
      'settings_hidden_tabs': [
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
        'playlists',
        'albums',
        'artists',
        'recent',
        'folders',
        'scan',
        'local_favorites',
      ],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 迁移版本推进到 7
    expect(
      await SettingsRepository().getTabConfigMigrationVersion(),
      7,
      reason: 'v6 → v7 升级后版本号应写入 7',
    );
    // fm/search 出隐藏集合（升级为默认 Tab，老用户立即可见）
    expect(
      provider.hiddenTabs,
      isNot(contains('fm')),
      reason: 'v7 迁移应把 fm 移出隐藏集合',
    );
    expect(
      provider.hiddenTabs,
      isNot(contains('search')),
      reason: 'v7 迁移应把 search 移出隐藏集合',
    );
    // favorites 入隐藏集合（收藏降级为可选）
    expect(
      provider.hiddenTabs.contains('favorites'),
      isTrue,
      reason: 'v7 迁移应把 favorites 加入隐藏集合',
    );
    // 已下线 id 从隐藏集合中剔除（保留 recent/scan）
    expect(
      provider.hiddenTabs,
      {'favorites', 'recognition', 'audiobook', 'settings', 'recent', 'scan'},
      reason: 'v7 迁移后隐藏集合应为 6 个可选 Tab（已下线 id 被剔除）',
    );
    // 已下线 id 从完整顺序中剔除并回写
    expect(
      provider.allTabs.map((t) => t.id).toList(),
      [
        'discover',
        'favorites',
        'library',
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
        'recent',
        'scan',
      ],
      reason: 'v7 迁移后完整顺序应为 10 项（user/歌单/专辑/歌手/文件夹/本地收藏被剔除）',
    );
    // 老用户可见集合：默认四项（收藏降级后隐藏）
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      kDefaultVisibleIds,
      reason: 'v7 迁移后可见 tab 应为默认四项',
    );
    // 回写验证：持久化 order 已不含已下线 id
    final persistedOrder = await SettingsRepository().getTabOrder();
    expect(persistedOrder, isNotNull);
    for (final id in kRetiredTabIds) {
      expect(
        persistedOrder,
        isNot(contains(id)),
        reason: '持久化 order 中的已下线 id（$id）应被剔除',
      );
    }
  });

  testWidgets('v6 → v7 升级：老用户已开启的收藏/识曲保持原有显隐语义（favorites 强制降级）', (tester) async {
    // 模拟 v6 老用户：收藏与识曲已手动开启（不在隐藏集合），
    // 且主动开启过已下线的「歌手」tab（order 含 artists）。
    SharedPreferences.setMockInitialValues({
      'settings_tab_config_migration_version': 6,
      'settings_tab_order': [
        'discover',
        'favorites',
        'library',
        'fm',
        'search',
        'recognition',
        'artists',
        'user',
      ],
      'settings_hidden_tabs': ['audiobook', 'settings', 'recent', 'scan'],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 收藏无论此前是否显示，v7 一律降级隐藏
    expect(
      provider.hiddenTabs.contains('favorites'),
      isTrue,
      reason: 'v7 起收藏降级为可选 Tab，老用户已开启也强制隐藏',
    );
    // 识曲不在隐藏集合 → 保持可见（用户手动开启的状态不受迁移影响）
    expect(
      provider.hiddenTabs,
      isNot(contains('recognition')),
      reason: '老用户已开启的识曲保持可见',
    );
    expect(provider.visibleIndexOf('recognition'), greaterThanOrEqualTo(0));
    // 已下线的「歌手」从完整列表消失
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('artists')),
      reason: '已下线 tab（artists）应从完整列表剔除',
    );
    // 可见集合：默认四项 + 识曲
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'library', 'fm', 'search', 'recognition'],
      reason: '可见 tab 为默认四项 + 老用户已开启的识曲',
    );
  });

  testWidgets('v7 幂等：重复加载不改变迁移结果', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_tab_config_migration_version': 7,
      'settings_tab_order': kAllTabIds,
      'settings_hidden_tabs': kOptionalHiddenIds,
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      kDefaultVisibleIds,
      reason: 'v7 持久化状态下可见 tab 应为默认四项',
    );
    expect(
      provider.hiddenTabs,
      containsAll(kOptionalHiddenIds),
      reason: 'v7 持久化状态下可选 Tab 保持隐藏',
    );
    expect(
      provider.allTabs.map((t) => t.id).toList(),
      kAllTabIds,
      reason: 'v7 持久化状态下完整列表保持 10 项',
    );
  });

  testWidgets('v7 新配置可经主页管理手动调整（开关 → 可见 → Dock 数据源）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 收藏默认隐藏（降级）
    expect(provider.hiddenTabs.contains('favorites'), isTrue);
    expect(provider.visibleIndexOf('favorites'), -1);

    // 手动开启后进入可见集合
    await provider.toggleTabVisibility('favorites');
    expect(provider.hiddenTabs, isNot(contains('favorites')));
    expect(provider.visibleIndexOf('favorites'), greaterThanOrEqualTo(0));

    // 再手动隐藏（v7 起所有 Tab 均可移除）
    await provider.toggleTabVisibility('favorites');
    expect(provider.hiddenTabs.contains('favorites'), isTrue);
    expect(provider.visibleIndexOf('favorites'), -1);
  });

  testWidgets('拖拽排序：reorderTabs 调整完整顺序并持久化', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 把 search（索引 3）移到最前（newIndex 0）
    await provider.reorderTabs(3, 0);
    expect(
      provider.allTabs.map((t) => t.id).toList(),
      ['search', 'discover', 'library', 'fm', ...kOptionalHiddenIds],
      reason: 'reorder 后完整顺序应反映拖动结果',
    );
    // 可见顺序同步（search 仍是默认 Tab，保持可见）
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['search', 'discover', 'library', 'fm'],
      reason: '可见顺序应跟随完整顺序',
    );
    // 持久化 order 同步
    final persistedOrder = await SettingsRepository().getTabOrder();
    expect(
      persistedOrder,
      ['search', 'discover', 'library', 'fm', ...kOptionalHiddenIds],
      reason: 'reorder 后应回写持久化 order',
    );
  });
}
