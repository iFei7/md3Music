import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/providers/tab_config_provider.dart';

/// 主页 Tab 默认配置测试。
///
/// 需求（v4 迁移后）：默认 Tab 顺序为 发现(discover) → 收藏(favorites) →
/// 我的(user)；本地音乐(library)/私人FM/听书等均为**可选 Tab**，
/// 默认隐藏、需在主页管理中手动开启；已彻底下线的 tab（launchpad）
/// 不应从持久化顺序中恢复。
void main() {
  testWidgets('全新安装：默认 Tab 为 发现/收藏/我的，可选 Tab 默认隐藏', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = TabConfigProvider();
    await tester.pump(); // 等待异步 _load 完成
    await tester.pump();

    // 可见 Tab 顺序：发现 → 收藏 → 我的
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'user'],
      reason: '默认 Tab 顺序应为 发现/收藏/我的',
    );
    // 可选 Tab（本地音乐/FM/听书等）默认隐藏
    expect(
      provider.hiddenTabs,
      containsAll([
        'library',
        'fm',
        'search',
        'recognition',
        'audiobook',
        'settings',
      ]),
      reason: '可选 Tab 默认隐藏，需在主页管理手动开启',
    );
    // LaunchPad 已彻底下线，不应出现在任何 tab 列表
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('launchpad')),
      reason: 'LaunchPad tab 已下线',
    );
  });

  testWidgets('重置默认：恢复 发现/收藏/我的，可选 Tab 默认隐藏', (tester) async {
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
      ['discover', 'favorites', 'user'],
      reason: '重置后默认 Tab 顺序应为 发现/收藏/我的',
    );
    expect(
      provider.hiddenTabs,
      containsAll(['library', 'fm', 'search', 'recognition', 'settings']),
      reason: '重置后可选 Tab 默认隐藏',
    );
  });

  testWidgets('升级迁移：收藏恢复可见，library 保持隐藏且「我的」收尾', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_tab_order': ['discover', 'favorites', 'launchpad', 'library', 'user'],
      'settings_hidden_tabs': ['favorites', 'library', 'fm'],
    });
    final provider = TabConfigProvider();
    await tester.pump();
    await tester.pump();

    // v1 迁移：favorites 从隐藏集合恢复
    expect(provider.visibleIndexOf('favorites'), greaterThanOrEqualTo(0));
    // v4 语义：library 回归可选 Tab，老用户保持隐藏（不突然多出 tab）
    expect(provider.hiddenTabs, contains('library'));
    expect(provider.visibleTabs.map((t) => t.id).toList(), ['discover', 'favorites', 'user']);
    // launchpad 从持久化顺序中被过滤
    expect(
      provider.allTabs.map((t) => t.id),
      isNot(contains('launchpad')),
      reason: 'LaunchPad tab 不应从持久化顺序中恢复',
    );
  });

  testWidgets('旧版本持久化顺序中的已下线 tab（launchpad）被过滤', (tester) async {
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
    // 听书在 v3 后是合法可选 Tab（默认隐藏），应被保留在完整列表中
    expect(
      provider.allTabs.map((t) => t.id),
      contains('audiobook'),
      reason: '听书为可选 Tab，保留在完整列表',
    );
    expect(provider.hiddenTabs, contains('audiobook'));
    expect(provider.hiddenTabs, contains('library'));
    expect(
      provider.visibleTabs.map((t) => t.id).toList(),
      ['discover', 'favorites', 'user'],
      reason: '可见 tab 应只剩默认三项',
    );
  });
}
