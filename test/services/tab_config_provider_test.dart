import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/providers/tab_config_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主页 Tab 默认配置测试。
///
/// 需求（v5 迁移后）：默认 Tab 顺序为 发现(discover) → 收藏(favorites) →
/// 本地音乐(library) → 我的(user)；私人FM/听书等仍为**可选 Tab**，
/// 默认隐藏、需在主页管理中手动开启；已彻底下线的 tab（launchpad）
/// 不应从持久化顺序中恢复；老用户由 v2/v4 迁移写入隐藏集合的 library
/// 由 v5 迁移统一恢复显示。
///
/// v6 起音乐库 9 项子页面中的可独立导航项（歌单/专辑/歌手/最近播放/
/// 文件夹/扫描状态/本地收藏）注册为可选 Tab：默认隐藏，老用户由
/// 「补充新增 tab」追加后经 v6 迁移恢复「我的」收尾。
void main() {
  /// v6 新增的音乐库子页面可选 Tab id。
  const kLibrarySubTabs = [
    'playlists',
    'albums',
    'artists',
    'recent',
    'folders',
    'scan',
    'local_favorites',
  ];

  testWidgets('全新安装：默认 Tab 为 主页/收藏/本地音乐/我的，其余可选 Tab 默认隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump(); // 等待异步 _load 完成
    await tester.pump();

    // 可见 Tab 顺序：主页 → 收藏 → 本地音乐 → 我的
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'user'],
      reason: 'v5 起默认 Tab 应含 library（音乐库），且「我的」收尾',
    );
    // 可选 Tab（FM/搜索/识曲/听书/设置 + v6 音乐库子页面）默认隐藏，
    // library 不再隐藏
    expect(
      provider.hiddenTabs,
      containsAll([
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
        ...kLibrarySubTabs,
      ]),
      reason: '可选 Tab 默认隐藏，需在主页管理手动开启',
    );
    expect(
      provider.hiddenTabs,
      isNot(contains('library')),
      reason: 'library 已回归默认 Tab，不应隐藏',
    );
    // LaunchPad 已彻底下线，不应出现在任何 tab 列表
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('launchpad')),
      reason: 'LaunchPad tab 已下线',
    );
    // v6：音乐库子页面进入完整列表（供主页管理枚举），「我的」仍收尾
    expect(
      provider.allTabs.map((t) => t.id),
      containsAll(kLibrarySubTabs),
      reason: '音乐库子页面应枚举进主页管理',
    );
    expect(
      provider.allTabs.last.id,
      'user',
      reason: '「我的」收尾不变量',
    );
  });

  testWidgets('重置默认：恢复 主页/收藏/本地音乐/我的，其余可选 Tab 默认隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 先把收藏手动隐藏，再重置，应恢复为显示
    await provider.toggleTabVisibility('favorites');
    expect(provider.hiddenTabs.contains('favorites'), isTrue, reason: '前置：收藏已手动隐藏');

    await provider.resetToDefault();
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'user'],
      reason: '重置后默认 Tab 顺序应为 主页/收藏/本地音乐/我的',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['fm', 'search', 'recognition', 'settings', ...kLibrarySubTabs]),
      reason: '重置后可选 Tab 默认隐藏',
    );
    expect(
      provider.hiddenTabs,
      isNot(contains('library')),
      reason: '重置后 library 为默认 Tab，应显示',
    );
  });

  testWidgets('升级迁移（v0）：收藏/library 恢复可见，launchpad 被过滤且「我的」收尾', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_tab_order': ['discover', 'favorites', 'launchpad', 'library', 'user'],
      'settings_hidden_tabs': ['favorites', 'library', 'fm'],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // v1 迁移：favorites 从隐藏集合恢复
    expect(provider.visibleIndexOf('favorites'), greaterThanOrEqualTo(0));
    // v5 迁移：library 恢复可见（音乐库回归默认导航）
    expect(provider.hiddenTabs, isNot(contains('library')));
    expect(provider.visibleIndexOf('library'), greaterThanOrEqualTo(0));
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'user'],
    );
    // launchpad 从持久化顺序中被过滤
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('launchpad')),
      reason: 'LaunchPad tab 不应从持久化顺序中恢复',
    );
    // v6：音乐库子页面由「补充新增 tab」追加后默认隐藏，且「我的」经
    // v6 迁移回到末位（不被追加的新 tab 挤到中间）
    expect(
      provider.allTabs.map((t) => t.id),
      containsAll(kLibrarySubTabs),
      reason: '音乐库子页面应追加进完整列表',
    );
    expect(
      provider.hiddenTabs,
      containsAll(kLibrarySubTabs),
      reason: '追加的新 tab 一律默认隐藏',
    );
    expect(
      provider.allTabs.last.id,
      'user',
      reason: 'v6 迁移后「我的」仍收尾',
    );
  });

  testWidgets('旧版本持久化顺序中的已下线 tab（launchpad）被过滤，已开启可选 tab 保持可见', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_tab_order': [
        'discover',
        'favorites',
        'launchpad',
        'library',
        'audiobook',
        'user',
      ],
      'settings_hidden_tabs': <String>[],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('launchpad')),
      reason: 'LaunchPad tab 不应从持久化顺序中恢复',
    );
    // 听书在持久化 order 中 → 「补充新增 tab」不触发 → 老用户已开启的
    // 可选 tab 保持可见（不会被默认隐藏语义重置）
    expect(
      provider.allTabs.map((t) => t.id),
      contains('audiobook'),
      reason: '听书为可选 Tab，保留在完整列表',
    );
    expect(provider.hiddenTabs, isNot(contains('audiobook')),
        reason: '听书在持久化 order 中，属老用户已开启，保持可见');
    expect(provider.hiddenTabs, isNot(contains('library')),
        reason: 'v5 迁移后 library 为默认 Tab，应显示');
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'audiobook', 'user'],
      reason: '可见 tab 为默认四项 + 老用户已开启的听书',
    );
    // v6 追加的音乐库子页面默认隐藏，不影响已开启的可选 tab
    expect(
      provider.hiddenTabs,
      containsAll(kLibrarySubTabs),
      reason: 'v6 新 tab 默认隐藏',
    );
    expect(
      provider.allTabs.last.id,
      'user',
      reason: 'v6 迁移后「我的」仍收尾',
    );
  });

  testWidgets('v4 → v5 升级：library 从隐藏集合恢复显示，顺序与「我的」收尾不变', (tester) async {
    // 模拟已完成 v4 迁移的老用户持久化状态：library 被写入隐藏集合、
    // order 中 library 已在收藏之后、「我的」收尾。
    SharedPreferences.setMockInitialValues({
      'settings_tab_config_migration_version': 4,
      'settings_tab_order': [
        'discover',
        'favorites',
        'library',
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
        'user',
      ],
      'settings_hidden_tabs': [
        'library',
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
      ],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // v5 迁移：library 恢复显示，其余可选 tab 保持隐藏
    expect(provider.hiddenTabs, isNot(contains('library')),
        reason: 'v5 迁移应恢复 library 显示');
    expect(
      provider.hiddenTabs,
      containsAll(['fm', 'search', 'recognition', 'audiobook', 'settings']),
      reason: '其余可选 Tab 保持隐藏',
    );
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'user'],
      reason: '可见顺序应为 主页/收藏/本地音乐/我的',
    );
    // 持久化 order 未被改动，「我的」收尾不变量保持
    expect(provider.allTabs.last.id, 'user', reason: '「我的」收尾不变量保持');
    // v6 追加的音乐库子页面默认隐藏
    expect(
      provider.hiddenTabs,
      containsAll(kLibrarySubTabs),
      reason: 'v6 新 tab 默认隐藏',
    );
  });

  testWidgets('v5 → v6 升级：音乐库子页面追加为可选 Tab，「我的」收尾恢复', (tester) async {
    // 模拟已完成 v5 迁移的老用户持久化状态：order 为 v5 的 9 项、
    // 「我的」收尾、隐藏集合仅旧可选 Tab（无 library）。
    SharedPreferences.setMockInitialValues({
      'settings_tab_config_migration_version': 5,
      'settings_tab_order': [
        'discover',
        'favorites',
        'library',
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
        'user',
      ],
      'settings_hidden_tabs': [
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
      ],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 迁移版本已推进到 6（持久化）
    expect(
      await SettingsRepository().getTabConfigMigrationVersion(),
      6,
      reason: 'v6 迁移后版本号应写入 6',
    );
    // 音乐库子页面进入完整列表且默认隐藏（「补充新增 tab」语义：
    // 不在持久化 order 中的非默认 tab 一律默认隐藏）
    expect(
      provider.allTabs.map((t) => t.id),
      containsAll(kLibrarySubTabs),
      reason: 'v6 新 tab 应追加进完整列表',
    );
    expect(
      provider.hiddenTabs,
      containsAll(kLibrarySubTabs),
      reason: 'v6 新 tab 一律默认隐藏',
    );
    // 追加逻辑曾把新 tab 排到「我的」之后，v6 迁移把 user 移回末位
    expect(
      provider.allTabs.last.id,
      'user',
      reason: 'v6 迁移应恢复「我的」收尾',
    );
    // 老用户可见集合不变（新 tab 不擅自显示）
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'library', 'user'],
      reason: '可见 tab 不受 v6 迁移影响',
    );
    // 完整顺序：旧 9 项 + 7 个新 tab + 我的收尾
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
        'playlists',
        'albums',
        'artists',
        'recent',
        'folders',
        'scan',
        'local_favorites',
        'user',
      ],
      reason: 'v6 后完整顺序应为旧 9 项 + 音乐库子页面 + 我的收尾',
    );
  });

  testWidgets('v6 新 tab 可经主页管理手动开启（开关 → 可见 → Dock 数据源）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // 默认隐藏
    expect(provider.hiddenTabs.contains('recent'), isTrue);
    expect(provider.visibleIndexOf('recent'), -1);

    // 手动开启后进入可见集合
    await provider.toggleTabVisibility('recent');
    expect(provider.hiddenTabs, isNot(contains('recent')));
    expect(provider.visibleIndexOf('recent'), greaterThanOrEqualTo(0));

    // 再手动隐藏（可移除 tab 允许用户决策去留）
    await provider.toggleTabVisibility('recent');
    expect(provider.hiddenTabs.contains('recent'), isTrue);
    expect(provider.visibleIndexOf('recent'), -1);
  });
}
